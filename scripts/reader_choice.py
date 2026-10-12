#!/usr/bin/env python3
"""Reader choice on the new default: Vertex Sonnet 5.5 against Vertex Gemini 3.8 Flash on the exact
``exchange_packed`` requests.

Requested by the user on October 12, 2026 ("ok run sonnet vs gemini on the new default"), after
ordinary Send's default became ``exchange_packed`` (docs/EXCHANGE-PACKED-ANSWERS.md). Record:
docs/READER-CHOICE.md.

Inputs are reused, not rebuilt: the ``exchange_packed`` request bodies captured for the 73 step 3
retrieval inputs (``exchange_packed_answers.py``) and for the 20 BEAM questions
(``beam_exchange_packed.py``), each verified against its capture digest. Gemini's answers to those
bodies (three replicates, generated earlier the same day) are reused and verified against their
ledger digests. Only Sonnet answers are generated here: the reader comparison's Sonnet settings
(thinking ``between_tools``, which is off; the step 3 output limit, or the BEAM comparison's 2,048;
no sampling field), three replicates.

Grading. Step 3: one blinded set holding both readers' answers, graded by the default judge (Gemini,
``gemini_judge.py``, prompt set v4) and, because Gemini is also a contestant, by the same v4 verdict
request sent to Sonnet (``second-judge``). BEAM: the ported ``beam-native-grader-1`` request with its
calibration controls, on both Gemini and Sonnet as graders.

Commands: ``count`` (free), ``declare``, ``run`` (paid), ``judge-set``, ``second-judge`` (paid),
``beam-grade-declare``, ``beam-grade-run`` (paid), ``score``.

Privacy: request bodies, answers, items and grades stay in private output directories (0700
directories, 0600 files) and are never printed. stdout carries counts, hashes, identifiers and
fixed codes only. The Boros application is unchanged.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from decimal import Decimal
import json
import math
from pathlib import Path
import statistics
import sys
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import answer_presentation_replay as replay  # noqa: E402
import beam_exchange_packed as beam  # noqa: E402
import exchange_packed_answers as epa  # noqa: E402
import framing_v4_variants_replay as v4v  # noqa: E402
import framing_v5_replay as v5plan  # noqa: E402
import reader_comparison as rc  # noqa: E402
import vertex_anthropic as va  # noqa: E402
import vertex_gemini as vg  # noqa: E402

ROOT = replay.ROOT
VERSION = "reader-choice-v1"
SONNET, GEMINI = "claude-sonnet-5-5", "gemini-3.8-flash"
READERS = (GEMINI, SONNET)
ARM = epa.CANDIDATE
REPLICATES = 3
WORKERS = 6
BETWEEN_TOOLS = {"type": "between_tools"}
PRICES = {SONNET: va.Pricing("2.00", "10.00"), GEMINI: va.Pricing("1.50", "7.50")}
PRICE_SOURCES = {SONNET: "Vertex AI pricing for Sonnet 5.5 ($2.00 / $10.00), as declared in the reader comparison",
                 GEMINI: "Gemini 3.8 Flash standard global rate from 2027-01-01; the introductory $0.75 / $3.75 "
                         "billed through 2026-12-31 is half"}
GENERATION_CAP_USD = Decimal("20")
SECOND_JUDGE_CAP_USD = Decimal("15")
BEAM_GRADE_CAP_USD = Decimal("20")
JUDGE_OUTPUT_TOKENS = 512
BEAM_SONNET_GRADE_TOKENS = 384
DECISION_RULE = {
    "unit": "question: the 72 step 3 retrieval questions without 54026fce, on the exchange_packed requests; each "
            "question's accept rate per reader is its accepted answers over three replicates (majority of three; "
            "unknown is not accepted)",
    "difference": "D = mean accept rate of Sonnet minus Gemini, in points, with the paired bootstrap interval and sign "
                  "test of exchange_packed_answers.py, under the default judge (Gemini) and under the second judge "
                  "(Sonnet, the same v4 verdict request)",
    "sonnet_preferred": "D >= +5 and its interval's lower bound > 0 under the default judge, and D > 0 under the "
                        "second judge",
    "gemini_preferred": "D <= -5 and its interval's upper bound < 0 under the default judge, and D < 0 under the "
                        "second judge",
    "otherwise": "no measured quality difference at this size; the choice rests on cost, latency and the egress "
                 "terms a hosted reader needs",
    "beam": "the 20 BEAM questions are reported beside the decision under both graders; they do not decide it",
}
AUTHORIZATION = ("user, 2026-10-12, in chat: 'ok run sonnet vs gemini on the new default', after 'just use vertex for "
                 "evals' earlier the same day; the coordinator declared Sonnet answers on the reused exchange_packed "
                 "requests, three replicates, a second judge, and the caps in this declaration")


class ChoiceError(Exception):
    pass


def require(condition, code):
    if not condition:
        raise ChoiceError(code)


def now():
    return datetime.now(timezone.utc).isoformat()


# --------------------------------------------------------------------------- sources

def step3_rows(source: Path):
    manifest = epa.load_captures(source)
    return [row for row in manifest["rows"] if row["arm"] == ARM]


def beam_rows(source: Path):
    manifest = beam.load_captures(source)
    return [row for row in manifest["rows"] if row["arm"] == ARM]


def source_digests(step3: Path, beam_source: Path):
    return {"step3_captures_sha256": replay.digest((step3 / "captures.json").read_bytes()),
            "step3_declaration_sha256": replay.digest((step3 / "declaration.json").read_bytes()),
            "step3_ledger_sha256": replay.digest((step3 / "ledger.jsonl").read_bytes()),
            "beam_captures_sha256": replay.digest((beam_source / "captures.json").read_bytes()),
            "beam_declaration_sha256": replay.digest((beam_source / "declaration.json").read_bytes()),
            "beam_ledger_sha256": replay.digest((beam_source / "ledger.jsonl").read_bytes())}


def gemini_step3_answers(source: Path):
    """(cohort, question, replicate) -> (text, ledger record) for Gemini's exchange_packed answers."""
    _declaration, entries = epa.answered(source)
    out = {}
    for entry in entries:
        if entry["arm"] == ARM and entry["answer"] is not None:
            out[(entry["cohort"], entry["question_id"], entry["replicate"])] = (entry["answer"], entry["record"])
    require(len(out) == 73 * REPLICATES, "gemini_step3_answers_incomplete")
    return out


