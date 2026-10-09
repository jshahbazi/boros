#!/usr/bin/env python3
"""Answer presentation replay: V3 versus V4 (fixes A, D and G) framing.

Replays, one generation per question and framing, a declared cohort of frozen
LongMemEval question-arm cases (docs/ANSWER-PRESENTATION-DEFECTS.md):

- ``echo-7``: the seven question-arm cases whose saved Qwen answers opened with a copied
  envelope header. 14 generations.
- ``recent-only-21``: the recent-only arm of all 21 distinct questions of the saved
  native runs (7 frozen pilot questions from natural-v5, 14 independent questions from
  independent-v1). 42 generations. It measures fix G: declines, AI or memory
  disclaimers, and correct abstentions.
- ``retrieval-on-21``: the same 21 questions and runner inputs with past-conversation retrieval
  on: the recorded ``hybrid`` attempt. By default the runner runs it as explicit fused retrieval
  with the history's semantic index. Declared with ``--retrieval-arm ordinary_send``, each run
  passes ``--retrieval-arm ordinary_send`` to the runner, which runs the attempt in the ordinary
  Send configuration instead: lexical selection, no semantic index built or passed, semantic
  retrieval disabled by policy. 42 generations. It measures whether fix G declines when the
  delivered evidence holds the gold turns.

Both arms run the same verified binary through the existing ``--answer-evaluation``
path with the frozen runner input; only the context framing differs (V3 pinned with
``--context-framing``; V4 pinned in ``echo-7`` and left to the default in
``recent-only-21``, with the reported framing verified at measurement). ``--attempt``
restricts each run to the one declared attempt, so each run makes at most one answer
generation.

Commands:

- ``declare``: rebuild the frozen runner inputs from the pinned dataset, verify each
  against the runner-input SHA-256 recorded by its original run, verify that the live
  local server lists the pinned model, and write a frozen declaration before any
  generation.
- ``run``: execute the declared runs in order through the local server only. A durable
  ledger refuses any run beyond the declared generation limit.
- ``measure``: apply the detector in ``answer_presentation_defects.py`` and print counts,
  identifiers and booleans only. Each attempt's gold delivery (whole, partial, none) is scored
  from the runner's own delivered ranges as the retrieval harness scores R2.
- ``judge-set``: build a private, blinded verdict item set (the calibration item shape, no
  evidence) from a finished replay, for ``judge_calibration_run.py`` under a verdict-only
  declaration. ``judge-summary``: join the judge's labels (majority of three, ties ``unknown``)
  with the measured rows and print IDs, classes and counts only.

Privacy: inputs, answers and native reports stay in the private output directory
(0700 directories, 0600 files). stdout never carries question, answer, evidence or
history text. No remote call of any kind is made; the only network peer is the local
model server named in the frozen configuration.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
import answer_presentation_defects as apd  # noqa: E402
import evaluate_answers as e  # noqa: E402
import evaluate_longmemeval as baseline  # noqa: E402
import longmemeval_cases as cases  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
VERSION = "answer-presentation-replay-v1"
MODEL = "ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit"
MODELS_URL = "http://127.0.0.1:11234/v1/models"
EVALUATION_ROOT = Path("/Users/johnshahbazian/development/boros/.build/evaluation")
RUN_REPORTS = {"natural-v4": "longmemeval-natural-v4-20261006.json", "natural-v5": "longmemeval-natural-v5-20261006.json",
               "independent-v1": "longmemeval-independent-v1-20261006.json",
               "neighborhood-v1": "longmemeval-neighborhood-v1-20261006.json"}
NEIGHBORHOOD_POLICY = "selected-model-context-components-v2"
# (question ID, run whose saved answer copied the header, strategy, component policy pin).
# Where several runs echoed, the most recent run under the current default policy is used.
ECHO_CASES = (("001be529", "natural-v4", "hybrid", None),
              ("06878be2", "natural-v5", "recent_only", None),
              ("0e5e2d1a", "natural-v5", "hybrid", None),
              ("1192316e", "neighborhood-v1", "hybrid", NEIGHBORHOOD_POLICY),
              ("1a1907b4", "independent-v1", "hybrid", None),
              ("1faac195", "independent-v1", "hybrid", None),
              ("54026fce", "neighborhood-v1", "hybrid", NEIGHBORHOOD_POLICY))
# The recent-only arm of every distinct question in the saved native runs. The 7 frozen
# pilot questions use natural-v5 (the latest runner document 5 run that has a recent-only
# arm); the 14 independent questions use independent-v1 (the default component policy).
PILOT_QUESTIONS = ("001be529", "00ca467f", "01493427", "031748ae_abs", "06878be2", "08f4fc43", "0e5e2d1a")
INDEPENDENT_QUESTIONS = ("0862e8bf_abs", "1192316e", "1a1907b4", "1b9b7252", "1faac195", "3f1e9474", "4baee567",
                         "51c32626", "54026fce", "7a87bd0c", "a1eacc2a", "f685340e_abs", "gpt4_2655b836",
                         "gpt4_70e84552")
RECENT_ONLY_CASES = tuple((question_id, "natural-v5", "recent_only", None) for question_id in PILOT_QUESTIONS) \
    + tuple((question_id, "independent-v1", "recent_only", None) for question_id in INDEPENDENT_QUESTIONS)
# The same 21 questions and frozen runner inputs with past-conversation retrieval on: the recorded
# ``hybrid`` attempt. Without a retrieval arm, the runner builds the history's semantic index and
# passes it to the coordinator (explicit fused retrieval, the harness ``hybrid`` arm). Declared with
# ``--retrieval-arm ordinary_send``, the runner instead runs the ordinary Send configuration that
# the GUI uses since October 8, 2026 (docs/P2-SEMANTIC-DECISION.md): the harness ``ordinary_send``
# arm, whose selection equals the harness ``lexical`` arm.
RETRIEVAL_ON_CASES = tuple((question_id, run, "hybrid", policy) for question_id, run, _, policy in RECENT_ONLY_CASES)
# Questions whose saved recent-only answers carried an AI or memory disclaimer.
DISCLAIMER_QUESTIONS = ("031748ae_abs", "0862e8bf_abs", "1192316e")
V3 = "context-source-snapshot-v3"
V4 = "context-source-snapshot-v4"
COHORTS = {
    "echo-7": {"cases": ECHO_CASES, "generation_limit": 14,
               "arms": (("main-v3", V3), ("fix-v4", V4)),
               "authorization": "user, 2026-10-09: implement fix A and replay the 7 questions; "
                                "fix arm extended to A+D+G by the coordinator"},
    # A None framing leaves --context-framing off, so the run uses the binary's default (V4).
    "recent-only-21": {"cases": RECENT_ONLY_CASES, "generation_limit": 42,
                       "arms": (("v3-pinned", V3), ("v4-default", None)),
                       "authorization": "user, 2026-10-09: up to 42 local generations, local server only; paired V3 "
                                        "versus V4 (default) replay of the recent-only arm on the 21 distinct questions"},
    "retrieval-on-21": {"cases": RETRIEVAL_ON_CASES, "generation_limit": 42,
                        "arms": (("v3-pinned", V3), ("v4-default", None)),
                        "authorization": "user, 2026-10-09: up to 42 local generations (21 questions x 2 framings), "
                                         "local model server only; paired V3 versus V4 replay of the same 21 questions "
                                         "with past-conversation retrieval on (lexical if the runner can select it, "
                                         "else the recorded hybrid arm, stated clearly)"},
}
# Arm descriptions recorded in the declaration, per cohort.
ARM_DESCRIPTIONS = {
    "echo-7": {"main-v3": "context-source-snapshot-v3, pinned with --context-framing; the framing of main",
               "fix-v4": "context-source-snapshot-v4 (fixes A, D, G), the new default"},
    "recent-only-21": {"v3-pinned": "context-source-snapshot-v3, pinned with --context-framing",
                       "v4-default": "no --context-framing flag: the binary's default, context-source-snapshot-v4 "
                                     "(fixes A, D, G); the reported framing is verified at measurement"},
}
ARM_DESCRIPTIONS["retrieval-on-21"] = dict(ARM_DESCRIPTIONS["recent-only-21"])
RETRIEVAL_SELECTION = {
    "echo-7": "the declared attempt's recorded strategy",
    "recent-only-21": "recent_only attempt: no past-conversation retrieval",
    "retrieval-on-21": "hybrid attempt: the runner constructs the history's semantic index and passes it to the "
                       "coordinator (explicit fused retrieval, the retrieval harness hybrid arm). Not the lexical "
                       "selection that ordinary Send uses since 2026-10-08; declare with --retrieval-arm "
                       "ordinary_send for that.",
}
# Runner retrieval arms a declaration may request (``--answer-evaluation --retrieval-arm``). The arm
# replaces declared hybrid attempts only, so it is accepted only for cohorts of hybrid cases.
RETRIEVAL_ARMS = {
    "ordinary_send": "hybrid attempt run in the ordinary Send configuration (--retrieval-arm ordinary_send): "
                     "lexical selection, no semantic index built or passed, semantic retrieval disabled by policy "
                     "and recorded as disabled_by_policy in the retrieval audit; the retrieval harness ordinary_send "
                     "arm, whose selection equals its lexical arm. The runner report records the arm per attempt "
                     "and it is verified at measurement.",
}
# Authorization recorded for a cohort declared with a runner retrieval arm, per (cohort, arm). It
# replaces the cohort's own text, which describes the run declared without the arm.
RETRIEVAL_ARM_AUTHORIZATIONS = {
    ("retrieval-on-21", "ordinary_send"): "user, 2026-10-09: up to 42 local generations (21 questions x 2 framings, "
                                          "V3 pinned and V4 default), all with --retrieval-arm ordinary_send, local "
                                          "model server only, same settings as the hybrid retrieval-on run; then "
                                          "default-judge verdicts on all 42 answers under a $1.00 cap",
}
DETECTOR = ("copied_header", "fabricated_event_ids", "repeated_question", "raw_event_ids", "ai_disclaimer",
            "plain_decline", "latex", "answer_bytes", "answer_words", "addresses_question", "contains_reference",
            "cited_labels", "unresolved_labels", "ends_with_question", "markdown_bold")
DECLINE_OPENING_CHARACTERS = 200


class ReplayError(Exception):
    """Fixed, content-free reason codes only."""


def require(condition, code):
    if not condition:
        raise ReplayError(code)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical(value) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def private_directory(path: Path):
    path.mkdir(mode=0o700, parents=False, exist_ok=False)
    os.chmod(path, 0o700)


def private_write(path: Path, data: bytes):
    e.private_write(path, data)
    os.chmod(path, 0o600)


def git(*args) -> str:
    process = subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, timeout=30)
    require(process.returncode == 0, "git_failed")
    return process.stdout.strip()


def histories(dataset: Path, case_list):
    """Frozen runner documents per (question ID, run), verified against the recorded runner-input SHA-256."""
    import longmemeval_independent_cases as independent
    pilot = {history["id"]: history for history in cases.prepare(dataset)}
    fresh = {history["id"]: history for history in independent.prepare(dataset)}
    out = {}
    for question_id, run, _, _ in case_list:
        report = json.loads((EVALUATION_ROOT / RUN_REPORTS[run]).read_text())
        declared = {case["question_id"]: case for case in report["declaration"]["cases"]}[question_id]
        version = report["runner_document_version"]
        if version in (4, 5):
            history = pilot[question_id]
            document = cases.runner_input(history, baseline.CONFIGURATION, version=version)
        else:
            require(version == 7, "unsupported_runner_version")
            history = fresh[question_id]
            document = independent.runner_input(history, {**baseline.CONFIGURATION, "maximum_output": 1024})
        require(digest(canonical(document)) == declared["runner_input_sha256"], "runner_input_hash_mismatch")
        out[(question_id, run)] = (history, document, report)
    return out


def declared_retrieval_arm(cohort_name, arm):
    """The runner retrieval arm a declaration requests, or None. Refused unless every case of the
    cohort is a hybrid attempt, since the runner applies the arm to declared hybrid attempts only."""
    if arm is None:
        return None
    require(arm in RETRIEVAL_ARMS, "unknown_retrieval_arm")
    require(all(strategy == "hybrid" for _, _, strategy, _ in COHORTS[cohort_name]["cases"]),
            "retrieval_arm_requires_hybrid_cohort")
    return arm


def declared_authorization(cohort_name, retrieval_arm):
    """The authorization text a declaration records: the cohort's own, or, with a retrieval arm, the
    authorization of that arm's run. A retrieval arm without a recorded authorization is refused."""
    if retrieval_arm is None:
        return COHORTS[cohort_name]["authorization"]
    require((cohort_name, retrieval_arm) in RETRIEVAL_ARM_AUTHORIZATIONS, "retrieval_arm_not_authorized")
    return RETRIEVAL_ARM_AUTHORIZATIONS[(cohort_name, retrieval_arm)]


