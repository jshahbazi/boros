#!/usr/bin/env python3
"""Framing V4 variants replay: V4 (default) against V4-advice and V4-ordered.

Step 3 of the answer-presentation work (docs/FRAMING-V4-VARIANTS.md). Two narrow System-text variants
of V4, each derived byte for byte from the pinned V4 literal by adding one sentence after the
unchanged fix G sentences:

- ``v4-advice`` (``context-source-snapshot-v4-advice``): V5's advice clause only.
- ``v4-ordered`` (``context-source-snapshot-v4-ordered``): evidence and arithmetic first, the conclusion
  after them, never revising a stated conclusion.

Arms, all through the same verified binary and the existing ``--answer-evaluation`` path:
``v4-default`` (no ``--context-framing`` flag), ``v4-advice`` and ``v4-ordered`` (pinned with
``--context-framing``).

Cohorts, in run order:

- ``retrieval-on-21``: the 21 questions of the saved native runs, recorded hybrid attempt, run with
  ``--retrieval-arm ordinary_send``.
- ``preference-27``: the V5 test's fresh preference cohort (runner document version 9), also with
  ``--retrieval-arm ordinary_send``.
- ``temporal-25``: the 25 answerable temporal-reasoning questions of the development cohort (runner
  document version 10, ``framing_v4_temporal_cases.py``), also with ``--retrieval-arm ordinary_send``.
- ``recent-only-21``: the recent-only attempt of the 21 questions.

Commands:

- ``validate-detector``: the self-contradiction detector against the user's adjudication of the
  likely-wrong extension (stratum ``self_correction``) and of the base set. Counts and item IDs only.
- ``gold``: offline gold delivery for every declared runner input, before any generation.
- ``declare``: freezes the one declaration (arms, cohorts, question lists, gold delivery, settings, cap,
  detector and its validation, and the pre-declared rule per variant) before the first generation.
- ``run``: the replay driver's ledgered runner under this declaration's generation limit.
- ``measure``: counts, identifiers and classes only, and the lexical criteria of both rules.
- ``judge-set``: the blinded verdict items for later grading. No judge is called here.

Privacy: inputs, answers and native reports stay in the private output directory (0700 directories,
0600 files). stdout never carries question, answer, reference, evidence or history text. No remote
call is made by any command; the only network peer is the local model server.
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
import framing_v4_temporal_cases as temporal  # noqa: E402
import framing_v5_preference_cases as preference  # noqa: E402
import framing_v5_replay as v5plan  # noqa: E402

ROOT = replay.ROOT
VERSION = "framing-v4-variants-replay-v1"
V4 = replay.V4
ADVICE = "context-source-snapshot-v4-advice"
ORDERED = "context-source-snapshot-v4-ordered"
# (arm name, --context-framing value or None for the binary's default). Run order per question.
ARMS = (("v4-default", None), ("v4-advice", ADVICE), ("v4-ordered", ORDERED))
ARM_DESCRIPTIONS = {
    "v4-default": "no --context-framing flag: the binary's default, context-source-snapshot-v4 (fixes A, D, G); "
                  "the reported framing is verified at measurement",
    "v4-advice": "context-source-snapshot-v4-advice, pinned with --context-framing: V4 plus only V5's advice clause "
                 "after the unchanged fix G sentences; every other model-visible byte equals V4's",
    "v4-ordered": "context-source-snapshot-v4-ordered, pinned with --context-framing: V4 plus one sentence (evidence and "
                  "date or count arithmetic first, conclusion after, never revise a stated conclusion) after the "
                  "unchanged fix G sentences; every other model-visible byte equals V4's",
}
ORDINARY_SEND = "ordinary_send"
COHORT_ORDER = ("retrieval-on-21", "preference-27", "temporal-25", "recent-only-21")
RETRIEVAL_COHORTS = ("retrieval-on-21", "preference-27", "temporal-25")
EXCLUDED_FROM_DECISION = ("54026fce",)
GENERATION_CAP = 290
AUTHORIZATION = ("user, 2026-10-09, in chat: implement V4-advice and V4-ordered and run local generations only, up to "
                 "290 (V4, V4-advice, V4-ordered on retrieval-on-21, preference-27, the development cohort's "
                 "temporal-reasoning questions and recent-only-21); retries of runs that never started an answer "
                 "invocation do not count; no remote calls; grading by the remote judge is not authorized and is "
                 "not part of this run")
TEMPORAL_TYPE = "temporal-reasoning"
PREFERENCE_TYPE = "single-session-preference"

# --------------------------------------------------------------------------- self-contradiction detector

DETECTOR_VERSION = "boros-self-contradiction-detector-v1"
SELF_CONTRADICTION_DETECTOR = {
    "version": DETECTOR_VERSION,
    "target": "wrong-first-then-corrected answers: an answer that states a conclusion first and later states a "
              "different one, the shape of the gpt4_70e84552 answers (docs/ANSWER-PRESENTATION-DEFECTS.md)",
    "explicit_revision": "judge_calibration.EXPLICIT_REVISION matches anywhere in the answer ('Correction', 'Wait,', "
                         "'Actually,', 'let me re-check', an apology for an error, 'my mistake', ...)",
    "late_reference": "answerable question; a reference target exists (the whole reference, or its first sentence, at "
                      "most 6 normalized tokens); the answer has at least two paragraphs; the first paragraph has an "
                      "answer-like bold headline (the first bold span that does not end with ':' and is not followed "
                      "by ':') of the target's kind (numeric or not); the first paragraph contains no target; the last "
                      "paragraph contains a target in at least one sentence without a conditional marker",
    "conditional_markers": "if, unless, assuming, depending, otherwise, alternatively, whether (a hedge such as "
                           "'if you count only ..., it is two' is not a correction)",
    "normalization": "judge_calibration._normalize_for_heuristic: lowercase, emphasis removed, number words zero to "
                     "twenty as digits, punctuation other than $ and apostrophes as spaces, whitespace collapsed",
    "self_contradiction": "explicit_revision or late_reference",
    "derived_from": "judge_calibration.self_correction_signals (boros-judge-calibration-self-correction-heuristic-v1) "
                    "with three declared changes: answer-like headline, first-sentence reference target, hedge "
                    "exclusion",
}
CONDITIONAL = re.compile(r"\b(?:if|unless|assuming|depending|otherwise|alternatively|whether)\b", re.I)
SENTENCE_SPLIT = re.compile(r"(?<=[.!?])\s+|\n+")


def _jc():
    import judge_calibration as jc
    return jc


def reference_targets(reference):
    """Normalized reference targets of at most six tokens: the whole reference and its first sentence."""
    jc = _jc()
    text = str(reference or "").strip()
    sentences = [part.strip() for part in re.split(r"(?<=[.!?])\s+", text) if part.strip()]
    targets = []
    for candidate in [text] + sentences[:1]:
        normalized = jc._normalize_for_heuristic(candidate.rstrip(".")).strip()
        if normalized and len(normalized.split()) <= 6 and normalized not in targets:
            targets.append(normalized)
    return targets


def answer_headline(paragraph):
    """The first answer-like bold span of a paragraph: not a label ending in or followed by a colon."""
    for match in _jc().BOLD_SPAN.finditer(paragraph):
        span = match.group(1).strip()
        if not span or span.endswith(":") or paragraph[match.end():match.end() + 1] == ":":
            continue
        return span
    return None


def self_contradiction(answer, reference, abstention):
    """The declared detector (SELF_CONTRADICTION_DETECTOR). Booleans only."""
    jc = _jc()
    text = answer or ""
    explicit = bool(jc.EXPLICIT_REVISION.search(text))
    late = False
    paragraphs = [part.strip() for part in re.split(r"\n\s*\n", text.strip()) if part.strip()]
    targets = reference_targets(reference)
    if not abstention and targets and len(paragraphs) >= 2:
        headline = answer_headline(paragraphs[0])
        first = jc._normalize_for_heuristic(paragraphs[0])
        if headline is not None and not any(" " + target + " " in first for target in targets):
            numeric_headline = any(character.isdigit() for character in jc._normalize_for_heuristic(headline))
            kinds = [target for target in targets if any(character.isdigit() for character in target) == numeric_headline]
            sentences = [jc._normalize_for_heuristic(part) for part in SENTENCE_SPLIT.split(paragraphs[-1]) if part.strip()]
            late = any(" " + target + " " in sentence and not CONDITIONAL.search(sentence)
                       for target in kinds for sentence in sentences)
    return {"explicit_revision": explicit, "late_reference": late, "self_contradiction": explicit or late}


def confusion(rows):
    """Detector confusion counts against a truth label: rows of (item ID, truth, predicted)."""
    counts = {"true_positive": [], "false_positive": [], "false_negative": [], "true_negative": []}
    for item_id, truth, predicted in rows:
        key = ("true_" if truth == predicted else "false_") + ("positive" if predicted else "negative")
        counts[key].append(item_id)
    return {key: {"count": len(value), "items": sorted(value)} for key, value in counts.items()}


EXTENSION_SET = Path("/Users/johnshahbazian/development/boros/.claude/worktrees/nervous-kapitsa-65f1d9/.build/"
                     "judge-calibration/set-x1-20261009")
EXTENSION_ADJUDICATION = EXTENSION_SET.parent / "adjudications-jx-6dbd69dec7456178.json"
BASE_SET = EXTENSION_SET.parent / "set-v1-20261008"
# The user's self-correction decisions (docs/JUDGE-CALIBRATION.md, "Self-corrections" and "Human adjudication of
# the extension"): six self-corrections across the 79 items, all rejected. Every other item is not one.
SELF_CORRECTIONS = {"extension": ("item-004", "item-008", "item-009", "item-017"), "base": ("item-010", "item-011")}


def detector_validation(extension_set: Path = EXTENSION_SET, adjudication: Path = EXTENSION_ADJUDICATION,
                        base_set: Path = BASE_SET):
    """Detector confusion on the 7 extension self-correction items (primary), the other 22 extension items and
    the 50 base items. Truth is the user's self-correction decision. IDs and counts only."""
    jc = _jc()
    key = jc.load_json(extension_set / "key.json")
    items = {item["item_id"]: item for item in jc.load_json(extension_set / "items.json")["items"]}
    decisions = jc.load_json(adjudication)["decisions"]
    rejected = {item_id for item_id, value in decisions.items() if value.get("verdict") == "reject"}
    require(rejected == set(SELF_CORRECTIONS["extension"]), "extension_self_corrections_changed")
    primary, rest = [], []
    for entry in key["items"]:
        item = items[entry["item_id"]]
        predicted = self_contradiction(item["answer"], item["reference"], item["abstention"])["self_contradiction"]
        row = (entry["item_id"], entry["item_id"] in SELF_CORRECTIONS["extension"], predicted)
        (primary if entry["stratum"] == "self_correction" else rest).append(row)
    require(len(primary) == 7, "extension_self_correction_stratum_not_seven")
    base_rows = []
    if (base_set / "items.json").exists():
        for item in jc.load_json(base_set / "items.json")["items"]:
            predicted = self_contradiction(item["answer"], item["reference"], item["abstention"])["self_contradiction"]
            base_rows.append((item["item_id"], item["item_id"] in SELF_CORRECTIONS["base"], predicted))
    return {"detector": DETECTOR_VERSION,
            "extension_set_id": key["set_id"], "extension_items_sha256": replay.digest((extension_set / "items.json").read_bytes()),
            "adjudication_sha256": replay.digest(adjudication.read_bytes()),
            "self_correction_stratum_7": confusion(primary), "extension_other_22": confusion(rest),
            "base_50": confusion(base_rows) if base_rows else None,
            "base_set_items_sha256": replay.digest((base_set / "items.json").read_bytes()) if base_rows else None,
            "truth": "the user's adjudication: the self-correction rejects (extension 004, 008, 009, 017; base 010, "
                     "011); every other item is not a self-correction",
            "in_sample": "the detector's three changes were chosen with these items' documented descriptions in view; "
                         "the counts are in-sample"}


