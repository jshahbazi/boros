#!/usr/bin/env python3
"""Frozen supplementary original-source controls for six reused development cases.

The selected IDs are a separate oracle-derived control. They do not change the
ordinary recall projections, source arrays, question text, or provider caps.
"""
from __future__ import annotations

from pathlib import Path

import evaluate_answers as e
import evaluate_longmemeval as baseline
import longmemeval_cases as cases

VERSION = 6
CONTROL_VERSION = "longmemeval-complete-source-development-v1"
CASE_IDS = cases.CASE_IDS[:6]

# Reviewed before execution: original positives plus complete preceding context
# through the next assistant, opening exchanges, or the complete positive
# session. No source is summarized, spliced, reordered, or synthesized.
PACK_SPECS = {
    "01493427": ((0, 8), (27, 8)),
    "00ca467f": ((1, 2), (40, 2)),
    "0e5e2d1a": ((23, 6),),
    "06878be2": ((35, 16),),
    "001be529": ((42, 12),),
    "08f4fc43": ((23, 2), (27, 2)),
}
PACKS = {qid: tuple(f"{qid}-s{session:04d}-m{turn:04d}"
                    for session, count in specs for turn in range(count))
         for qid, specs in PACK_SPECS.items()}
RATIONALES = {
    "01493427": "complete_original_antecedent_prefix_and_following_assistant_per_positive_session",
    "00ca467f": "complete_original_opening_exchange_per_positive_session",
    "0e5e2d1a": "complete_original_positive_session_preserves_assistant_question_context",
    "06878be2": "complete_original_positive_session_preserves_preference_referents",
    "001be529": "complete_original_positive_session_preserves_user_referents",
    "08f4fc43": "complete_original_opening_exchange_per_positive_session_with_original_dates",
}

# Configuration is separately pinned by the native diagnostic. These pins bind
# the complete oracle-free input, including original dates and selected IDs.
PROJECTION_PINS = {
    "01493427": "fe6e8f3f0f46ab3cd1396552d14a6fad3e3ff6ba8dc79237318f07cedc9ff88f",
    "00ca467f": "4cfe6f614ee53b8884d7976fb07d33c1c84291c13fdcd3b51e9c74f736188909",
    "0e5e2d1a": "147b22015fb585e5dfe5f16aa83bd00d6a78d1025ac284a689c4d87afbe066bf",
    "06878be2": "617cc682749008ee32ce7f2ecddc06bd900cb2de933312295de11bc7d170af40",
    "001be529": "d7a5dbeb84cb541483728498fa80912120be549ac67d7dba3d635a40e747de29",
    "08f4fc43": "3bec8104d1c60064cd378b304754e876ad0891470e20c4679df0e21bda36e0a3",
}
PACK_INVENTORY_PINS = {
    "01493427": "5f72640d341a7a159f1a7d58df85c434864a01b8082ce045b9cb44e2d960cdf4",
    "00ca467f": "f7326acc09ac9ad3f66864c226d860a0225b2614a523347db3500ee7568994a5",
    "0e5e2d1a": "26fd20d658bca854a4e56db12ab229beecfcec69c4f27e7386febcbb8c115f7a",
    "06878be2": "5f2f91b1c3534d9a41e88f69cde5eada07a58dae8e63dabbc06a8d1cef99c4ba",
    "001be529": "008be313074331377e12ba55a1e5650d4dc8d267ac05ad0a7e52a9a0605bf109",
    "08f4fc43": "661ae9c92859de7b0ad5cdb2950cbe1061a2e4e3edbd106f45016d983b7a73a5",
}


