#!/usr/bin/env python3
"""Answer-blind proportional selection and opaque native-v8 projections."""
from __future__ import annotations

from collections import Counter
from pathlib import Path

import evaluate_answers as e
import local_longmemeval_qa as qa
import longmemeval_independent_cases as independent

DOMAIN = "boros-native-investigation-hundred-selection-v1"
IDENTITY_DOMAIN = "boros-native-investigation-hundred-opaque-identity-v1"
COHORT = "native-investigation-100-v1"
VERSION = 8
COUNT = 100
CONFIGURATION = dict(independent.CONFIGURATION)
CATEGORIES = tuple(sorted(set(qa.CASE_TYPES)))
EARLY_CASE_IDS = ("0ddfec37_abs", "29f2956b_abs", "6aeb4375_abs", "80ec1f4f_abs", "ba358f49_abs",
    "e493bb7c", "184da446", "0f05491a", "9ea5eabc", "8979f9ec", "gpt4_ab202e7f", "gpt4_59c863d7",
    "5a7937c8", "ceb54acb", "f523d9fe", "41275add", "7a8d0b71", "6b7dfb22", "75832dbd", "0edc2aef",
    "1c0ddc50", "ccb36322", "36580ce8", "577d4d32", "f8c5f88b", "gpt4_f420262d", "2ebe6c90",
    "gpt4_fa19884d", "c8090214", "6cb6f249")
EXCLUDED_CASE_IDS = tuple(sorted(set(qa.CASE_IDS + independent.CASE_IDS + EARLY_CASE_IDS)))


def require(condition, code):
    if not condition:
        raise e.EvaluationError(code)


def rank_sha256(question_id):
    require(isinstance(question_id, str) and bool(question_id), "hundred_identity_invalid")
    return qa.digest((DOMAIN + "\0" + question_id).encode())


def opaque(kind, question_id, *coordinates):
    require(kind in ("history", "project", "conversation", "event", "probe"), "hundred_identity_kind_invalid")
    # No category/abstention bit, ordinal rank or scorer information is encoded.
    return qa.digest(qa.canonical([IDENTITY_DOMAIN, kind, question_id, *coordinates]))