def validate_detector(args):
    result = detector_validation()
    print(json.dumps({key: ({name: value["count"] for name, value in result[key].items()} if isinstance(result.get(key), dict)
                            and "true_positive" in result[key] else result[key]) for key in result}, indent=1))
    print(json.dumps({"items": {name: result[name] for name in ("self_correction_stratum_7", "extension_other_22", "base_50")}}))


# --------------------------------------------------------------------------- cohorts and inputs

class PlanError(Exception):
    """Fixed, content-free reason codes only."""


def require(condition, code):
    if not condition:
        raise PlanError(code)


def cohorts():
    """The four cohorts in run order: name -> (cases, retrieval arm)."""
    base = v5plan.cohorts()
    temporal_cases = tuple((qid, temporal.COHORT, "hybrid", None) for qid in temporal.PROJECTION_PINS)
    return {"retrieval-on-21": base["retrieval-on-21"], "preference-27": base["preference-27"],
            "temporal-25": (temporal_cases, ORDINARY_SEND), "recent-only-21": base["recent-only-21"]}


def frozen_inputs(dataset: Path, plan):
    """(question ID, source run) -> (history, runner document, recorded report or None), verified against the
    recorded runner-input SHA-256 (saved runs) or the projection pins (preference, temporal)."""
    out = v5plan.frozen_inputs(dataset, {name: plan[name] for name in ("retrieval-on-21", "preference-27", "recent-only-21")})
    wanted = [qid for qid, _, _, _ in plan["temporal-25"][0]]
    if wanted:
        histories, _manifest = temporal.prepare(dataset)
        by_id = {history["episodes"][0]["question_id"]: history for history in histories}
        for qid in wanted:
            document = temporal.runner_input(by_id[qid])
            require(v5plan.e_digest(document, projection=True) == temporal.PROJECTION_PINS[qid], "temporal_pin_mismatch")
            out[(qid, temporal.COHORT)] = (by_id[qid], document, None)
    return out


