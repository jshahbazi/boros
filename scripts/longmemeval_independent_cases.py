#!/usr/bin/env python3
"""Frozen fresh development cohort with disjoint original histories and queries.

Ranking and disjointness do not inspect answers or positive annotations. The
unchanged pinned QA projector validates and preserves selected original content.
No source text, questions, answers, or original date literals are reported.
"""
from __future__ import annotations

from pathlib import Path

import local_longmemeval_qa as qa

DOMAIN = "boros-independent-longmemeval-development-v1"
VERSION = 7
COHORT = "independent-v1"
SOURCE_REVISION = qa.SOURCE_REVISION
SOURCE_SHA256 = qa.SOURCE_SHA256
SOURCE_BYTES = qa.SOURCE_BYTES
SOURCE_NAME = qa.SOURCE_NAME
SOURCE_RECORDS = 500
EXCLUDED_CASE_IDS = qa.CASE_IDS
SLOTS = tuple(category for category in qa.CASE_TYPES[:6] for _ in range(2)) + ("abstention", "abstention")
CASE_IDS = ("7a87bd0c", "a1eacc2a", "1192316e", "51c32626", "1b9b7252", "4baee567", "1a1907b4",
    "54026fce", "3f1e9474", "1faac195", "gpt4_70e84552", "gpt4_2655b836", "0862e8bf_abs", "f685340e_abs")
CASE_TYPES = tuple(category for category in qa.CASE_TYPES[:6] for _ in range(2)) + ("single-session-user", "knowledge-update")
CONFIGURATION = {**qa.ANSWER_CONFIGURATION, "maximum_output": 1024}
PROJECTION_PINS = {
    "7a87bd0c": "4aad7cb5d65069b853c6852bca223049020417ecae799344a9ff579600c469e8",
    "a1eacc2a": "877999e49027c2d1801da2072dffdfc1b625dc1cc90f3954909d78a91fb95d7d",
    "1192316e": "d34354e4d795f92a65535b1b4c7038f0917772790263b3466aa7e3ee4da822e1",
    "51c32626": "e43a5d27f41961f8aae69bdab5858cea1ede19e1d0d7a30e5d37c3a315081942",
    "1b9b7252": "d7768d3ae9538f26a6d377d3351448e432f821d22df79ee99521c0fa3c907b76",
    "4baee567": "d522f012e5ec259dc6154934462cc96c5a131a0d68a06b83d504d66db5f85a04",
    "1a1907b4": "adfa18a04185021306d5a7602fa81f74b32402506cf8d6b1cc0fbaa8e247f48f",
    "54026fce": "9263f9f93c02b4764b8c7ca78251627abf95ad2100c4cb5262a665562825457f",
    "3f1e9474": "5f0a5b74a478f640e55971f48d2f7f91270bf79a05496832722cc3a7b0f847a8",
    "1faac195": "baf71a226fb86f2e515a30d863ac1e408e84fee183987eef5e928c8edf9f1999",
    "gpt4_70e84552": "98983bd7eaaad4e48c182293adb8dcc66900d9eb472841750f6b665733aeffeb",
    "gpt4_2655b836": "205a6863707939eb00720a72c7166d3ae98720190275a2425ef589ae538b92d9",
    "0862e8bf_abs": "b276edab0ad6cfc4e27f3c4834f6f4dd3375049d7a053cf591e4f7bb1d7af314",
    "f685340e_abs": "853e68bd253f3ae19612131600b16a86c37dff639c555aa510efa3c6752c3780",
}
EvaluationError = qa.GradeError


def require(condition, code):
    if not condition:
        raise EvaluationError(code)


def rank_sha256(question_id):
    require(isinstance(question_id, str) and question_id, "independent_case_identity_invalid")
    return qa.digest((DOMAIN + "\0" + question_id).encode())


def session_payload_sha256(turns):
    require(isinstance(turns, list) and turns, "independent_session_invalid")
    for turn in turns:
        require(isinstance(turn, dict) and turn.get("role") in ("user", "assistant")
            and isinstance(turn.get("content"), str), "independent_session_invalid")
    # Positive annotations, answer/session labels, and dates do not affect this
    # overlap test. Full original role/content order and bytes do affect it.
    return qa.digest(qa.canonical([{"role": turn["role"], "content": turn["content"]} for turn in turns]))


def _features(row):
    ids, sessions = row.get("haystack_session_ids"), row.get("haystack_sessions")
    require(isinstance(ids, list) and isinstance(sessions, list) and ids and len(ids) == len(sessions)
        and all(isinstance(sid, str) and sid for sid in ids)
        and isinstance(row.get("question"), str) and row["question"], "independent_source_inventory_invalid")
    payloads = [session_payload_sha256(turns) for turns in sessions]
    return ids, payloads, qa.digest(row["question"].encode())


