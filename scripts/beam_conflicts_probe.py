#!/usr/bin/env python3
"""The conflicts sentence on the BEAM cohort's contradiction questions (docs/PRESENTATION-PROBES.md, item 3c).

A small adapter over the 100-question BEAM cohort of ``beam_cohort.py`` (read-only; the cohort directory of
another worktree is read and never written). It takes the captured ``exchange_packed`` V4-advice request of
every ``contradiction_resolution`` question, applies the ``conflicts`` presentation of
``exchange_packed_answers.py`` (one System sentence; every other byte unchanged), answers each three times
with Gemini 3.8 Flash under the cohort's reader settings, grades the answers with OptChat's
``beam-native-grader-1`` request as ported in ``beam_exchange_packed.py`` (three replicates, majority), and
reports the per-question correct rate beside the cohort run's recorded ``ordinary_send`` rate for the same
questions. The baseline answers are the cohort run's, not regenerated here, so this is a before/after on
one grader, not a comparison paired within one run; it is the rule's target, measured cheaply.

Commands: ``declare`` (free: derives the bodies, counts tokens, freezes the jobs and cap), ``run`` (paid),
``grade`` (paid), ``score``.

Privacy: request bodies, answers and grades stay in the private output directory (0700 directories, 0600
files) and are never printed. stdout carries counts, hashes, labels and fixed codes only.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from decimal import Decimal
import json
from pathlib import Path
import sys
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import answer_presentation_replay as replay  # noqa: E402
import beam_exchange_packed as beam  # noqa: E402
import exchange_packed_answers as epa  # noqa: E402
import reader_comparison as rc  # noqa: E402
import vertex_anthropic as va  # noqa: E402
import vertex_gemini as vg  # noqa: E402

ROOT = replay.ROOT
VERSION = "beam-conflicts-probe-v1"
READER = "gemini-3.8-flash"
THINKING_LEVEL = "low"
THINKING_ALLOWANCE = 2048
CATEGORY = "contradiction_resolution"
SOURCE_ARM = "exchange_packed"
ARM = "exchange_packed_conflicts"
REPLICATES = 3
WORKERS = 4
PRICING = va.Pricing("1.50", "7.50")


class ProbeError(Exception):
    pass


def require(condition, code):
    if not condition:
        raise ProbeError(code)


def now():
    return datetime.now(timezone.utc).isoformat()


def cohort_questions(cohort: Path):
    """label -> grader question of every contradiction question, from the cohort's case files (read-only)."""
    manifest = json.loads((cohort / "cohort.json").read_text())
    out, hashes = {}, {}
    for conversation in manifest["conversations"]:
        raw = (cohort / "cohort" / conversation["case_file"]).read_bytes()
        require(replay.digest(raw) == conversation["case_sha256"], "case_changed")
        hashes[conversation["case_file"]] = conversation["case_sha256"]
        for question in json.loads(raw)["questions"]:
            if question["category"] == CATEGORY:
                out[beam.label_of(question["id"])] = question
    return out, hashes, replay.digest((cohort / "cohort.json").read_bytes())