def gold_arm(cohort, strategy):
    return "recent_only" if strategy == "recent_only" else cohorts()[cohort][1]


# --------------------------------------------------------------------------- offline gold delivery

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
            jobs.setdefault((qid, run), set()).add("recent_only" if strategy == "recent_only" else retrieval_arm)
    replay.private_directory(output)
    cache_root = output / "harness"
    replay.private_directory(cache_root)
    binary, implementation = harness.compile_harness(cache_root)
    endpoint = harness.OfflineEndpoint(args.tokenizer, 0).start()
    rows = []
    try:
        with tempfile.TemporaryDirectory(prefix="boros-framing-v4-variants-gold-", dir=output) as scratch_name:
            scratch = Path(scratch_name)
            os.chmod(scratch, 0o700)
            for (qid, run), arms in jobs.items():
                history, document, _ = frozen[(qid, run)]
                hybrid = [attempt for attempt in document["attempts"] if attempt["strategy"] == "hybrid"][0]
                configuration = dict(document["configuration"], endpoint=endpoint.url)
                base = {"version": 1, "cache_directory": str(cache_root / "stores" / v5plan.e_digest(document)),
                        "events": document["events"], "configuration": configuration,
                        "question": {key: hybrid[key] for key in ("project_id", "conversation_key", "prompt", "question_time")}}
                selection = harness.run_process(binary, "select", {**base, "arms": sorted(arms), "declared_source_ids": None},
                                                scratch, "select")
                attempts = {item.get("arm"): item for item in selection.get("attempts") or []}
                sizes = {event["id"]: len(event["text"].encode()) for event in document["events"]}
                for arm in sorted(arms):
                    item = attempts.get(arm) or {}
                    ranges = v5plan.delivered_ranges(item.get("recent_source_ids") or [], item.get("evidence") or [], sizes)
                    rows.append({"question_id": qid, "source_run": run, "arm": arm,
                                 "runner_input_sha256": v5plan.e_digest(document),
                                 "process_failure": selection.get("process_failure"),
                                 "preparation_completed": bool(item.get("preparation_completed")),
                                 "runner_started": bool(item.get("runner_started")),
                                 "failure": item.get("failure"), "prompt_tokens": item.get("prompt_tokens"),
                                 "delivered_recent": len(item.get("recent_source_ids") or []),
                                 "delivered_excerpts": len(item.get("evidence") or []),
                                 "delivered_ranges_sha256": replay.ranges_digest(ranges),
                                 "question_type": history["episodes"][0]["question_type"],
                                 "abstention": bool(history["episodes"][0]["abstention"]),
                                 **replay.gold_delivery(history, ranges)})
    finally:
        endpoint.stop()
    require(not any(row["runner_started"] for row in rows), "answer_runner_started")
    table = {"version": VERSION, "kind": "offline-gold-delivery", "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
             "method": "retrieval harness delivery binary (Tests/Evaluation/DeliveryHarness.swift) compiled from this "
                       "checkout, loopback tokenizer stand-in with the pinned tokenizer, no answer generation; arms "
                       "ordinary_send (retrieval-on-21, preference-27, temporal-25) and recent_only (recent-only-21); "
                       "default framing V4 with each runner input's own configuration; gold turns scored with "
                       "answer_presentation_replay.gold_delivery (retrieval_harness.coverage)",
             "harness": implementation, "endpoint_counters": endpoint.counters, "rows": rows}
    replay.private_write(output / "gold-delivery.json", replay.canonical(table) + b"\n")
    summary = {}
    for row in rows:
        summary.setdefault(row["arm"], {}).setdefault(row["gold_delivery"], 0)
        summary[row["arm"]][row["gold_delivery"]] += 1
    print(json.dumps({"rows": len(rows), "failures": sum(1 for row in rows if not row["preparation_completed"]),
                      "gold_delivery": summary, "table_sha256": replay.digest((output / "gold-delivery.json").read_bytes())}))


