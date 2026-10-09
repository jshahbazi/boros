#!/usr/bin/env python3
"""Fresh single-session-preference cohort for the framing V5 replay, as opaque runner documents.

The cohort is every ``single-session-preference`` question of the pinned LongMemEval S file except
the three already in the saved native runs (54026fce, 06878be2 and 1a1907b4). Selection reads only
question identity and type. Histories are projected by the unchanged pinned QA projector, then
given opaque model-visible identifiers exactly as the version-8 development cohort does
(``native_investigation_hundred_cases``; plan P4 step 4: no answerability cue such as ``_abs`` or
the question ID in any model-visible identifier), under a separate identity domain.

Runner document version 9 has the version-8 shape (one ``hybrid`` attempt, original session dates,
question date) but is answered by the ordinary ``--answer-evaluation`` path, never the native
investigation. Its configuration is the independent cohort's (1,024 output tokens). The native
runner accepts only the pinned projection digests in ``PROJECTION_PINS``.

No source text, question, answer or date literal is reported by this module.
"""
from __future__ import annotations

from pathlib import Path

import evaluate_answers as e
import local_longmemeval_qa as qa
import longmemeval_independent_cases as independent

COHORT = "framing-v5-preference-27"
QUESTION_TYPE = "single-session-preference"
IDENTITY_DOMAIN = "boros-framing-v5-preference-opaque-identity-v1"
RANK_DOMAIN = "boros-framing-v5-preference-order-v1"
VERSION = 9
# Already in the saved native runs and in the regression cohorts of this replay.
EXCLUDED_CASE_IDS = ("06878be2", "1a1907b4", "54026fce")
CONFIGURATION = dict(independent.CONFIGURATION)
# Public projection SHA-256 (runner document without configuration) per question, as accepted by
# AnswerEvaluationCommand.preferenceLongMemoryCorpusProjectionSHA256. Changing one requires a
# matching source amendment there.
PROJECTION_PINS = {
    "1d4e3b97": "4db7ec6dd1f957e6e70f0fa34a9f2c30d4cf1d9816291b1cc6b55b69e5501f76",
    "35a27287": "ad5352f5a9472ceacd7db4d4dbc0a6561c915c2bc23779c9cc1e4019635a93a8",
    "505af2f5": "eda5d01bd55d921c350d32b8ae7c5a2a316f9afb48b531bed3ef5c4919345a59",
    "0a34ad58": "86e7797334dde10e23ff624f9acb95cfd1e18cb385e9a2ac96a02cbcd820285d",
    "32260d93": "458d931d55407be4e1770ce1c09ae9b6fc02050720a846217bfdecf8ae4df9f8",
    "57f827a0": "b1b01960100ed3149cd74596d606fe64e0646c61fcd128ed4fb3ec051b04f4f0",
    "1c0ddc50": "c19abced05a3970c97be170c069ab8b2868d2e76cf6c8ea83d2184f32af29a6f",
    "a89d7624": "47aad81b39e0d1e4b9a51c1c07aa346050469a7ce6f45fd586bf6623c058980d",
    "b6025781": "5aae2636209f810a87e1bcc47ad9b5cb55f1d6af20866d756d4d9cc8ae967652",
    "d6233ab6": "c2913de168a4a1e0407cf10f1ae3c032f7eee3fa54128755c51c66603fedbfae",
    "6b7dfb22": "36bb99ae409d791e7e6a4edeb9e1b2a40e8c80c7021cad0e911ce6f05ddc94d7",
    "75832dbd": "e23198333269800bb9d495c450f3f4e51f444b35e8ee4dc8f2597200f4a542be",
    "b0479f84": "81e3a4ffc4030f248e17e4c9a4556866d36870f5b39efc1c4260a4636e145e12",
    "1da05512": "592e12dd268619867db67ef9713d2d9cc62f0ccb00dd07b7dcc52940c7d27469",
    "75f70248": "f04516cdd3426ef1b2a050cd063ca9dece70bc106e3a90224b9e435934406976",
    "8a2466db": "3ddf149ec9e3fe288b709343f207f841f23119279c7f20ab0897211d0a9777fd",
    "afdc33df": "35160d2e6af48d719043dc601677b755339c23e129963d6bb280d815836a6886",
    "d24813b1": "5202586e713393d762ca2f28cb6dd459150a04afdc5cd4da02522ff0f77a241e",
    "caf03d32": "582e208a1e777dd6542e9de7763ef516b0c3e10919b4a3898bc834a46dbf2974",
    "06f04340": "4ec62ff83eff03c6c026b81c98fe8e98ca0b66646d62081e245b1e5c723f9860",
    "09d032c9": "f65c9975e44859920e80530daab2e194e4b08d7915e72c5a760911ffcf766143",
    "95228167": "5ce7a9879db2850e81a525b314e8f2ee9436e96a3c245a3ba64d0b5753f2a94a",
    "07b6f563": "df68fa7df1d40f708fc7ed4979f4daec98da69217d2b057b8ab0426ad3d231ea",
    "0edc2aef": "574ee8e99b15921207e95e6d0f86805aba903c64a82c464177909dd6c35c68f2",
    "38146c39": "418ed248876edd00b2345c9831a051893434700607b801ae503a63adce48d13a",
    "195a1a1b": "41868926df9f412c60259df94f873ebcd95ae7e884bc8886c8c1a4d12c58eff9",
    "fca70973": "b9edef0a8401054a86a5694cb1b2ec49fc9875dcf499290a7fe6234f5375e7a2",
}


