#!/usr/bin/env python3
"""P2 latency diagnostic for the explicit exchange policies on the public synthetic scaling corpus.

It generates the deterministic development scaling fixture, compiles every application source except the app
entry point with Tests/Evaluation/ExchangeLatencyHarness.swift, and runs a warm profile (ingest, then probes) and a
restart profile (reopen, then probes) per scale. No model server, tokenizer or provider is involved. Output is
metadata only: counts, statuses and timings. Token counting and admission are not part of the measured path.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from evaluation_fixtures import canonical_json, generate  # noqa: E402

SCALES = (1000, 10000, 100000)
HARNESS = "Tests/Evaluation/ExchangeLatencyHarness.swift"
POLICIES = ("recent_only", "exchange_adjacent", "exchange_packed")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def compile_harness(output: Path) -> tuple[Path, dict]:
    sources = sorted(p for p in (ROOT / "Sources/Boros").glob("*.swift") if p.name != "BonsaiPlayground.swift")
    files = [*sources, ROOT / HARNESS]
    hashes = {str(p.relative_to(ROOT)): digest(p.read_bytes()) for p in files}
    binary = output / "exchange-latency"
    command = ["/usr/bin/swiftc", "-O", "-swift-version", "5", "-parse-as-library", "-target", "arm64-apple-macos14.0",
               "-framework", "AppKit", "-framework", "Foundation", "-framework", "Security",
               "-framework", "LocalAuthentication", "-framework", "NaturalLanguage",
               "-I", str(ROOT / "Sources/CSQLite"), "-lsqlite3", "-o", str(binary), *map(str, files)]
    process = subprocess.run(command, capture_output=True, timeout=1200)
    if process.returncode:
        raise SystemExit("Compilation failed; diagnostics withheld.")
    revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    dirty = bool(subprocess.run(["git", "status", "--porcelain", "--", "Sources", "Tests", "scripts"], cwd=ROOT,
                                capture_output=True, text=True).stdout.strip())
    return binary, {"git_revision": revision, "working_tree_modified": dirty, "build_sha256": digest(canonical_json(hashes)),
                    "binary_sha256": digest(binary.read_bytes())}


def distribution(values):
    values = sorted(v for v in values if isinstance(v, (int, float)))
    if not values:
        return None
    pick = lambda q: values[min(len(values) - 1, max(0, int(round(q * (len(values) - 1)))))]
    return {"n": len(values), "p50": round(pick(0.5), 3), "p95": round(pick(0.95), 3), "max": round(values[-1], 3)}


def summarize(raw: dict) -> dict:
    probes = raw["probes"]
    result = {"event_count": raw["event_count"], "source_bytes": raw["source_bytes"],
              "store_open_milliseconds": raw["store_open_milliseconds"], "ingestion_milliseconds": raw["ingestion_milliseconds"],
              "limits": raw["limits"], "policies": {}}
    for name in POLICIES:
        rows = [probe[name] for probe in probes]
        statuses = {}
        for row in rows:
            statuses[row.get("status", "recent_only")] = statuses.get(row.get("status", "recent_only"), 0) + 1
        entry = {"recent_milliseconds": distribution([row["recent_milliseconds"] for row in rows]), "statuses": statuses}
        if name != "recent_only":
            entry["evidence_milliseconds"] = distribution([row.get("evidence_milliseconds") for row in rows])
            entry["memory_path_milliseconds"] = distribution([row["recent_milliseconds"] + row.get("evidence_milliseconds", 0) for row in rows])
            entry["indexed_source_count"] = distribution([row.get("indexed_source_count") for row in rows])
        result["policies"][name] = entry
    stages = [probe["uncapped_stages"] for probe in probes]
    result["uncapped_stages"] = {key: distribution([stage[key] for stage in stages]) for key in stages[0]}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--output-directory", type=Path, required=True)
    parser.add_argument("--scales", type=int, nargs="+", default=list(SCALES), choices=SCALES)
    args = parser.parse_args()
    output = args.output_directory.absolute()
    if output.exists() or not str(output.resolve()).startswith(str((ROOT / ".build").resolve())):
        raise SystemExit("Output directory must be new and under this checkout's .build.")
    output.mkdir(parents=True, mode=0o700)
    binary, implementation = compile_harness(output)
    report = {"version": "boros-exchange-latency-v1", "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
              "implementation": implementation, "policies": list(POLICIES), "scales": {},
              "limitations": ["one synthetic history per scale; nine probes per profile", "token counting, admission and generation excluded",
                              "probes run sequentially in one process; operating-system cache uncontrolled after restart",
                              "uncapped stages are a diagnostic without lease or snapshot cap, not a shipped path"]}
    for scale in args.scales:
        directory = output / str(scale)
        runtime = directory / "runtime"
        runtime.mkdir(parents=True)
        fixtures = directory / "fixtures.json"
        fixtures.write_bytes(canonical_json(generate("development", scale_events=scale)))
        report["scales"][str(scale)] = {"fixture_sha256": digest(fixtures.read_bytes())}
        for mode in ("warm", "restart"):
            raw_path = directory / (mode + ".json")
            started = time.monotonic()
            process = subprocess.run([str(binary), mode, str(fixtures), str(runtime), str(raw_path)], capture_output=True, timeout=1800)
            wall = round(time.monotonic() - started, 3)
            if process.returncode or not raw_path.exists():
                report["scales"][str(scale)][mode] = {"status": "failed", "wall_seconds": wall}
                break
            report["scales"][str(scale)][mode] = summarize(json.loads(raw_path.read_bytes())) | {"wall_seconds": wall}
        shutil.rmtree(runtime, ignore_errors=True)
        fixtures.unlink()
    (output / "report.json").write_bytes(canonical_json(report) + b"\n")
    for scale, value in report["scales"].items():
        for mode in ("warm", "restart"):
            entry = value.get(mode) or {}
            print(json.dumps({"scale": scale, "mode": mode, "policies": {name: {k: entry["policies"][name].get(k) for k in (
                "statuses", "memory_path_milliseconds", "evidence_milliseconds")} for name in POLICIES} if "policies" in entry else entry,
                "uncapped_total": (entry.get("uncapped_stages") or {}).get("total_milliseconds")}, sort_keys=True))
    print("Metadata-only report: " + str(output / "report.json"))


if __name__ == "__main__":
    main()