def _selected_row_validation(row, features):
    ids, payloads, _query = features
    require(len(ids) == len(set(ids)), "independent_duplicate_selected_session_id")
    require(len(payloads) == len(set(payloads)), "independent_duplicate_selected_session_payload")
    # Strict selected-row validation of all other original fields is performed
    # by qa.project_cases after the answer-blind selection has been frozen.


def select_rows(rows):
    """Pure fixed selector for portable checks; production source pins are later required."""
    require(isinstance(rows, list) and rows, "independent_source_root_invalid")
    by_id = {}
    for index, row in enumerate(rows):
        require(isinstance(row, dict) and isinstance(row.get("question_id"), str) and row["question_id"]
            and row["question_id"] not in by_id and row.get("question_type") in qa.CASE_TYPES,
            "independent_source_identity_invalid")
        by_id[row["question_id"]] = (index, row)
    require(all(case_id in by_id for case_id in EXCLUDED_CASE_IDS), "independent_excluded_cases_missing")
    cache = {}
    def features(case_id):
        if case_id not in cache:
            cache[case_id] = _features(by_id[case_id][1])
        return cache[case_id]
    used_ids, used_payloads, used_questions = set(), set(), set()
    excluded = []
    for case_id in EXCLUDED_CASE_IDS:
        ids, payloads, question = features(case_id)
        used_ids.update(ids); used_payloads.update(payloads); used_questions.add(question)
        excluded.append({"question_id": case_id, "source_index": by_id[case_id][0],
            "question_sha256": question, "session_id_sha256": [qa.digest(v.encode()) for v in ids],
            "session_payload_sha256": payloads})
    excluded_counts = {"session_ids": len(used_ids), "session_payloads": len(used_payloads), "questions": len(used_questions)}
    selected_ids, slot_proofs, selected_proofs = [], [], []
    for ordinal, category in enumerate(SLOTS):
        pool = sorted((case_id for case_id, (_index, row) in by_id.items()
            if case_id not in EXCLUDED_CASE_IDS and case_id not in selected_ids
            and (case_id.endswith("_abs") if category == "abstention" else
                 not case_id.endswith("_abs") and row["question_type"] == category)),
            key=lambda case_id: (rank_sha256(case_id), case_id))
        counts = {"session_id_overlap": 0, "session_payload_overlap": 0, "question_overlap": 0}
        inspected, chosen = 0, None
        for case_id in pool:
            inspected += 1
            ids, payloads, question = features(case_id)
            conflicts = (bool(used_ids.intersection(ids)), bool(used_payloads.intersection(payloads)), question in used_questions)
            for key, conflict in zip(counts, conflicts):
                counts[key] += int(conflict)
            if any(conflicts):
                continue
            _selected_row_validation(by_id[case_id][1], features(case_id))
            chosen = case_id
            selected_ids.append(case_id)
            used_ids.update(ids); used_payloads.update(payloads); used_questions.add(question)
            selected_proofs.append({"question_id": case_id, "question_type": by_id[case_id][1]["question_type"],
                "abstention": case_id.endswith("_abs"), "source_index": by_id[case_id][0],
                "rank_sha256": rank_sha256(case_id), "question_sha256": question,
                "session_count": len(ids), "session_id_sha256": [qa.digest(v.encode()) for v in ids],
                "session_payload_sha256": payloads})
            break
        require(chosen is not None, "independent_selection_slot_exhausted")
        slot_proofs.append({"ordinal": ordinal, "category": category, "candidate_count": len(pool),
            "inspected_count": inspected, "selected_question_id": chosen, **counts})
    return tuple(selected_ids), {"selection_version": DOMAIN, "cohort": COHORT,
        "rank_rule": "sha256_domain_nul_question_id_utf8", "session_payload_rule": "canonical_full_ordered_role_content_v1",
        "slot_order": list(SLOTS), "excluded_case_ids": list(EXCLUDED_CASE_IDS),
        "excluded_inventory": excluded, "excluded_distinct_counts": excluded_counts,
        "slots": slot_proofs, "selected_inventory": selected_proofs, "declared_cases": 14, "declared_attempts": 28,
        "disjointness": {"against_all_excluded_and_previous_selected_session_ids": True,
            "against_all_excluded_and_previous_selected_session_payloads": True,
            "against_all_excluded_and_previous_selected_question_utf8_digests": True,
            "within_selected_session_ids_unique": True, "within_selected_session_payloads_unique": True},
        "rank_or_eligibility_uses_answers": False, "rank_or_eligibility_uses_positive_annotations": False}