def runner_command(binary: Path, input_path: Path, native: Path, entry):
    """The ``--answer-evaluation`` command of one declared run. Runs declared before retrieval arms
    existed have no ``retrieval_arm`` field and keep their exact command."""
    command = [str(binary), "--answer-evaluation", str(input_path), "--output-directory", str(native),
               "--attempt", str(entry["attempt"])]
    if entry["context_framing"] is not None:
        command += ["--context-framing", entry["context_framing"]]
    if entry["component_policy"] != "selected-model-context-components-v1":
        command += ["--component-policy", entry["component_policy"]]
    if entry.get("retrieval_arm") is not None:
        command += ["--retrieval-arm", entry["retrieval_arm"]]
    return command


def retrieval_arm_as_declared(entry, report, item):
    """Whether the runner report shows the declared retrieval arm. Without one, the report must carry
    no arm fields; with ``ordinary_send``, the attempt must record the arm, the disabled policy, no
    semantic index received, no sidecar and a validated lexical receipt."""
    arm = entry.get("retrieval_arm")
    if arm is None:
        return "retrieval_arm_override" not in report and "retrieval_arm" not in item
    return (report.get("retrieval_arm_override") == arm and item.get("retrieval_arm") == arm
            and item.get("semantic_retrieval_policy") == "disabled_by_policy"
            and item.get("preparation_received_semantic_index") is False
            and item.get("semantic_sidecar_present") is False
            and item.get("retrieval_arm_receipt_validated") is True
            and (item.get("background") or {}).get("performed") is False)