def declare(args):
    output, cohort = args.output.absolute(), args.cohort.absolute()
    require(output.is_relative_to(ROOT / ".build") and not output.exists(), "output_invalid")
    captures = json.loads((cohort / "captures.json").read_text())
    rows = [row for row in captures["rows"] if row["category"] == CATEGORY and row["arm"] == SOURCE_ARM]
    questions, case_hashes, cohort_sha256 = cohort_questions(cohort)
    require(rows and {row["label"] for row in rows} == set(questions), "cohort_rows_mismatch")
    replay.private_directory(output)
    requests = output / "requests"
    replay.private_directory(requests)
    token = va.AccessTokens()
    jobs, derived_rows, worst = [], [], 0
    for row in sorted(rows, key=lambda value: value["label"]):
        raw = (cohort / "requests" / row["label"] / (SOURCE_ARM + ".request.json")).read_bytes()
        require(replay.digest(raw) == row["request_sha256"], "source_body_changed")
        body = json.loads(raw)
        messages = rc.request_messages(raw)
        derived_messages, _meta = epa.present("conflicts", messages, {"context_framing": row["context_framing"]})
        require(derived_messages[1:] == messages[1:], "transform_touched_other_messages")
        derived = json.dumps(dict(body, messages=derived_messages), ensure_ascii=False, sort_keys=True,
                             separators=(",", ":")).encode()
        directory = requests / row["label"]
        replay.private_directory(directory)
        replay.private_write(directory / (ARM + ".request.json"), derived)
        url, count_body = vg.count_url(READER), vg.count_payload(derived_messages)
        input_tokens = vg.parse_count(vg.post(url, count_body, token()))
        limit = row["maximum_output"] + THINKING_ALLOWANCE
        derived_rows.append({"label": row["label"], "gold_delivery": row["gold_delivery"], "maximum_output": row["maximum_output"],
                             "source_request_sha256": row["request_sha256"], "request_sha256": replay.digest(derived),
                             "input_tokens": input_tokens, "output_limit": limit, "context_framing": epa.CONFLICTS_FRAMING})
        for replicate in range(REPLICATES):
            jobs.append({"label": row["label"], "replicate": replicate})
            worst += PRICING.microusd(input_tokens, limit)
    grade_worst = sum(PRICING.microusd(4_000, beam.GRADE_OUTPUT_TOKENS) for _ in jobs) * REPLICATES
    document = {"version": VERSION, "declared_at_utc": now(), "authorization": args.authorization,
                "purpose": "the conflicts sentence on the BEAM cohort's contradiction questions, graded by the cohort's grader "
                           "request, against the cohort run's recorded ordinary_send rate",
                "cohort": {"path_name": cohort.name, "cohort_sha256": cohort_sha256, "case_sha256": case_hashes,
                           "captures_sha256": replay.digest((cohort / "captures.json").read_bytes()),
                           "baseline_score_path": str(args.baseline_score.absolute()) if args.baseline_score else None},
                "rows": derived_rows, "jobs": jobs, "replicates": REPLICATES,
                "reader": {"model": READER, "configuration": vg.configuration(READER, THINKING_LEVEL),
                           "thinking_allowance": THINKING_ALLOWANCE, "pricing": PRICING.declaration()},
                "grader": {"version": beam.GRADER_VERSION, "model": READER, "output_tokens": beam.GRADE_OUTPUT_TOKENS,
                           "replicates": REPLICATES, "vote": "majority of three on `correct`; fewer than two valid agreeing "
                           "replicates is unknown (not correct)", "calibration": "not run here; the cohort run calibrated the "
                           "same request on the same model the same day (docs of that run)"},
                "worst_case_usd": {"answers": str(Decimal(worst) / 10**6), "grades": str(Decimal(grade_worst) / 10**6)},
                "spending_cap_usd": str(args.cap_usd),
                "sentence_sha256": replay.digest(epa.CONFLICTS_SENTENCE.encode()),
                "drivers": {name: replay.digest((ROOT / "scripts" / name).read_bytes())
                            for name in ("beam_conflicts_probe.py", "exchange_packed_answers.py", "beam_exchange_packed.py",
                                         "vertex_gemini.py")},
                "build_commit": replay.git("rev-parse", "HEAD")}
    require(Decimal(worst + grade_worst) / 10**6 <= Decimal(str(args.cap_usd)), "worst_case_exceeds_cap")
    replay.private_write(output / "declaration.json", replay.canonical(document) + b"\n")
    replay.private_write(output / "ledger.jsonl", b"")
    print(json.dumps({"questions": len(derived_rows), "jobs": len(jobs), "worst_case_usd": document["worst_case_usd"],
                      "cap_usd": str(args.cap_usd), "input_tokens_median": sorted(r["input_tokens"] for r in derived_rows)[len(derived_rows) // 2],
                      "declaration_sha256": replay.digest((output / "declaration.json").read_bytes())}))


def load(output: Path):
    declaration = json.loads((output / "declaration.json").read_text())
    require(declaration.get("version") == VERSION, "declaration_version")
    for name, value in declaration["drivers"].items():
        require(replay.digest((ROOT / "scripts" / name).read_bytes()) == value, "driver_changed")
    return declaration


def finished(ledger: Path):
    out = {}
    for line in ledger.read_text().splitlines():
        record = json.loads(line)
        if record.get("state") == "finished":
            out[record["job"]] = record
    return out


def dispatch(output: Path, ledger_name: str, jobs, prepare, store, cap_usd):
    """Cap-checked concurrent dispatch to Vertex; the same rule as exchange_packed_answers.run."""
    ledger = output / ledger_name
    if not ledger.exists():
        replay.private_write(ledger, b"")
    done = finished(ledger)
    cap = Decimal(str(cap_usd)) * 10**6
    lock = threading.Lock()
    token = va.AccessTokens()
    state = {"spent": sum(r.get("microusd") or 0 for r in done.values()), "stopped": None}

    def append(record):
        with open(ledger, "a") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")

    def work(index):
        messages, limit, worst = prepare(index)
        with lock:
            if state["stopped"] or state["spent"] + worst > cap:
                state["stopped"] = state["stopped"] or "cap_reached"
                return
            state["spent"] += worst
            append({"job": index, "state": "started", "at": now()})
        url, body = vg.generation_url(READER), vg.payload(messages, limit, thinking_level=THINKING_LEVEL)
        failure, raw, tries = None, None, 0
        while True:
            tries += 1
            try:
                raw = vg.post(url, body, token())
                failure = None
            except va.VertexError as error:
                failure = str(error)
            if failure in rc.RETRYABLE and tries <= len(rc.RETRY_DELAYS):
                time.sleep(rc.RETRY_DELAYS[tries - 1])
                continue
            break
        record = {"job": index, "state": "finished", **jobs[index], "tries": tries, "at": now(), "failure": failure}
        microusd = 0
        if raw is not None:
            text, usage, stop, failure = rc.parse(READER, raw)
            record.update(stop_reason=stop, failure=failure)
            if usage is not None:
                microusd = PRICING.microusd(usage["input_tokens"], usage["output_tokens"])
                record.update(input_tokens=usage["input_tokens"], output_tokens=usage["output_tokens"])
            store(index, raw, text, record)
        record["microusd"] = microusd
        with lock:
            state["spent"] += microusd - worst
            append(record)
        print(json.dumps({key: record.get(key) for key in ("job", "label", "replicate", "failure", "microusd")}), flush=True)

    pending = [index for index in range(len(jobs)) if index not in done]
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        list(pool.map(work, pending))
    records = finished(ledger)
    return {"finished": len(records), "jobs": len(jobs), "stopped": state["stopped"],
            "spent_usd_declared_rate": str(Decimal(sum(r.get("microusd") or 0 for r in records.values())) / 10**6),
            "failures": sum(1 for r in records.values() if r.get("failure") not in (None, "incomplete_result"))}


def run(args):
    output = args.output.absolute()
    declaration = load(output)
    rows = {row["label"]: row for row in declaration["rows"]}
    answers = output / "answers"
    if not answers.exists():
        replay.private_directory(answers)

    def prepare(index):
        job = declaration["jobs"][index]
        row = rows[job["label"]]
        raw = (output / "requests" / job["label"] / (ARM + ".request.json")).read_bytes()
        require(replay.digest(raw) == row["request_sha256"], "request_changed")
        return rc.request_messages(raw), row["output_limit"], PRICING.microusd(row["input_tokens"], row["output_limit"])

    def store(index, raw, text, record):
        job = declaration["jobs"][index]
        name = f"{job['label']}--r{job['replicate']}"
        replay.private_write(answers / (name + ".response.json"), raw)
        if text is not None:
            replay.private_write(answers / (name + ".txt"), text.encode())
            record["answer_sha256"] = replay.digest(text.encode())

    print(json.dumps(dispatch(output, "ledger.jsonl", declaration["jobs"], prepare, store, declaration["spending_cap_usd"])))


def grade(args):
    output, cohort = args.output.absolute(), args.cohort.absolute()
    declaration = load(output)
    questions, _hashes, cohort_sha256 = cohort_questions(cohort)
    require(cohort_sha256 == declaration["cohort"]["cohort_sha256"], "cohort_changed")
    records = finished(output / "ledger.jsonl")
    items = []
    for index, job in enumerate(declaration["jobs"]):
        record = records.get(index)
        path = output / "answers" / f"{job['label']}--r{job['replicate']}.txt"
        if not record or not path.exists():
            continue
        text = path.read_text()
        require(replay.digest(text.encode()) == record.get("answer_sha256"), "answer_changed")
        for replicate in range(REPLICATES):
            items.append({"label": job["label"], "answer_replicate": job["replicate"], "replicate": replicate,
                          "candidate_sha256": replay.digest(text.encode())})
    grades = output / "grades"
    if not grades.exists():
        replay.private_directory(grades)

    def prepare(index):
        item = items[index]
        text = (output / "answers" / f"{item['label']}--r{item['answer_replicate']}.txt").read_text()
        messages = beam.grade_messages(questions[item["label"]], text)
        return messages, beam.GRADE_OUTPUT_TOKENS, PRICING.microusd(4_000, beam.GRADE_OUTPUT_TOKENS)

    def store(index, raw, text, record):
        item = items[index]
        replay.private_write(grades / f"{item['label']}--a{item['answer_replicate']}--g{item['replicate']}.response.json", raw)
        verdict = beam.parse_verdict(text) if text is not None else None
        if verdict is not None and verdict["grounded"] is not None:
            verdict, record["failure"] = None, record["failure"] or "UNEXPECTED_GROUNDING_SCORE"
        record["verdict"] = verdict
        if verdict is None and record["failure"] is None:
            record["failure"] = "GRADER_FORMAT"

    print(json.dumps(dispatch(output, "grade-ledger.jsonl", items, prepare, store, declaration["spending_cap_usd"])))


def score(args):
    output = args.output.absolute()
    declaration = load(output)
    baseline = {}
    if declaration["cohort"]["baseline_score_path"]:
        prior = json.loads(Path(declaration["cohort"]["baseline_score_path"]).read_text())
        baseline = {label: value.get("ordinary_send") for label, value in prior["per_question"].items()}
    votes = {}
    for record in finished(output / "grade-ledger.jsonl").values():
        votes.setdefault((record["label"], record["answer_replicate"]), []).append(record.get("verdict"))
    per_question = {}
    for row in declaration["rows"]:
        correct = 0
        for replicate in range(REPLICATES):
            vote = beam.majority(votes.get((row["label"], replicate), []))
            correct += 1 if vote is True else 0
        per_question[row["label"]] = {"gold_delivery": row["gold_delivery"], "conflicts": correct / REPLICATES,
                                      "ordinary_send_cohort_run": baseline.get(row["label"])}
    rate = sum(v["conflicts"] for v in per_question.values()) / len(per_question)
    base_rate = (sum(v["ordinary_send_cohort_run"] or 0 for v in per_question.values()) / len(per_question)) if baseline else None
    document = {"version": VERSION, "kind": "beam-conflicts-score", "recorded_at_utc": now(), "per_question": per_question,
                "conflicts_percent": round(100 * rate, 1), "ordinary_send_cohort_run_percent": round(100 * base_rate, 1) if base_rate is not None else None,
                "questions": len(per_question), "better": sum(1 for v in per_question.values() if (v["ordinary_send_cohort_run"] or 0) < v["conflicts"]),
                "worse": sum(1 for v in per_question.values() if (v["ordinary_send_cohort_run"] or 0) > v["conflicts"]),
                "note": "before/after on one grader; the baseline answers are the cohort run's, not regenerated here"}
    replay.private_write(output / "score.json", replay.canonical(document) + b"\n")
    print(json.dumps({key: document[key] for key in ("questions", "conflicts_percent", "ordinary_send_cohort_run_percent", "better", "worse", "per_question")}, indent=1))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("declare", "run", "grade", "score"):
        command = commands.add_parser(name)
        command.add_argument("--output", type=Path, required=True)
        if name in ("declare", "grade"):
            command.add_argument("--cohort", type=Path, required=True, help="the BEAM cohort output directory (read-only)")
        if name == "declare":
            command.add_argument("--baseline-score", type=Path, default=None, help="the cohort run's score.json for ordinary_send")
            command.add_argument("--cap-usd", type=float, required=True)
            command.add_argument("--authorization", required=True)
    args = parser.parse_args(argv)
    try:
        {"declare": declare, "run": run, "grade": grade, "score": score}[args.command](args)
    except (ProbeError, rc.ComparisonError, va.VertexError, replay.ReplayError, epa.EvaluationError, beam.BeamError) as error:
        print(json.dumps({"error": str(error)}))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