def _history_from_case(case, source_index):
    row = case["row"]
    labels = []
    for session_index, (session_id, turns) in enumerate(zip(row["haystack_session_ids"], row["haystack_sessions"])):
        for turn_index, turn in enumerate(turns):
            label = {"event_id": f"{case['id']}-s{session_index:04d}-m{turn_index:04d}", "session_id": session_id}
            if "has_answer" in turn:
                label["has_answer"] = turn["has_answer"]
            labels.append(label)
    request = case["attempts"][0]
    return {"id": case["id"], "source_index": source_index, "session_count": len(row["haystack_sessions"]),
        "events": case["events"], "source_labels": labels,
        "episodes": [{"id": case["id"], "question_id": case["id"],
            **{key: request[key] for key in ("project_id", "conversation_key", "prompt", "question_time")},
            "answer": row["answer"], "question_type": row["question_type"], "abstention": case["id"].endswith("_abs"),
            "answer_session_ids": list(row["answer_session_ids"])}]}


def runner_input(history, configuration):
    require(isinstance(configuration, dict) and type(configuration.get("maximum_output")) is int
            and configuration["maximum_output"] == 1024,
            "independent_output_configuration_invalid")
    probe = history["episodes"][0]
    events = [{key: event[key] for key in ("id", "project_id", "conversation_key", "role", "status", "text", "source_time")}
              for event in history["events"]]
    attempts = [{"probe_id": probe["id"], **{key: probe[key] for key in ("project_id", "conversation_key", "prompt", "question_time")},
                 "strategy": strategy, "replicate": 0} for strategy in qa.STRATEGIES]
    return {"version": VERSION, "split": "development", "history_id": history["id"],
        "events": events, "attempts": attempts, "configuration": dict(configuration)}


def projection_sha256(document):
    return qa.digest(qa.canonical({key: value for key, value in document.items() if key != "configuration"}))


def scorer_annotations_sha256(history):
    probe = history["episodes"][0]
    return qa.digest(qa.canonical({"source_labels": history["source_labels"],
        **{key: probe[key] for key in ("answer", "question_type", "abstention", "answer_session_ids")}}))


def case_annotation(history, configuration=CONFIGURATION):
    document = runner_input(history, configuration)
    probe = history["episodes"][0]
    return {"question_id": history["id"], "question_type": probe["question_type"], "abstention": probe["abstention"],
        "source_index": history["source_index"], "session_count": history["session_count"],
        "source_count": len(history["events"]), "source_bytes": sum(len(event["text"].encode()) for event in history["events"]),
        "question_time_sha256": qa.digest(qa.canonical(probe["question_time"])),
        "runner_input_sha256": qa.digest(qa.canonical(document)), "public_projection_sha256": projection_sha256(document),
        "scorer_annotations_sha256": scorer_annotations_sha256(history)}


def prepare_with_manifest(source):
    try:
        raw = qa.read_file(Path(source), SOURCE_BYTES)
        require(len(raw) == SOURCE_BYTES and qa.digest(raw) == SOURCE_SHA256, "independent_source_pin_mismatch")
        rows = qa.strict_json(raw)
        require(isinstance(rows, list) and len(rows) == SOURCE_RECORDS, "independent_source_inventory_mismatch")
        selected, manifest = select_rows(rows)
        require(selected == CASE_IDS, "independent_frozen_case_inventory_mismatch")
        by_id = {row["question_id"]: index for index, row in enumerate(rows)}
        types = tuple(rows[by_id[case_id]]["question_type"] for case_id in selected)
        require(types == CASE_TYPES, "independent_frozen_case_types_mismatch")
        cases = qa.project_cases(raw, qa.SourcePins(sha256=SOURCE_SHA256, byte_count=SOURCE_BYTES,
            revision=SOURCE_REVISION, name=SOURCE_NAME, record_count=SOURCE_RECORDS, case_ids=CASE_IDS, case_types=CASE_TYPES))
        histories = [_history_from_case(case, by_id[case["id"]]) for case in cases]
        annotations = [case_annotation(history) for history in histories]
        require(all(annotation["public_projection_sha256"] == PROJECTION_PINS.get(annotation["question_id"])
            for annotation in annotations), "independent_native_projection_pin_mismatch")
        require(all(annotation["scorer_annotations_sha256"] == case["oracle_sha256"]
            for annotation, case in zip(annotations, cases)), "independent_oracle_projection_mismatch")
        manifest.update(source={"revision": SOURCE_REVISION, "sha256": SOURCE_SHA256, "bytes": SOURCE_BYTES,
            "name": SOURCE_NAME, "records": SOURCE_RECORDS}, case_ids=list(CASE_IDS), case_types=list(CASE_TYPES),
            runner_document_version=VERSION, cases=annotations)
        return histories, manifest
    except EvaluationError:
        raise
    except (KeyError, TypeError, ValueError, AttributeError, IndexError, UnicodeError):
        raise EvaluationError("independent_cohort_invalid") from None


def prepare(source):
    return prepare_with_manifest(source)[0]