def gemini_beam_answers(source: Path):
    declaration = json.loads((source / "declaration.json").read_text())
    records = beam.finished(source / "ledger.jsonl")
    out = {}
    for index, job in enumerate(declaration["jobs"]):
        if job["arm"] != ARM:
            continue
        path = source / "answers" / (beam.answer_name(job) + ".txt")
        text = path.read_text()
        require(replay.digest(text.encode()) == records[index]["answer_sha256"], "gemini_beam_answer_changed")
        out[(job["label"], job["replicate"])] = (text, records[index])
    require(len(out) == 20 * REPLICATES, "gemini_beam_answers_incomplete")
    return out


# --------------------------------------------------------------------------- count and declare

def sonnet_limit(row):
    return row["maximum_output"]


def count(args):
    output = args.output.absolute()
    require(output.is_relative_to(ROOT / ".build"), "output_outside_build")
    replay.private_directory(output)
    token = va.AccessTokens()
    rows = []
    for kind, source, items in (("step3", args.step3, step3_rows(args.step3)), ("beam", args.beam, beam_rows(args.beam))):
        for row in items:
            messages = (epa.captured_body if kind == "step3" else beam.captured_body)(source, row)
            tokens = va.parse_count(va.post(va.count_url(), va.count_payload(messages, model=SONNET), token()))
            key = {"cohort": row["cohort"], "question_id": row["question_id"]} if kind == "step3" else {"label": row["label"]}
            rows.append({"kind": kind, **key, "input_tokens": tokens, "max_output_tokens": sonnet_limit(row)})
    worst = sum(PRICES[SONNET].microusd(row["input_tokens"], row["max_output_tokens"]) for row in rows) * REPLICATES
    document = {"version": VERSION, "kind": "reader-choice-counts", "recorded_at_utc": now(), "model": SONNET,
                "sources": source_digests(args.step3, args.beam), "rows": rows,
                "worst_case_usd_all_replicates": str(Decimal(worst) / 10**6)}
    replay.private_write(output / "counts.json", replay.canonical(document) + b"\n")
    print(json.dumps({"counts": len(rows), "worst_case_usd_all_replicates": document["worst_case_usd_all_replicates"],
                      "median_input_tokens": {kind: statistics.median(row["input_tokens"] for row in rows if row["kind"] == kind)
                                              for kind in ("step3", "beam")}}))


def sonnet_jobs(counts_rows):
    step3 = [row for row in counts_rows if row["kind"] == "step3"]
    beam_items = [row for row in counts_rows if row["kind"] == "beam"]
    jobs = []
    for replicate in range(REPLICATES):
        jobs += [{"kind": "step3", "cohort": row["cohort"], "question_id": row["question_id"], "replicate": replicate}
                 for row in step3]
        jobs += [{"kind": "beam", "label": row["label"], "replicate": replicate} for row in beam_items]
    return jobs


def drivers():
    return {name: replay.digest((ROOT / "scripts" / name).read_bytes())
            for name in ("reader_choice.py", "exchange_packed_answers.py", "beam_exchange_packed.py",
                         "reader_comparison.py", "vertex_anthropic.py", "vertex_gemini.py", "gemini_judge.py")}


