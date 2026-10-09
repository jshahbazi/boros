#!/usr/bin/env python3
"""Framing V5 replay: V4 (default) against V5 (scoped fix G) and the V4 no-G ablation.

Executes the test plan of docs/ANSWER-PRESENTATION-DEFECTS.md ("Proposed mitigation") as one
pre-declared, paired replay. See docs/FRAMING-V5.md.

Arms, all through the same verified binary and the existing ``--answer-evaluation`` path:

- ``v4-default``: no ``--context-framing`` flag, so the binary's default (V4).
- ``v5``: ``--context-framing context-source-snapshot-v5``.
- ``v4-no-g``: ``--context-framing context-source-snapshot-v4-no-g`` (evaluation-only ablation).

Cohorts:

- ``retrieval-on-21``: the 21 questions of the saved native runs, recorded hybrid attempt, run with
  ``--retrieval-arm ordinary_send`` (lexical selection, what ordinary Send ships).
- ``preference-27``: the dataset's other single-session-preference questions as opaque version-9
  runner documents (``framing_v5_preference_cases.py``), also with ``--retrieval-arm ordinary_send``.
- ``recent-only-21``: the recent-only attempt of the same 21 questions.

Commands:

- ``gold``: offline, before any generation. Runs the retrieval harness's delivery binary (no answer
  generation; a loopback tokenizer stand-in) on every declared runner input and scores the annotated
  gold turns against what the declared arm delivers. Writes a private gold-delivery table.
- ``declare``: freezes the one declaration (arms, cohorts, question lists, gold-delivery table,
  settings, caps, judge plan and the decision rule) before the first generation.
- ``run``: the replay driver's ledgered runner (``answer_presentation_replay.run``) under this
  declaration's generation limit.
- ``measure``, ``judge-set``, ``judge-summary``: counts, identifiers and classes only. The
  judge summary evaluates the pre-declared decision rule.

Privacy: inputs, answers and native reports stay in the private output directory (0700 directories,
0600 files). stdout never carries question, answer, reference, evidence or history text.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import answer_presentation_defects as apd  # noqa: E402
import answer_presentation_replay as replay  # noqa: E402
import evaluate_answers as e  # noqa: E402
import evaluate_longmemeval as baseline  # noqa: E402
import framing_v5_preference_cases as preference  # noqa: E402

ROOT = replay.ROOT
VERSION = "framing-v5-replay-v1"
V4 = replay.V4
V5 = "context-source-snapshot-v5"
ABLATION = "context-source-snapshot-v4-no-g"
# (arm name, --context-framing value or None for the binary's default). Run order per question.
ARMS = (("v4-default", None), ("v5", V5), ("v4-no-g", ABLATION))
ARM_DESCRIPTIONS = {
    "v4-default": "no --context-framing flag: the binary's default, context-source-snapshot-v4 (fixes A, D, G); "
                  "the reported framing is verified at measurement",
    "v5": "context-source-snapshot-v5, pinned with --context-framing: V4 with the second fix G sentence replaced by "
          "the scoped rewording; every other model-visible byte equals V4's",
    "v4-no-g": "context-source-snapshot-v4-no-g, pinned with --context-framing: V4 without both fix G sentences "
               "(evaluation-only ablation separating G from fix A)",
}
PREFERENCE_RUN = preference.COHORT
ORDINARY_SEND = "ordinary_send"
# (cohort, cases, runner retrieval arm). Cases are (question ID, source run, strategy, policy).
COHORT_ORDER = ("retrieval-on-21", "preference-27", "recent-only-21")
EXCLUDED_FROM_DECISION = ("54026fce",)
GENERATION_CAP = 207
AUTHORIZATION = ("user, 2026-10-09, in chat: implement V5 and run the test plan; up to 207 local generations "
                 "((21+27+21) x 3 arms), local model server only; default-judge verdicts on every answer, Vertex "
                 "claude-sonnet-5-5, cap $2.00")
# Declined-answer wording beyond the detector's phrase list (answer_presentation_defects v2), anchored
# to a source noun so that advice text ("do not include sugar") does not match. Applied to every arm.
RE_SOURCE_DECLINE = re.compile(
    r"\b(?:quoted sources?|sources?|excerpts?|history|conversations?|messages?|records?|context|notes?)\b"
    r"[^.\n]{0,40}?\b(?:do|does|did)\s*(?:not|n't)\s+(?:show|contain|mention|state|include|say|specify|indicate|provide)\b"
    r"|\b(?:no|none of the)\s+(?:quoted\s+)?(?:sources?|excerpts?|messages?|records?)\b[^.\n]{0,40}?"
    r"\b(?:shows?|contains?|mentions?|states?|includes?|says?|specif(?:y|ies)|indicates?)\b", re.I)
JUDGE_PLAN = {
    "judge": "vertex-sonnet", "template": "scripts/judge_calibration_declarations/vertex-sonnet.v3.template.json",
    "provider": {"project_id": "llm-train-482420", "location": "global", "model": "claude-sonnet-5-5"},
    "declaration_format": "boros-judge-calibration-vertex-declaration-v3",
    "prompts": "boros-judge-calibration-prompts-v3", "stages_per_item": ["verdict"], "replicates": 3,
    "vote": "majority of three; a tie or an unparseable majority is unknown and never counted as accept",
    "max_output_tokens_per_request": 64,
    "max_output_tokens_reason": "the runner reserves counted input plus the output cap per request against the cap; "
                                "at the template's 512, 621 requests reserve about $3.7 and the run would be "
                                "refused under $2.00. Verdict replies averaged 12 output tokens (1,479 for 126) "
                                "with 0 thinking tokens; 64 is inside the declared Sonnet range 16 to 4096. The "
                                "prompt, reply format, model and replicate count are unchanged.",
    "pricing": {"input_usd_per_million_tokens": 2.0, "output_usd_per_million_tokens": 10.0},
    "spending_cap_usd": 2.0, "max_generation_requests": 640, "max_count_requests": 414,
    "request_limits_reason": "621 planned verdict requests (207 items x 3) plus room for one resume after an "
                             "interrupted session: requests whose session failed are re-sent, and counts may be "
                             "repeated; every reservation still counts against the one $2.00 cap",
    "access_probe": "one standalone empty-body probe first (HTTP 400 reachable, 404 no access), then the runner's own",
    "items": "answer_presentation_replay.judge_items: dataset question, date, type, reference, abstention flag, no "
             "evidence, calibration identifier scrub, seeded interleaved order; no arm, cohort, run or question ID",
    "calibrated_rates": {"error": "2/50, 4% (1-13%)", "false_reject": "1/30, 3% (1-17%)",
                         "false_accept": "1/20, 5% (1-24%)"},
}
DECISION_RULE = {
    "compared_arms": ["v5", "v4-default"],
    "ablation": "v4-no-g is reported for the G-versus-A attribution and is not part of the rule",
    "excluded_question": "54026fce is reported separately in every cohort and excluded from every count below",
    "decline": "lexical outcome decline or partial_decline under the declared decline measure "
               "(detector phrase list plus the anchored source-decline pattern), on the measured answer",
    "gold_class": "the pre-declared offline gold delivery of the declaration's gold table (ordinary_send for "
                  "retrieval-on-21 and preference-27); a runner delivery that differs is reported, not reclassified",
    "criteria": {
        "R1_preference_declines_reduced": "over the preference questions (question type single-session-preference) "
            "of retrieval-on-21 and preference-27 whose declared gold delivery is whole: declines(v5) < "
            "declines(v4-default). A tie fails. If v4-default has 0 such declines, R1 fails (no reduction possible).",
        "R2_abstention_declines_kept": "over the 3 abstention questions of retrieval-on-21: declines(v5) >= "
            "declines(v4-default).",
        "R3_recent_only_declines_kept": "over recent-only-21 without 54026fce (20 answers per arm): declines(v5) >= "
            "declines(v4-default).",
        "R4_zero_disclaimers": "v5 has 0 AI or memory disclaimers over all its answers in the three cohorts.",
        "R5_gold_whole_accepts_not_lower": "over the answerable questions of retrieval-on-21 whose declared gold "
            "delivery is whole: default-judge accepts(v5) >= accepts(v4-default); unknown counts as not accepted.",
    },
    "adopt": "recommend V5 as the default only if R1, R2, R3, R4 and R5 all hold; otherwise V4 stays the default. "
             "The recommendation goes to the coordinator and the user; this replay changes no default.",
    "missing": "a criterion whose subset has a run without a measured answer in either compared arm is "
               "inconclusive, which counts as not holding",
}


class PlanError(Exception):
    """Fixed, content-free reason codes only."""


def require(condition, code):
    if not condition:
        raise PlanError(code)


def cohorts(case_ids=None):
    """The three cohorts in run order: name -> (cases, retrieval arm)."""
    ids = tuple(case_ids) if case_ids is not None else None
    preference_cases = tuple((qid, PREFERENCE_RUN, "hybrid", None) for qid in (ids or tuple(preference.PROJECTION_PINS)))
    return {"retrieval-on-21": (replay.RETRIEVAL_ON_CASES, ORDINARY_SEND),
            "preference-27": (preference_cases, ORDINARY_SEND),
            "recent-only-21": (replay.RECENT_ONLY_CASES, None)}


def frozen_inputs(dataset: Path, plan):
    """(question ID, source run) -> (history, runner document, recorded report or None), each verified
    against its recorded runner-input SHA-256 (saved runs) or its projection pin (preference)."""
    saved = [case for name in COHORT_ORDER if name != "preference-27" for case in plan[name][0]]
    out = dict(replay.histories(dataset, saved))
    wanted = [qid for qid, _, _, _ in plan["preference-27"][0]]
    if wanted:
        histories, _manifest = preference.prepare(dataset)
        by_id = {history["episodes"][0]["question_id"]: history for history in histories}
        for qid in wanted:
            document = preference.runner_input(by_id[qid])
            require(e_digest(document, projection=True) == preference.PROJECTION_PINS[qid], "preference_pin_mismatch")
            out[(qid, PREFERENCE_RUN)] = (by_id[qid], document, None)
    return out


def e_digest(document, projection=False):
    value = {key: item for key, item in document.items() if key != "configuration"} if projection else document
    return replay.digest(replay.canonical(value))


def delivered_ranges(recent_ids, evidence, sizes):
    """Runner-shaped delivered ranges from a harness attempt: whole recent sources and excerpts."""
    return ([{"event_id": item["event_id"], "offset": item["offset"], "byte_length": item["bytes"]} for item in evidence]
            + [{"event_id": identifier, "offset": 0, "byte_length": sizes[identifier]} for identifier in recent_ids])


# ----------------------------------------------------------------- offline gold delivery

def gold(args):
    """Offline gold delivery for every declared runner input, before any generation."""
    import retrieval_harness as harness
    output = args.output.absolute()
    require(output.is_relative_to(ROOT / ".build"), "output_outside_build")
    plan = cohorts()
    frozen = frozen_inputs(args.dataset, plan)
    jobs = {}
    for name in COHORT_ORDER:
        cases, retrieval_arm = plan[name]
        for qid, run, strategy, _policy in cases:
            arm = "recent_only" if strategy == "recent_only" else retrieval_arm
            jobs.setdefault((qid, run), set()).add(arm)
    replay.private_directory(output)
    cache_root = output / "harness"
    replay.private_directory(cache_root)
    binary, implementation = harness.compile_harness(cache_root)
    endpoint = harness.OfflineEndpoint(args.tokenizer, 0).start()
    rows = []
    try:
        with tempfile.TemporaryDirectory(prefix="boros-framing-v5-gold-", dir=output) as temporary:
            scratch = Path(temporary)
            os.chmod(scratch, 0o700)
            for (qid, run), arms in jobs.items():
                history, document, _ = frozen[(qid, run)]
                hybrid = [attempt for attempt in document["attempts"] if attempt["strategy"] == "hybrid"][0]
                configuration = dict(document["configuration"], endpoint=endpoint.url)
                base = {"version": 1, "cache_directory": str(cache_root / "stores" / e_digest(document)),
                        "events": document["events"], "configuration": configuration,
                        "question": {key: hybrid[key] for key in ("project_id", "conversation_key", "prompt", "question_time")}}
                selection = harness.run_process(binary, "select", {**base, "arms": sorted(arms), "declared_source_ids": None},
                                                scratch, "select")
                attempts = {item.get("arm"): item for item in selection.get("attempts") or []}
                sizes = {event["id"]: len(event["text"].encode()) for event in document["events"]}
                for arm in sorted(arms):
                    item = attempts.get(arm) or {}
                    ranges = delivered_ranges(item.get("recent_source_ids") or [], item.get("evidence") or [], sizes)
                    rows.append({"question_id": qid, "source_run": run, "arm": arm,
                                 "runner_input_sha256": e_digest(document),
                                 "process_failure": selection.get("process_failure"),
                                 "preparation_completed": bool(item.get("preparation_completed")),
                                 "runner_started": bool(item.get("runner_started")),
                                 "failure": item.get("failure"), "prompt_tokens": item.get("prompt_tokens"),
                                 "delivered_recent": len(item.get("recent_source_ids") or []),
                                 "delivered_excerpts": len(item.get("evidence") or []),
                                 "delivered_ranges_sha256": replay.ranges_digest(ranges),
                                 "delivered_recent_sha256": replay.digest(replay.canonical(item.get("recent_source_ids") or [])),
                                 "question_type": history["episodes"][0]["question_type"],
                                 "abstention": bool(history["episodes"][0]["abstention"]),
                                 **replay.gold_delivery(history, ranges)})
    finally:
        endpoint.stop()
    require(not any(row["runner_started"] for row in rows), "answer_runner_started")
    table = {"version": VERSION, "kind": "offline-gold-delivery", "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
             "method": "retrieval harness delivery binary (Tests/Evaluation/DeliveryHarness.swift) compiled from this "
                       "checkout, loopback tokenizer stand-in with the pinned tokenizer, no answer generation; arms "
                       "ordinary_send (retrieval-on-21, preference-27) and recent_only (recent-only-21); default "
                       "framing V4 with each runner input's own configuration; gold turns scored with "
                       "answer_presentation_replay.gold_delivery (retrieval_harness.coverage)",
             "harness": implementation, "endpoint_counters": endpoint.counters, "rows": rows}
    replay.private_write(output / "gold-delivery.json", replay.canonical(table) + b"\n")
    summary = {}
    for row in rows:
        key = row["arm"]
        summary.setdefault(key, {}).setdefault(row["gold_delivery"], 0)
        summary[key][row["gold_delivery"]] += 1
    print(json.dumps({"rows": len(rows), "failures": sum(1 for row in rows if not row["preparation_completed"]),
                      "gold_delivery": summary, "table_sha256": replay.digest((output / "gold-delivery.json").read_bytes())}))


def gold_lookup(table):
    return {(row["question_id"], row["arm"]): row for row in table["rows"]}


# ----------------------------------------------------------------- declaration

def runs_for(plan, frozen, gold_rows):
    runs = []
    for name in COHORT_ORDER:
        cases, retrieval_arm = plan[name]
        for qid, run, strategy, policy in cases:
            history, document, report = frozen[(qid, run)]
            ordinal = [attempt["strategy"] for attempt in document["attempts"]].index(strategy)
            gold_arm = "recent_only" if strategy == "recent_only" else retrieval_arm
            declared_gold = gold_rows[(qid, gold_arm)]
            require(declared_gold["runner_input_sha256"] == e_digest(document) and declared_gold["preparation_completed"],
                    "gold_row_missing_or_failed")
            for arm, framing in ARMS:
                entry = {"cohort": name, "question_id": qid, "source_run": run, "strategy": strategy,
                         "attempt": ordinal, "component_policy": policy or "selected-model-context-components-v1",
                         "arm": arm, "context_framing": framing, "runner_document_version": document["version"],
                         "runner_input_sha256": e_digest(document),
                         "question_type": history["episodes"][0]["question_type"],
                         "abstention": bool(history["episodes"][0]["abstention"]),
                         "declared_gold_delivery": declared_gold["gold_delivery"],
                         "declared_delivered_ranges_sha256": declared_gold["delivered_ranges_sha256"],
                         "declared_gold_arm": gold_arm,
                         "maximum_output": document["configuration"]["maximum_output"]}
                if report is not None:
                    entry["recorded_binary_sha256"] = report["implementation"].get("binary_sha256")
                if retrieval_arm is not None:
                    entry["retrieval_arm"] = retrieval_arm
                runs.append(entry)
    return runs


def declare(args):
    output = args.output.absolute()
    require(output.is_relative_to(ROOT / ".build"), "output_outside_build")
    binary = args.binary.absolute()
    require(binary.is_file(), "binary_missing")
    require(not replay.git("status", "--porcelain", "--", "Sources", "scripts"), "sources_not_committed")
    gold_raw = args.gold.read_bytes()
    table = json.loads(gold_raw)
    require(table.get("kind") == "offline-gold-delivery", "gold_table_invalid")
    models = replay.live_models()
    require(replay.MODEL in models, "pinned_model_not_listed")
    plan = cohorts()
    frozen = frozen_inputs(args.dataset, plan)
    runs = runs_for(plan, frozen, gold_lookup(table))
    require(len(runs) <= GENERATION_CAP, "generation_cap_exceeded")
    replay.private_directory(output)
    replay.private_directory(output / "inputs")
    written = set()
    for entry in runs:
        if entry["question_id"] in written:
            continue
        _, document, _ = frozen[(entry["question_id"], entry["source_run"])]
        replay.private_write(output / "inputs" / f"{entry['question_id']}.json", replay.canonical(document))
        written.add(entry["question_id"])
    require(all(replay.digest((output / "inputs" / f"{entry['question_id']}.json").read_bytes())
                == entry["runner_input_sha256"] for entry in runs), "input_identity_mismatch")
    questions = {name: [qid for qid, _, _, _ in plan[name][0]] for name in COHORT_ORDER}
    gold_table = {name: {qid: gold_lookup(table)[(qid, "recent_only" if name == "recent-only-21" else ORDINARY_SEND)]["gold_delivery"]
                         for qid in questions[name]} for name in COHORT_ORDER}
    configuration = {key: value for key, value in baseline.CONFIGURATION.items() if key != "system"}
    declaration = {
        "version": VERSION, "declared_at_utc": datetime.now(timezone.utc).isoformat(), "authorization": AUTHORIZATION,
        "cohort": "framing-v5-plan", "cohorts": {name: {"questions": questions[name], "count": len(questions[name]),
                                                        "retrieval_arm": plan[name][1],
                                                        "cases": [list(case) for case in plan[name][0]]}
                                                 for name in COHORT_ORDER},
        "preference_selection": {"population": "single-session-preference questions of the pinned dataset (30)",
                                 "excluded": list(preference.EXCLUDED_CASE_IDS), "selected": len(questions["preference-27"]),
                                 "order": "sha256 rank in domain " + preference.RANK_DOMAIN,
                                 "runner_document_version": preference.VERSION,
                                 "opaque_identity_domain": preference.IDENTITY_DOMAIN,
                                 "projection_pins_sha256": replay.digest(replay.canonical(preference.PROJECTION_PINS))},
        "arms": dict(ARM_DESCRIPTIONS), "arm_order": [arm for arm, _ in ARMS],
        "run_order": "cohorts retrieval-on-21, preference-27, recent-only-21; questions as listed; arms v4-default, "
                     "v5, v4-no-g for each question",
        "gold_delivery_table": gold_table, "gold_delivery_table_sha256": replay.digest(gold_raw),
        "gold_delivery_method": table["method"], "gold_delivery_harness": table["harness"],
        "model": replay.MODEL, "live_models_listed": models, "endpoint": baseline.CONFIGURATION["endpoint"],
        "temperature": baseline.CONFIGURATION["temperature"], "thinking": baseline.CONFIGURATION["thinking"],
        "seed": baseline.CONFIGURATION["seed"], "context_limit": baseline.CONFIGURATION["context_limit"],
        "safety_tokens": baseline.CONFIGURATION["safety_tokens"],
        "maximum_output": {"runner_document_5": 512, "runner_document_7": 1024, "runner_document_9": 1024},
        "configuration_without_system": configuration,
        "generation_limit": len(runs), "generation_cap_authorized": GENERATION_CAP, "generations_per_run": 1,
        "retry_rule": "a run whose answer invocation never started may be retried at most twice and does not count "
                      "toward the generation limit; any run that started an answer invocation counts",
        "remote_calls": "none during generation; default-judge verdicts only, under the judge plan",
        "judge_plan": JUDGE_PLAN, "decision_rule": DECISION_RULE,
        "binary": {"path_name": binary.name, "sha256": replay.digest(binary.read_bytes()),
                   "build_commit": replay.git("rev-parse", "HEAD"), "branch": replay.git("rev-parse", "--abbrev-ref", "HEAD"),
                   "framing_source_sha256": replay.digest((ROOT / "Sources/Boros/ContextSourceFraming.swift").read_bytes()),
                   "assembler_source_sha256": replay.digest((ROOT / "Sources/Boros/ContextAssembler.swift").read_bytes())},
        "detector": {"module": "scripts/answer_presentation_defects.py", "tool_version": apd.TOOL_VERSION,
                     "module_sha256": replay.digest((ROOT / "scripts/answer_presentation_defects.py").read_bytes()),
                     "measures": list(replay.DETECTOR), "decline_extension": RE_SOURCE_DECLINE.pattern,
                     "decline_measure": "decline_opening and outcome as in answer_presentation_replay "
                                        f"({replay.DECLINE_OPENING_CHARACTERS} characters), with the phrase list "
                                        "extended by decline_extension; the unextended outcome is also reported",
                     "driver_sha256": replay.digest((ROOT / "scripts/framing_v5_replay.py").read_bytes())},
        "runs": runs}
    replay.private_write(output / "declaration.json", replay.canonical(declaration) + b"\n")
    replay.private_write(output / "ledger.jsonl", b"")
    print(json.dumps({"declared_runs": len(runs), "generation_limit": len(runs),
                      "cohorts": {name: len(questions[name]) for name in COHORT_ORDER},
                      "binary_sha256": declaration["binary"]["sha256"], "build_commit": declaration["binary"]["build_commit"],
                      "model_listed": True, "declaration_sha256": replay.digest((output / "declaration.json").read_bytes())}))


# ----------------------------------------------------------------- measurement

def decline_outcome(answer):
    """The declared decline measure: the detector's phrases plus the anchored source-decline pattern."""
    lower = answer.lower().replace("’", "'")
    positions = [lower.find(phrase) for phrase in apd.PLAIN_DECLINES if phrase in lower]
    positions += [match.start() for match in RE_SOURCE_DECLINE.finditer(lower)]
    opening = bool(positions) and min(positions) < replay.DECLINE_OPENING_CHARACTERS
    return {"outcome": "decline" if opening else ("partial_decline" if positions else "answer")}


