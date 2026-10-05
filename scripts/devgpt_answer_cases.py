"""Frozen source-derived development cases; never accepts arbitrary chat data.

The source stays in a private local file. This module publishes hashes/counts,
not conversations. DevGPT's serialized Prompt/Answer fields are preserved;
code-block sidecars and conversation-level times are not injected as messages.
"""
from __future__ import annotations

from pathlib import Path
import re

from evaluation_fixtures import canonical_json
from evaluate_answers import EvaluationError, STRATEGIES, digest, read_file, strict_json, validate_configuration

REVISION = "685efd2509dede9a6e996b839ae4e20d33430648"
SOURCE_PATH = "snapshot_20230727/20230727_195927_pr_sharings.json"
SOURCE_SHA256 = "45798598c79dbf6b69b8aee81fc137df084a2359697bafb55e4461cb9b4f2912"
SOURCE_BYTES = 21_495_241
SOURCE_URL = f"https://media.githubusercontent.com/media/NAIST-SE/DevGPT/{REVISION}/{SOURCE_PATH}"
VERSION = "boros-devgpt-exact-quotes-v1"
RUBRIC_VERSION = "boros-public-exact-answer-v1"
# Immutable indices into the content-addressed source, not runtime selection.
# Each sharing identity is distinct. This does not establish independent authors.
CASES = ((139, 1), (90, 1), (143, 0))
PROJECTION_SHA256 = (
    "3ce6a107744a380f2b1f047bbfcacae380bb396cc14cc23c8108d8c240d1d091",
    "9d2a765385191a91562e52312ad906338aba99c7cf46aa144497e7b7047fff41",
    "0ac2f9963c690db4365792fbd2f0f82dfc0929baf15df535caa41f29bef9bd38",
)
ORACLE_SHA256 = (
    "b049c67f31fd4023c7ef55f1727a24898bd698e2818954bb2a0db84d5c7eede0",
    "f2dbb3a0bea007676248f28d729ff7d09f378b72a7c4ffa7941a70d7558a32f5",
    "0a09bcffdb8536ade246788e97acf8d316f327449d815db18d28be26e74e6b35",
)


def first_line(text):
    return next(line.strip() for line in text.splitlines() if line.strip())