def declare(args):
    output = args.output.absolute()
    counts_document = json.loads((output / "counts.json").read_text())
    require(counts_document["sources"] == source_digests(args.step3, args.beam), "sources_changed")
    worst = Decimal(counts_document["worst_case_usd_all_replicates"])
    require(worst <= GENERATION_CAP_USD, "worst_case_exceeds_cap")
    require(not (output / "declaration.json").exists(), "declaration_exists")
    require(not replay.git("status", "--porcelain", "--", "scripts", "Tests/Evaluation", "Sources"), "sources_not_committed")
    gemini_step3_answers(args.step3)
    gemini_beam_answers(args.beam)
    jobs = sonnet_jobs(counts_document["rows"])
    declaration = {
        "version": VERSION, "declared_at_utc": now(), "authorization": AUTHORIZATION,
        "purpose": "reader choice on the new ordinary Send default: Sonnet 5.5 against Gemini 3.8 Flash on the exact "
                   "exchange_packed requests, both judged blind",
        "sources": {**counts_document["sources"], "step3_path": str(args.step3.absolute()),
                    "beam_path": str(args.beam.absolute())},
        "counts_sha256": replay.digest((output / "counts.json").read_bytes()),
        "readers": {SONNET: {"configuration": va.configuration(model=SONNET), "thinking": BETWEEN_TOOLS,
                             "output_limit": "the step 3 run's maximum_output per input; 2,048 for BEAM",
                             "pricing": {**PRICES[SONNET].declaration(), "source": PRICE_SOURCES[SONNET]},
                             "answers": "generated here"},
                    GEMINI: {"configuration": vg.configuration(GEMINI, "low"),
                             "answers": "reused from exchange_packed_answers.py and beam_exchange_packed.py, verified "
                                        "against their ledger digests",
                             "pricing": {**PRICES[GEMINI].declaration(), "source": PRICE_SOURCES[GEMINI]}}},
        "request": "only the captured body's messages; no sampling parameter or seed is sent",
        "replicates": REPLICATES, "jobs": jobs, "generation_limit": len(jobs), "workers": WORKERS,
        "spending_cap_usd": str(GENERATION_CAP_USD), "worst_case_usd": str(worst),
        "judging": {"default": "gemini_judge.py, prompt set v4, one blinded set of both readers' step 3 answers",
                    "second": "the same v4 verdict request (gemini_judge.messages_for) sent to Sonnet 5.5 with thinking "
                              "between_tools and 512 output tokens, three replicates, majority vote",
                    "beam": "beam-native-grader-1 with its calibration controls, on Gemini and on Sonnet"},
        "decision_rule": DECISION_RULE,
        "exclusion": "54026fce is reported separately and excluded from counts",
        "remote_calls": "Vertex AI only (llm-train-482420, global); the inputs are LongMemEval and BEAM benchmark "
                        "histories, not private user history",
        "drivers": drivers(), "build_commit": replay.git("rev-parse", "HEAD"),
    }
    replay.private_write(output / "declaration.json", replay.canonical(declaration) + b"\n")
    replay.private_write(output / "ledger.jsonl", b"")
    print(json.dumps({"jobs": len(jobs), "worst_case_usd": str(worst), "cap_usd": str(GENERATION_CAP_USD),
                      "declaration_sha256": replay.digest((output / "declaration.json").read_bytes())}))


# --------------------------------------------------------------------------- dispatch

def dispatch(ledger: Path, jobs, prepare, store, cap_usd, workers=WORKERS):
    """Runs declared `jobs` under a cap with the declared retry rule. `prepare(index)` returns (model, url, body,
    worst micro-USD); `store(index, raw, text, record)` keeps the response."""
    cap = Decimal(cap_usd) * 10**6
    done = beam.finished(ledger)
    lock = threading.Lock()
    state = {"spent": sum(record.get("microusd") or 0 for record in done.values()), "stopped": None}
    token = va.AccessTokens()

    def append(record):
        with open(ledger, "a") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")

    def work(index):
        model, url, body, worst = prepare(index)
        with lock:
            if state["stopped"] or state["spent"] + worst > cap:
                state["stopped"] = state["stopped"] or "cap_reached"
                return
            state["spent"] += worst
            append({"job": index, "state": "started", "at": now()})
        post = va.post if rc.READERS[model]["route"] == "anthropic" else vg.post
        failure, raw, tries = None, None, 0
        while True:
            tries += 1
            started = time.monotonic()
            try:
                raw = post(url, body, token())
                failure = None
            except va.VertexError as error:
                failure = str(error)
            if failure in rc.RETRYABLE and tries <= len(rc.RETRY_DELAYS):
                time.sleep(rc.RETRY_DELAYS[tries - 1])
                continue
            break
        record = {"job": index, **jobs[index], "state": "finished", "model": model, "tries": tries,
                  "seconds": round(time.monotonic() - started, 3), "at": now(), "failure": failure, "microusd": 0}
        if raw is not None:
            text, usage, stop, failure = rc.parse(model, raw)
            record.update(failure=failure, stop_reason=stop)
            if usage is not None:
                record.update(input_tokens=usage["input_tokens"], output_tokens=usage["output_tokens"],
                              microusd=PRICES[model].microusd(usage["input_tokens"], usage["output_tokens"]))
            store(index, raw, text, record)
        with lock:
            state["spent"] += record["microusd"] - worst
            append(record)
            code = record["failure"]
            if code not in (None, "incomplete_result") and code.startswith("http_status_4") and code != "http_status_429":
                state["stopped"] = "client_error_" + code
        print(json.dumps({key: record.get(key) for key in ("job", "model", "failure", "seconds", "microusd")}), flush=True)

    pending = [index for index in range(len(jobs)) if index not in done]
    with ThreadPoolExecutor(max_workers=workers) as pool:
        list(pool.map(work, pending))
    records = list(beam.finished(ledger).values())
    return {"finished": len(records), "jobs": len(jobs), "stopped": state["stopped"],
            "spent_usd_declared_rate": str(Decimal(sum(record.get("microusd") or 0 for record in records)) / 10**6),
            "failures": sum(1 for record in records if record.get("failure") not in (None, "incomplete_result")),
            "incomplete": sum(1 for record in records if record.get("failure") == "incomplete_result")}