def recorded_attempt(report, question_id, strategy):
    for history in report["histories"]:
        for attempt in history["attempts"]:
            if attempt["question_id"] == question_id and attempt["strategy"] == strategy:
                return attempt
    raise ReplayError("recorded_attempt_missing")


def live_models():
    with urllib.request.urlopen(MODELS_URL, timeout=10) as response:  # local server only
        return [entry.get("id") for entry in json.loads(response.read()).get("data", [])]


def declare(args):
    output = args.output.absolute()
    require(output.is_relative_to((ROOT / ".build").resolve()) or output.is_relative_to(ROOT / ".build"), "output_outside_build")
    binary = args.binary.absolute()
    require(binary.is_file(), "binary_missing")
    require(not git("status", "--porcelain", "--", "Sources"), "sources_not_committed")
    models = live_models()
    require(MODEL in models, "pinned_model_not_listed")
    cohort = COHORTS[args.cohort]
    retrieval_arm = declared_retrieval_arm(args.cohort, getattr(args, "retrieval_arm", None))
    frozen = histories(args.dataset, cohort["cases"])
    private_directory(output)
    private_directory(output / "inputs")
    runs = []
    for question_id, run, strategy, policy in cohort["cases"]:
        history, document, report = frozen[(question_id, run)]
        ordinal = [attempt["strategy"] for attempt in document["attempts"]].index(strategy)
        encoded = canonical(document)
        input_path = output / "inputs" / f"{question_id}.json"
        private_write(input_path, encoded)
        recorded = recorded_attempt(report, question_id, strategy)
        for arm, framing in cohort["arms"]:
            runs.append({"question_id": question_id, "source_run": run, "strategy": strategy, "attempt": ordinal,
                         "component_policy": policy or "selected-model-context-components-v1", "arm": arm,
                         "context_framing": framing, "runner_document_version": document["version"],
                         "runner_input_sha256": digest(encoded),
                         "recorded_request_sha256": (recorded["metadata"].get("preparation") or {}).get("request_sha256"),
                         "recorded_prompt_tokens": ((recorded["metadata"].get("preparation") or {}).get("admission")
                                                    or {}).get("promptTokens"),
                         "recorded_delivered_recent_sha256": digest(canonical(
                             recorded["metadata"].get("delivered_recent_source_ids") or [])),
                         "recorded_delivered_ranges_sha256": ranges_digest(recorded["metadata"].get("delivered_ranges")),
                         "abstention": question_id.endswith("_abs"),
                         "recorded_binary_sha256": report["implementation"].get("binary_sha256")})
            if retrieval_arm is not None:
                runs[-1]["retrieval_arm"] = retrieval_arm
    configuration = {key: value for key, value in baseline.CONFIGURATION.items() if key != "system"}
    declaration = {
        "version": VERSION, "declared_at_utc": datetime.now(timezone.utc).isoformat(),
        "cohort": args.cohort, "authorization": declared_authorization(args.cohort, retrieval_arm),
        "cases": [list(case) for case in cohort["cases"]],
        "model": MODEL, "live_models_listed": models, "endpoint": baseline.CONFIGURATION["endpoint"],
        "temperature": baseline.CONFIGURATION["temperature"], "thinking": baseline.CONFIGURATION["thinking"],
        "seed": baseline.CONFIGURATION["seed"], "maximum_output": {"runner_document_4_5": 512, "runner_document_7": 1024},
        "configuration_without_system": configuration,
        "system_sha256": digest(baseline.CONFIGURATION["system"].encode()),
        "generation_limit": cohort["generation_limit"], "generations_per_run": 1,
        "retry_rule": "a run whose answer invocation never started may be retried at most twice and does not count "
                      "toward the generation limit; any run that started an answer invocation counts",
        "run_order": "question order as listed, V3 then V4 for each question",
        "non_answer_requests_per_run": "existing admission path: tokenizer counts and one 1-token calibration completion",
        "binary": {"path_name": binary.name, "sha256": digest(binary.read_bytes()), "build_commit": git("rev-parse", "HEAD"),
                   "branch": git("rev-parse", "--abbrev-ref", "HEAD"),
                   "main_commit": git("rev-parse", "main"),
                   "framing_source_sha256": digest((ROOT / "Sources/Boros/ContextSourceFraming.swift").read_bytes()),
                   "assembler_source_sha256": digest((ROOT / "Sources/Boros/ContextAssembler.swift").read_bytes())},
        "arms": ({"main-v3": "context-source-snapshot-v3, pinned with --context-framing; the framing of main at "
                             + git("rev-parse", "main")[:7],
                  "fix-v4": "context-source-snapshot-v4 (fixes A, D, G), the new default"} if args.cohort == "echo-7" else
                 dict(ARM_DESCRIPTIONS[args.cohort])),
        "retrieval_selection": RETRIEVAL_ARMS[retrieval_arm] if retrieval_arm else RETRIEVAL_SELECTION[args.cohort],
        "disclaimer_questions": list(DISCLAIMER_QUESTIONS),
        "both_arms_same_binary": True,
        "detector": {"module": "scripts/answer_presentation_defects.py", "tool_version": apd.TOOL_VERSION,
                     "module_sha256": digest((ROOT / "scripts/answer_presentation_defects.py").read_bytes()),
                     "measures": list(DETECTOR),
                     "definitions": {
                         "copied_header": "host_header_at_answer_start or envelope_header_at_answer_start",
                         "fabricated_event_ids": "distinct raw or JSON event IDs in the answer absent from the history",
                         "repeated_question": "question_verbatim",
                         "latex": "math_inline_dollar_pair + math_display_or_paren + math_latex_command",
                         "addresses_question": "non-empty, no host header at start, question not repeated verbatim",
                         "contains_reference": "normalized reference answer is a substring of the normalized answer",
                         "unresolved_labels": "cited [E n] labels absent from the recorded citation label map",
                         "decline_opening": "a plain_decline phrase starts within the first "
                                            f"{DECLINE_OPENING_CHARACTERS} characters of the answer",
                         "outcome": "decline (decline_opening), partial_decline (a plain_decline phrase later "
                                    "in the answer only), or answer (no plain_decline phrase); lexical, not a judge",
                         "delivered_gold_turns": "delivered recent sources whose benchmark turn is marked has_answer",
                         "delivered_answer_session_sources": "delivered recent sources from a gold answer session",
                         "gold_delivery": "annotated has_answer turns against the attempt's delivered_ranges, scored "
                                          "by retrieval_harness.coverage: whole (every gold turn's bytes covered), "
                                          "partial (some gold bytes, not every turn whole), none, or no_gold_turns",
                         "decline_class": "a decline or partial_decline outcome on an answerable question is "
                                          "false_decline when gold_delivery is whole, justified_decline when none, "
                                          "decline_partial_gold when partial; abstention_decline on abstention "
                                          "questions"}},
        "runs": runs}
    if retrieval_arm is not None:
        declaration["retrieval_arm"] = retrieval_arm
    private_write(output / "declaration.json", canonical(declaration) + b"\n")
    private_write(output / "ledger.jsonl", b"")
    print(json.dumps({"cohort": args.cohort, "retrieval_arm": retrieval_arm, "declared_runs": len(runs),
                      "generation_limit": cohort["generation_limit"],
                      "binary_sha256": declaration["binary"]["sha256"], "build_commit": declaration["binary"]["build_commit"],
                      "model_listed": True, "declaration_sha256": digest((output / "declaration.json").read_bytes())}))