def is_decline(outcome):
    return outcome in ("decline", "partial_decline")


def cites_gold(answer, history, label_map):
    """Whether a cited [E n] label resolves to an annotated gold turn or a gold-session source."""
    cited = set(apd.cited_labels(answer))
    gold_ids = {label["event_id"] for label in history.get("source_labels") or [] if label.get("has_answer") is True}
    sessions = set(history["episodes"][0].get("answer_session_ids") or [])
    session_ids = {label["event_id"] for label in history.get("source_labels") or [] if label.get("session_id") in sessions}
    resolved = {entry["event_id"] for entry in label_map or [] if entry.get("label") in cited}
    return {"cites_gold_turn": bool(resolved & gold_ids), "cites_gold_session": bool(resolved & session_ids)}


def measurement(output: Path, dataset: Path):
    declaration = json.loads((output / "declaration.json").read_text())
    plan = {name: ([tuple(case) for case in value["cases"]], value["retrieval_arm"])
            for name, value in declaration["cohorts"].items()}
    frozen = frozen_inputs(dataset, plan)
    ledger_rows = replay.ledger(output)
    rows = []
    for index, entry in enumerate(declaration["runs"]):
        history, document, _ = frozen[(entry["question_id"], entry["source_run"])]
        require(e_digest(document) == entry["runner_input_sha256"], "frozen_input_changed")
        finished = [row for row in ledger_rows if row["run"] == index and row.get("invocation_started") is True]
        native = output / (finished[-1]["directory"] if finished else "missing")
        row = {key: entry[key] for key in ("cohort", "question_id", "arm", "strategy", "question_type", "abstention",
                                           "declared_gold_delivery")}
        row["run_index"] = index
        if not (native / "report.json").exists():
            rows.append({**row, "status": "not_run"})
            continue
        report = json.loads((native / "report.json").read_text())
        item = [attempt for attempt in report["attempts"] if attempt["ordinal"] == entry["attempt"]][0]
        answer = (native / item["answer_file"]).read_text() if (native / item["answer_file"]).exists() else ""
        probe = history["episodes"][0]
        known = [event["id"] for event in document["events"]]
        expected_framing = entry["context_framing"] or V4
        measured = replay.measure_answer(answer, probe["prompt"], probe["answer"], known, item.get("citation_labels"))
        base_outcome = measured.pop("outcome")
        measured.pop("decline_opening", None)
        delivery = replay.gold_delivery(history, item.get("delivered_ranges"))
        row.update(status="measured", invocation_started=item.get("invocation_started"), failure=item.get("failure"),
                   framing_as_declared=report.get("context_framing") == expected_framing
                   and item.get("context_framing") == expected_framing,
                   retrieval_arm_as_declared=replay.retrieval_arm_as_declared(entry, report, item),
                   prompt_tokens=((item.get("preparation") or {}).get("admission") or {}).get("promptTokens"),
                   delivered_recent=len(item.get("delivered_recent_source_ids") or []),
                   delivered_ranges=len(item.get("delivered_ranges") or []),
                   delivery_matches_declared=replay.ranges_digest(item.get("delivered_ranges"))
                   == entry["declared_delivered_ranges_sha256"],
                   measured_gold_delivery=delivery["gold_delivery"], gold_turns=delivery["gold_turns"],
                   base_outcome=base_outcome, **measured, **decline_outcome(answer),
                   **cites_gold(answer, history, item.get("citation_labels")))
        row["decline_class"] = replay.decline_class(row["outcome"], row["abstention"], row["declared_gold_delivery"])
        rows.append(row)
    ledger = {"answer_generations": sum(1 for row in ledger_rows if row.get("invocation_started") is True),
              "runs_without_answer_invocation": sum(1 for row in ledger_rows
                                                    if row["state"] != "started" and row.get("invocation_started") is False)}
    return {"version": VERSION, "ledger": ledger, "rows": rows, "tables": tables(rows)}