def sonnet_answer_name(job):
    if job["kind"] == "step3":
        return f"step3/{job['cohort']}--{job['question_id']}--r{job['replicate']}"
    return f"beam/{job['label']}--r{job['replicate']}"


def run(args):
    output = args.output.absolute()
    declaration = json.loads((output / "declaration.json").read_text())
    require(declaration.get("version") == VERSION, "declaration_version")
    require(drivers() == declaration["drivers"], "driver_changed")
    step3, beam_source = Path(declaration["sources"]["step3_path"]), Path(declaration["sources"]["beam_path"])
    require(source_digests(step3, beam_source) == {key: value for key, value in declaration["sources"].items()
                                                   if not key.endswith("_path")}, "sources_changed")
    counted = {(row["kind"], row.get("cohort"), row.get("question_id"), row.get("label")): row
               for row in json.loads((output / "counts.json").read_text())["rows"]}
    step3_by = {(row["cohort"], row["question_id"]): row for row in step3_rows(step3)}
    beam_by = {row["label"]: row for row in beam_rows(beam_source)}
    answers = output / "answers"
    for directory in (answers, answers / "step3", answers / "beam"):
        replay.private_directory(directory)
    jobs = declaration["jobs"]

    def prepare(index):
        job = jobs[index]
        if job["kind"] == "step3":
            row = step3_by[(job["cohort"], job["question_id"])]
            messages = epa.captured_body(step3, row)
            tokens = counted[("step3", job["cohort"], job["question_id"], None)]["input_tokens"]
        else:
            row = beam_by[job["label"]]
            messages = beam.captured_body(beam_source, row)
            tokens = counted[("beam", None, None, job["label"])]["input_tokens"]
        body = va.payload(messages, sonnet_limit(row), model=SONNET, thinking=BETWEEN_TOOLS)
        return SONNET, va.generation_url(model=SONNET), body, PRICES[SONNET].microusd(tokens, sonnet_limit(row))

    def store(index, raw, text, record):
        name = sonnet_answer_name(jobs[index])
        replay.private_write(answers / (name + ".response.json"), raw)
        if text is not None:
            replay.private_write(answers / (name + ".txt"), text.encode())
            record["answer_sha256"] = replay.digest(text.encode())

    print(json.dumps(dispatch(output / "ledger.jsonl", jobs, prepare, store, declaration["spending_cap_usd"])))


def sonnet_answers(output: Path, kind):
    declaration = json.loads((output / "declaration.json").read_text())
    records = beam.finished(output / "ledger.jsonl")
    out = {}
    for index, job in enumerate(declaration["jobs"]):
        if job["kind"] != kind or index not in records:
            continue
        path = output / "answers" / (sonnet_answer_name(job) + ".txt")
        if path.exists():
            text = path.read_text()
            require(replay.digest(text.encode()) == records[index].get("answer_sha256"), "sonnet_answer_changed")
            key = (job["cohort"], job["question_id"], job["replicate"]) if kind == "step3" else (job["label"], job["replicate"])
            out[key] = (text, records[index])
    return out


# --------------------------------------------------------------------------- step 3 judging

