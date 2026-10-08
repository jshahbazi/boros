#!/usr/bin/env python3
"""Recall floor for the ordinary retrieval path, checked by scripts/check.py.

Runs `scripts/retrieval_harness.py --cohort regression` into a temporary report
under `.build/`, then compares each arm's case-level R1 and R2 and its turn-level
counts with the committed numbers in `scripts/retrieval_floor.json`. A build that
delivers fewer cases or turns than the floor fails. Arms in the floor but missing
from the run fail; arms in the run but not in the floor are reported only.

The check needs the pinned LongMemEval source and the pinned selected-model
tokenizer, neither of which is committed. When either is unavailable it prints
one skip reason and exits 0 with `"status": "skipped"`, so check.py still runs
elsewhere. A skip is not a pass: it reports zero checks run.

Output is metadata only: arm names, counts and fixed reason strings. No source
text, question, answer or history content is read into this script's output.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import retrieval_harness as harness  # noqa: E402

FLOOR_PATH = ROOT / "scripts/retrieval_floor.json"
COHORT = "regression"
WORKERS = 3
HARNESS_TIMEOUT = 1800
# Each floor entry is a minimum count; the report key and field it is read from.
MEASURES = {
    "r1_cases": ("r1_candidate_recall", "passed"),
    "r2_cases": ("r2_delivered_recall", "passed"),
    "r1_turns": ("turn_candidate", "passed"),
    "r2_turns": ("turn_delivered_whole", "passed"),
}


class FloorError(Exception):
    """Carries only fixed host-authored reason strings."""


def unavailable_reason(dataset: Path, tokenizer: Path, expected_sha256: str, tokenizers_importable: bool):
    """One-line reason the pinned inputs are missing, or None when the check can run."""
    if not dataset.is_file():
        return "pinned LongMemEval S dataset not found; fetch it into .build/datasets to enable the floor"
    if not tokenizer.is_file():
        return "pinned selected-model tokenizer.json not found; install the model to enable the floor"
    if hashlib.sha256(tokenizer.read_bytes()).hexdigest() != expected_sha256:
        return "tokenizer.json present but does not match the pinned SHA-256; the pinned tokenizer is unavailable"
    if not tokenizers_importable:
        return "python package 'tokenizers' is not installed; install it to enable the floor"
    return None


def load_floor(path: Path):
    try:
        floor = json.loads(path.read_text())
    except (OSError, ValueError):
        raise FloorError("floor file missing or not valid JSON")
    if not (isinstance(floor, dict) and isinstance(floor.get("manifest_sha256"), str)
            and isinstance(floor.get("arms"), dict) and floor["arms"]
            and all(isinstance(floor.get(key), int) for key in ("eligible_cases", "eligible_turns"))):
        raise FloorError("floor file has an unexpected shape")
    for values in floor["arms"].values():
        if not (isinstance(values, dict) and set(values) == set(MEASURES)
                and all(isinstance(number, int) and not isinstance(number, bool) and number >= 0
                        for number in values.values())):
            raise FloorError("floor file has an unexpected arm entry")
    return floor


def measured(report):
    """Arm -> {measure: passed} plus denominators and manifest hash, from a harness report."""
    try:
        summary = report["summary"]
        arms = {}
        denominators = {}
        for arm, values in summary["arms"].items():
            arms[arm] = {name: int(values[key][field]) for name, (key, field) in MEASURES.items()}
            denominators[arm] = {"cases": int(values["r2_delivered_recall"]["cases"]),
                                 "turns": int(values["turn_delivered_whole"]["cases"])}
        return {"manifest_sha256": report["cohort"]["manifest_sha256"], "arms": arms, "denominators": denominators}
    except (KeyError, TypeError, ValueError):
        raise FloorError("harness report has an unexpected shape")


def compare(floor, run):
    """Compare a run with the floor. Returns checks run, failed check names and notes."""
    failed, notes, checks = [], [], 0
    checks += 1
    if run["manifest_sha256"] != floor["manifest_sha256"]:
        failed.append("manifest_sha256")
        notes.append("cohort manifest hash differs from the floor; the floor must be re-recorded for the new cohort")
    for arm, minimums in sorted(floor["arms"].items()):
        if arm not in run["arms"]:
            checks += 1
            failed.append(f"{arm}.missing_arm")
            continue
        denominator = run["denominators"][arm]
        for label, expected, actual in (("eligible_cases", floor["eligible_cases"], denominator["cases"]),
                                        ("eligible_turns", floor["eligible_turns"], denominator["turns"])):
            checks += 1
            if expected != actual:
                failed.append(f"{arm}.{label}")
                notes.append(f"{arm}: {label} is {actual}, floor was recorded at {expected}")
        for name in MEASURES:
            checks += 1
            if run["arms"][arm][name] < minimums[name]:
                failed.append(f"{arm}.{name}")
                notes.append(f"{arm}: {name} is {run['arms'][arm][name]}, floor is {minimums[name]}")
    for arm in sorted(set(run["arms"]) - set(floor["arms"])):
        notes.append(f"{arm}: arm has no floor entry (reported, not failed): "
                     + ", ".join(f"{name}={number}" for name, number in run["arms"][arm].items()))
    return checks, failed, notes


def run_harness(output: Path, source: Path, tokenizer: Path):
    command = [sys.executable, str(ROOT / "scripts/retrieval_harness.py"), "--cohort", COHORT,
               "--workers", str(WORKERS), "--source", str(source), "--tokenizer", str(tokenizer),
               "--parity-sample", "0", "--output", str(output)]
    try:
        process = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=HARNESS_TIMEOUT)
    except subprocess.TimeoutExpired:
        raise FloorError("harness timed out")
    if process.returncode:
        last = (process.stderr.strip().splitlines() or ["no message"])[-1][:200]
        raise FloorError(f"harness exited {process.returncode}: {last}")
    try:
        return json.loads(output.read_text())
    except (OSError, ValueError):
        raise FloorError("harness wrote no readable report")


def lowered(old, new):
    """Names of floor numbers a rewrite would lower."""
    names = [key for key in ("eligible_cases", "eligible_turns") if new[key] < old[key]]
    for arm, minimums in old["arms"].items():
        for name, number in minimums.items():
            if new["arms"].get(arm, {}).get(name, -1) < number:
                names.append(f"{arm}.{name}")
    return names


def floor_from_run(run):
    denominators = next(iter(run["denominators"].values()))
    return {"cohort": COHORT, "manifest_sha256": run["manifest_sha256"],
            "eligible_cases": denominators["cases"], "eligible_turns": denominators["turns"],
            "arms": {arm: dict(values) for arm, values in sorted(run["arms"].items())}}


def importable(name):
    try:
        __import__(name)
        return True
    except ImportError:
        return False


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--floor", type=Path, default=FLOOR_PATH)
    parser.add_argument("--update", action="store_true",
                        help="Rewrite the floor file from this run instead of checking it")
    parser.add_argument("--allow-lower", action="store_true", help="With --update, permit lowering existing numbers")
    args = parser.parse_args(argv)
    report = {"suite": "retrieval-floor", "checks": 0, "failed": [], "errors": [], "skipped": 0, "status": "passed"}

    source = harness.default_source()
    tokenizer = harness.DEFAULT_TOKENIZER
    reason = unavailable_reason(source, tokenizer, harness.TOKENIZER_SHA256, importable("tokenizers"))
    if reason:
        report.update(status="skipped", skipped=1, skip_reason=reason)
        print(json.dumps(report))
        return 0
    try:
        floor = None if args.update and not args.floor.exists() else load_floor(args.floor)
        scratch_parent = ROOT / ".build"
        scratch_parent.mkdir(mode=0o700, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="retrieval-floor-", dir=scratch_parent) as directory:
            run = measured(run_harness(Path(directory) / "report.json", source, tokenizer))
        if args.update:
            new = floor_from_run(run)
            drops = lowered(floor, new) if floor else []
            if drops and not args.allow_lower:
                raise FloorError("update would lower: " + ", ".join(drops) + "; pass --allow-lower to record it")
            args.floor.write_text(json.dumps(new, indent=2, sort_keys=True) + "\n")
            report.update(status="updated")
        else:
            checks, failed, notes = compare(floor, run)
            report.update(checks=checks, failed=failed)
            if notes:
                report["notes"] = notes
            if failed:
                report["status"] = "failed"
    except FloorError as error:
        report.update(status="error", errors=[str(error)])
    print(json.dumps(report))
    return 1 if report["failed"] or report["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