def require(condition, code):
    if not condition:
        raise e.EvaluationError(code)


def rank_sha256(question_id):
    require(isinstance(question_id, str) and bool(question_id), "preference_identity_invalid")
    return qa.digest((RANK_DOMAIN + "\0" + question_id).encode())


def opaque(kind, question_id, *coordinates):
    require(kind in ("history", "project", "conversation", "event", "probe"), "preference_identity_kind_invalid")
    # No question ID, type, abstention bit, ordinal rank or scorer information is visible.
    return qa.digest(qa.canonical([IDENTITY_DOMAIN, kind, question_id, *coordinates]))


def select_rows(rows, excluded=EXCLUDED_CASE_IDS):
    """Every preference question minus the exclusions, in rank order. Reads identity and type only."""
    require(isinstance(rows, list) and bool(rows), "preference_inventory_invalid")
    by_id = {}
    for index, row in enumerate(rows):
        require(isinstance(row, dict) and isinstance(row.get("question_id"), str) and bool(row["question_id"])
                and row["question_id"] not in by_id and isinstance(row.get("question_type"), str),
                "preference_identity_invalid")
        by_id[row["question_id"]] = (index, row["question_type"])
    require(set(excluded).issubset(by_id) and all(by_id[qid][1] == QUESTION_TYPE for qid in excluded),
            "preference_excluded_identity_missing")
    population = [qid for qid, (_index, task) in by_id.items() if task == QUESTION_TYPE]
    chosen = sorted((qid for qid in population if qid not in excluded), key=lambda qid: (rank_sha256(qid), qid))
    require(bool(chosen), "preference_selection_empty")
    return tuple(chosen), {"cohort": COHORT, "question_type": QUESTION_TYPE,
        "population": len(population), "excluded_case_ids": list(excluded), "declared_questions": len(chosen),
        "order_rule": "sha256_rank_domain_nul_question_id_utf8", "selection_uses_answers": False,
        "selection_uses_positive_labels": False, "selection_uses_history_or_question_content": False,
        "case_ids": list(chosen),
        "selected_inventory": [{"ordinal": ordinal, "question_id": qid, "source_index": by_id[qid][0],
                                "rank_sha256": rank_sha256(qid)} for ordinal, qid in enumerate(chosen)]}


def opaque_history(case, source_index):
    """The independent cohort's history with opaque project, conversation, event and probe IDs."""
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
    require(configuration == CONFIGURATION, "preference_configuration_changed")
    probe = history["episodes"][0]
    return {"version": VERSION, "split": "development", "history_id": history["id"],
            "events": [{key: event[key] for key in ("id", "project_id", "conversation_key", "role", "status", "text",
                                                    "source_time")} for event in history["events"]],
            "attempts": [{"probe_id": probe["id"], **{key: probe[key] for key in
                          ("project_id", "conversation_key", "prompt", "question_time")}, "strategy": "hybrid",
                          "replicate": 0}],
            "configuration": dict(configuration)}


def annotation(history):
    document, probe = runner_input(history), history["episodes"][0]
    return {"question_id": probe["question_id"], "history_id": history["id"], "question_type": probe["question_type"],
            "abstention": probe["abstention"], "source_index": history["source_index"],
            "session_count": history["session_count"], "source_count": len(history["events"]),
            "runner_input_sha256": qa.digest(qa.canonical(document)),
            "public_projection_sha256": independent.projection_sha256(document),
            "scorer_annotations_sha256": independent.scorer_annotations_sha256(history)}


def prepare(source, verify_pins=True):
    """(histories, manifest). With ``verify_pins``, every projection must equal its source pin."""
    raw = qa.read_file(Path(source), qa.SOURCE_BYTES)
    require(len(raw) == qa.SOURCE_BYTES and qa.digest(raw) == qa.SOURCE_SHA256, "preference_source_pin_mismatch")
    rows = qa.strict_json(raw)
    require(len(rows) == 500, "preference_source_record_count_invalid")
    selected, manifest = select_rows(rows)
    by_id = {row["question_id"]: index for index, row in enumerate(rows)}
    # Oracle fields are validated and projected only after the IDs are selected.
    pins = qa.SourcePins(case_ids=selected, case_types=tuple(QUESTION_TYPE for _ in selected))
    histories = [opaque_history(case, by_id[case["id"]]) for case in qa.project_cases(raw, pins)]
    annotations = [annotation(history) for history in histories]
    if verify_pins:
        require(set(PROJECTION_PINS) == set(selected), "preference_projection_pin_inventory_mismatch")
        require(all(item["public_projection_sha256"] == PROJECTION_PINS[item["question_id"]] for item in annotations),
                "preference_projection_pin_mismatch")
    manifest.update(source={"sha256": qa.SOURCE_SHA256, "bytes": qa.SOURCE_BYTES, "records": 500,
                            "revision": qa.SOURCE_REVISION, "name": qa.SOURCE_NAME},
                    runner_document_version=VERSION, opaque_identity_domain=IDENTITY_DOMAIN,
                    configuration=CONFIGURATION, cases=annotations)
    return histories, manifest
