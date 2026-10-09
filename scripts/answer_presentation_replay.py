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
  identifiers and booleans only.

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
                         "abstention": question_id.endswith("_abs"),
                         "recorded_binary_sha256": report["implementation"].get("binary_sha256")})
    configuration = {key: value for key, value in baseline.CONFIGURATION.items() if key != "system"}
    declaration = {
        "version": VERSION, "declared_at_utc": datetime.now(timezone.utc).isoformat(),
        "cohort": args.cohort, "authorization": cohort["authorization"],
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
                 {"v3-pinned": "context-source-snapshot-v3, pinned with --context-framing",
                  "v4-default": "no --context-framing flag: the binary's default, context-source-snapshot-v4 (fixes A, "
                                "D, G); the reported framing is verified at measurement"}),
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
                         "delivered_answer_session_sources": "delivered recent sources from a gold answer session"}},
        "runs": runs}
    private_write(output / "declaration.json", canonical(declaration) + b"\n")
    private_write(output / "ledger.jsonl", b"")
    print(json.dumps({"cohort": args.cohort, "declared_runs": len(runs), "generation_limit": cohort["generation_limit"],
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
        command = [str(binary), "--answer-evaluation", str(input_path), "--output-directory", str(native),
                   "--attempt", str(entry["attempt"])]
        if entry["context_framing"] is not None:
            command += ["--context-framing", entry["context_framing"]]
        if entry["component_policy"] != "selected-model-context-components-v1":
            command += ["--component-policy", entry["component_policy"]]
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


def measure(args):
    output = args.output.absolute()
    declaration = json.loads((output / "declaration.json").read_text())
    cohort_name = declaration.get("cohort", "echo-7")
    cohort = COHORTS[cohort_name]
    frozen = histories(args.dataset, [tuple(case) for case in declaration.get("cases") or cohort["cases"]])
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
                   recorded_prompt_tokens=entry.get("recorded_prompt_tokens"),
                   delivered_recent_matches_recorded=(digest(canonical(item.get("delivered_recent_source_ids") or []))
                                                      == entry["recorded_delivered_recent_sha256"]
                                                      if "recorded_delivered_recent_sha256" in entry else None),
                   abstention=entry["question_id"].endswith("_abs"),
                   **delivered_evidence(history, item.get("delivered_recent_source_ids")),
                   **measure_answer(answer, probe["prompt"], probe["answer"], known, item.get("citation_labels")))
        rows.append(row)
    totals = {}
    for arm, _ in cohort["arms"]:
        measured = [row for row in rows if row["arm"] == arm and row.get("status") == "measured"]
        totals[arm] = {"answers": len(measured),
                       **{name: sum(int(row[name]) for row in measured) for name in DETECTOR if name not in ("answer_bytes", "answer_words")},
                       "median_answer_words": sorted(row["answer_words"] for row in measured)[len(measured) // 2] if measured else None}
    groups = {}
    if cohort_name == "recent-only-21":
        subsets = {"abstention": lambda row: row["abstention"], "answerable": lambda row: not row["abstention"],
                   "disclaimer_questions": lambda row: row["question_id"] in DISCLAIMER_QUESTIONS,
                   "answerable_without_delivered_gold": lambda row: not row["abstention"] and not row["delivered_gold_turns"],
                   "answerable_with_delivered_gold": lambda row: not row["abstention"] and bool(row["delivered_gold_turns"])}
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
                                  "incomplete_result": sum(1 for row in chosen if row["failure"] == "incomplete_result")}
                           for name, test in subsets.items() for chosen in [[row for row in measured if test(row)]]}
    print(json.dumps({"version": VERSION, "cohort": cohort_name, "ledger": attempts_made, "rows": rows, "totals": totals,
                      "groups": groups}, indent=1))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("declare", "run", "measure"):
        command = commands.add_parser(name)
        command.add_argument("--output", type=Path, required=True)
        if name in ("declare", "measure"):
            command.add_argument("--dataset", type=Path, required=True)
        if name in ("declare", "run"):
            command.add_argument("--binary", type=Path, required=True)
        if name == "declare":
            command.add_argument("--cohort", choices=sorted(COHORTS), default="echo-7")
    args = parser.parse_args(argv)
    try:
        {"declare": declare, "run": run, "measure": measure}[args.command](args)
    except (ReplayError, e.EvaluationError) as error:
        print(json.dumps({"error": str(error)}))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