def ledger(output: Path):
    text = (output / "ledger.jsonl").read_text()
    return [json.loads(line) for line in text.splitlines() if line.strip()]


def run(args):
    output = args.output.absolute()
    declaration = json.loads((output / "declaration.json").read_text())
    binary = args.binary.absolute()
    require(digest(binary.read_bytes()) == declaration["binary"]["sha256"], "binary_identity_mismatch")
    require(MODEL in live_models(), "pinned_model_not_listed")
    for index, entry in enumerate(declaration["runs"]):
        done = ledger(output)
        rows = [row for row in done if row["run"] == index]
        if any(row.get("invocation_started") is True for row in rows):
            continue
        # A run whose answer invocation never started (admission or setup
        # failure) made no answer generation and may be retried, at most twice.
        tries = sum(1 for row in rows if row["state"] == "started")
        require(all(any(other["run"] == row["run"] and other["state"] != "started" and other.get("try") == row.get("try")
                        for other in done) for row in done if row["state"] == "started"), "unfinished_run_in_ledger")
        require(tries < 3, "retry_limit_reached")
        # A finished run whose report does not say whether the answer invocation started
        # may have generated; stop for review rather than retry it or leave it uncounted.
        require(all(row.get("invocation_started") is not None for row in done if row["state"] == "finished"),
                "unknown_invocation_state_in_ledger")
        generations = sum(1 for row in done if row.get("invocation_started") is True)
        require(generations < declaration["generation_limit"], "generation_limit_reached")
        input_path = output / "inputs" / f"{entry['question_id']}.json"
        require(digest(input_path.read_bytes()) == entry["runner_input_sha256"], "frozen_input_changed")
        native = output / (f"run-{index:02d}-{entry['question_id']}-{entry['arm']}" + (f"-try{tries}" if tries else ""))
        command = runner_command(binary, input_path, native, entry)
        # Reserve the generation before starting so a crash cannot hide one.
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
        print(json.dumps({"run": index, "question_id": entry["question_id"], "arm": entry["arm"],
                          "returncode": process.returncode, "invocation_started": item.get("invocation_started"),
                          "failure": item.get("failure"), "answer_bytes": item.get("answer_bytes")}), flush=True)