def source_inventory(history, source_ids):
    """Content-free immutable full-source/date inventory, in original order."""
    probe = baseline.validate_history(history)
    if probe["abstention"]:
        raise e.EvaluationError("absence case is outside source control scope")
    if (not isinstance(source_ids, (list, tuple)) or not 1 <= len(source_ids) <= 16
            or any(not isinstance(s, str) for s in source_ids)
            or len(set(source_ids)) != len(source_ids)):
        raise e.EvaluationError("invalid declared control source inventory")
    sources = {event["id"]: event for event in history["events"]}
    labels = {label["event_id"]: label for label in history["source_labels"]}
    ordered = [event["id"] for event in history["events"] if event["id"] in source_ids]
    if ordered != list(source_ids):
        raise e.EvaluationError("control sources must preserve original order")
    result = []
    for source_id in source_ids:
        source = sources[source_id]
        encoded = source["text"].encode("utf-8")
        if not 1 <= len(encoded) <= 4096 or source["project_id"] != probe["project_id"]:
            raise e.EvaluationError("control source is outside full-page or scope bounds")
        result.append({"event_id": source_id, "offset": 0, "byte_length": len(encoded),
            "sha256": e.digest(encoded), "source_time_sha256": e.digest(e.canonical_json(source["source_time"])),
            "conversation_key": source["conversation_key"], "role": source["role"], "status": source["status"],
            "original_session_sha256": e.digest(labels[source_id]["session_id"].encode()),
            "positive_annotation": labels[source_id].get("has_answer") is True})
    positives = {label["event_id"] for label in history["source_labels"] if label.get("has_answer") is True}
    if not positives or not positives.issubset(source_ids):
        raise e.EvaluationError("control pack omits original positive turns")
    return result


def runner_input(history, configuration, source_ids=None):
    """Pure oracle-free projection; native eligibility additionally needs pins."""
    selected = list(PACKS.get(history.get("id"), ())) if source_ids is None else list(source_ids)
    source_inventory(history, selected)
    value = cases.runner_input(history, configuration, version=5)
    value["version"] = VERSION
    value["attempts"] = [next(row for row in value["attempts"] if row["strategy"] == "hybrid")]
    value["attempts"][0]["evidence_source_ids"] = selected
    return value


def projection_sha256(document):
    return e.digest(e.canonical_json({key: value for key, value in document.items() if key != "configuration"}))


def validate_document(history, document, configuration, source_ids=None):
    if e.canonical_json(document) != e.canonical_json(runner_input(history, configuration, source_ids)):
        raise e.EvaluationError("source control runner document mismatch")


def prepare(source):
    histories = cases.prepare(Path(source))[:6]
    if tuple(history["id"] for history in histories) != CASE_IDS:
        raise e.EvaluationError("source control case inventory mismatch")
    for history in histories:
        inventory = source_inventory(history, PACKS[history["id"]])
        document = runner_input(history, baseline.CONFIGURATION)
        if (projection_sha256(document) != PROJECTION_PINS.get(history["id"])
                or e.digest(e.canonical_json(inventory)) != PACK_INVENTORY_PINS.get(history["id"])):
            raise e.EvaluationError("frozen source control evidence mismatch")
    return histories


def declaration_case(history, document):
    probe = baseline.validate_history(history)
    inventory = source_inventory(history, document["attempts"][0]["evidence_source_ids"])
    return {"question_id": probe["question_id"], "question_type": probe["question_type"],
        "source_count": len(history["events"]), "source_bytes": sum(len(row["text"].encode()) for row in history["events"]),
        "runner_input_sha256": e.digest(e.canonical_json(document)), "public_projection_sha256": projection_sha256(document),
        "scorer_annotations_sha256": baseline.oracle_sha256(history),
        "question_time_sha256": e.digest(e.canonical_json(probe["question_time"])),
        "declared_source_count": len(inventory), "declared_source_bytes": sum(row["byte_length"] for row in inventory),
        "source_inventory": inventory, "source_inventory_sha256": e.digest(e.canonical_json(inventory)),
        "selection_rationale": RATIONALES.get(history["id"], "synthetic_contract_original_sources"),
        "semantic_sufficiency": None, "provider_token_feasibility": None}