def judge_set(args):
    """One blinded verdict set holding both readers' step 3 answers, in a seeded order. No judge call."""
    import judge_calibration as jc
    output = args.output.absolute()
    declaration = json.loads((output / "declaration.json").read_text())
    step3 = Path(declaration["sources"]["step3_path"])
    entries = [(GEMINI, key, text) for key, (text, _record) in sorted(gemini_step3_answers(step3).items())]
    entries += [(SONNET, key, text) for key, (text, _record) in sorted(sonnet_answers(output, "step3").items())]
    plan = v4v.cohorts()
    frozen = v4v.frozen_inputs(args.dataset, plan)
    sources = {(qid, cohort): run for cohort in epa.COHORTS for qid, run, _, _ in plan[cohort][0]}
    seed = replay.digest((output / "declaration.json").read_bytes())
    records = jc.load_dataset(args.dataset)
    candidates = []
    for position, (reader, (cohort, qid, replicate), text) in enumerate(entries):
        history, _document, _ = frozen[(qid, sources[(qid, cohort)])]
        arm = f"{reader}:r{replicate}"
        candidate = jc.new_candidate(run=f"reader-choice-{cohort}", run_family="reader-choice", arm=arm, question_id=qid,
                                     answer_model=reader, operational_complete=True,
                                     answer_sha256=replay.digest(text.encode()))
        jc.attach_question(candidate, records)
        require(candidate["reference"] is not None, "question_missing_from_dataset")
        candidate["scrub_ids"].update(event["id"] for event in history["events"])
        jc.verify_answer(candidate, text)
        candidates.append((jc.rank(seed, str(position), qid, arm), position, reader, cohort, qid, replicate, candidate))
    candidates.sort(key=lambda value: value[0])
    require(len(candidates) <= 999, "judge_set_too_large")
    items, keys = [], []
    for number, (_rank, position, reader, cohort, qid, replicate, candidate) in enumerate(candidates, start=1):
        item, replaced = jc.blind_item(candidate, f"item-{number:03d}")
        items.append(item)
        keys.append({"item_id": item["item_id"], "row_index": position, "run": candidate["run"], "arm": candidate["arm"],
                     "reader": reader, "replicate": replicate, "cohort": cohort, "question_id": qid,
                     "abstention": bool(candidate["abstention"]), "question_type": candidate["question_type"],
                     "answer_sha256": candidate["answer_sha256"], "item_sha256": replay.digest(replay.canonical(item)),
                     "identifier_substitutions": replaced})
    set_id = "jrx-" + replay.digest(replay.canonical({"seed": seed, "keys": [[key["row_index"], key["answer_sha256"]]
                                                                            for key in keys]}))[:16]
    items_document = {"format": jc.ITEMS_FORMAT, "set_id": set_id, "items": items}
    key_document = {"format": replay.JUDGE_KEY_FORMAT, "set_id": set_id, "seed": seed, "items": keys}
    require(not jc.blinding_violations(items_document, key_document), "blinding_violation")
    manifest = replay.write_judge_set(output / "judge-set", items_document, key_document, "reader-choice", seed)
    print(json.dumps({"set_id": manifest["set_id"], "items": manifest["item_count"], "items_sha256": manifest["items_sha256"],
                      "readers": {reader: sum(1 for key in keys if key["reader"] == reader) for reader in READERS},
                      "identifier_substitutions": manifest["identifier_substitutions"],
                      "identity_mention_items": len(manifest["identity_mention_items"])}))


def second_judge(args):
    """The default judge's v4 verdict request sent to Sonnet: a check on Gemini judging Gemini's answers."""
    import gemini_judge as gj
    import judge_calibration as jc
    import judge_calibration_run as jcr
    output = args.output.absolute()
    directory = output / "sonnet-judge"
    replay.private_directory(directory)
    _manifest, items = jcr.load_set(output / "judge-set")
    prompt_function = jc.load_upstream_prompt_function(args.protocol)
    rendered = {item["item_id"]: gj.messages_for(item, prompt_function, "v4") for item in items}
    plan_path = directory / "plan.json"
    if not plan_path.exists():
        jobs = [{"item_id": item["item_id"], "replicate": replicate} for replicate in range(REPLICATES) for item in items]
        replay.private_write(plan_path, replay.canonical({
            "version": VERSION, "judge": "vertex-sonnet", "model": SONNET, "prompt_set": "v4", "thinking": BETWEEN_TOOLS,
            "max_output_tokens": JUDGE_OUTPUT_TOKENS, "replicates": REPLICATES, "jobs": jobs,
            "rendered_messages_sha256": replay.digest(replay.canonical([replay.digest(replay.canonical(rendered[item["item_id"]]))
                                                                        for item in items])),
            "spending_cap_usd": str(SECOND_JUDGE_CAP_USD), "drivers": drivers()}) + b"\n")
    plan = json.loads(plan_path.read_text())
    require(plan["drivers"] == drivers(), "driver_changed")
    jobs = plan["jobs"]
    replies = directory / "replies"
    replay.private_directory(replies)

    def prepare(index):
        messages = rendered[jobs[index]["item_id"]]
        worst = PRICES[SONNET].microusd(gj.estimated_input_tokens(messages), JUDGE_OUTPUT_TOKENS)
        return SONNET, va.generation_url(model=SONNET), va.payload(messages, JUDGE_OUTPUT_TOKENS, model=SONNET,
                                                                     thinking=BETWEEN_TOOLS), worst

    def store(index, raw, text, record):
        replay.private_write(replies / f"{jobs[index]['item_id']}--r{jobs[index]['replicate']}.json", raw)
        label = jc.parse_instructed_reply(text, "verdict") if text is not None else None
        record["label"] = label
        if label is None and record["failure"] is None:
            record["failure"] = "output_off_schema"

    print(json.dumps(dispatch(directory / "ledger.jsonl", jobs, prepare, store, plan["spending_cap_usd"])))
    records = beam.finished(directory / "ledger.jsonl")
    labels = {}
    for index, job in enumerate(jobs):
        labels.setdefault(job["item_id"], []).append({"verdict": (records.get(index) or {}).get("label")})
    complete = len(records) == len(jobs) and all(len(value) == REPLICATES for value in labels.values())
    replay.private_write(directory / "labels.json", replay.canonical({
        "set_id": _manifest["set_id"], "judge": "vertex-sonnet", "prompt_set": "v4", "replicates": REPLICATES,
        "complete": complete, "labels": labels}) + b"\n")


