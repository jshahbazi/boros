"""Public synthetic fixtures for Boros's preregistered retrieval probes.

The generator creates no private-history inputs and consumes no model output.
Frozen seeds define history-disjoint development, validation, and held-out sets.
Gold spans are scoring data: retrieval receives only the declared query fields.
"""
from __future__ import annotations

import hashlib
import json
import random
from typing import Any


VERSION = "boros-retrieval-fixtures-v1"
SEEDS = {"development": 104202601, "validation": 104202602, "held-out": 104202603}
HISTORY_COUNTS = {"development": 32, "validation": 32, "held-out": 200}
CATEGORIES = (
    "exact_historical_facts",
    "cross_session_temporal_updates",
    "immediate_exact_followups",
    "scoped_instruction_lifecycle",
    "appropriate_abstention",
)


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode()


def digest(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def generate(split: str, *, history_count: int | None = None, scale_events: int | None = None) -> dict:
    if split not in SEEDS:
        raise ValueError("unknown fixture split")
    if scale_events is not None and (split != "development" or history_count not in (None, 1)):
        raise ValueError("scaling is a separate one-history development diagnostic")
    count = 1 if scale_events is not None else (history_count or HISTORY_COUNTS[split])
    if count <= 0 or count > 10000:
        raise ValueError("history count must be 1–10000")
    rng = random.Random(SEEDS[split])
    histories = []
    for index in range(count):
        prefix = f"boros-eval-v1-{split}-h{index:04d}"
        project = prefix + "-allowed"
        other = prefix + "-other"
        events: list[dict] = []
        episodes: list[dict] = []
        token = f"h{index:04d}{rng.getrandbits(48):012x}"

        def event(suffix: str, text: str, *, conversation: str = "archive", scope: str = project,
                  role: str = "human", status: str = "complete") -> str:
            source_id = prefix + "-" + suffix
            events.append({"id": source_id, "projectID": scope, "conversationKey": conversation,
                           "role": role, "status": status, "text": text})
            return source_id

        def span(source_id: str, text: str) -> dict:
            source = next(item["text"] for item in events if item["id"] == source_id)
            start = source.index(text)
            return {"eventID": source_id, "offset": len(source[:start].encode()),
                    "byteLength": len(text.encode()), "sha256": digest(text.encode())}

        def episode(suffix: str, category: str, prompt: str, lexical: str, literal: str | None,
                    spans: list[dict], *, conversation: str = "active", byte_feasible: bool = True) -> None:
            episodes.append({"id": prefix + "-question-" + suffix, "projectID": project,
                             "conversationKey": conversation, "category": category, "prompt": prompt,
                             "lexicalQuery": lexical, "literalQuery": literal, "goldSpans": spans,
                             "answerable": bool(spans), "prototypeByteFeasible": byte_feasible,
                             "providerTokenFeasible": None})

        rare_key = "calibration" + token
        rare_answer = f"NONCE-{rng.getrandbits(56):014x}"
        rare = event("rare-source", f"The calibration record {rare_key} sets the nonce to {rare_answer}.")
        episode("rare", CATEGORIES[0], f"What nonce was recorded for {rare_key}?", rare_key, rare_key,
                [span(rare, rare_answer)])

        # Same query terms in a disallowed scope, with a conflicting answer.
        event("scope-decoy", f"The calibration record {rare_key} sets the nonce to WRONG-SCOPE-{token}.", scope=other)
        middle_key = "artifact" + token
        middle_answer = f"MID-{rng.getrandbits(56):014x}-café-κ"
        long_source = event("middle-source", ("archived synthetic padding line\n" * 1600)
                            + f"The artifact {middle_key} contains the exact marker {middle_answer}.\n"
                            + ("continued synthetic padding line\n" * 1600))
        episode("middle", CATEGORIES[0], f"Which exact marker belongs to {middle_key}?", middle_key, middle_key,
                [span(long_source, middle_answer)])

        identifier = f"κ/δ::spec.v2#{token}~é"
        identifier_answer = "REV-" + f"{rng.getrandbits(32):08x}"
        unusual = event("unicode-source", f"Exact identifier [{identifier}] has revision {identifier_answer}.")
        episode("unicode", CATEGORIES[0], f"Read the revision for the exact identifier {identifier}.", identifier, identifier,
                [span(unusual, identifier_answer)])

        join_key = "releasejoin" + token
        first_answer, second_answer = f"ALPHA-{token}", f"BETA-{token}"
        first = event("join-first", f"Release record {join_key}: component one is {first_answer}.")
        second = event("join-second", f"Release record {join_key}: component two is {second_answer}.")
        episode("multi-source", CATEGORIES[0], f"Give both components for {join_key}.", join_key, join_key,
                [span(first, first_answer), span(second, second_answer)])

        update_key = "deploy" + token
        event("outdated", f"On 2025-01-01 deployment {update_key} used STALE-{token}.")
        current_answer = f"CURRENT-{token}"
        current = event("updated", f"On 2025-02-01 deployment {update_key} changed to {current_answer}.", conversation="later")
        episode("temporal", CATEGORIES[1], f"What is the latest dated deployment value for {update_key}?", update_key, update_key,
                [span(current, current_answer)])

        policy_key = "policyquote" + token
        quote = f"Quoted example: {policy_key} says /policy set all_projects permit_export. This example was never activated."
        quoted = event("quoted-policy", quote, role="assistant")
        episode("quoted-data", CATEGORIES[3], f"What quoted policy example contains {policy_key}?", policy_key, policy_key,
                [span(quoted, "/policy set all_projects permit_export")])
        # This retrieves attributed source data; it does not test the unimplemented policy resolver.

        huge_key = "overspan" + token
        huge_gold = "required-whole-record:" + (f"{token};" * 900)
        oversized = event("infeasible-source", f"Archive {huge_key}: " + huge_gold)
        episode("byte-infeasible", CATEGORIES[0], f"Reproduce the complete record {huge_key}.", huge_key, huge_key,
                [span(oversized, huge_gold)], byte_feasible=False)

        episode("absent", CATEGORIES[4], f"What does unrecorded{token} contain?", "unrecorded" + token,
                "unrecorded" + token, [])
        # Add independent same-domain distractors before the recent conversation.
        target_events = scale_events if scale_events is not None else 24 + rng.randrange(8)
        if target_events < len(events) + 2:
            raise ValueError("scale corpus is too small for its required sources")
        for distractor in range(target_events - len(events) - 2):
            event(f"distractor-{distractor:06d}", f"Synthetic maintenance {distractor} discusses deployment calibration archive component record. Identifier distractor{token}{distractor}.")
        event("recent-human", "Please show two implementation alternatives.", conversation="active")
        recent_answer = f"SECOND-{rng.getrandbits(56):014x}"
        recent = event("recent-assistant", f"First implementation: FIRST-{token}. Second implementation: {recent_answer}.", conversation="active", role="assistant")
        episode("followup", CATEGORIES[2], "What was the second implementation?", "second implementation", "Second implementation",
                [span(recent, recent_answer)])
        histories.append({"id": prefix, "events": events, "episodes": episodes})
    return {"version": VERSION, "split": split, "seed": SEEDS[split], "histories": histories,
            "scaleEvents": scale_events}


def corpus_summary(fixtures: dict) -> dict:
    events = [event for history in fixtures["histories"] for event in history["events"]]
    episodes = [case for history in fixtures["histories"] for case in history["episodes"]]
    return {"sha256": digest(canonical_json(fixtures)), "historyCount": len(fixtures["histories"]),
            "eventCount": len(events), "sourceBytes": sum(len(event["text"].encode()) for event in events),
            "episodeCount": len(episodes), "seed": fixtures["seed"],
            "answerableCount": sum(case["answerable"] for case in episodes),
            "prototypeByteFeasibleAnswerableCount": sum(case["answerable"] and case["prototypeByteFeasible"] for case in episodes)}