# --------------------------------------------------------------------------- declaration

DECISION_RULES = {
    "common": {
        "excluded_question": "54026fce is reported separately in every cohort and excluded from every count below",
        "decline": "lexical outcome decline or partial_decline under the declared decline measure (the V5 test's: "
                   "detector phrase list plus the anchored source-decline pattern), on the measured answer",
        "gold_class": "the pre-declared offline gold delivery of the declaration's gold table; a runner delivery that "
                      "differs is reported, not reclassified",
        "missing": "a criterion whose subset has a run without a measured answer in either compared arm is "
                   "inconclusive, which counts as not holding",
        "judged_accepts": "PENDING. Grading by the remote judge is not authorized for this run (the user is still "
                          "choosing the default judge). Judged-accept criteria will be added, before any grading, "
                          "when grading is authorized. Until then neither variant can be recommended as a "
                          "replacement; the lexical criteria below are necessary, not sufficient.",
        "outcome": "each variant is reported as meeting or failing its lexical criteria; this replay changes no "
                   "default",
    },
    "v4-advice": {
        "compared_arms": ["v4-advice", "v4-default"],
        "A1_fewer_false_declines_on_preference_gold_whole": "over the preference questions (question type "
            "single-session-preference) of retrieval-on-21 and preference-27 whose declared gold delivery is whole: "
            "declines(v4-advice) < declines(v4-default). A tie fails. If v4-default has 0 such declines, A1 fails.",
        "A2_abstention_declines_kept": "over the 3 abstention questions of retrieval-on-21: declines(v4-advice) >= "
            "declines(v4-default).",
        "A3_recent_only_declines_kept": "over recent-only-21 without 54026fce (20 answers per arm, all without "
            "delivered gold, so every decline there is correct): declines(v4-advice) >= declines(v4-default).",
        "A4_zero_disclaimers": "v4-advice has 0 AI or memory disclaimers over all its answers in the four cohorts.",
        "candidate": "V4-advice is a candidate replacement for V4 on the lexical criteria only if A1 to A4 all hold; "
                     "the judged-accept criteria are pending",
    },
    "v4-ordered": {
        "compared_arms": ["v4-ordered", "v4-default"],
        "O1_fewer_self_contradictions_on_temporal": "over the answerable temporal-reasoning questions of "
            "retrieval-on-21 and temporal-25 (2 + 25 = 27 per arm): answers flagged self_contradiction by the "
            "declared detector (boros-self-contradiction-detector-v1): count(v4-ordered) < count(v4-default). A tie "
            "fails. If v4-default has 0 flagged answers, O1 fails.",
        "O2_no_more_declines_on_gold_whole": "over the answerable questions of retrieval-on-21, preference-27 and "
            "temporal-25 whose declared gold delivery is whole: declines(v4-ordered) <= declines(v4-default).",
        "O3_zero_disclaimers": "v4-ordered has 0 AI or memory disclaimers over all its answers in the four cohorts.",
        "candidate": "V4-ordered is a candidate replacement for V4 on the lexical criteria only if O1 to O3 all hold; "
                     "the judged-accept criteria are pending",
    },
}


def runs_for(plan, frozen, gold_rows):
    runs = []
    for name in COHORT_ORDER:
        cases, retrieval_arm = plan[name]
        for qid, run, strategy, policy in cases:
            history, document, report = frozen[(qid, run)]
            ordinal = [attempt["strategy"] for attempt in document["attempts"]].index(strategy)
            arm_for_gold = "recent_only" if strategy == "recent_only" else retrieval_arm
            declared_gold = gold_rows[(qid, arm_for_gold)]
            require(declared_gold["runner_input_sha256"] == v5plan.e_digest(document) and declared_gold["preparation_completed"],
                    "gold_row_missing_or_failed")
            for arm, framing in ARMS:
                entry = {"cohort": name, "question_id": qid, "source_run": run, "strategy": strategy,
                         "attempt": ordinal, "component_policy": policy or "selected-model-context-components-v1",
                         "arm": arm, "context_framing": framing, "runner_document_version": document["version"],
                         "runner_input_sha256": v5plan.e_digest(document),
                         "question_type": history["episodes"][0]["question_type"],
                         "abstention": bool(history["episodes"][0]["abstention"]),
                         "declared_gold_delivery": declared_gold["gold_delivery"],
                         "declared_delivered_ranges_sha256": declared_gold["delivered_ranges_sha256"],
                         "declared_gold_arm": arm_for_gold,
                         "maximum_output": document["configuration"]["maximum_output"]}
                if report is not None:
                    entry["recorded_binary_sha256"] = report["implementation"].get("binary_sha256")
                if retrieval_arm is not None:
                    entry["retrieval_arm"] = retrieval_arm
                runs.append(entry)
    return runs