# --------------------------------------------------------------------------- BEAM grading

def beam_grade_declare(args):
    """Freezes BEAM grading on both graders: calibration controls, then both readers' answers, seeded order."""
    output = args.output.absolute()
    declaration = json.loads((output / "declaration.json").read_text())
    beam_source = Path(declaration["sources"]["beam_path"])
    _case, questions, _hashes = beam.load_beam(args.case, args.supplement)
    seed = replay.digest((output / "declaration.json").read_bytes())
    items = [{"item": control["control"], "kind": control["kind"], "label": beam.label_of(control["question_id"]),
              "candidate_sha256": beam.sha256_text(control["candidate"])} for control in beam.calibration_controls(questions)]
    answers = []
    for reader, source in ((GEMINI, gemini_beam_answers(beam_source)), (SONNET, sonnet_answers(output, "beam"))):
        for (label, replicate), (text, _record) in sorted(source.items()):
            name = f"{reader}--{label}--r{replicate}"
            answers.append((replay.digest(f"{seed}\0{name}".encode()), {
                "item": f"answer-{replay.digest(name.encode())[:12]}", "kind": "answer", "reader": reader, "label": label,
                "replicate": replicate, "candidate_sha256": beam.sha256_text(text)}))
    items += [item for _rank, item in sorted(answers, key=lambda value: value[0])]
    require(not (output / "beam-grade-declaration.json").exists(), "beam_grade_declaration_exists")
    document = {"version": VERSION, "kind": "reader-choice-beam-grading", "declared_at_utc": now(),
                "answers_declaration_sha256": seed, "grader_version": beam.GRADER_VERSION,
                "instruction_sha256": beam.sha256_text(beam.GRADER_INSTRUCTION),
                "graders": {GEMINI: {"configuration": vg.configuration(GEMINI, "low"), "max_output_tokens": beam.GRADE_OUTPUT_TOKENS},
                            SONNET: {"configuration": va.configuration(model=SONNET), "thinking": BETWEEN_TOOLS,
                                     "max_output_tokens": BEAM_SONNET_GRADE_TOKENS}},
                "items": items, "jobs": [{"item": item["item"], "replicate": replicate}
                                         for replicate in range(REPLICATES) for item in items],
                "spending_cap_usd_per_grader": str(BEAM_GRADE_CAP_USD), "drivers": drivers()}
    replay.private_write(output / "beam-grade-declaration.json", replay.canonical(document) + b"\n")
    print(json.dumps({"items": len(items), "answers": len(answers), "requests_per_grader": len(document["jobs"]),
                      "sha256": replay.digest((output / "beam-grade-declaration.json").read_bytes())}))


def beam_candidate(output, declaration, item, questions, gemini, sonnet):
    if item["kind"] != "answer":
        for control in beam.calibration_controls(questions):
            if control["control"] == item["item"]:
                return control["candidate"]
        raise ChoiceError("control_missing")
    return (gemini if item["reader"] == GEMINI else sonnet)[(item["label"], item["replicate"])][0]


def beam_grade_run(args):
    output = args.output.absolute()
    declaration = json.loads((output / "declaration.json").read_text())
    grading = json.loads((output / "beam-grade-declaration.json").read_text())
    require(grading["drivers"] == drivers(), "driver_changed")
    grader = args.grader
    _case, questions, _hashes = beam.load_beam(args.case, args.supplement)
    by_label = {beam.label_of(question["id"]): question for question in questions}
    gemini = gemini_beam_answers(Path(declaration["sources"]["beam_path"]))
    sonnet = sonnet_answers(output, "beam")
    items = {item["item"]: item for item in grading["items"]}
    directory = output / f"beam-grades-{grader}"
    replay.private_directory(directory)
    jobs = grading["jobs"]

    def prepare(index):
        item = items[jobs[index]["item"]]
        text = beam_candidate(output, declaration, item, questions, gemini, sonnet)
        require(beam.sha256_text(text) == item["candidate_sha256"], "candidate_changed")
        messages = beam.grade_messages(by_label[item["label"]], text)
        estimate = math.ceil(sum(len(message["content"]) for message in messages) / 2) + 16
        if grader == GEMINI:
            return GEMINI, vg.generation_url(GEMINI), vg.payload(messages, beam.GRADE_OUTPUT_TOKENS, thinking_level="low"), \
                PRICES[GEMINI].microusd(estimate, beam.GRADE_OUTPUT_TOKENS)
        return SONNET, va.generation_url(model=SONNET), va.payload(messages, BEAM_SONNET_GRADE_TOKENS, model=SONNET,
                                                                     thinking=BETWEEN_TOOLS), \
            PRICES[SONNET].microusd(estimate, BEAM_SONNET_GRADE_TOKENS)

    def store(index, raw, text, record):
        replay.private_write(directory / f"{jobs[index]['item']}--r{jobs[index]['replicate']}.json", raw)
        verdict = beam.parse_verdict(text) if text is not None else None
        if verdict is not None and verdict["grounded"] is not None:
            verdict = None
            record["failure"] = record["failure"] or "UNEXPECTED_GROUNDING_SCORE"
        record["verdict"] = verdict
        if verdict is None and record["failure"] is None:
            record["failure"] = "GRADER_FORMAT"

    print(json.dumps(dispatch(directory / "ledger.jsonl", jobs, prepare, store, grading["spending_cap_usd_per_grader"])))