def select_rows(rows, excluded=EXCLUDED_CASE_IDS, count=COUNT):
    """Only question identity and category are accessed until selection is frozen."""
    require(type(count) is int and count > 0 and isinstance(rows, list), "hundred_selection_inventory_invalid")
    by_id = {}
    for index, row in enumerate(rows):
        require(isinstance(row, dict) and isinstance(row.get("question_id"), str) and bool(row["question_id"])
            and row["question_id"] not in by_id and row.get("question_type") in CATEGORIES,
            "hundred_selection_identity_invalid")
        by_id[row["question_id"]] = (index, row["question_type"])
    require(set(excluded).issubset(by_id), "hundred_excluded_identity_missing")
    eligible = {qid: value for qid, value in by_id.items() if qid not in set(excluded)}
    require(len(eligible) >= count, "hundred_selection_pool_insufficient")
    population = Counter(category for _index, category in eligible.values())
    # Hamilton apportionment of the remaining pool; ties use category name.
    quotas = {category: count * population[category] // len(eligible) for category in CATEGORIES}
    remainder_order = sorted(CATEGORIES,
        key=lambda category: (-(count * population[category] % len(eligible)), category))
    for category in remainder_order[:count - sum(quotas.values())]:
        quotas[category] += 1
    chosen = []
    for category in CATEGORIES:
        pool = sorted((qid for qid, (_index, task) in eligible.items() if task == category),
                      key=lambda qid: (rank_sha256(qid), qid))
        chosen.extend(pool[:quotas[category]])
    chosen.sort(key=lambda qid: (rank_sha256(qid), qid))
    require(len(chosen) == count and len(set(chosen)) == count, "hundred_selection_count_invalid")
    return tuple(chosen), {"version": DOMAIN, "cohort": COHORT, "declared_questions": count,
        "rank_rule": "sha256_domain_nul_question_id_utf8", "stratification": "question_type",
        "allocation": "Hamilton_largest_remainder_of_eligible_category_counts_ties_category_name",
        "population_category_counts": dict(population), "category_quotas": quotas,
        "excluded_case_ids": list(excluded), "eligible_questions": len(eligible),
        "selection_uses_answers": False, "selection_uses_positive_labels": False,
        "selection_uses_abstention": False, "selection_uses_history_or_question_content": False,
        "case_ids": chosen, "case_types": [by_id[qid][1] for qid in chosen],
        "selected_inventory": [{"ordinal": ordinal, "question_id": qid, "question_type": by_id[qid][1],
            "source_index": by_id[qid][0], "rank_sha256": rank_sha256(qid)} for ordinal, qid in enumerate(chosen)]}


def _history(case, source_index):
    original = independent._history_from_case(case, source_index)
    qid, events = original["id"], original["events"]
    project = opaque("project", qid)
    conversation_map = {f"session-{index:04d}": opaque("conversation", qid, index)
                        for index in range(original["session_count"])}
    event_map = {event["id"]: opaque("event", qid, ordinal) for ordinal, event in enumerate(events)}
    public_events = [{**event, "id": event_map[event["id"]], "project_id": project,
                      "conversation_key": conversation_map[event["conversation_key"]]} for event in events]
    probe = original["episodes"][0]
    return {**original, "id": opaque("history", qid), "events": public_events,
        "source_labels": [{**label, "event_id": event_map[label["event_id"]]} for label in original["source_labels"]],
        "episodes": [{**probe, "id": opaque("probe", qid), "project_id": project,
                      "conversation_key": conversation_map[probe["conversation_key"]]}]}


def runner_input(history, configuration=CONFIGURATION):
    require(configuration == CONFIGURATION, "hundred_configuration_changed")
    probe = history["episodes"][0]
    return {"version": VERSION, "split": "development", "history_id": history["id"],
        "events": [{key: event[key] for key in ("id", "project_id", "conversation_key", "role", "status", "text", "source_time")}
                   for event in history["events"]],
        "attempts": [{"probe_id": probe["id"], **{key: probe[key] for key in
            ("project_id", "conversation_key", "prompt", "question_time")}, "strategy": "hybrid", "replicate": 0}],
        "configuration": dict(configuration)}


def annotation(history):
    document, probe = runner_input(history), history["episodes"][0]
    return {"question_id": probe["question_id"], "history_id": history["id"],
        "question_type": probe["question_type"], "abstention": probe["abstention"],
        "source_index": history["source_index"], "session_count": history["session_count"],
        "source_count": len(history["events"]), "source_bytes": sum(len(event["text"].encode()) for event in history["events"]),
        "runner_input_sha256": qa.digest(qa.canonical(document)),
        "public_projection_sha256": independent.projection_sha256(document),
        "scorer_annotations_sha256": independent.scorer_annotations_sha256(history)}


def prepare(source):
    raw = qa.read_file(Path(source), qa.SOURCE_BYTES)
    require(len(raw) == qa.SOURCE_BYTES and qa.digest(raw) == qa.SOURCE_SHA256, "hundred_source_pin_mismatch")
    rows = qa.strict_json(raw)
    require(len(rows) == 500, "hundred_source_record_count_invalid")
    selected, manifest = select_rows(rows)
    by_id = {row["question_id"]: index for index, row in enumerate(rows)}
    # Oracle fields are validated and projected only AFTER the IDs are selected.
    pins = qa.SourcePins(case_ids=selected, case_types=tuple(rows[by_id[qid]]["question_type"] for qid in selected))
    projected = qa.project_cases(raw, pins)
    histories = [_history(case, by_id[case["id"]]) for case in projected]
    manifest.update(source={"sha256": qa.SOURCE_SHA256, "bytes": qa.SOURCE_BYTES, "records": 500,
        "revision": qa.SOURCE_REVISION, "name": qa.SOURCE_NAME}, runner_document_version=VERSION,
        opaque_identity_domain=IDENTITY_DOMAIN, configuration=CONFIGURATION,
        cases=[{"ordinal": ordinal, **annotation(history)} for ordinal, history in enumerate(histories)],
        limitations=["identity exclusions do not establish session-disjoint or semantic-independent histories",
                     "one native investigation answer per question; no matched recent-only or ordinary-hybrid arm"])
    return histories, manifest