def measure_answer(answer, question, reference, known_ids, label_map):
    counts = apd.pattern_counts(answer, question)
    ids = apd.event_id_mentions(answer, known_ids)
    citations = apd.citation_resolution(answer, label_map)
    return {"copied_header": int(bool(counts["host_header_at_answer_start"] or counts["envelope_header_at_answer_start"])),
            "fabricated_event_ids": ids["fabricated_event_ids"], "repeated_question": counts["question_verbatim"],
            "raw_event_ids": ids["raw_event_ids"], "ai_disclaimer": counts["ai_disclaimer"],
            "plain_decline": counts["plain_decline"],
            "latex": counts["math_inline_dollar_pair"] + counts["math_display_or_paren"] + counts["math_latex_command"],
            "answer_bytes": len(answer.encode()), "answer_words": len(answer.split()),
            "addresses_question": apd.addresses_question(answer, question, counts),
            "contains_reference": apd.contains_reference(answer, reference),
            "cited_labels": citations["cited_labels"], "unresolved_labels": citations["unresolved_labels"],
            "ends_with_question": counts["ends_with_question"], "markdown_bold": counts["markdown_bold"],
            **decline_outcome(answer)}


def decline_outcome(answer):
    """Lexical decline position, using the detector's plain-decline phrase list."""
    lower = answer.lower().replace("’", "'")
    positions = [lower.find(phrase) for phrase in apd.PLAIN_DECLINES if phrase in lower]
    opening = bool(positions) and min(positions) < DECLINE_OPENING_CHARACTERS
    return {"decline_opening": opening,
            "outcome": "decline" if opening else ("partial_decline" if positions else "answer")}


def delivered_evidence(history, delivered_ids):
    """Content-free count of delivered recent sources that carry gold benchmark evidence."""
    labels = {label["event_id"]: label for label in history.get("source_labels") or []}
    gold_sessions = set(history["episodes"][0].get("answer_session_ids") or [])
    delivered = [labels.get(event_id) or {} for event_id in delivered_ids or []]
    return {"delivered_gold_turns": sum(1 for label in delivered if label.get("has_answer") is True),
            "delivered_answer_session_sources": sum(1 for label in delivered if label.get("session_id") in gold_sessions)}


def ranges_digest(ranges):
    """Order-independent digest of delivered (event ID, offset, byte length) triples; no text."""
    triples = sorted([item["event_id"], item["offset"], item["byte_length"]] for item in ranges or [])
    return digest(canonical(triples))


def gold_delivery(history, delivered_ranges):
    """Content-free delivery of the annotated gold turns, scored as the retrieval harness scores R2.

    The gold turns are the history's source labels marked ``has_answer``. The runner's delivered
    ranges (historical excerpts and whole recent sources, as byte offset and length) go through
    ``retrieval_harness.coverage`` unchanged: a turn is delivered whole when the union of its
    delivered ranges covers all of its UTF-8 bytes, and it has bytes delivered when any range is
    non-empty. Class: ``whole`` (every gold turn whole), ``partial`` (some gold bytes delivered but
    not every turn whole), ``none`` (no gold byte delivered) or ``no_gold_turns``.
    """
    import retrieval_harness as harness
    sizes = {event["id"]: len(event["text"].encode()) for event in history["events"]}
    positives = [label["event_id"] for label in history.get("source_labels") or [] if label.get("has_answer") is True]
    attempt = {"recent_source_ids": [], "evidence": [
        {"event_id": item["event_id"], "offset": item["offset"], "bytes": item["byte_length"]}
        for item in delivered_ranges or []]}
    whole, partial = harness.coverage(attempt, sizes)
    delivered_whole = sum(1 for identifier in positives if identifier in whole)
    any_bytes = sum(1 for identifier in positives if identifier in partial)
    if not positives:
        kind = "no_gold_turns"
    elif delivered_whole == len(positives):
        kind = "whole"
    elif any_bytes:
        kind = "partial"
    else:
        kind = "none"
    return {"gold_turns": len(positives), "gold_turns_whole": delivered_whole, "gold_turns_any_bytes": any_bytes,
            "gold_delivery": kind}


def decline_class(outcome, abstention, delivery):
    """Lexical decline classified against gold delivery: ``false_decline`` (answerable, every gold turn
    delivered whole), ``justified_decline`` (answerable, no gold byte delivered),
    ``decline_partial_gold`` (answerable, some but not all gold delivered), ``abstention_decline``;
    None when the outcome is not a decline. A partial decline is classified the same way."""
    if outcome not in ("decline", "partial_decline"):
        return None
    if abstention:
        return "abstention_decline"
    return {"whole": "false_decline", "none": "justified_decline"}.get(delivery, "decline_partial_gold")