# --------------------------------------------------------------------------- score

def paired_readers(per_question, questions, seed):
    """epa.paired with Gemini as the baseline and Sonnet as the candidate."""
    renamed = {question: {epa.BASELINE: values[GEMINI], epa.CANDIDATE: values[SONNET]}
               for question, values in per_question.items()}
    result = epa.paired(renamed, questions, seed)
    result["gemini_percent"] = result.pop("baseline_percent")
    result["sonnet_percent"] = result.pop("candidate_percent")
    return result


def decide(default, second):
    d, (low, high) = default["difference_points"], default["interval_points"]
    if d >= 5 and low > 0 and second["difference_points"] > 0:
        return "sonnet_preferred"
    if d <= -5 and high < 0 and second["difference_points"] < 0:
        return "gemini_preferred"
    return "no_measured_difference"


def step3_tables(key_document, labels_document, gold, seed):
    require(labels_document.get("set_id") == key_document["set_id"], "labels_set_mismatch")
    require(labels_document.get("complete") is True, "labels_incomplete")
    samples = {}
    for key in key_document["items"]:
        verdict = replay.majority_of_three([value.get("verdict") for value in labels_document["labels"][key["item_id"]]])
        samples.setdefault(f"{key['cohort']}--{key['question_id']}", {}).setdefault(key["reader"], []).append(verdict)
    per_question = {question: {reader: sum(1 for value in values.get(reader, []) if value == "accept") / REPLICATES
                               for reader in READERS} for question, values in samples.items()}
    counted = sorted(question for question in per_question if not question.endswith(tuple(epa.EXCLUDED_FROM_COUNTS)))
    tables = {"overall": paired_readers(per_question, counted, seed),
              "cohorts": {cohort: paired_readers(per_question, [q for q in counted if q.startswith(cohort + "--")], seed)
                          for cohort in epa.COHORTS},
              "by_gold_delivery": {kind: paired_readers(per_question, [q for q in counted if gold[q] == kind], seed)
                                   for kind in ("whole", "partial", "none", "no_gold_turns")
                                   if any(gold[q] == kind for q in counted)},
              "unknown": {reader: sum(1 for values in samples.values() for value in values.get(reader, [])
                                      if value == "unknown") for reader in READERS},
              "excluded": {question: samples[question] for question in samples
                           if question.endswith(tuple(epa.EXCLUDED_FROM_COUNTS))}}
    return tables, per_question


def beam_tables(output, grading, grader, seed):
    records = beam.finished(output / f"beam-grades-{grader}" / "ledger.jsonl")
    replicates = {}
    for index, job in enumerate(grading["jobs"]):
        replicates.setdefault(job["item"], []).append((records.get(index) or {}).get("verdict"))
    vote = {name: beam.majority(values) for name, values in replicates.items()}
    controls = [item for item in grading["items"] if item["kind"] != "answer"]
    calibration = {"positives": sum(1 for item in controls if item["kind"] == "positive"),
                   "positives_accepted": sum(1 for item in controls if item["kind"] == "positive" and vote[item["item"]] is True),
                   "negatives": sum(1 for item in controls if item["kind"] == "negative"),
                   "negatives_rejected": sum(1 for item in controls if item["kind"] == "negative" and vote[item["item"]] is False),
                   "invalid": sum(1 for item in controls if vote[item["item"]] is None),
                   "failures": sum(1 for record in records.values() if record.get("failure"))}
    calibration["accepted"] = calibration["positives_accepted"] == calibration["positives"] \
        and calibration["negatives_rejected"] == calibration["negatives"] and calibration["invalid"] == 0
    samples, per_replicate = {}, {reader: [0] * REPLICATES for reader in READERS}
    for item in grading["items"]:
        if item["kind"] == "answer":
            samples.setdefault(item["label"], {}).setdefault(item["reader"], []).append(vote[item["item"]])
            per_replicate[item["reader"]][item["replicate"]] += vote[item["item"]] is True
    per_question = {label: {reader: sum(1 for value in values.get(reader, []) if value is True) / REPLICATES
                            for reader in READERS} for label, values in samples.items()}
    return {"calibration": calibration, "correct_per_replicate_of_20": per_replicate,
            "overall": paired_readers(per_question, sorted(per_question), seed),
            "unknown_votes": {reader: sum(1 for values in samples.values() for value in values.get(reader, []) if value is None)
                              for reader in READERS}}, per_question


