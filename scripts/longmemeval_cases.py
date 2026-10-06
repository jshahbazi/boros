#!/usr/bin/env python3
"""Exact source and oracle separation for the frozen LongMemEval S pilot."""
from __future__ import annotations

import json
from pathlib import Path

import evaluate_answers as e
from import_chat import normalize_time as source_normalization

SOURCE_REVISION = "98d7416c24c778c2fee6e6f3006e7a073259d48f"
SOURCE_BYTES = 277383467
SOURCE_SHA256 = "d6f21ea9d60a0d56f34a05b609c79c88a451d2ae03597821ea3d5a9678c3a442"
SOURCE_NAME = "longmemeval_s_cleaned.json"
CASE_IDS = ("01493427", "00ca467f", "0e5e2d1a", "06878be2", "001be529", "08f4fc43", "031748ae_abs")
CASE_TYPES = ("knowledge-update", "multi-session", "single-session-assistant",
              "single-session-preference", "single-session-user", "temporal-reasoning", "knowledge-update")
EvaluationError = e.EvaluationError
canonical_json = e.canonical_json
digest = e.digest


def normalize_time(value):
    try:
        return source_normalization(value)
    except (ValueError, TypeError, UnicodeError):
        raise EvaluationError("invalid benchmark source date") from None


def _source_time(value, sha, locator):
    return {**normalize_time(value), "source_sha256": sha, "locator": locator, "original_value": value}


def prepare_rows(rows, source_sha256=SOURCE_SHA256):
    """Pure projection, also used by synthetic contract checks; not a native grant."""
    if not isinstance(rows, list) or not rows or not e.SHA.fullmatch(source_sha256):
        raise EvaluationError("invalid benchmark root")
    by_id = {}
    for index, row in enumerate(rows):
        if not isinstance(row, dict) or not isinstance(row.get("question_id"), str):
            raise EvaluationError("invalid benchmark record identity")
        qid = row["question_id"]
        if qid in by_id:
            raise EvaluationError("duplicate benchmark question identity")
        by_id[qid] = (index, row)
    if any(qid not in by_id for qid in CASE_IDS):
        raise EvaluationError("frozen benchmark case unavailable")
    histories = []
    keys = {"question_id", "question_type", "question", "question_date", "answer",
            "answer_session_ids", "haystack_dates", "haystack_session_ids", "haystack_sessions"}
    for qid, expected_type in zip(CASE_IDS, CASE_TYPES):
        source_index, row = by_id[qid]
        if (set(row) != keys or row["question_type"] != expected_type
                or not isinstance(row["question"], str) or not row["question"]
                or type(row["answer"]) not in (str, int)):
            raise EvaluationError("invalid benchmark case fields")
        dates, ids, sessions, gold = (row[k] for k in (
            "haystack_dates", "haystack_session_ids", "haystack_sessions", "answer_session_ids"))
        if (not all(isinstance(v, list) for v in (dates, ids, sessions, gold)) or not sessions
                or len(dates) != len(ids) or len(ids) != len(sessions)
                or not all(isinstance(sid, str) and sid for sid in ids)
                or not all(isinstance(sid, str) for sid in gold)
                or len(set(gold)) != len(gold) or not set(gold).issubset(ids)):
            raise EvaluationError("invalid benchmark session inventory")
        project = "longmemeval-" + qid
        events, labels = [], []
        for session_index, (literal, session_id, turns) in enumerate(zip(dates, ids, sessions)):
            if not isinstance(turns, list) or not turns:
                raise EvaluationError("empty benchmark session")
            time = _source_time(literal, source_sha256, f"/{source_index}/haystack_dates/{session_index}")
            conversation = f"session-{session_index:04d}"
            for turn_index, turn in enumerate(turns):
                if (not isinstance(turn, dict) or set(turn) - {"role", "content", "has_answer"}
                        or not {"role", "content"}.issubset(turn)
                        or turn["role"] not in ("user", "assistant") or not isinstance(turn["content"], str)
                        or ("has_answer" in turn and type(turn["has_answer"]) is not bool)):
                    raise EvaluationError("invalid benchmark turn")
                event_id = f"{qid}-s{session_index:04d}-m{turn_index:04d}"
                events.append({"id": event_id, "project_id": project, "conversation_key": conversation,
                               "role": turn["role"], "status": "complete", "text": turn["content"],
                               "source_time": dict(time)})
                label = {"event_id": event_id, "session_id": session_id}
                if "has_answer" in turn:
                    label["has_answer"] = turn["has_answer"]
                labels.append(label)
        question_time = _source_time(row["question_date"], source_sha256, f"/{source_index}/question_date")
        histories.append({"id": qid, "source_index": source_index, "session_count": len(sessions),
                          "events": events, "source_labels": labels,
                          "episodes": [{"id": qid, "question_id": qid, "project_id": project,
                              "conversation_key": f"session-{len(sessions)-1:04d}",
                              "prompt": row["question"], "question_time": question_time,
                              "answer": row["answer"], "question_type": row["question_type"],
                              "abstention": qid.endswith("_abs"), "answer_session_ids": list(gold)}]})
    return histories


def prepare(source):
    raw = e.read_file(Path(source), SOURCE_BYTES)
    if len(raw) != SOURCE_BYTES or digest(raw) != SOURCE_SHA256:
        raise EvaluationError("pinned benchmark source mismatch")
    try:
        rows = e.strict_json(raw)
    except (ValueError, UnicodeError):
        raise EvaluationError("invalid benchmark JSON") from None
    if not isinstance(rows, list) or len(rows) != 500:
        raise EvaluationError("pinned benchmark inventory mismatch")
    # Selection is fixed before results. Verify its documented rule on the complete source.
    selected = []
    for category in CASE_TYPES[:6]:
        ids = sorted(row["question_id"] for row in rows if row["question_type"] == category
                     and not row["question_id"].endswith("_abs"))
        selected.append(ids[0] if ids else None)
    absent = sorted(row["question_id"] for row in rows if row["question_id"].endswith("_abs"))
    selected.append(absent[0] if absent else None)
    if tuple(selected) != CASE_IDS:
        raise EvaluationError("frozen benchmark selection mismatch")
    return prepare_rows(rows)


def runner_input(history, configuration, version=5):
    if type(version) is not int or version not in (4, 5):
        raise EvaluationError("unsupported benchmark runner version")
    events = [{key: event[key] for key in ("id", "project_id", "conversation_key", "role", "status", "text", "source_time")}
              for event in history["events"]]
    probe = history["episodes"][0]
    attempts = [{"probe_id": probe["id"], "project_id": probe["project_id"],
                 "conversation_key": probe["conversation_key"], "prompt": probe["prompt"],
                 "question_time": probe["question_time"], "strategy": strategy, "replicate": 0}
                for strategy in e.STRATEGIES]
    return {"version": version, "split": "development", "history_id": history["id"],
            "events": events, "attempts": attempts, "configuration": dict(configuration)}


def projection_sha256(history, configuration, version=5):
    document = runner_input(history, configuration, version=version)
    document.pop("configuration")
    return digest(canonical_json(document))


def native_configuration_sha256(configuration):
    normalized = {key: (int(value) if type(value) is float and value.is_integer() else value)
                  for key, value in configuration.items()}
    return digest(canonical_json(normalized))