def counts(chosen):
    measured = [row for row in chosen if row.get("status") == "measured"]
    words = sorted(row["answer_words"] for row in measured)
    return {"answers": len(measured), "not_run": len(chosen) - len(measured),
            "decline": sum(1 for row in measured if row["outcome"] == "decline"),
            "partial_decline": sum(1 for row in measured if row["outcome"] == "partial_decline"),
            "base_decline_or_partial": sum(1 for row in measured if is_decline(row["base_outcome"])),
            "false_decline": sum(1 for row in measured if row["decline_class"] == "false_decline"),
            "justified_decline": sum(1 for row in measured if row["decline_class"] == "justified_decline"),
            "decline_partial_gold": sum(1 for row in measured if row["decline_class"] == "decline_partial_gold"),
            "abstention_decline": sum(1 for row in measured if row["decline_class"] == "abstention_decline"),
            "ai_disclaimer": sum(1 for row in measured if row["ai_disclaimer"]),
            "copied_header": sum(row["copied_header"] for row in measured),
            "fabricated_event_ids": sum(row["fabricated_event_ids"] for row in measured),
            "with_raw_event_ids": sum(1 for row in measured if row["raw_event_ids"]),
            "raw_event_ids": sum(row["raw_event_ids"] for row in measured),
            "cited_labels": sum(row["cited_labels"] for row in measured),
            "unresolved_labels": sum(row["unresolved_labels"] for row in measured),
            "answers_citing_gold_turn": sum(1 for row in measured if row["cites_gold_turn"]),
            "answers_citing_gold_session": sum(1 for row in measured if row["cites_gold_session"]),
            "incomplete_result": sum(1 for row in measured if row["failure"] == "incomplete_result"),
            "contains_reference": sum(1 for row in measured if row["contains_reference"]),
            "framing_not_as_declared": sum(1 for row in measured if not row["framing_as_declared"]),
            "retrieval_arm_not_as_declared": sum(1 for row in measured if not row["retrieval_arm_as_declared"]),
            "delivery_differs_from_declared": sum(1 for row in measured if not row["delivery_matches_declared"]),
            "median_words": words[len(words) // 2] if words else None}


SUBSETS = {
    "all": lambda row: True,
    "answerable_gold_whole": lambda row: not row["abstention"] and row["declared_gold_delivery"] == "whole",
    "answerable_gold_partial": lambda row: not row["abstention"] and row["declared_gold_delivery"] == "partial",
    "answerable_gold_none": lambda row: not row["abstention"] and row["declared_gold_delivery"] == "none",
    "abstention": lambda row: row["abstention"],
    "preference": lambda row: row["question_type"] == "single-session-preference",
    "preference_gold_whole": lambda row: row["question_type"] == "single-session-preference"
                                         and row["declared_gold_delivery"] == "whole",
}


def tables(rows):
    out = {}
    for cohort in COHORT_ORDER:
        mine = [row for row in rows if row["cohort"] == cohort]
        out[cohort] = {arm: {"without_54026fce": {name: counts([row for row in mine if row["arm"] == arm
                                                                and row["question_id"] not in EXCLUDED_FROM_DECISION
                                                                and test(row)]) for name, test in SUBSETS.items()},
                             "54026fce": [{key: row.get(key) for key in ("status", "outcome", "decline_class",
                                                                         "measured_gold_delivery", "cited_labels",
                                                                         "cites_gold_turn", "ai_disclaimer")}
                                          for row in mine if row["arm"] == arm and row["question_id"] == "54026fce"]}
                       for arm, _ in ARMS}
    return out


def measure(args):
    result = measurement(args.output.absolute(), args.dataset)
    print(json.dumps({key: result[key] for key in ("version", "ledger", "tables")}, indent=1))


# ----------------------------------------------------------------- judge set and decision

def judge_set(args):
    import judge_calibration as jc
    output = args.output.absolute()
    declaration = json.loads((output / "declaration.json").read_text())
    measured = measurement(output, args.dataset)
    require(all(row.get("status") == "measured" for row in measured["rows"]), "replay_incomplete")
    plan = {name: ([tuple(case) for case in value["cases"]], value["retrieval_arm"])
            for name, value in declaration["cohorts"].items()}
    frozen = frozen_inputs(args.dataset, plan)
    answered = []
    ledger_rows = replay.ledger(output)
    for index, entry in enumerate(declaration["runs"]):
        history, _document, _ = frozen[(entry["question_id"], entry["source_run"])]
        finished = [row for row in ledger_rows if row["run"] == index and row.get("invocation_started") is True]
        native = output / finished[-1]["directory"]
        report = json.loads((native / "report.json").read_text())
        item = [attempt for attempt in report["attempts"] if attempt["ordinal"] == entry["attempt"]][0]
        path = native / item["answer_file"]
        answered.append((index, entry, history, path.read_text() if path.exists() else ""))
    seed = replay.digest((output / "declaration.json").read_bytes())
    items_document, key_document = replay.judge_items("framing-v5", answered, jc.load_dataset(args.dataset), seed)
    manifest = replay.write_judge_set(output / "judge-set", items_document, key_document, "framing-v5-plan", seed)
    print(json.dumps({"set_id": manifest["set_id"], "items": manifest["item_count"],
                      "items_sha256": manifest["items_sha256"], "key_sha256": manifest["key_sha256"],
                      "identifier_substitutions": manifest["identifier_substitutions"],
                      "identity_mention_items": len(manifest["identity_mention_items"])}))


def verdict_rows(measure_rows, key_document, labels_document):
    """Labels joined to measured rows by run index (majority of three, ties unknown)."""
    require(labels_document.get("set_id") == key_document["set_id"], "labels_set_mismatch")
    labels = labels_document["labels"]
    out = []
    for key in sorted(key_document["items"], key=lambda key: key["run_index"]):
        row = measure_rows[key["run_index"]]
        require(row["question_id"] == key["question_id"] and row["arm"] == key["arm"]
                and row["run_index"] == key["run_index"], "key_row_mismatch")
        verdicts = [entry.get("verdict") for entry in labels.get(key["item_id"], [{}, {}, {}])]
        out.append({**row, "replicate_verdicts": verdicts, "verdict": replay.majority_of_three(verdicts)})
    return out


def verdict_tables(rows):
    def tally(chosen):
        return {"answers": len(chosen), **{label: sum(1 for row in chosen if row["verdict"] == label)
                                           for label in ("accept", "reject", "unknown")},
                "split_votes": sum(1 for row in chosen if len(set(row["replicate_verdicts"])) > 1)}
    out = {}
    for cohort in COHORT_ORDER:
        mine = [row for row in rows if row["cohort"] == cohort]
        out[cohort] = {}
        for arm, _ in ARMS:
            chosen = [row for row in mine if row["arm"] == arm and row["question_id"] not in EXCLUDED_FROM_DECISION]
            answerable = [row for row in chosen if not row["abstention"]]
            out[cohort][arm] = {
                "all": tally(chosen), "abstention": tally([row for row in chosen if row["abstention"]]),
                "answerable_gold_whole": tally([row for row in answerable if row["declared_gold_delivery"] == "whole"]),
                "answerable_gold_not_whole": tally([row for row in answerable if row["declared_gold_delivery"] != "whole"]),
                "preference_gold_whole": tally([row for row in chosen if row["question_type"] == "single-session-preference"
                                                and row["declared_gold_delivery"] == "whole"]),
                "lexical_decline": tally([row for row in chosen if is_decline(row["outcome"])]),
                "54026fce": [row["verdict"] for row in mine if row["arm"] == arm and row["question_id"] == "54026fce"]}
    return out


def decision(rows, verdicts=None):
    """The pre-declared rule (DECISION_RULE). ``rows`` are measured rows; ``verdicts`` maps run index
    to the majority verdict, or None when no judge labels exist (R5 then cannot hold)."""
    def subset(arm, test):
        return [row for row in rows if row["arm"] == arm and row["question_id"] not in EXCLUDED_FROM_DECISION
                and test(row)]

    def complete(test):
        return all(row.get("status") == "measured" for arm in ("v5", "v4-default") for row in subset(arm, test))

    def declines(arm, test):
        return sum(1 for row in subset(arm, test) if is_decline(row["outcome"]))

    preference_whole = lambda row: (row["cohort"] in ("retrieval-on-21", "preference-27")  # noqa: E731
                                    and row["question_type"] == "single-session-preference"
                                    and row["declared_gold_delivery"] == "whole")
    abstention = lambda row: row["cohort"] == "retrieval-on-21" and row["abstention"]  # noqa: E731
    recent = lambda row: row["cohort"] == "recent-only-21"  # noqa: E731
    everything = lambda row: True  # noqa: E731
    regression_whole = lambda row: (row["cohort"] == "retrieval-on-21" and not row["abstention"]  # noqa: E731
                                    and row["declared_gold_delivery"] == "whole")
    result = {}
    v4, v5 = declines("v4-default", preference_whole), declines("v5", preference_whole)
    result["R1_preference_declines_reduced"] = {"v4-default": v4, "v5": v5, "questions": len(subset("v5", preference_whole)),
                                                "holds": complete(preference_whole) and v4 > 0 and v5 < v4}
    v4, v5 = declines("v4-default", abstention), declines("v5", abstention)
    result["R2_abstention_declines_kept"] = {"v4-default": v4, "v5": v5, "questions": len(subset("v5", abstention)),
                                             "holds": complete(abstention) and v5 >= v4}
    v4, v5 = declines("v4-default", recent), declines("v5", recent)
    result["R3_recent_only_declines_kept"] = {"v4-default": v4, "v5": v5, "questions": len(subset("v5", recent)),
                                              "holds": complete(recent) and v5 >= v4}
    disclaimers = sum(1 for row in subset("v5", everything) if row.get("ai_disclaimer"))
    result["R4_zero_disclaimers"] = {"v5": disclaimers, "answers": len(subset("v5", everything)),
                                     "holds": complete(everything) and disclaimers == 0}
    if verdicts is None:
        result["R5_gold_whole_accepts_not_lower"] = {"holds": False, "reason": "no_judge_labels"}
    else:
        def accepts(arm):
            return sum(1 for row in subset(arm, regression_whole) if verdicts.get(row["run_index"]) == "accept")
        v4, v5 = accepts("v4-default"), accepts("v5")
        result["R5_gold_whole_accepts_not_lower"] = {"v4-default": v4, "v5": v5,
                                                     "questions": len(subset("v5", regression_whole)),
                                                     "holds": complete(regression_whole) and v5 >= v4}
    result["adopt_v5"] = all(value["holds"] for value in result.values())
    return result


def ablation_comparison(rows, verdicts=None):
    """G versus A: V4 against V4 without G, on the same subsets as the rule (reported, not decided)."""
    def pick(arm, test):
        return [row for row in rows if row["arm"] == arm and row["question_id"] not in EXCLUDED_FROM_DECISION
                and row.get("status") == "measured" and test(row)]
    subsets = {"preference_gold_whole": lambda row: row["cohort"] in ("retrieval-on-21", "preference-27")
               and row["question_type"] == "single-session-preference" and row["declared_gold_delivery"] == "whole",
               "retrieval_on_answerable_gold_whole": lambda row: row["cohort"] == "retrieval-on-21" and not row["abstention"]
               and row["declared_gold_delivery"] == "whole",
               "retrieval_on_abstention": lambda row: row["cohort"] == "retrieval-on-21" and row["abstention"],
               "recent_only": lambda row: row["cohort"] == "recent-only-21"}
    out = {}
    for name, test in subsets.items():
        out[name] = {}
        for arm, _ in ARMS:
            chosen = pick(arm, test)
            out[name][arm] = {"answers": len(chosen), "declines": sum(1 for row in chosen if is_decline(row["outcome"])),
                              "ai_disclaimer": sum(1 for row in chosen if row["ai_disclaimer"])}
            if verdicts is not None:
                out[name][arm]["accept"] = sum(1 for row in chosen if verdicts.get(row["run_index"]) == "accept")
    return out


def judge_summary(args):
    import judge_calibration as jc
    output = args.output.absolute()
    key_document = jc.load_json(output / "judge-set" / "key.json")
    labels_document = jc.load_json(args.labels)
    require(labels_document.get("replicates") == 3 and labels_document.get("complete") is True, "labels_incomplete")
    measured = measurement(output, args.dataset)
    rows = verdict_rows(measured["rows"], key_document, labels_document)
    verdicts = {row["run_index"]: row["verdict"] for row in rows}
    print(json.dumps({"set_id": key_document["set_id"], "judge": labels_document.get("judge"),
                      "declaration_sha256": labels_document.get("declaration_sha256"),
                      "prompts": labels_document.get("prompts"),
                      "rows": [{key: row.get(key) for key in ("run_index", "cohort", "question_id", "arm", "abstention",
                                                              "question_type", "declared_gold_delivery",
                                                              "measured_gold_delivery", "outcome", "decline_class",
                                                              "verdict", "replicate_verdicts")} for row in rows],
                      "verdict_tables": verdict_tables(rows), "decision": decision(measured["rows"], verdicts),
                      "ablation": ablation_comparison(measured["rows"], verdicts)}, indent=1))


def run(args):
    replay.run(args)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("gold", "declare", "run", "measure", "judge-set", "judge-summary"):
        command = commands.add_parser(name)
        command.add_argument("--output", type=Path, required=True)
        if name != "run":
            command.add_argument("--dataset", type=Path, required=True)
        if name in ("declare", "run"):
            command.add_argument("--binary", type=Path, required=True)
        if name == "declare":
            command.add_argument("--gold", type=Path, required=True)
        if name == "gold":
            import retrieval_harness as harness
            command.add_argument("--tokenizer", type=Path, default=harness.DEFAULT_TOKENIZER)
        if name == "judge-summary":
            command.add_argument("--labels", type=Path, required=True)
    args = parser.parse_args(argv)
    import judge_calibration as jc
    import retrieval_harness as harness
    try:
        {"gold": gold, "declare": declare, "run": run, "measure": measure, "judge-set": judge_set,
         "judge-summary": judge_summary}[args.command](args)
    except (PlanError, replay.ReplayError, e.EvaluationError, jc.CalibrationError, harness.HarnessError) as error:
        print(json.dumps({"error": str(error)}))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