def operations(output, step3):
    out = {}
    gemini = gemini_step3_answers(step3)
    sonnet = sonnet_answers(output, "step3")
    for reader, source in ((GEMINI, gemini), (SONNET, sonnet)):
        records = [record for _text, record in source.values()]
        seconds = sorted(record["seconds"] for record in records if record.get("seconds"))
        microusd = sum(record.get("microusd") or 0 for record in records)
        out[reader] = {"answers": len(records), "median_seconds": round(statistics.median(seconds), 2),
                       "p90_seconds": round(seconds[int(0.9 * (len(seconds) - 1))], 2),
                       "usd_declared_rate": str(Decimal(microusd) / 10**6),
                       "usd_per_answer": str((Decimal(microusd) / len(records) / 10**6).quantize(Decimal("0.0001"))),
                       "median_output_tokens": statistics.median(record.get("output_tokens") or 0 for record in records)}
        declines = [v5plan.is_decline(v5plan.decline_outcome(text)["outcome"]) for text, _record in source.values()]
        out[reader]["declines"] = sum(declines)
    return out


def score(args):
    import judge_calibration as jc
    output = args.output.absolute()
    declaration = json.loads((output / "declaration.json").read_text())
    step3 = Path(declaration["sources"]["step3_path"])
    seed = replay.digest((output / "declaration.json").read_bytes())
    key_document = jc.load_json(output / "judge-set" / "key.json")
    gold = {f"{row['cohort']}--{row['question_id']}": row["gold_delivery"] for row in step3_rows(step3)}
    default, default_pq = step3_tables(key_document, jc.load_json(args.labels), gold, seed)
    second, second_pq = step3_tables(key_document, jc.load_json(output / "sonnet-judge" / "labels.json"), gold, seed)
    grading = json.loads((output / "beam-grade-declaration.json").read_text())
    beam_default, beam_pq = beam_tables(output, grading, GEMINI, seed)
    beam_second, _ = beam_tables(output, grading, SONNET, seed)
    document = {"version": VERSION, "kind": "reader-choice-score", "recorded_at_utc": now(),
                "decision_rule": declaration["decision_rule"],
                "decision": decide(default["overall"], second["overall"]),
                "step3": {"default_judge": default, "second_judge": second},
                "beam": {"gemini_grader": beam_default, "sonnet_grader": beam_second},
                "operations": operations(output, step3),
                "per_question": {"step3_default": default_pq, "step3_second": second_pq, "beam_gemini": beam_pq}}
    replay.private_write(output / "score.json", replay.canonical(document) + b"\n")
    print(json.dumps({key: document[key] for key in ("decision", "step3", "beam", "operations")}, indent=1))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("count", "declare", "run", "judge-set", "second-judge", "beam-grade-declare", "beam-grade-run", "score"):
        command = commands.add_parser(name)
        command.add_argument("--output", type=Path, required=True)
        if name in ("count", "declare"):
            command.add_argument("--step3", type=Path, required=True, help="exchange_packed_answers.py output directory")
            command.add_argument("--beam", type=Path, required=True, help="beam_exchange_packed.py output directory")
        if name == "judge-set":
            command.add_argument("--dataset", type=Path, required=True)
        if name == "second-judge":
            import judge_calibration as jc
            command.add_argument("--protocol", type=Path, default=jc.DEFAULT_PROTOCOL)
        if name in ("beam-grade-declare", "beam-grade-run"):
            command.add_argument("--case", type=Path, required=True)
            command.add_argument("--supplement", type=Path, required=True)
        if name == "beam-grade-run":
            command.add_argument("--grader", choices=READERS, required=True)
        if name == "score":
            command.add_argument("--labels", type=Path, required=True, help="the default judge's labels for judge-set")
    args = parser.parse_args(argv)
    import judge_calibration as jc
    import retrieval_harness as harness
    try:
        {"count": count, "declare": declare, "run": run, "judge-set": judge_set, "second-judge": second_judge,
         "beam-grade-declare": beam_grade_declare, "beam-grade-run": beam_grade_run, "score": score}[args.command](args)
    except (ChoiceError, epa.EvaluationError, beam.BeamError, rc.ComparisonError, va.VertexError, replay.ReplayError,
            v4v.PlanError, jc.CalibrationError, harness.HarnessError) as error:
        print(json.dumps({"error": str(error)}))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