def input_name(entry):
    return f"{entry['cohort']}--{entry['question_id']}.json"


def declare(args):
    output = args.output.absolute()
    require(output.is_relative_to(ROOT / ".build"), "output_outside_build")
    binary = args.binary.absolute()
    require(binary.is_file(), "binary_missing")
    require(not replay.git("status", "--porcelain", "--", "Sources", "scripts"), "sources_not_committed")
    gold_raw = args.gold.read_bytes()
    table = json.loads(gold_raw)
    require(table.get("kind") == "offline-gold-delivery" and table.get("version") == VERSION, "gold_table_invalid")
    validation = detector_validation()
    models = replay.live_models()
    require(replay.MODEL in models, "pinned_model_not_listed")
    plan = cohorts()
    frozen = frozen_inputs(args.dataset, plan)
    runs = runs_for(plan, frozen, v5plan.gold_lookup(table))
    require(len(runs) <= GENERATION_CAP, "generation_cap_exceeded")
    replay.private_directory(output)
    replay.private_directory(output / "inputs")
    for entry in runs:
        path = output / "inputs" / input_name(entry)
        if not path.exists():
            _, document, _ = frozen[(entry["question_id"], entry["source_run"])]
            replay.private_write(path, replay.canonical(document))
        require(replay.digest(path.read_bytes()) == entry["runner_input_sha256"], "input_identity_mismatch")
    questions = {name: [qid for qid, _, _, _ in plan[name][0]] for name in COHORT_ORDER}
    lookup = v5plan.gold_lookup(table)
    gold_table = {name: {qid: lookup[(qid, "recent_only" if name == "recent-only-21" else ORDINARY_SEND)]["gold_delivery"]
                         for qid in questions[name]} for name in COHORT_ORDER}
    _, temporal_manifest = temporal.prepare(args.dataset)
    configuration = {key: value for key, value in baseline.CONFIGURATION.items() if key != "system"}
    declaration = {
        "version": VERSION, "declared_at_utc": datetime.now(timezone.utc).isoformat(), "authorization": AUTHORIZATION,
        "cohort": "framing-v4-variants-plan",
        "cohorts": {name: {"questions": questions[name], "count": len(questions[name]), "retrieval_arm": plan[name][1],
                           "cases": [list(case) for case in plan[name][0]]} for name in COHORT_ORDER},
        "preference_selection": {"source": "the framing V5 test's preference-27 cohort, unchanged",
                                 "runner_document_version": preference.VERSION,
                                 "projection_pins_sha256": replay.digest(replay.canonical(preference.PROJECTION_PINS))},
        "temporal_selection": {key: temporal_manifest[key] for key in (
            "cohort", "development_cohort", "development_selection_version", "selection_rule",
            "temporal_abstention_left_out", "declared_questions", "runner_document_version", "opaque_identity_domain")}
        | {"overlap_with_retrieval_on_21": sorted(set(questions["temporal-25"]) & set(questions["retrieval-on-21"])),
           "projection_pins_sha256": replay.digest(replay.canonical(temporal.PROJECTION_PINS)),
           "construction": "native_investigation_hundred_cases._history (the version-8 development runner document) "
                           "with only the runner document version changed to 10"},
        "arms": dict(ARM_DESCRIPTIONS), "arm_order": [arm for arm, _ in ARMS],
        "run_order": "cohorts retrieval-on-21, preference-27, temporal-25, recent-only-21; questions as listed; arms "
                     "v4-default, v4-advice, v4-ordered for each question",
        "gold_delivery_table": gold_table, "gold_delivery_table_sha256": replay.digest(gold_raw),
        "gold_delivery_method": table["method"], "gold_delivery_harness": table["harness"],
        "model": replay.MODEL, "live_models_listed": models, "endpoint": baseline.CONFIGURATION["endpoint"],
        "temperature": baseline.CONFIGURATION["temperature"], "thinking": baseline.CONFIGURATION["thinking"],
        "seed": baseline.CONFIGURATION["seed"], "context_limit": baseline.CONFIGURATION["context_limit"],
        "safety_tokens": baseline.CONFIGURATION["safety_tokens"],
        "maximum_output": {"runner_document_5": 512, "runner_document_7": 1024, "runner_document_9": 1024,
                           "runner_document_10": 1024},
        "configuration_without_system": configuration,
        "generation_limit": len(runs), "generation_cap_authorized": GENERATION_CAP, "generations_per_run": 1,
        "retry_rule": "a run whose answer invocation never started may be retried at most twice and does not count "
                      "toward the generation limit; any run that started an answer invocation counts",
        "remote_calls": "none; the only network peer is the local model server. Judge grading is not part of this run.",
        "judge_plan": "pending: the blinded verdict items are prepared by judge-set for later grading; no judge is "
                      "called, and the judged-accept criteria are added when grading is authorized",
        "decision_rules": DECISION_RULES,
        "self_contradiction_detector": SELF_CONTRADICTION_DETECTOR,
        "self_contradiction_detector_validation": {
            key: ({name: value["count"] for name, value in validation[key].items()} if isinstance(validation.get(key), dict)
                  and "true_positive" in validation[key] else validation[key]) for key in validation},
        "binary": {"path_name": binary.name, "sha256": replay.digest(binary.read_bytes()),
                   "build_commit": replay.git("rev-parse", "HEAD"), "branch": replay.git("rev-parse", "--abbrev-ref", "HEAD"),
                   "framing_source_sha256": replay.digest((ROOT / "Sources/Boros/ContextSourceFraming.swift").read_bytes()),
                   "assembler_source_sha256": replay.digest((ROOT / "Sources/Boros/ContextAssembler.swift").read_bytes())},
        "detector": {"module": "scripts/answer_presentation_defects.py", "tool_version": apd.TOOL_VERSION,
                     "module_sha256": replay.digest((ROOT / "scripts/answer_presentation_defects.py").read_bytes()),
                     "measures": list(replay.DETECTOR), "decline_extension": v5plan.RE_SOURCE_DECLINE.pattern,
                     "decline_measure": "framing_v5_replay.decline_outcome: decline_opening and outcome as in "
                                        f"answer_presentation_replay ({replay.DECLINE_OPENING_CHARACTERS} characters), "
                                        "with the phrase list extended by decline_extension",
                     "driver_sha256": replay.digest((ROOT / "scripts/framing_v4_variants_replay.py").read_bytes())},
        "runs": runs}
    replay.private_write(output / "declaration.json", replay.canonical(declaration) + b"\n")
    replay.private_write(output / "ledger.jsonl", b"")
    print(json.dumps({"declared_runs": len(runs), "generation_limit": len(runs),
                      "cohorts": {name: len(questions[name]) for name in COHORT_ORDER},
                      "binary_sha256": declaration["binary"]["sha256"], "build_commit": declaration["binary"]["build_commit"],
                      "model_listed": True, "declaration_sha256": replay.digest((output / "declaration.json").read_bytes())}))