def prepare(source: Path):
    data = read_file(source, SOURCE_BYTES)
    if len(data) != SOURCE_BYTES or digest(data) != SOURCE_SHA256:
        raise EvaluationError("public developer source pin mismatch")
    root = strict_json(data)
    histories, identities = [], set()
    for case_index, (source_index, sharing_index) in enumerate(CASES):
        sharing = root["Sources"][source_index]["ChatgptSharing"][sharing_index]
        identity = digest(sharing["URL"].encode())
        if sharing["Status"] != 200 or identity in identities:
            raise EvaluationError("public developer sharing identity mismatch")
        identities.add(identity)
        prefix = f"boros-devgpt-v1-h{case_index:02d}"
        project, conversation = prefix + "-project", prefix + "-chat"
        events, eligible = [], []
        pairs = sharing["Conversations"]
        if (len({pair["Prompt"] for pair in pairs}) != len(pairs)
                or len({pair["Answer"] for pair in pairs}) != len(pairs)
                or any(pair["Prompt"] == pair["Answer"] for pair in pairs)):
            raise EvaluationError("public developer duplicate message contamination")
        for index, pair in enumerate(pairs):
            if any(type(pair.get(key)) is not str or not pair[key].strip() for key in ("Prompt", "Answer")):
                raise EvaluationError("public developer pair unsupported")
            for role, field in (("human", "Prompt"), ("assistant", "Answer")):
                events.append({"id": f"{prefix}-p{index:03d}-{role}", "projectID": project,
                               "conversationKey": conversation, "role": role, "status": "complete",
                               "text": pair[field]})
            question, answer = first_line(pair["Prompt"]), first_line(pair["Answer"])
            if (20 <= len(answer.encode()) <= 2000 and len(question) >= 15
                    and question != answer and "[CODE_BLOCK_" not in answer
                    and not re.match(r"(?:```|<|(?:user|assistant|human)\s*:)", answer, re.I)):
                eligible.append(index)
        if len(eligible) < 3:
            raise EvaluationError("public developer quote targets unavailable")
        # Deterministic selectors frozen by the entire oracle-free projection.
        old, middle, recent = eligible[0], eligible[len(eligible) // 2], eligible[-1]
        episodes = []

        def quote_probe(suffix, indices, category):
            answers, spans, source_ids, requests = [], [], [], []
            for index in indices:
                pair = pairs[index]
                answer = first_line(pair["Answer"])
                event_id = f"{prefix}-p{index:03d}-assistant"
                offset = len(pair["Answer"][:pair["Answer"].index(answer)].encode())
                answers.append(answer); source_ids.append(event_id)
                spans.append({"eventID": event_id, "offset": offset, "byteLength": len(answer.encode()),
                              "sha256": digest(answer.encode())})
                # Source-derived query anchor, explicitly targeted development evidence.
                anchor = first_line(pair["Prompt"])[:160]
                if sum(first_line(other["Prompt"]).startswith(anchor) for other in pairs) != 1:
                    raise EvaluationError("public developer query anchor ambiguous")
                requests.append("the earlier user message whose first nonempty line starts with " + canonical_json(anchor).decode())
            kind = "cross_message_quotes" if len(indices) > 1 else "exact_quote"
            shape = "an array of strings in the requested order" if len(indices) > 1 else "a string"
            prompt = ("Quote exactly the first nonempty line (trim outer whitespace) of the assistant reply to "
                      + "; then ".join(requests) + ". Return only a JSON object with exactly answer, citations, abstain. "
                      + f"answer must be {shape}; citations must be an array of supporting historical event IDs; "
                      + "abstain must be false. If the evidence is unavailable, use an empty answer and abstain true.")
            episodes.append({"id": prefix + "-" + suffix, "projectID": project, "conversationKey": conversation,
                "prompt": prompt, "category": category, "goldSpans": spans, "answerable": True,
                "prototypeByteFeasible": True, "providerTokenFeasible": None,
                "oracle": {"rubric_version": RUBRIC_VERSION, "kind": kind, "expected_answers": answers,
                           "required_source_ids": source_ids, "forbidden_answers": [], "answerable": True}})

        quote_probe("historical", [old], "exact_historical_facts")
        quote_probe("cross-message", [old, middle], "cross_message_quotes")
        quote_probe("later-quote", [recent], "later_source_quotes")
        absent = "boros-unrecorded-" + identity
        if any(absent.casefold() in event["text"].casefold() for event in events):
            raise EvaluationError("public developer absence collision")
        episodes.append({"id": prefix + "-absence", "projectID": project, "conversationKey": conversation,
            "prompt": f"What value was recorded for {absent} in this conversation? Return only a JSON object with exactly answer, citations, abstain. If no value was recorded, answer must be the empty string, citations an empty array, and abstain true.",
            "category": "appropriate_abstention", "goldSpans": [], "answerable": False,
            "prototypeByteFeasible": True, "providerTokenFeasible": None,
            "oracle": {"rubric_version": RUBRIC_VERSION, "kind": "absence", "expected_answers": [],
                       "required_source_ids": [], "forbidden_answers": [], "answerable": False}})
        histories.append({"id": prefix, "events": events, "episodes": episodes,
            "provenance": {"source_index": source_index, "sharing_index": sharing_index,
                "sharing_url_sha256": identity, "serialized_fields": "Prompt/Answer",
                "original_time_indexed": False, "code_sidecars_injected": False,
                "capture_completeness": "serialized_text_only_original_generation_unknown"}})
    return histories


def projection(history):
    return {"version": 1, "split": "development", "history_id": history["id"],
        "events": [{"id": event["id"], "conversation_key": event["conversationKey"],
                    "project_id": event["projectID"], "role": {"human": "user", "assistant": "assistant"}[event["role"]],
                    "status": event["status"], "text": event["text"]} for event in history["events"]],
        "attempts": [{"probe_id": case["id"], "project_id": case["projectID"],
                      "conversation_key": case["conversationKey"], "prompt": case["prompt"],
                      "strategy": strategy, "replicate": 0} for case in history["episodes"] for strategy in STRATEGIES]}


def runner_input(history, configuration):
    value = projection(history)
    if digest(canonical_json(value)) not in PROJECTION_SHA256:
        raise EvaluationError("public developer projection pin mismatch")
    index = PROJECTION_SHA256.index(digest(canonical_json(value)))
    if digest(canonical_json([case["oracle"] for case in history["episodes"]])) != ORACLE_SHA256[index]:
        raise EvaluationError("public developer oracle pin mismatch")
    return {**value, "configuration": validate_configuration(configuration)}


def metadata(history):
    return {"history_id": history["id"], "events": len(history["events"]),
            "source_bytes": sum(len(event["text"].encode()) for event in history["events"]),
            "probes": len(history["episodes"]), "projection_sha256": digest(canonical_json(projection(history))),
            "oracle_sha256": digest(canonical_json([case["oracle"] for case in history["episodes"]])),
            "provenance": history["provenance"]}
