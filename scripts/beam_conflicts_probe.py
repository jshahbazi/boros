#!/usr/bin/env python3
"""The gated conflicts sentence on BEAM contradiction questions, paired against a fresh baseline (docs/CONFLICT-DETECTOR.md).

A driver over a BEAM cohort directory built by ``beam_cohort.py`` (read-only; the other worktree's cohort is read
and never written). For every ``contradiction_resolution`` question it takes the captured ``exchange_packed``
V4-advice request as the baseline body and derives the candidate with the ``conflicts-gated`` presentation of
``exchange_packed_answers.py``: the conflicts sentence when the lexical conflict detector fires, otherwise a
byte-identical body. Both arms are answered fresh, three replicates each, with Gemini 3.8 Flash under the
cohort's reader settings; a question whose candidate is unchanged takes the baseline's answers (a tie by
construction). Answers are graded with OptChat's ``beam-native-grader-1`` request as ported in
``beam_exchange_packed.py`` (three replicates, majority), with that request's calibration controls, and scored
paired: D is the candidate's mean per-question correct rate minus the baseline's, with a seeded 10,000-resample
bootstrap percentile interval, against the threshold the declaration records.

Version 1 of this driver (October 13, earlier) answered the ungated sentence alone against the cohort run's
recorded baseline; that record stands in docs/FOUR-ARM-PAIRED-RUN.md.

Commands: ``declare`` (free: derives the bodies, runs the detector, counts tokens, freezes the jobs, cap and rule),
``run`` (paid), ``grade`` (paid), ``score``.

Privacy: request bodies, answers and grades stay in the private output directory (0700 directories, 0600
files) and are never printed. stdout carries counts, hashes, labels and fixed codes only.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from decimal import Decimal
import json
import math
from pathlib import Path
import random
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
VERSION = "beam-conflicts-paired-v1"
READER = "gemini-3.8-flash"
THINKING_LEVEL = "low"
THINKING_ALLOWANCE = 2048
CATEGORY = "contradiction_resolution"
BASELINE = "exchange_packed"
CANDIDATE = "exchange_packed_conflicts_gated"
ARMS = (BASELINE, CANDIDATE)
REPLICATES = 3
WORKERS = 4
BOOTSTRAP_RESAMPLES = 10000
PRICING = va.Pricing("1.50", "7.50")
# Grade requests hold the question, reference, rubric, native object and candidate: about this many input tokens.
GRADE_INPUT_ESTIMATE = 4_000


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


def decision_rule(minimum_points):
    return {"unit": "question: each contradiction question's correct rate is its correct answers over three replicates "
                    "(grader majority of three; unknown is not correct)",
            "difference": f"D = mean correct rate of {CANDIDATE} minus {BASELINE}, in points, with a 95 percent paired "
                          f"bootstrap percentile interval over questions ({BOOTSTRAP_RESAMPLES} resamples, seeded by the "
                          "declaration digest)",
            "pass": f"this set passes when D >= +{minimum_points:g} points and the interval's lower bound is above 0",
            "minimum_points": minimum_points,
            "unchanged": "a question whose candidate request equals the baseline's (the detector did not fire) takes the "
                         "baseline's answers for both arms: a tie by construction",
            "context": "one of three conditions of the promotion rule declared on October 13, 2026 (docs/CONFLICT-DETECTOR.md); "
                       "the 72 step 3 questions and the other contradiction set are decided by their own runs"}


def declare(args):
    output, cohort = args.output.absolute(), args.cohort.absolute()
    require(output.is_relative_to(ROOT / ".build") and not output.exists(), "output_invalid")
    captures = json.loads((cohort / "captures.json").read_text())
    rows = [row for row in captures["rows"] if row["category"] == CATEGORY and row["arm"] == BASELINE]
    questions, case_hashes, cohort_sha256 = cohort_questions(cohort)
    require(rows and {row["label"] for row in rows} == set(questions), "cohort_rows_mismatch")
    require(all(row.get("body_digest_matches") and row.get("preparation_completed") for row in rows), "captures_incomplete")
    replay.private_directory(output)
    requests = output / "requests"
    replay.private_directory(requests)
    token = va.AccessTokens()
    jobs, derived_rows, worst = [], [], 0
    for row in sorted(rows, key=lambda value: value["label"]):
        raw = (cohort / "requests" / row["label"] / (BASELINE + ".request.json")).read_bytes()
        require(replay.digest(raw) == row["request_sha256"], "source_body_changed")
        body = json.loads(raw)
        messages = rc.request_messages(raw)
        derived_messages, meta = epa.present("conflicts-gated", messages, {"context_framing": row["context_framing"]})
        derived = json.dumps(dict(body, messages=derived_messages), ensure_ascii=False, sort_keys=True,
                             separators=(",", ":")).encode()
        fired = bool(meta["detector"]["fires"])
        require(fired == (derived != raw) and derived_messages[1:] == messages[1:], "transform_inconsistent")
        directory = requests / row["label"]
        replay.private_directory(directory)
        replay.private_write(directory / (BASELINE + ".request.json"), raw)
        replay.private_write(directory / (CANDIDATE + ".request.json"), derived)
        limit = row["maximum_output"] + THINKING_ALLOWANCE
        counts = {}
        for arm, arm_messages in ((BASELINE, messages), (CANDIDATE, derived_messages)):
            if arm == CANDIDATE and not fired:
                counts[arm] = counts[BASELINE]
                continue
            counts[arm] = vg.parse_count(vg.post(vg.count_url(READER), vg.count_payload(arm_messages), token()))
        derived_rows.append({"label": row["label"], "gold_delivery": row["gold_delivery"], "maximum_output": row["maximum_output"],
                             "output_limit": limit, "fired": fired, "detector": meta["detector"], "detector_sources": meta["detector_sources"],
                             "request_sha256": {BASELINE: row["request_sha256"], CANDIDATE: replay.digest(derived)},
                             "input_tokens": counts, "context_framing": {BASELINE: row["context_framing"],
                                                                         CANDIDATE: epa.GATED_CONFLICTS_FRAMING if fired else row["context_framing"]}})
        for replicate in range(REPLICATES):
            for arm in (ARMS if (replicate + len(jobs)) % 2 == 0 else tuple(reversed(ARMS))):
                if arm == CANDIDATE and not fired:
                    continue
                jobs.append({"label": row["label"], "arm": arm, "replicate": replicate})
                worst += PRICING.microusd(counts[arm], limit)
    controls = sum(1 for question in questions.values() if isinstance(question.get("referenceAnswer"), str)
                   and question["referenceAnswer"].strip()) + len(questions)
    grade_worst = (len(jobs) + controls) * REPLICATES * PRICING.microusd(GRADE_INPUT_ESTIMATE, beam.GRADE_OUTPUT_TOKENS)
    document = {"version": VERSION, "declared_at_utc": now(), "authorization": args.authorization,
                "purpose": "the gated conflicts sentence against a fresh baseline on a BEAM cohort's contradiction questions, "
                           "graded by the cohort's grader request with its calibration controls, paired",
                "cohort": {"path_name": cohort.name, "cohort_sha256": cohort_sha256, "case_sha256": case_hashes,
                           "captures_sha256": replay.digest((cohort / "captures.json").read_bytes())},
                "arms": list(ARMS), "rows": derived_rows, "jobs": jobs, "replicates": REPLICATES,
                "detector": {"version": meta["detector"]["version"], "fired": sum(1 for r in derived_rows if r["fired"]),
                             "questions": len(derived_rows)},
                "reader": {"model": READER, "configuration": vg.configuration(READER, THINKING_LEVEL),
                           "thinking_allowance": THINKING_ALLOWANCE, "pricing": PRICING.declaration()},
                "grader": {"version": beam.GRADER_VERSION, "model": READER, "output_tokens": beam.GRADE_OUTPUT_TOKENS,
                           "replicates": REPLICATES, "controls": "OptChat's calibration controls: one authored positive where "
                           "a reference exists and one fabricated negative per question; the calibration rule is reported, "
                           "not used to exclude grades", "vote": "majority of three on `correct`; fewer than two valid "
                           "agreeing replicates is unknown (not correct)"},
                "decision_rule": decision_rule(float(args.promote_minimum_points)),
                "worst_case_usd": {"answers": str(Decimal(worst) / 10**6), "grades": str(Decimal(grade_worst) / 10**6)},
                "spending_cap_usd": str(args.cap_usd),
                "sentence_sha256": replay.digest(epa.CONFLICTS_SENTENCE.encode()),
                "drivers": {name: replay.digest((ROOT / "scripts" / name).read_bytes())
                            for name in ("beam_conflicts_probe.py", "exchange_packed_answers.py", "conflict_detector.py",
                                         "beam_exchange_packed.py", "vertex_gemini.py")},
                "build_commit": replay.git("rev-parse", "HEAD")}
    require(Decimal(worst + grade_worst) / 10**6 <= Decimal(str(args.cap_usd)), "worst_case_exceeds_cap")
    replay.private_write(output / "declaration.json", replay.canonical(document) + b"\n")
    replay.private_write(output / "ledger.jsonl", b"")
    print(json.dumps({"questions": len(derived_rows), "fired": document["detector"]["fired"], "jobs": len(jobs),
                      "worst_case_usd": document["worst_case_usd"], "cap_usd": str(args.cap_usd),
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
        print(json.dumps({key: record.get(key) for key in ("job", "label", "arm", "replicate", "failure", "microusd")}), flush=True)

    pending = [index for index in range(len(jobs)) if index not in done]
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        list(pool.map(work, pending))
    records = finished(ledger)
    return {"finished": len(records), "jobs": len(jobs), "stopped": state["stopped"],
            "spent_usd_declared_rate": str(Decimal(sum(r.get("microusd") or 0 for r in records.values())) / 10**6),
            "failures": sum(1 for r in records.values() if r.get("failure") not in (None, "incomplete_result"))}


def answer_path(output: Path, arm, label, replicate):
    return output / "answers" / arm / f"{label}--r{replicate}.txt"


def run(args):
    output = args.output.absolute()
    declaration = load(output)
    rows = {row["label"]: row for row in declaration["rows"]}
    for arm in ARMS:
        if not (output / "answers" / arm).exists():
            replay.private_directory(output / "answers" / arm)

    def prepare(index):
        job = declaration["jobs"][index]
        row = rows[job["label"]]
        raw = (output / "requests" / job["label"] / (job["arm"] + ".request.json")).read_bytes()
        require(replay.digest(raw) == row["request_sha256"][job["arm"]], "request_changed")
        return rc.request_messages(raw), row["output_limit"], PRICING.microusd(row["input_tokens"][job["arm"]], row["output_limit"])

    def store(index, raw, text, record):
        job = declaration["jobs"][index]
        replay.private_write(output / "answers" / job["arm"] / f"{job['label']}--r{job['replicate']}.response.json", raw)
        if text is not None:
            replay.private_write(answer_path(output, job["arm"], job["label"], job["replicate"]), text.encode())
            record["answer_sha256"] = replay.digest(text.encode())

    print(json.dumps(dispatch(output, "ledger.jsonl", declaration["jobs"], prepare, store, declaration["spending_cap_usd"])))


def grade_items(output: Path, declaration, questions):
    """Calibration controls, then every generated answer, each graded three times."""
    records = finished(output / "ledger.jsonl")
    items = []
    for control in beam.calibration_controls(list(questions.values())):
        items.append({"kind": control["kind"], "control": control["control"], "label": beam.label_of(control["question_id"]),
                      "candidate_sha256": beam.sha256_text(control["candidate"])})
    for index, job in enumerate(declaration["jobs"]):
        record = records.get(index)
        path = answer_path(output, job["arm"], job["label"], job["replicate"])
        if not record or not path.exists():
            continue
        text = path.read_text()
        require(replay.digest(text.encode()) == record.get("answer_sha256"), "answer_changed")
        items.append({"kind": "answer", "label": job["label"], "arm": job["arm"], "answer_replicate": job["replicate"],
                      "candidate_sha256": beam.sha256_text(text)})
    expanded = []
    for item in items:
        for replicate in range(REPLICATES):
            expanded.append({**item, "replicate": replicate})
    return expanded


def grade(args):
    output, cohort = args.output.absolute(), args.cohort.absolute()
    declaration = load(output)
    questions, _hashes, cohort_sha256 = cohort_questions(cohort)
    require(cohort_sha256 == declaration["cohort"]["cohort_sha256"], "cohort_changed")
    controls = {control["control"]: control for control in beam.calibration_controls(list(questions.values()))}
    items = grade_items(output, declaration, questions)
    grades = output / "grades"
    if not grades.exists():
        replay.private_directory(grades)

    def text_of(item):
        if item["kind"] == "answer":
            return answer_path(output, item["arm"], item["label"], item["answer_replicate"]).read_text()
        return controls[item["control"]]["candidate"]

    def prepare(index):
        item = items[index]
        messages = beam.grade_messages(questions[item["label"]], text_of(item))
        return messages, beam.GRADE_OUTPUT_TOKENS, PRICING.microusd(GRADE_INPUT_ESTIMATE, beam.GRADE_OUTPUT_TOKENS)

    def store(index, raw, text, record):
        item = items[index]
        name = (f"{item['label']}--{item['arm']}--a{item['answer_replicate']}" if item["kind"] == "answer" else item["control"]) + f"--g{item['replicate']}"
        replay.private_write(grades / (name + ".response.json"), raw)
        verdict = beam.parse_verdict(text) if text is not None else None
        if verdict is not None and verdict["grounded"] is not None:
            verdict, record["failure"] = None, record["failure"] or "UNEXPECTED_GROUNDING_SCORE"
        record["verdict"] = verdict
        if verdict is None and record["failure"] is None:
            record["failure"] = "GRADER_FORMAT"

    print(json.dumps(dispatch(output, "grade-ledger.jsonl", items, prepare, store, declaration["spending_cap_usd"])))


def bootstrap_interval(differences, seed):
    generator = random.Random(seed)
    n = len(differences)
    means = sorted(sum(differences[generator.randrange(n)] for _ in range(n)) / n for _ in range(BOOTSTRAP_RESAMPLES))
    return means[int(0.025 * BOOTSTRAP_RESAMPLES)], means[int(math.ceil(0.975 * BOOTSTRAP_RESAMPLES)) - 1]


def score(args):
    output = args.output.absolute()
    declaration = load(output)
    votes, control_votes = {}, {}
    for record in finished(output / "grade-ledger.jsonl").values():
        if record.get("kind") == "answer":
            votes.setdefault((record["label"], record["arm"], record["answer_replicate"]), []).append(record.get("verdict"))
        else:
            control_votes.setdefault((record["control"], record["kind"]), []).append(record.get("verdict"))
    per_question = {}
    for row in declaration["rows"]:
        rates = {}
        for arm in ARMS:
            if arm == CANDIDATE and not row["fired"]:
                rates[arm] = rates[BASELINE]
                continue
            correct = sum(1 for replicate in range(REPLICATES) if beam.majority(votes.get((row["label"], arm, replicate), [])) is True)
            rates[arm] = correct / REPLICATES
        per_question[row["label"]] = {"gold_delivery": row["gold_delivery"], "fired": row["fired"], **rates}
    labels = sorted(per_question)
    differences = [100 * (per_question[label][CANDIDATE] - per_question[label][BASELINE]) for label in labels]
    seed = replay.digest((output / "declaration.json").read_bytes())
    low, high = bootstrap_interval(differences, seed)
    positives = [beam.majority(values) is True for (_, kind), values in control_votes.items() if kind == "positive"]
    negatives = [beam.majority(values) is False for (_, kind), values in control_votes.items() if kind == "negative"]
    calibration = {"positives": len(positives), "positives_accepted": sum(positives), "negatives": len(negatives),
                   "negatives_rejected": sum(negatives), "accepted": bool(positives) and all(positives) and all(negatives)}
    rule = declaration["decision_rule"]
    difference = sum(differences) / len(differences)
    document = {"version": VERSION, "kind": "beam-conflicts-paired-score", "recorded_at_utc": now(),
                "questions": len(labels), "fired": sum(1 for label in labels if per_question[label]["fired"]),
                "baseline_percent": round(100 * sum(per_question[l][BASELINE] for l in labels) / len(labels), 1),
                "candidate_percent": round(100 * sum(per_question[l][CANDIDATE] for l in labels) / len(labels), 1),
                "difference_points": round(difference, 1), "interval_points": [round(low, 1), round(high, 1)],
                "better": sum(1 for d in differences if d > 0), "worse": sum(1 for d in differences if d < 0),
                "tie": sum(1 for d in differences if d == 0),
                "decision": {"minimum_points": rule["minimum_points"],
                             "passes": difference >= rule["minimum_points"] and low > 0},
                "calibration": calibration, "per_question": per_question, "decision_rule": rule}
    replay.private_write(output / "score.json", replay.canonical(document) + b"\n")
    print(json.dumps({key: document[key] for key in ("questions", "fired", "baseline_percent", "candidate_percent",
                                                      "difference_points", "interval_points", "better", "worse", "tie",
                                                      "decision", "calibration", "per_question")}, indent=1))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("declare", "run", "grade", "score"):
        command = commands.add_parser(name)
        command.add_argument("--output", type=Path, required=True)
        if name in ("declare", "grade"):
            command.add_argument("--cohort", type=Path, required=True, help="a BEAM cohort output directory (read-only)")
        if name == "declare":
            command.add_argument("--cap-usd", type=float, required=True)
            command.add_argument("--promote-minimum-points", type=float, required=True, help="the declared D threshold")
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