# --------------------------------------------------------------------------- run

def run(args):
    """The ledgered runner of answer_presentation_replay.run, with cohort-qualified input files."""
    output = args.output.absolute()
    declaration = json.loads((output / "declaration.json").read_text())
    require(declaration.get("version") == VERSION, "declaration_version_mismatch")
    binary = args.binary.absolute()
    require(replay.digest(binary.read_bytes()) == declaration["binary"]["sha256"], "binary_identity_mismatch")
    require(replay.MODEL in replay.live_models(), "pinned_model_not_listed")
    import subprocess
    for index, entry in enumerate(declaration["runs"]):
        done = replay.ledger(output)
        rows = [row for row in done if row["run"] == index]
        if any(row.get("invocation_started") is True for row in rows):
            continue
        tries = sum(1 for row in rows if row["state"] == "started")
        require(all(any(other["run"] == row["run"] and other["state"] != "started" and other.get("try") == row.get("try")
                        for other in done) for row in done if row["state"] == "started"), "unfinished_run_in_ledger")
        require(tries < 3, "retry_limit_reached")
        require(all(row.get("invocation_started") is not None for row in done if row["state"] == "finished"),
                "unknown_invocation_state_in_ledger")
        generations = sum(1 for row in done if row.get("invocation_started") is True)
        require(generations < declaration["generation_limit"], "generation_limit_reached")
        input_path = output / "inputs" / input_name(entry)
        require(replay.digest(input_path.read_bytes()) == entry["runner_input_sha256"], "frozen_input_changed")
        native = output / (f"run-{index:03d}-{entry['cohort']}-{entry['question_id']}-{entry['arm']}"
                           + (f"-try{tries}" if tries else ""))
        command = replay.runner_command(binary, input_path, native, entry)
        with open(output / "ledger.jsonl", "a") as handle:
            handle.write(json.dumps({"run": index, "state": "started", "try": tries or None}) + "\n")
        process = subprocess.run(command, capture_output=True, timeout=3600,
                                 env={**os.environ, "BOROS_DATA_DIR": str(output / "unused-app-runtime")})
        report = json.loads((native / "report.json").read_text()) if (native / "report.json").exists() else {}
        attempts = [item for item in report.get("attempts", []) if item.get("ordinal") == entry["attempt"]]
        item = attempts[0] if attempts else {}
        with open(output / "ledger.jsonl", "a") as handle:
            handle.write(json.dumps({"run": index, "state": "finished", "try": tries or None, "directory": native.name,
                                     "returncode": process.returncode,
                                     "invocation_started": item.get("invocation_started"),
                                     "failure": item.get("failure")}) + "\n")
        print(json.dumps({"run": index, "cohort": entry["cohort"], "question_id": entry["question_id"], "arm": entry["arm"],
                          "returncode": process.returncode, "invocation_started": item.get("invocation_started"),
                          "failure": item.get("failure")}), flush=True)


# --------------------------------------------------------------------------- measurement

def native_attempt(output, ledger_rows, index, entry):
    finished = [row for row in ledger_rows if row["run"] == index and row.get("invocation_started") is True]
    native = output / (finished[-1]["directory"] if finished else "missing")
    if not (native / "report.json").exists():
        return None, None, None
    report = json.loads((native / "report.json").read_text())
    item = [attempt for attempt in report["attempts"] if attempt["ordinal"] == entry["attempt"]][0]
    path = native / item["answer_file"]
    return report, item, (path.read_text() if path.exists() else "")


def measurement(output: Path, dataset: Path):
    declaration = json.loads((output / "declaration.json").read_text())
    require(declaration.get("version") == VERSION, "declaration_version_mismatch")
    plan = {name: ([tuple(case) for case in value["cases"]], value["retrieval_arm"])
            for name, value in declaration["cohorts"].items()}
    frozen = frozen_inputs(dataset, plan)
    ledger_rows = replay.ledger(output)
    rows = []
    for index, entry in enumerate(declaration["runs"]):
        history, document, _ = frozen[(entry["question_id"], entry["source_run"])]
        require(v5plan.e_digest(document) == entry["runner_input_sha256"], "frozen_input_changed")
        row = {key: entry[key] for key in ("cohort", "question_id", "arm", "strategy", "question_type", "abstention",
                                           "declared_gold_delivery")}
        row["run_index"] = index
        report, item, answer = native_attempt(output, ledger_rows, index, entry)
        if report is None:
            rows.append({**row, "status": "not_run"})
            continue
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
                   delivery_matches_declared=replay.ranges_digest(item.get("delivered_ranges"))
                   == entry["declared_delivered_ranges_sha256"],
                   measured_gold_delivery=delivery["gold_delivery"], base_outcome=base_outcome, **measured,
                   **v5plan.decline_outcome(answer), **v5plan.cites_gold(answer, history, item.get("citation_labels")),
                   **self_contradiction(answer, probe["answer"], bool(probe["abstention"])))
        row["decline_class"] = replay.decline_class(row["outcome"], row["abstention"], row["declared_gold_delivery"])
        rows.append(row)
    ledger = {"answer_generations": sum(1 for row in ledger_rows if row.get("invocation_started") is True),
              "runs_without_answer_invocation": sum(1 for row in ledger_rows
                                                    if row["state"] != "started" and row.get("invocation_started") is False)}
    return {"version": VERSION, "ledger": ledger, "rows": rows, "tables": tables(rows), "decision": decision(rows),
            "flagged": flagged(rows)}


