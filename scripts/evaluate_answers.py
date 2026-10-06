#!/usr/bin/env python3
"""One-history public development diagnostic through Boros's shared answering path."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time

from evaluation_fixtures import canonical_json, corpus_summary, generate

ROOT = Path(__file__).resolve().parents[1]
STRATEGIES = ("recent_only", "hybrid")
RUBRIC = "boros-public-factual-literal-v1"
MAX_BYTES = 32 * 1024 * 1024
SHA = re.compile(r"[0-9a-f]{64}\Z")
DEFAULTS = {"endpoint": "http://localhost:11234/v1/",
            "model": "ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit",
            "system": "Be helpful, concise, and accurate.", "temperature": 0.0, "seed": 104202601,
            "thinking": False, "maximum_output": 128, "context_limit": 32768, "safety_tokens": 256}
PUBLIC_PROJECTION_SHA256 = "6ca035c6bb87f23b75c59c8529a0181667e8ece0cc838056139d009f0c501bb4"
FACTUAL_CATEGORIES = {"exact_historical_facts", "cross_session_temporal_updates", "immediate_exact_followups"}


class EvaluationError(Exception):
    """Only fixed, host-authored diagnostics may be stored here."""


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def strict_json(data: bytes):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise EvaluationError("duplicate JSON fields")
            result[key] = value
        return result
    def invalid(_):
        raise EvaluationError("nonfinite JSON number")
    return json.loads(data.decode("utf-8"), object_pairs_hook=pairs, parse_constant=invalid)


def private_write(path: Path, data: bytes):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data); stream.flush(); os.fsync(stream.fileno())


def read_file(path: Path, limit=MAX_BYTES) -> bytes:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or not 0 <= info.st_size <= limit:
            raise EvaluationError("invalid runner file")
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise EvaluationError("runner file exceeds bound")
    return data


def validate_configuration(configuration):
    if not isinstance(configuration, dict) or set(configuration) != set(DEFAULTS):
        raise EvaluationError("unknown or missing configuration fields")
    for field in ("endpoint", "model", "system"):
        if not isinstance(configuration[field], str) or not 1 <= len(configuration[field].encode()) <= 8192:
            raise EvaluationError("invalid text configuration")
    if configuration["model"] != DEFAULTS["model"]:
        raise EvaluationError("diagnostic requires pinned selected-Qwen model")
    from urllib.parse import urlsplit
    url = urlsplit(configuration["endpoint"])
    if (url.scheme != "http" or url.hostname not in ("localhost", "127.0.0.1", "::1")
            or url.username is not None or url.password is not None or url.query or url.fragment):
        raise EvaluationError("diagnostic requires credential-free loopback endpoint")
    if (type(configuration["temperature"]) not in (int, float)
            or not math.isfinite(configuration["temperature"]) or not 0 <= configuration["temperature"] <= 2):
        raise EvaluationError("invalid temperature")
    if type(configuration["thinking"]) is not bool:
        raise EvaluationError("invalid thinking configuration")
    bounds = {"seed": (0, 2**31 - 1), "maximum_output": (1, 8192),
              "context_limit": (1024, 131072), "safety_tokens": (0, 8192)}
    for field, (low, high) in bounds.items():
        if type(configuration[field]) is not int or not low <= configuration[field] <= high:
            raise EvaluationError("invalid integer configuration")
    if configuration["maximum_output"] + configuration["safety_tokens"] >= configuration["context_limit"]:
        raise EvaluationError("invalid context reservation")
    return dict(configuration)


def runner_input(fixtures, configuration):
    """Project generated public material; deliberately exclude all oracle fields."""
    if fixtures.get("split") != "development" or len(fixtures.get("histories", [])) != 1:
        raise EvaluationError("only one generated development history is supported")
    history = fixtures["histories"][0]
    allowed = {case["projectID"] for case in history["episodes"]}
    if len(allowed) != 1:
        raise EvaluationError("unexpected public fixture scopes")
    events = [{"id": event["id"], "conversation_key": event["conversationKey"],
               "project_id": event["projectID"],
               "role": {"human": "user", "assistant": "assistant"}[event["role"]],
               "status": event["status"], "text": event["text"]} for event in history["events"]]
    attempts = [{"probe_id": case["id"], "project_id": case["projectID"], "conversation_key": case["conversationKey"],
                 "prompt": case["prompt"], "strategy": strategy, "replicate": 0}
                for case in history["episodes"] for strategy in STRATEGIES]
    projection = {"version": 1, "split": "development", "history_id": history["id"],
                  "events": events, "attempts": attempts}
    if digest(canonical_json(projection)) != PUBLIC_PROJECTION_SHA256:
        raise EvaluationError("public generator projection changed")
    return {**projection, "configuration": validate_configuration(configuration)}


def expected_values(history, probe):
    sources = {event["id"]: event["text"].encode() for event in history["events"]}
    expected = []
    for span in probe["goldSpans"]:
        data = sources[span["eventID"]]
        start, end = span["offset"], span["offset"] + span["byteLength"]
        if start < 0 or end > len(data) or digest(data[start:end]) != span["sha256"]:
            raise EvaluationError("generated gold digest mismatch")
        data[:start].decode("utf-8")
        expected.append(data[start:end].decode("utf-8"))
    return expected


def factual_score(history, probe, answer: str, operational_complete: bool):
    # Whole-record reproduction, quoted policy, abstention and citations need
    # their own frozen rubrics. Do not turn the scored subset into five-category quality.
    if not probe["prototypeByteFeasible"]:
        return {"rubric": RUBRIC, "score": None, "unavailable_reason": "whole_record_rubric_unfrozen"}
    if probe["category"] not in FACTUAL_CATEGORIES:
        reason = "abstention_rubric_unfrozen" if not probe["answerable"] else "quoted_policy_rubric_unfrozen"
        return {"rubric": RUBRIC, "score": None, "unavailable_reason": reason}
    if not operational_complete:
        return {"rubric": RUBRIC, "score": 0, "unavailable_reason": None,
                "expected_value_count": len(probe["goldSpans"]), "matched_expected_value_count": None}
    expected = expected_values(history, probe)
    if not expected:
        raise EvaluationError("factual probe has no explicit expected values")
    # Byte/case exact public marker presence with identifier boundaries. This
    # intentionally makes no semantic judgment of prose, negation or citations.
    present = [re.search(r"(?<![\w-])" + re.escape(value) + r"(?![\w-])", answer) is not None for value in expected]
    return {"rubric": RUBRIC, "score": int(operational_complete and all(present)),
            "unavailable_reason": None, "expected_value_count": len(expected),
            "matched_expected_value_count": sum(present)}


def delivered_coverage(history, probe, ranges, recent_ids):
    sources = {event["id"]: event for event in history["events"]}
    intervals = {}
    for source_id in recent_ids:
        if source_id not in sources:
            raise EvaluationError("unknown delivered recent source")
        intervals.setdefault(source_id, []).append((0, len(sources[source_id]["text"].encode())))
    for row in ranges:
        if not isinstance(row, dict) or set(row) != {"event_id", "offset", "byte_length", "sha256"}:
            raise EvaluationError("invalid delivered range fields")
        source_id = row["event_id"]
        if source_id not in sources or type(row["offset"]) is not int or type(row["byte_length"]) is not int:
            raise EvaluationError("invalid delivered range")
        data = sources[source_id]["text"].encode()
        start, end = row["offset"], row["offset"] + row["byte_length"]
        if start < 0 or row["byte_length"] <= 0 or end > len(data) or digest(data[start:end]) != row["sha256"]:
            raise EvaluationError("delivered range digest mismatch")
        data[:start].decode("utf-8"); data[start:end].decode("utf-8")
        intervals.setdefault(source_id, []).append((start, end))
    coverage = []
    for gold in probe["goldSpans"]:
        cursor, end = gold["offset"], gold["offset"] + gold["byteLength"]
        for start, stop in sorted(intervals.get(gold["eventID"], [])):
            if start > cursor:
                break
            cursor = max(cursor, stop)
        coverage.append(cursor >= end)
    return {"required_span_count": len(coverage), "covered_span_count": sum(coverage),
            "all_required_spans_delivered": all(coverage) if coverage else None,
            "covered_required_source_ids": sorted({span["eventID"] for span in probe["goldSpans"]
                if all(covered for gold, covered in zip(probe["goldSpans"], coverage)
                       if gold["eventID"] == span["eventID"])}),
            "citation_correctness": None, "sufficient_evidence_token_feasibility": None}


def compile_driver(scratch: Path):
    """Compile an immutable copied source snapshot, binding the binary to it."""
    files = sorted(ROOT.glob("Sources/**/*.swift")) + sorted((ROOT / "Sources/CSQLite").glob("*"))
    files += [ROOT / "scripts/evaluate_answers.py", ROOT / "scripts/test_answer_evaluation.py",
              ROOT / "scripts/evaluation_fixtures.py", ROOT / "scripts/devgpt_answer_cases.py",
              ROOT / "scripts/evaluate_developer_answers.py", ROOT / "scripts/answer_rubrics.py",
              ROOT / "scripts/test_answer_rubrics.py", ROOT / "scripts/test_developer_answer_evaluation.py"]
    files += [ROOT / "scripts/devgpt_evidence_controls.py", ROOT / "scripts/evaluate_evidence_controls.py",
              ROOT / "scripts/test_evidence_controls.py"]
    hashes = {}
    captured = scratch / "captured-source"
    for path in files:
        if not path.is_file():
            continue
        relative = path.relative_to(ROOT)
        data = path.read_bytes()
        destination = captured / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        private_write(destination, data)
        hashes[str(relative)] = digest(data)
    binary = scratch / "answer-driver"
    flags = ["-O", "-swift-version", "5", "-parse-as-library", "-target", "arm64-apple-macos14.0",
             "-framework", "AppKit", "-framework", "Foundation", "-framework", "Security",
             "-framework", "LocalAuthentication", "-framework", "NaturalLanguage"]
    command = ["/usr/bin/swiftc", *flags, *map(str, sorted((captured / "Sources/Boros").glob("*.swift"))),
               "-I", str(captured / "Sources/CSQLite"), "-lsqlite3", "-o", str(binary)]
    built = subprocess.run(command, capture_output=True, timeout=240)
    if built.returncode:
        raise EvaluationError("copied answering driver compilation failed")
    revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, timeout=10)
    return binary, {"git_revision": revision.stdout.decode().strip() if revision.returncode == 0 else None,
            "source_sha256": hashes, "binary_sha256": digest(read_file(binary, 256 * 1024 * 1024)),
            "compiler_flags": flags, "source_binary_linkage": "compiled only from immutable copied source inventory"}


def summarize(attempts):
    result = {}
    for strategy in STRATEGIES:
        selected = [row for row in attempts if row["strategy"] == strategy]
        scored = [row for row in selected if row["task_score"]["score"] is not None]
        result[strategy] = {"attempts": len(selected), "scorable_attempts": len(scored),
                            "successful_factual_attempts": sum(row["task_score"]["score"] for row in scored),
                            "unscored_attempts": len(selected) - len(scored),
                            "operational_completed": sum(row["operational_complete"] for row in selected),
                            "operational_failures": sum(not row["operational_complete"] for row in selected),
                            "categories": {category: {"attempts": len(rows),
                                "scorable_attempts": sum(row["task_score"]["score"] is not None for row in rows)}
                                for category in sorted({row["category"] for row in selected})
                                for rows in [[row for row in selected if row["category"] == category]]}}
    return result


def execute(binary, input_path, directory, timeout):
    # stdout/stderr are private: compiler/provider exceptions can contain chat.
    failure = None
    try:
        process = subprocess.run([str(binary), "--answer-evaluation", str(input_path),
                                  "--output-directory", str(directory)], capture_output=True, timeout=timeout,
                                 env={**os.environ, "BOROS_DATA_DIR": str(directory.parent / "unused-app-runtime")})
        if process.returncode:
            failure = "runner_process_failed"
    except subprocess.TimeoutExpired:
        failure = "runner_process_timeout"
    if (directory / "report.json").exists():
        try:
            report = strict_json(read_file(directory / "report.json"))
            if not isinstance(report, dict):
                raise EvaluationError("invalid runner report")
        except Exception:
            return {"version": 1, "fatal_failure": "runner_report_invalid", "attempts": []}
        if failure:
            report["host_process_failure"] = failure
        return report
    return {"version": 1, "fatal_failure": failure or "runner_report_missing", "attempts": []}


def run(args):
    if set(vars(args)) != {"output", "configuration", "timeout"}:
        raise EvaluationError("unknown diagnostic options")
    output = args.output.absolute()
    if output.exists() or output.is_symlink():
        raise EvaluationError("report already exists")
    configuration = validate_configuration(args.configuration)
    if type(args.timeout) is not int or not 60 <= args.timeout <= 21600:
        raise EvaluationError("invalid runner timeout")
    fixtures = generate("development", history_count=1)
    history = fixtures["histories"][0]
    document = runner_input(fixtures, configuration)
    with tempfile.TemporaryDirectory(prefix="boros-public-answer-evaluation-") as temporary:
        scratch = Path(temporary).resolve(); os.chmod(scratch, 0o700)
        input_path = scratch / "input.json"
        private_write(input_path, canonical_json(document))
        binary, implementation = compile_driver(scratch)
        native = execute(binary, input_path, scratch / "driver-output", args.timeout)
        try:
            if native.get("input_sha256") is not None and native["input_sha256"] != digest(canonical_json(document)):
                raise EvaluationError("runner input provenance mismatch")
            attempts = score_driver_report(native, scratch / "driver-output", history, document["attempts"])
        except (EvaluationError, OSError, UnicodeError, ValueError):
            native = {"version": 1, "fatal_failure": "runner_report_invalid", "attempts": []}
            attempts = score_driver_report(native, scratch / "driver-output", history, document["attempts"])
        report = {"answer_evaluation_version": 1, "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
                  "registration_status": "unregistered_development_diagnostic", "split": "development",
                  "replicates": 1, "strategy_order": list(STRATEGIES), "corpus": corpus_summary(fixtures),
                  "runner_input_sha256": digest(canonical_json(document)), "implementation": implementation,
                  "configuration": {key: value for key, value in configuration.items() if key != "system"},
                  "system_sha256": digest(configuration["system"].encode()),
                  "configuration_sha256": digest(canonical_json(configuration)),
                  "attempts": attempts, "summary": summarize(attempts), "driver": native_metadata(native),
                  "five_category_quality_gate": "inconclusive", "local_billed_cost": None,
                  "limitations": ["one public development history; one replicate; fixed paired order; caches uncontrolled",
                    "factual scoring measures exact expected marker presence, not semantic correctness of prose or negation",
                    "whole-record, abstention, quoted-policy attribution and citation rubrics remain unfrozen",
                    "Apple encoder input tokens, model instance continuity, economics and power are unknown",
                    "delivered gold coverage does not establish sufficient-evidence provider-token feasibility",
                    "fresh index construction per hybrid attempt is experimental spend; partial coverage and failures retained"]}
        output.parent.mkdir(parents=True, exist_ok=True)
        private_write(output, canonical_json(report) + b"\n")
        print(json.dumps({"summary": report["summary"], "five_category_quality_gate": "inconclusive"}, sort_keys=True))
    return report


# Preserve authoritative structured metadata while excluding every free-form
# textual leaf. Unknown field names also become hashes, so a provider-controlled
# key cannot carry chat content into a published report.
METADATA_KEYS = set("""
version diagnostic split history_id input_sha256 fatal_failure declared_attempts completed_attempts baseline
witness_mode witness_validation declared_source_count declared_source_bytes delivered_source_count
complete_pack_delivered source_body_count_revalidated input_proof_version failure_code
source_control_validation complete_declared_sources_delivered declared_source_ids_sha256 selected_historical_source_count
validation_milliseconds native_configuration_sha256
configuration unknowns host_process_failure events source_bytes conversations archive_id database_schema
archive_sha256 timestamps derived_sidecar_in_checkpoint endpoint model instruction_sha256 temperature seed
thinking maximum_output context_limit safety_tokens episode_limits background_limits componentPolicy
ordinal probe_id strategy replicate answer_file terminalized failure_stage failure answer_bytes answer_sha256
episode_state invocation_status delivered_ranges delivered_recent_source_ids full_host_milliseconds
background identifiers episode terminal_reason capture_healthy accounting_healthy invocation_started provider_usage
provider_milliseconds timing overlay_events overlay_bytes preparation background_budget_at_completion
request_sha256 selection_sha256 selection_work_id answer_work_id admission context_audit
schedule performed slices published_chunks failed_chunks scheduled_sources frontier pause_reason
index_fingerprint encoder_fingerprint ranking_fingerprint inventory partial_coverage milliseconds
budget_before budget_after quiescent_during_answer states state sources indexed_bytes indexed_chunks
unsupported_chunks offset_total limits resources charged held unknown issuedAt expiry deadlineSeconds
inputTokens outputTokens modelCalls httpAttempts memoryOperations rawSourceBytes vectorBytes metadataOperations
encoderCalls encoderInputBytes sourceJobs vectorPublicationBytes durationSeconds windowID windowStart
windowEnd episodeID invocationID turnID humanEventID assistantEventID operationID operationKind work
origin projectID conversationID byteLength digest id reason complete partial failed cancelled deadlineExceeded
budgetExceeded completed receivedBytes unknownInputOperations unknownOutputOperations providerInputTokens
providerOutputTokens outputTokenBound knownInputTokens requestedInputTokens requestedOutputTokens
mandatory recent evidence wholeRequest reductions tokenCountProofs inputCount requestedMaximumOutput
contextLimit safetyTokens inputTokenCount outputTokenCount counts sourceSelectionID sourceSelectionDigest
sourceSelectionWorkID requestDigest admittedAt expiresAt modelIdentity modelMetadata templateIdentity
modelID providerFingerprint serverVersion created calibration input_tokens output_tokens total_tokens
preparationMilliseconds firstDurableDeltaMilliseconds providerCompletionMilliseconds finalizationMilliseconds
fullAttemptMilliseconds providerStartedAt acceptedAt admissionMilliseconds encodingMilliseconds
mandatory_input_tokens recent_input_tokens evidence_input_tokens whole_request_input_tokens
historical_sources event_id excerpt_offset excerpt_bytes excerpt_sha256 recent_source_count recent_source_ids_digest
manifest_id coverage_limits raw_coverage lexical_coverage semantic_coverage continuation configuration_fingerprint
source_selection_work_id source_selection_sha256 request_sha256 delivered_source_count recentCount evidenceCount
maximumRecentTokens maximumEvidenceTokens reductionVersion policyVersion componentCounts
public_projection_sha256 firstDurableVisibleDeltaMilliseconds fullCompletionMilliseconds metadataRows
clock_domain created_ticks deadline_ticks clockDomain createdTicks deadlineTicks deadlineMilliseconds
requireKnownModelInput createdAt initiatorID requestID source_snapshot_sha256 message_components components
modelEpoch endpoint loadedModelEpoch templateDigest serverVersion bodyDigest envelopeBytes promptTokens
componentProof recentCap evidenceCap renderingVersion thinkingEnabled outputReserve effectiveContextLimit
sourceSnapshotDigest adapterIdentity assignmentDigest policyDigest sourceSelectionWorkID sourceSelectionDigest
recent_source_ids_sha256 manifest replay_manifest_id replay_manifest_sha256 indexConfigurationDigest
mandatoryCount recentCount evidenceCount wholePrompt recent evidence tokens bytes snapshotDigest
renderedDigest workID sessionID countKind freshnessDomain freshnessTicks reductionSteps retainedMessages
modelContextLimit maxModelLength metadataDigest observedMetadata serverIdentity modelInstanceIdentity
budgetWindow window durationHours raw_source_bytes model_calls http_attempts vector_bytes metadata_rows
promoted_primary_count quoted_anchor_count exchange_expansion exchange_expansion_omitted primary_count retained_primary_count
dropped_primary_count added_neighbor_count prefix_truncated_count decisions anchor_event_id neighbor_event_id prefix_truncated direction
retrieval selection selection_trace selection_trace_omitted lexical_query_version lexical_query_sha256
lexical_input_version lexical_input_sha256 lexical_input_offset lexical_input_bytes accepted_prompt_sha256
semantic_input_version semantic_input_sha256 semantic_input_offset semantic_input_bytes
primary_completion completed_primary_count original_excerpt_offset original_excerpt_bytes complete_source_bytes
lexical_term_count lexical_selected_token_indices candidate_count trace_truncated candidates assembly
source_sha256 byte_length offset rank disposition mode semantic_available failure source_frontier raw_work_version
raw_work_charged inspected_candidates candidate_window_full candidate_window_complete continuation_available
query_disposition query_sha256 lexical_query_sha256 published_chunk_frontier coverage_complete inspected_sources
complete_sources pending_sources unsupported_sources failed_sources holes_truncated vector_candidates_inspected
vector_continuation_available metadata_continuation_sequence raw_continuation_available literal_search raw_snapshot_id
query_configuration_fingerprint encoder_fingerprint ordered_recent_source_ids_sha256 omitted_recent_count
maximumRecentBytes maximumRecentRows maximumEvidenceBytes maximumEvidenceSpans maximumEvidenceSpanBytes
maximumSerializedBytes recentByteExcludedCount recentRowExcludedCount evidenceByteExcludedCount evidenceRowExcludedCount
recentTokenExcludedCount evidenceTokenExcludedCount recentEnvelopeExcludedCount evidenceEnvelopeExcludedCount
recentReductionRounds evidenceReductionRounds source_bytes source_created_utc capture_status conversation_id project_id
""".split())
SAFE_ENUMS = set("""
development recent_only hybrid complete partial failed cancelled deadlineExceeded budgetExceeded completed
sufficient-exchange-pack-v1 sufficient-exchange-pack-validation-v1 witness_outcome_unavailable
witness_pack_not_delivered witness_source_body_count_invalid
declared-original-sources-v1 declared_original_sources source_control_outcome_unavailable source_control_sources_not_delivered source_control_source_body_count_invalid
declared_sources_not_delivered skipped_declared_original_sources_control
none preparation answer_or_finalization restore_or_setup acceptance checkpoint_failed attempt_setup_failed
acceptance_failed index_construction_failed ipc_publication_failed attempt_metadata_failed
per_hybrid_attempt_before_acceptance ingestion_frozen_in_checkpoint apple_input_tokens local_billed_cost
first_useful_answer scheduled pending paused unsupported error working finished unknown prepared armed submitted
settled released chat localRead human assistant user running stopped queued available unavailable
mandatory recent evidence historicalEvidence wholePrompt answer calibration tokenization queryEncoding sourceRead
foreground background known opaque unobservable metadata_observation
production-answer-development-v1 runner_process_failed runner_process_timeout runner_report_missing runner_report_invalid
accepted-prompt-utf8-range-v1 complete-short-primaries-v1 retained_primary completed_short_primary historical-selection-trace-v1 prefix-eight-nonfiller-v1 quoted-anchor-round-robin-v1 following-assistant-prefix-v1 following-assistant-prefix-v2 adjacent-exchange-prefix-v3 preceding_human following_assistant assistant_boundary promoted_primary promoted_primary_retained covered_neighbor_prefix
candidate_limit excluded_primary duplicate_primary duplicate_anchor no_neighbor human_boundary excluded_neighbor duplicate_neighbor empty_neighbor included_prefix excluded_recent_or_request span_limit invalid_span_size
evidence_byte_limit envelope_byte_limit included metadata_limit supported adapterUnavailable inputTooLarge emptyInput
codeLike nonEnglish ambiguousLanguage inputAccountingUnavailable lexical lexical_fallback raw_work_v1
context-geometric-v1 semantic_search_failed
""".split())
UUID = re.compile(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\Z")


def content_free_metadata(value, public_ids=frozenset()):
    if value is None or type(value) in (bool, int):
        return value
    if type(value) is float:
        if not math.isfinite(value):
            raise EvaluationError("nonfinite driver metadata")
        return value
    if isinstance(value, str):
        if value in SAFE_ENUMS or value in public_ids or SHA.fullmatch(value) or UUID.fullmatch(value):
            return value
        return {"sha256": digest(value.encode()), "bytes": len(value.encode())}
    if isinstance(value, list):
        return [content_free_metadata(item, public_ids) for item in value]
    if isinstance(value, dict):
        return {(key if key in METADATA_KEYS else "field_sha256_" + digest(key.encode())):
                content_free_metadata(item, public_ids) for key, item in value.items()}
    raise EvaluationError("invalid driver metadata type")


def native_metadata(native):
    return content_free_metadata({key: value for key, value in native.items() if key != "attempts"})


def score_driver_report(native, directory, history, requested, task_scorer=None):
    if not isinstance(native, dict) or type(native.get("version")) is not int or native["version"] != 1:
        raise EvaluationError("invalid driver report version")
    raw = native.get("attempts")
    if not isinstance(raw, list) or len(raw) > len(requested) or any(not isinstance(item, dict) for item in raw):
        raise EvaluationError("invalid driver attempt inventory")
    probe_map = {probe["id"]: probe for probe in history["episodes"]}
    public_ids = frozenset([history["id"], *probe_map, *(event["id"] for event in history["events"])])
    results = []
    for ordinal, request in enumerate(requested):
        item = raw[ordinal] if ordinal < len(raw) else None
        answer = ""
        if item is not None:
            if (not isinstance(item, dict) or type(item.get("ordinal")) is not int or item["ordinal"] != ordinal
                    or type(item.get("replicate")) is not int
                    or any(item.get(key) != request[key] for key in ("probe_id", "strategy", "replicate"))
                    or type(item.get("terminalized")) is not bool
                    or item.get("answer_file") != f"answer-{ordinal:04d}.txt"):
                raise EvaluationError("driver terminal attempt linkage failed")
            if item["terminalized"] is False:
                # No oracle access to process-interrupted answers. Unknown
                # capture/resources remain unknown; failed factual task is zero.
                operational = False
                coverage = delivered_coverage(history, probe_map[request["probe_id"]], [], [])
                metadata = content_free_metadata(item, public_ids)
                started = time.monotonic()
                probe = probe_map[request["probe_id"]]
                results.append({"ordinal": ordinal, "probe_id": request["probe_id"], "strategy": request["strategy"],
                                "replicate": request["replicate"], "category": probe["category"],
                                "operational_complete": False, "task_score": (task_scorer(history, probe, "", False, coverage)
                                    if task_scorer else factual_score(history, probe, "", False)),
                                "answer_bytes": None, "answer_sha256": None, "delivered_coverage": coverage,
                                "oracle_scoring_milliseconds": (time.monotonic() - started) * 1000, "metadata": metadata})
                continue
            encoded = read_file(directory / item["answer_file"], 4 * 1024 * 1024)
            if (type(item.get("answer_bytes")) is not int or item["answer_bytes"] != len(encoded)
                    or item.get("answer_sha256") != digest(encoded)):
                raise EvaluationError("answer IPC digest mismatch")
            answer = encoded.decode("utf-8")
            operational = (item.get("episode_state") == "completed" and item.get("invocation_status") == "complete"
                           and item.get("capture_healthy") is True and item.get("accounting_healthy") is True
                           and item.get("failure") is None)
            ranges, recent = item.get("delivered_ranges"), item.get("delivered_recent_source_ids")
            if not isinstance(ranges, list) or not isinstance(recent, list) or not all(isinstance(source, str) for source in recent):
                raise EvaluationError("missing delivered source metadata")
            coverage = delivered_coverage(history, probe_map[request["probe_id"]], ranges, recent)
            metadata = content_free_metadata(item, public_ids)
        else:
            operational = False
            coverage = delivered_coverage(history, probe_map[request["probe_id"]], [], [])
            metadata = {"terminalized": False, "failure_stage": "runner_process_or_report",
                        "episode_state": None, "invocation_status": None,
                        "resources": None, "capture_status": None}
        started = time.monotonic()
        probe = probe_map[request["probe_id"]]
        task_score = (task_scorer(history, probe, answer, operational, coverage)
                      if task_scorer else factual_score(history, probe, answer, operational))
        results.append({"ordinal": ordinal, "probe_id": request["probe_id"], "strategy": request["strategy"],
                        "replicate": request["replicate"], "category": probe["category"],
                        "operational_complete": operational, "task_score": task_score,
                        "answer_bytes": len(answer.encode()) if item is not None else None,
                        "answer_sha256": digest(answer.encode()) if item is not None else None,
                        "delivered_coverage": coverage, "oracle_scoring_milliseconds": (time.monotonic() - started) * 1000,
                        "metadata": metadata})
        # Explicitly discard private answer material after its terminal score.
        answer = ""
    return results


class SafeParser(argparse.ArgumentParser):
    def error(self, _message):
        self.exit(2, "Invalid answer-evaluation arguments.\n")


def main():
    parser = SafeParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--configuration", type=Path, help="Exact supported configuration JSON; no credentials")
    parser.add_argument("--timeout", type=int, default=10800)
    args = parser.parse_args()
    try:
        args.configuration = strict_json(read_file(args.configuration)) if args.configuration else dict(DEFAULTS)
        run(args)
    except EvaluationError as error:
        print("Answer evaluation failed: " + str(error) + ".", file=sys.stderr); return 1
    except Exception:
        print("Answer evaluation failed; content diagnostics suppressed.", file=sys.stderr); return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