def measured_answers(output: Path, dataset: Path):
    """Per declared run: (declaration entry, frozen history, answer text or None). Private; no output."""
    declaration = json.loads((output / "declaration.json").read_text())
    cohort = COHORTS[declaration.get("cohort", "echo-7")]
    frozen = histories(dataset, [tuple(case) for case in declaration.get("cases") or cohort["cases"]])
    done = ledger(output)
    out = []
    for index, entry in enumerate(declaration["runs"]):
        history, document, _ = frozen[(entry["question_id"], entry["source_run"])]
        require(digest(canonical(document)) == entry["runner_input_sha256"], "frozen_input_changed")
        finished = [row for row in done if row["run"] == index and row.get("invocation_started") is True]
        native = output / (finished[-1]["directory"] if finished else "missing")
        answer = None
        if (native / "report.json").exists():
            report = json.loads((native / "report.json").read_text())
            item = [attempt for attempt in report["attempts"] if attempt["ordinal"] == entry["attempt"]][0]
            path = native / item["answer_file"]
            answer = path.read_text() if path.exists() else ""
        out.append((index, entry, history, answer))
    return declaration, out


def measure(args):
    print(json.dumps(measurement(args.output.absolute(), args.dataset), indent=1))


def measurement(output: Path, dataset: Path):
    declaration = json.loads((output / "declaration.json").read_text())
    cohort_name = declaration.get("cohort", "echo-7")
    cohort = COHORTS[cohort_name]
    frozen = histories(dataset, [tuple(case) for case in declaration.get("cases") or cohort["cases"]])
    rows = []
    ledger_rows = ledger(output)
    attempts_made = {"answer_generations": sum(1 for row in ledger_rows if row.get("invocation_started") is True),
                     "runs_without_answer_invocation": sum(1 for row in ledger_rows
                                                           if row["state"] != "started" and row.get("invocation_started") is False),
                     "failures_without_answer_invocation": sorted({row.get("failure") or row["state"] for row in ledger_rows
                                                                   if row["state"] != "started" and row.get("invocation_started") is False})}
    for index, entry in enumerate(declaration["runs"]):
        history, document, _ = frozen[(entry["question_id"], entry["source_run"])]
        require(digest(canonical(document)) == entry["runner_input_sha256"], "frozen_input_changed")
        finished = [row for row in ledger(output) if row["run"] == index and row.get("invocation_started") is True]
        native = output / (finished[-1]["directory"] if finished else "missing")
        report_path = native / "report.json"
        row = {"question_id": entry["question_id"], "source_run": entry["source_run"], "strategy": entry["strategy"],
               "arm": entry["arm"]}
        if entry.get("retrieval_arm") is not None:
            row["retrieval_arm"] = entry["retrieval_arm"]
        if not report_path.exists():
            rows.append({**row, "status": "not_run"})
            continue
        report = json.loads(report_path.read_text())
        item = [attempt for attempt in report["attempts"] if attempt["ordinal"] == entry["attempt"]][0]
        answer = (native / item["answer_file"]).read_text() if (native / item["answer_file"]).exists() else ""
        probe = history["episodes"][0]
        known = [event["id"] for event in document["events"]]
        preparation = item.get("preparation") or {}
        admission = preparation.get("admission") or {}
        row.update(status="measured", invocation_started=item.get("invocation_started"), failure=item.get("failure"),
                   report_framing=report.get("context_framing"), selection_framing=item.get("context_framing"),
                   prompt_tokens=admission.get("promptTokens"),
                   delivered_recent=len(item.get("delivered_recent_source_ids") or []),
                   delivered_ranges=len(item.get("delivered_ranges") or []),
                   label_map_size=len(item.get("citation_labels") or []),
                   request_matches_recorded=preparation.get("request_sha256") == entry["recorded_request_sha256"],
                   framing_as_declared=report.get("context_framing") == (entry["context_framing"] or V4)
                   and item.get("context_framing") in (None, entry["context_framing"] or V4),
                   retrieval_arm_as_declared=retrieval_arm_as_declared(entry, report, item),
                   recorded_prompt_tokens=entry.get("recorded_prompt_tokens"),
                   delivered_recent_matches_recorded=(digest(canonical(item.get("delivered_recent_source_ids") or []))
                                                      == entry["recorded_delivered_recent_sha256"]
                                                      if "recorded_delivered_recent_sha256" in entry else None),
                   delivered_ranges_match_recorded=(ranges_digest(item.get("delivered_ranges"))
                                                    == entry["recorded_delivered_ranges_sha256"]
                                                    if "recorded_delivered_ranges_sha256" in entry else None),
                   abstention=entry["question_id"].endswith("_abs"),
                   **delivered_evidence(history, item.get("delivered_recent_source_ids")),
                   **gold_delivery(history, item.get("delivered_ranges")),
                   **measure_answer(answer, probe["prompt"], probe["answer"], known, item.get("citation_labels")))
        row["decline_class"] = decline_class(row["outcome"], row["abstention"], row["gold_delivery"])
        rows.append(row)
    totals = {}
    for arm, _ in cohort["arms"]:
        measured = [row for row in rows if row["arm"] == arm and row.get("status") == "measured"]
        totals[arm] = {"answers": len(measured),
                       **{name: sum(int(row[name]) for row in measured) for name in DETECTOR if name not in ("answer_bytes", "answer_words")},
                       "median_answer_words": sorted(row["answer_words"] for row in measured)[len(measured) // 2] if measured else None}
    groups = {}
    if cohort_name in ("recent-only-21", "retrieval-on-21"):
        subsets = {"abstention": lambda row: row["abstention"], "answerable": lambda row: not row["abstention"],
                   "disclaimer_questions": lambda row: row["question_id"] in DISCLAIMER_QUESTIONS}
        if cohort_name == "recent-only-21":
            subsets.update({
                "answerable_without_delivered_gold": lambda row: not row["abstention"] and not row["delivered_gold_turns"],
                "answerable_with_delivered_gold": lambda row: not row["abstention"] and bool(row["delivered_gold_turns"])})
        else:
            subsets.update({f"answerable_gold_{kind}": (lambda kind: lambda row: not row["abstention"]
                                                        and row["gold_delivery"] == kind)(kind)
                            for kind in ("whole", "partial", "none")})
        for arm, _ in cohort["arms"]:
            measured = [row for row in rows if row["arm"] == arm and row.get("status") == "measured"]
            groups[arm] = {name: {"answers": len(chosen),
                                  "with_ai_disclaimer": sum(1 for row in chosen if row["ai_disclaimer"]),
                                  "decline": sum(1 for row in chosen if row["outcome"] == "decline"),
                                  "partial_decline": sum(1 for row in chosen if row["outcome"] == "partial_decline"),
                                  "answer": sum(1 for row in chosen if row["outcome"] == "answer"),
                                  "contains_reference": sum(1 for row in chosen if row["contains_reference"]),
                                  "copied_header": sum(row["copied_header"] for row in chosen),
                                  "with_raw_event_ids": sum(1 for row in chosen if row["raw_event_ids"]),
                                  "incomplete_result": sum(1 for row in chosen if row["failure"] == "incomplete_result"),
                                  "false_decline": sum(1 for row in chosen if row["decline_class"] == "false_decline"),
                                  "justified_decline": sum(1 for row in chosen
                                                           if row["decline_class"] == "justified_decline"),
                                  "decline_partial_gold": sum(1 for row in chosen
                                                              if row["decline_class"] == "decline_partial_gold")}
                           for name, test in subsets.items() for chosen in [[row for row in measured if test(row)]]}
    return {"version": VERSION, "cohort": cohort_name, "ledger": attempts_made, "rows": rows, "totals": totals,
            "groups": groups}


# ----------------------------------------------------------------- verdict judging of replay answers

JUDGE_SET_FORMAT = "boros-answer-replay-judge-set-v1"
JUDGE_KEY_FORMAT = "boros-answer-replay-judge-key-v1"


def judge_items(cohort_name, answered, dataset_records, seed):
    """Blinded verdict items (judge_calibration item shape) and their private key.

    Items are built exactly as ``judge_calibration.blind_item`` builds calibration items: question,
    date, type and reference from the pinned dataset record (``attach_question``), the abstention
    flag, no evidence (the verdict prompt never sees it), and the answer with the same identifier
    scrub. Item IDs are opaque and their order is a seeded hash order, so arms interleave and the
    judge never sees the arm, run or question ID. Returns (items document, key document)."""
    import judge_calibration as jc
    candidates = []
    for index, entry, _history, answer in answered:
        require(answer is not None, "answer_missing")
        candidate = jc.new_candidate(run=f"replay-{cohort_name}", run_family="answer-presentation-replay",
                                     arm=entry["arm"], question_id=entry["question_id"], answer_model=MODEL,
                                     operational_complete=True, answer_sha256=digest(answer.encode()))
        jc.attach_question(candidate, dataset_records)
        require(candidate["reference"] is not None, "question_missing_from_dataset")
        # As in calibration, source IDs map to [source]; the generic patterns catch the rest.
        candidate["scrub_ids"].update(event["id"] for event in _history["events"])
        jc.verify_answer(candidate, answer)
        candidates.append((jc.rank(seed, str(index), entry["question_id"], entry["arm"]), index, entry, candidate))
    candidates.sort(key=lambda value: value[0])
    items, keys = [], []
    for position, (_rank, index, entry, candidate) in enumerate(candidates, start=1):
        item, replaced = jc.blind_item(candidate, f"item-{position:03d}")
        items.append(item)
        keys.append({"item_id": item["item_id"], "run": candidate["run"], "arm": entry["arm"], "run_index": index,
                     "question_id": entry["question_id"], "abstention": bool(candidate["abstention"]),
                     "question_type": candidate["question_type"], "answer_sha256": candidate["answer_sha256"],
                     "item_sha256": digest(canonical(item)), "identifier_substitutions": replaced})
    set_id = "jr-" + digest(canonical({"seed": seed, "keys": [[key["run_index"], key["answer_sha256"]] for key in
                                                              sorted(keys, key=lambda key: key["run_index"])]}))[:16]
    items_document = {"format": jc.ITEMS_FORMAT, "set_id": set_id, "items": items}
    key_document = {"format": JUDGE_KEY_FORMAT, "set_id": set_id, "seed": seed, "items": keys}
    require(not jc.blinding_violations(items_document, key_document), "blinding_violation")
    return items_document, key_document


def judge_set(args):
    """Writes the private verdict item set of a finished replay: items.json, key.json, manifest.json."""
    import judge_calibration as jc
    output = args.output.absolute()
    declaration, answered = measured_answers(output, args.dataset)
    require(all(answer is not None for _, _, _, answer in answered), "replay_incomplete")
    seed = digest((output / "declaration.json").read_bytes())
    items_document, key_document = judge_items(declaration["cohort"], answered, jc.load_dataset(args.dataset), seed)
    manifest = write_judge_set(output / "judge-set", items_document, key_document, declaration["cohort"], seed)
    print(json.dumps({"set_id": manifest["set_id"], "items": manifest["item_count"],
                      "items_sha256": manifest["items_sha256"], "key_sha256": manifest["key_sha256"],
                      "identifier_substitutions": manifest["identifier_substitutions"],
                      "identity_mention_items": len(manifest["identity_mention_items"])}))


def write_judge_set(destination: Path, items_document, key_document, cohort_name, seed):
    """Private items.json, key.json and manifest.json; the manifest fields are those the judge runner
    verifies (set ID, item count, items SHA-256). No-clobber, 0600 files in a fresh 0700 directory."""
    import judge_calibration as jc
    jc.make_private_directory(destination, fresh=True)
    items_sha = jc.write_private_json(destination / "items.json", items_document)
    key_sha = jc.write_private_json(destination / "key.json", key_document)
    manifest = {"format": JUDGE_SET_FORMAT, "set_id": items_document["set_id"], "item_count": len(items_document["items"]),
                "items_sha256": items_sha, "key_sha256": key_sha, "seed": seed, "cohort": cohort_name,
                "replay_declaration_sha256": seed, "tasks": ["verdict"],
                "item_builder": "judge_calibration.attach_question + blind_item with no evidence",
                "identifier_substitutions": sum(entry["identifier_substitutions"] for entry in key_document["items"]),
                "identity_mention_items": jc.identity_mentions(items_document)}
    jc.write_private_json(destination / "manifest.json", manifest)
    return manifest


def majority_of_three(verdicts):
    """Default-judge vote: accept or reject when at least two of the three replicates agree; a tie or
    an unparseable majority is ``unknown``, never counted as accept."""
    require(len(verdicts) == 3, "replicates_not_three")
    for label in ("accept", "reject"):
        if sum(1 for value in verdicts if value == label) >= 2:
            return label
    return "unknown"


def judge_summary_rows(measure_rows, key_document, labels_document):
    """Joins verdict labels with measured rows by run index. IDs, classes and labels only."""
    require(labels_document.get("set_id") == key_document["set_id"], "labels_set_mismatch")
    labels = labels_document["labels"]
    out = []
    for key in sorted(key_document["items"], key=lambda key: key["run_index"]):
        row = measure_rows[key["run_index"]]
        require(row["question_id"] == key["question_id"] and row["arm"] == key["arm"], "key_row_mismatch")
        verdicts = [entry.get("verdict") for entry in labels.get(key["item_id"], [{}, {}, {}])]
        out.append({"question_id": key["question_id"], "arm": key["arm"], "abstention": key["abstention"],
                    "gold_delivery": row["gold_delivery"], "outcome": row["outcome"],
                    "decline_class": row["decline_class"], "contains_reference": row["contains_reference"],
                    "replicate_verdicts": verdicts, "verdict": majority_of_three(verdicts)})
    return out


def judge_tables(rows, arms):
    def counts(chosen):
        return {"answers": len(chosen), **{label: sum(1 for row in chosen if row["verdict"] == label)
                                           for label in ("accept", "reject", "unknown")}}
    tables = {}
    for arm in arms:
        mine = [row for row in rows if row["arm"] == arm]
        answerable = [row for row in mine if not row["abstention"]]
        tables[arm] = {"all": counts(mine), "abstention": counts([row for row in mine if row["abstention"]]),
                       "answerable": counts(answerable),
                       "answerable_gold_whole": counts([row for row in answerable if row["gold_delivery"] == "whole"]),
                       "answerable_gold_not_whole": counts([row for row in answerable if row["gold_delivery"] != "whole"]),
                       "answerable_gold_partial": counts([row for row in answerable if row["gold_delivery"] == "partial"]),
                       "answerable_gold_none": counts([row for row in answerable if row["gold_delivery"] == "none"]),
                       "lexical_decline": counts([row for row in mine if row["outcome"] != "answer"]),
                       "false_decline": counts([row for row in mine if row["decline_class"] == "false_decline"])}
    return tables


def judge_summary(args):
    import judge_calibration as jc
    output = args.output.absolute()
    key_document = jc.load_json(output / "judge-set" / "key.json")
    labels_document = jc.load_json(args.labels)
    require(labels_document.get("replicates") == 3 and labels_document.get("complete") is True, "labels_incomplete")
    measured = measurement(output, args.dataset)
    rows = judge_summary_rows(measured["rows"], key_document, labels_document)
    arms = [arm for arm, _ in COHORTS[measured["cohort"]]["arms"]]
    print(json.dumps({"set_id": key_document["set_id"], "judge": labels_document.get("judge"),
                      "declaration_sha256": labels_document.get("declaration_sha256"),
                      "prompts": labels_document.get("prompts"), "rows": rows, "tables": judge_tables(rows, arms)},
                     indent=1))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("declare", "run", "measure", "judge-set", "judge-summary"):
        command = commands.add_parser(name)
        command.add_argument("--output", type=Path, required=True)
        if name in ("declare", "measure", "judge-set", "judge-summary"):
            command.add_argument("--dataset", type=Path, required=True)
        if name in ("declare", "run"):
            command.add_argument("--binary", type=Path, required=True)
        if name == "declare":
            command.add_argument("--cohort", choices=sorted(COHORTS), default="echo-7")
            command.add_argument("--retrieval-arm", choices=sorted(RETRIEVAL_ARMS), default=None,
                                 help="runner retrieval arm for every run; hybrid-only cohorts (retrieval-on-21)")
        if name == "judge-summary":
            command.add_argument("--labels", type=Path, required=True)
    args = parser.parse_args(argv)
    import judge_calibration as jc
    try:
        {"declare": declare, "run": run, "measure": measure, "judge-set": judge_set,
         "judge-summary": judge_summary}[args.command](args)
    except (ReplayError, e.EvaluationError, jc.CalibrationError) as error:
        print(json.dumps({"error": str(error)}))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