def counts(chosen):
    measured = [row for row in chosen if row.get("status") == "measured"]
    words = sorted(row["answer_words"] for row in measured)
    return {"answers": len(measured), "not_run": len(chosen) - len(measured),
            "decline": sum(1 for row in measured if row["outcome"] == "decline"),
            "partial_decline": sum(1 for row in measured if row["outcome"] == "partial_decline"),
            "base_decline_or_partial": sum(1 for row in measured if v5plan.is_decline(row["base_outcome"])),
            "false_decline": sum(1 for row in measured if row["decline_class"] == "false_decline"),
            "justified_decline": sum(1 for row in measured if row["decline_class"] == "justified_decline"),
            "decline_partial_gold": sum(1 for row in measured if row["decline_class"] == "decline_partial_gold"),
            "abstention_decline": sum(1 for row in measured if row["decline_class"] == "abstention_decline"),
            "ai_disclaimer": sum(1 for row in measured if row["ai_disclaimer"]),
            "copied_header": sum(row["copied_header"] for row in measured),
            "fabricated_event_ids": sum(row["fabricated_event_ids"] for row in measured),
            "with_raw_event_ids": sum(1 for row in measured if row["raw_event_ids"]),
            "raw_event_ids": sum(row["raw_event_ids"] for row in measured),
            "self_contradiction": sum(1 for row in measured if row["self_contradiction"]),
            "explicit_revision": sum(1 for row in measured if row["explicit_revision"]),
            "late_reference": sum(1 for row in measured if row["late_reference"]),
            "cited_labels": sum(row["cited_labels"] for row in measured),
            "unresolved_labels": sum(row["unresolved_labels"] for row in measured),
            "answers_citing_gold_turn": sum(1 for row in measured if row["cites_gold_turn"]),
            "contains_reference": sum(1 for row in measured if row["contains_reference"]),
            "latex": sum(1 for row in measured if row["latex"]),
            "incomplete_result": sum(1 for row in measured if row["failure"] == "incomplete_result"),
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
    "preference_gold_whole": lambda row: row["question_type"] == PREFERENCE_TYPE and row["declared_gold_delivery"] == "whole",
    "temporal_answerable": lambda row: row["question_type"] == TEMPORAL_TYPE and not row["abstention"],
}


def tables(rows):
    out = {}
    for cohort in COHORT_ORDER:
        mine = [row for row in rows if row["cohort"] == cohort]
        out[cohort] = {arm: {"without_54026fce": {name: counts([row for row in mine if row["arm"] == arm
                                                                and row["question_id"] not in EXCLUDED_FROM_DECISION
                                                                and test(row)]) for name, test in SUBSETS.items()},
                             "54026fce": [{key: row.get(key) for key in ("status", "outcome", "decline_class",
                                                                         "cited_labels", "ai_disclaimer",
                                                                         "self_contradiction")}
                                          for row in mine if row["arm"] == arm and row["question_id"] == "54026fce"]}
                       for arm, _ in ARMS}
    return out


def flagged(rows):
    """Question IDs per cohort and arm for declines by class, disclaimers, headers, raw IDs and self-contradictions."""
    out = {}
    for cohort in COHORT_ORDER:
        out[cohort] = {}
        for arm, _ in ARMS:
            mine = [row for row in rows if row["cohort"] == cohort and row["arm"] == arm and row.get("status") == "measured"]
            out[cohort][arm] = {
                name: sorted(row["question_id"] for row in mine if test(row)) for name, test in {
                    "false_decline": lambda row: row["decline_class"] == "false_decline",
                    "justified_decline": lambda row: row["decline_class"] == "justified_decline",
                    "decline_partial_gold": lambda row: row["decline_class"] == "decline_partial_gold",
                    "abstention_decline": lambda row: row["decline_class"] == "abstention_decline",
                    "abstention_answered": lambda row: row["abstention"] and not v5plan.is_decline(row["outcome"]),
                    "ai_disclaimer": lambda row: bool(row["ai_disclaimer"]),
                    "copied_header": lambda row: bool(row["copied_header"]),
                    "raw_event_ids": lambda row: bool(row["raw_event_ids"]),
                    "self_contradiction": lambda row: bool(row["self_contradiction"]),
                    "incomplete_result": lambda row: row["failure"] == "incomplete_result",
                }.items()}
    return out


def decision(rows):
    """The lexical criteria of both pre-declared rules (DECISION_RULES). Judged accepts are pending."""
    def subset(arm, test):
        return [row for row in rows if row["arm"] == arm and row["question_id"] not in EXCLUDED_FROM_DECISION and test(row)]

    def complete(variant, test):
        return all(row.get("status") == "measured" for arm in (variant, "v4-default") for row in subset(arm, test))

    def declines(arm, test):
        return sum(1 for row in subset(arm, test) if v5plan.is_decline(row.get("outcome")))

    def flagged_count(arm, test):
        return sum(1 for row in subset(arm, test) if row.get("self_contradiction"))

    preference_whole = lambda row: (row["cohort"] in ("retrieval-on-21", "preference-27")  # noqa: E731
                                    and row["question_type"] == PREFERENCE_TYPE and row["declared_gold_delivery"] == "whole")
    abstention = lambda row: row["cohort"] == "retrieval-on-21" and row["abstention"]  # noqa: E731
    recent = lambda row: row["cohort"] == "recent-only-21"  # noqa: E731
    everything = lambda row: True  # noqa: E731
    temporal_rows = lambda row: (row["cohort"] in ("retrieval-on-21", "temporal-25")  # noqa: E731
                                 and row["question_type"] == TEMPORAL_TYPE and not row["abstention"])
    gold_whole = lambda row: (row["cohort"] in RETRIEVAL_COHORTS and not row["abstention"]  # noqa: E731
                              and row["declared_gold_delivery"] == "whole")

    def criterion(variant, test, measure, compare):
        base, mine = measure("v4-default", test), measure(variant, test)
        return {"v4-default": base, variant: mine, "questions": len(subset(variant, test)),
                "holds": complete(variant, test) and compare(mine, base)}

    def disclaimers(variant):
        count = sum(1 for row in subset(variant, everything) if row.get("ai_disclaimer"))
        return {variant: count, "answers": len(subset(variant, everything)), "holds": complete(variant, everything) and count == 0}

    advice = {"A1_fewer_false_declines_on_preference_gold_whole": criterion(
                  "v4-advice", preference_whole, declines, lambda mine, base: base > 0 and mine < base),
              "A2_abstention_declines_kept": criterion("v4-advice", abstention, declines, lambda mine, base: mine >= base),
              "A3_recent_only_declines_kept": criterion("v4-advice", recent, declines, lambda mine, base: mine >= base),
              "A4_zero_disclaimers": disclaimers("v4-advice")}
    advice["lexical_criteria_hold"] = all(value["holds"] for value in advice.values())
    ordered = {"O1_fewer_self_contradictions_on_temporal": criterion(
                   "v4-ordered", temporal_rows, flagged_count, lambda mine, base: base > 0 and mine < base),
               "O2_no_more_declines_on_gold_whole": criterion("v4-ordered", gold_whole, declines,
                                                              lambda mine, base: mine <= base),
               "O3_zero_disclaimers": disclaimers("v4-ordered")}
    ordered["lexical_criteria_hold"] = all(value["holds"] for value in ordered.values())
    return {"v4-advice": advice, "v4-ordered": ordered, "judged_accepts": "pending (grading not authorized)"}


def measure(args):
    output = args.output.absolute()
    result = measurement(output, args.dataset)
    replay.private_write(output / "measure.json", replay.canonical(result) + b"\n")
    print(json.dumps({key: result[key] for key in ("version", "ledger", "decision")}, indent=1))


# --------------------------------------------------------------------------- judge-ready items (no judge call)

def judge_set(args):
    """Writes the private, blinded verdict item set for later grading. No judge or remote call."""
    import judge_calibration as jc
    output = args.output.absolute()
    declaration = json.loads((output / "declaration.json").read_text())
    measured = measurement(output, args.dataset)
    require(all(row.get("status") == "measured" for row in measured["rows"]), "replay_incomplete")
    plan = {name: ([tuple(case) for case in value["cases"]], value["retrieval_arm"])
            for name, value in declaration["cohorts"].items()}
    frozen = frozen_inputs(args.dataset, plan)
    ledger_rows = replay.ledger(output)
    answered = []
    for index, entry in enumerate(declaration["runs"]):
        history, _document, _ = frozen[(entry["question_id"], entry["source_run"])]
        _report, _item, answer = native_attempt(output, ledger_rows, index, entry)
        answered.append((index, entry, history, answer))
    seed = replay.digest((output / "declaration.json").read_bytes())
    items_document, key_document = replay.judge_items("framing-v4-variants", answered, jc.load_dataset(args.dataset), seed)
    manifest = replay.write_judge_set(output / "judge-set", items_document, key_document, "framing-v4-variants-plan", seed)
    print(json.dumps({"set_id": manifest["set_id"], "items": manifest["item_count"],
                      "items_sha256": manifest["items_sha256"], "key_sha256": manifest["key_sha256"],
                      "identifier_substitutions": manifest["identifier_substitutions"],
                      "identity_mention_items": len(manifest["identity_mention_items"])}))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("validate-detector", "gold", "declare", "run", "measure", "judge-set"):
        command = commands.add_parser(name)
        if name != "validate-detector":
            command.add_argument("--output", type=Path, required=True)
        if name not in ("run", "validate-detector"):
            command.add_argument("--dataset", type=Path, required=True)
        if name in ("declare", "run"):
            command.add_argument("--binary", type=Path, required=True)
        if name == "declare":
            command.add_argument("--gold", type=Path, required=True)
        if name == "gold":
            import retrieval_harness as harness
            command.add_argument("--tokenizer", type=Path, default=harness.DEFAULT_TOKENIZER)
    args = parser.parse_args(argv)
    import judge_calibration as jc
    import retrieval_harness as harness
    try:
        {"validate-detector": validate_detector, "gold": gold, "declare": declare, "run": run, "measure": measure,
         "judge-set": judge_set}[args.command](args)
    except (PlanError, v5plan.PlanError, replay.ReplayError, e.EvaluationError, jc.CalibrationError,
            harness.HarnessError) as error:
        print(json.dumps({"error": str(error)}))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
