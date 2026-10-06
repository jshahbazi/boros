"""Frozen complete-exchange packs for a separate DevGPT feasibility control.

Source and question bytes stay private. The scorer-only oracle never enters
the version-2 native projection. The original paired inputs remain unchanged.
"""
from __future__ import annotations

import copy
from pathlib import Path

import devgpt_answer_cases as cases
import evaluate_answers as e
import evaluate_developer_answers as developer
from evaluation_fixtures import canonical_json

VERSION = "sufficient-exchange-pack-v1"
VALIDATION_VERSION = "sufficient-exchange-pack-validation-v1"
CONFIGURATION_SHA256 = "62381f748b563189b34b9c97f637c3ee234aef7095ce64096ecf6411ece850cf"
# Foundation canonical JSON emits the frozen 0.0 temperature as numeric 0.
# These are separately named representation pins for identical settings.
NATIVE_CONFIGURATION_SHA256 = "73729124226e2a729d052ea49d6f03ecced31b2b93e3beea63064ab046fa0013"
FORMAT_INSTRUCTION_AMENDMENT = "json-output-instructions-v1"
FORMAT_INSTRUCTION_SYSTEM = ("Be helpful, concise, and accurate. Follow the user's requested output format exactly. "
    "If the user requests JSON, return only valid JSON with the requested top-level structure and fields, "
    "without Markdown fences or explanatory text.")
FORMAT_CONFIGURATION_SHA256 = "2b1535b93ea3bbb16035bbe3f744b6e4c980eac9837ea8694925fc5554d37e69"
FORMAT_NATIVE_CONFIGURATION_SHA256 = "f13e87eb29ce2ecf88746293d3f01d74841394dc0a0aca3d2e9d5747dda53361"
JSON_OBJECT_AMENDMENT = "provider-json-object-v1"
JSON_OBJECT_CONFIGURATION_SHA256 = "9bc6d9649f9c9c4cc40682f79fc0babbe3397a0211856d708a577d907d44c297"
JSON_OBJECT_NATIVE_CONFIGURATION_SHA256 = "8aef45d2a8c7d20b8ee669606df5094f9d4ec960f82496841e8680dd433167cd"
JSON_OBJECT_PROJECTION_SHA256 = (
    "7eaa4b959959b0afcb5f9895634e552eae1bac062e3100ab1f0d2d8d2653bdcb",
    "ab841b6f5611ed3df034b384ec440a23c46e9968ffecf61482eea572dce97ade",
    "52150ae4979989ebf12a9628a6ad0aecd2960150f5b15e897c85c0ba2d02c32e",
    "42cdff1f9aa72c7b2c7ce8724d26c6397038b9288e354cb5f1346b5d80e2f790",
    "fa40c8a36239be193de2f88bc80b10ef54a1eb1b476b9d8fad58ff8d2d9fb2b7",
    "eaa7aa2b33c5c51acbb42f805e82709ff7409a72acaa36702cdcc5c66770a835",
    "5238c51f6ec58ad3908a3654ae0fbe1f0a373dd13bec9ff040338459cb138218",
    "09316ffa9fc3f26d2dc81acad2eb7ede0c1c1c9b12dd678e6c80d38ed9c8230c",
    "eedf2f3ca33017e90b1ad449be99ef50bddba4f792b5f9635f44001151cbccdb",
)
PROJECTION_SHA256 = (
    "ae74877c63469436c0e8e17c16f9f4098eeee06e34f5a52f68ddaf8ae0f32aee",
    "5dd12260c9eaedf39965285cdb1d0cd821bde4d8a3ce53d67546854dc06b950a",
    "f9846f813421e252690662e0e0f2c937d129b2d92725c4f8d0557448b2aee207",
    "6f3c01af22d0069091fffb571686fb2acea7ed25475fe1dcf3fdd94808f3567d",
    "01918c47e143c6c21288dc3302fc2d36cb3a98064625aa2b659eb8d23f39953d",
    "5c6002a0f86505e7c9b3d0aaef421c450bea49febf6ee3822c7d3f88662ad67f",
    "f3c2b62c221401c941fedd72aa288cd22868c3a259136bf45965b3670a49e787",
    "7a324ac5081b76309a2ba1667fd38a234ad55011382f6afe5cc335f4f7db96c4",
    "5ee1706bcc661fa306758e546a24c0c894f616ca5d07972ddb5e5f4ba0a7d0e1",
)
ORACLE_SHA256 = (
    "dde637836fbaaa6cb81ecf4fcf124f3d3e750e9527ba75869b3ee6aa8b4f4f0a",
    "c07343f1622107654a8664b520d3514cd1672a7d5146bfbcda71a0312372e292",
    "de661147e086761bb18cd61cc0ef80c6f4c69e78cd7f0b347c9620a72f05076c",
    "582a05a052f98494af46fae09fd8a82ba6487e0edaa99a497a2f7576c63ad9a4",
    "6f3e8633cc32a2c6f0bec1000aca99e0d5ee683729fda5dbcc4e8f856f55811c",
    "8cd520a7b86208d6f8e25b7d6a6b2a9127e5a96ae0037b0257bcf24940793f9c",
    "528b0f3fb28aefa9658e713f0ab2488c01156afa7f5f3fdadbd6f8dd479a2185",
    "05f0a774742d48dd6001aa2f8b07dd10d2506fd25edaa6c3c6620eaf87fd4f75",
    "339c942d71c1e961b39b4037aa06e79f786b06d286efd743a7872548344f349c",
)


def projection(pack, *, json_object=False):
    if type(json_object) is not bool:
        raise e.EvaluationError("invalid evidence control amendment option")
    probe = pack["episodes"][0]
    return {"version": 3 if json_object else 2, "split": "development", "history_id": pack["id"],
        "events": [{"id": event["id"], "project_id": event["projectID"],
                    "conversation_key": event["conversationKey"],
                    "role": {"human": "user", "assistant": "assistant"}[event["role"]],
                    "status": event["status"], "text": event["text"]} for event in pack["events"]],
        "attempts": [{"probe_id": probe["id"], "project_id": probe["projectID"],
                      "conversation_key": probe["conversationKey"], "prompt": probe["prompt"],
                      "strategy": "recent_only", "replicate": 0}]}


def validate_configuration(configuration):
    if isinstance(configuration, dict) and "response_format" in configuration:
        if configuration["response_format"] != "json_object":
            raise e.EvaluationError("evidence control configuration pin mismatch")
        e.validate_configuration({key: value for key, value in configuration.items() if key != "response_format"})
        if e.digest(canonical_json(configuration)) != JSON_OBJECT_CONFIGURATION_SHA256:
            raise e.EvaluationError("evidence control configuration pin mismatch")
        return dict(configuration)
    configuration = e.validate_configuration(configuration)
    if e.digest(canonical_json(configuration)) not in (CONFIGURATION_SHA256, FORMAT_CONFIGURATION_SHA256):
        raise e.EvaluationError("evidence control configuration pin mismatch")
    return configuration


def selected_configuration(*, format_instructions=False, json_object=False):
    if (type(format_instructions) is not bool or type(json_object) is not bool
            or (format_instructions and json_object)):
        raise e.EvaluationError("invalid evidence control amendment option")
    configuration = dict(developer.CONFIGURATION)
    if format_instructions:
        configuration["system"] = FORMAT_INSTRUCTION_SYSTEM
    if json_object:
        configuration["response_format"] = "json_object"
    return validate_configuration(configuration)


def configuration_pins(configuration):
    configuration = validate_configuration(configuration)
    pin = e.digest(canonical_json(configuration))
    if pin == JSON_OBJECT_CONFIGURATION_SHA256:
        return pin, JSON_OBJECT_NATIVE_CONFIGURATION_SHA256, JSON_OBJECT_AMENDMENT
    if pin == FORMAT_CONFIGURATION_SHA256:
        return pin, FORMAT_NATIVE_CONFIGURATION_SHA256, FORMAT_INSTRUCTION_AMENDMENT
    return pin, NATIVE_CONFIGURATION_SHA256, None


def validate_pack(pack):
    try:
        if len(pack["episodes"]) != 1 or pack["episodes"][0]["answerable"] is not True:
            raise e.EvaluationError("evidence control probe inventory mismatch")
        pin = e.digest(canonical_json(projection(pack)))
        if pin not in PROJECTION_SHA256:
            raise e.EvaluationError("evidence control projection pin mismatch")
        index = PROJECTION_SHA256.index(pin)
        probe = pack["episodes"][0]
        if e.digest(canonical_json(probe["oracle"])) != ORACLE_SHA256[index]:
            raise e.EvaluationError("evidence control oracle pin mismatch")
        developer.validate_probe(pack, probe)
        events = pack["events"]
        if len(events) not in (2, 4) or any(
                (human["role"], assistant["role"]) != ("human", "assistant")
                or human["projectID"] != assistant["projectID"]
                or human["conversationKey"] != assistant["conversationKey"]
                for human, assistant in zip(events[::2], events[1::2])):
            raise e.EvaluationError("evidence control exchange inventory mismatch")
        if {event["id"] for event in events[1::2]} != set(probe["oracle"]["required_source_ids"]):
            raise e.EvaluationError("evidence control exchange source mismatch")
        return index
    except (KeyError, TypeError, ValueError, IndexError):
        raise e.EvaluationError("evidence control pack invalid") from None


def runner_input(pack, configuration):
    index = validate_pack(pack)
    configuration = validate_configuration(configuration)
    json_object = "response_format" in configuration
    value = projection(pack, json_object=json_object)
    pins = JSON_OBJECT_PROJECTION_SHA256 if json_object else PROJECTION_SHA256
    if e.digest(canonical_json(value)) != pins[index]:
        raise e.EvaluationError("evidence control projection pin mismatch")
    return {**value, "configuration": configuration}


def prepare(source: Path):
    histories = cases.prepare(source)
    # Original projection/oracle pins are checked before selecting any pack.
    for history in histories:
        cases.runner_input(history, developer.CONFIGURATION)
    packs = []
    for history in histories:
        for probe in history["episodes"]:
            if not probe["answerable"]:
                continue
            required = set(probe["oracle"]["required_source_ids"])
            indices = [index for index, event in enumerate(history["events"]) if event["id"] in required]
            if len(indices) != len(required) or any(index == 0 for index in indices):
                raise e.EvaluationError("evidence control original exchange unavailable")
            pack = {"id": probe["id"] + "-evidence-control", "original_history_id": history["id"],
                    "events": copy.deepcopy([history["events"][position] for index in indices
                                              for position in (index - 1, index)]),
                    "episodes": [copy.deepcopy(probe)], "original_source_positions":
                        [position for index in indices for position in (index - 1, index)]}
            validate_pack(pack)
            packs.append(pack)
    if len(packs) != 9 or tuple(e.digest(canonical_json(projection(pack))) for pack in packs) != PROJECTION_SHA256:
        raise e.EvaluationError("evidence control declared inventory mismatch")
    return packs


def metadata(pack):
    index = validate_pack(pack)
    events = pack["events"]
    return {"history_id": pack["id"], "original_history_id": pack["original_history_id"],
        "probe_id": pack["episodes"][0]["id"], "projection_sha256": PROJECTION_SHA256[index],
        "oracle_sha256": ORACLE_SHA256[index], "source_count": len(events),
        "source_bytes": sum(len(event["text"].encode()) for event in events),
        "sufficiency_rationale": "complete_original_unique_human_anchor_and_immediately_following_assistant_in_original_order",
        "scope": "curated_exact_reproduction_and_citation_feasibility",
        "sources": [{"event_id": event["id"], "role": event["role"], "status": event["status"],
                     "original_position": position, "byte_length": len(event["text"].encode()),
                     "sha256": e.digest(event["text"].encode())}
                    for event, position in zip(events, pack["original_source_positions"])],
        "exchanges": [{"anchor_event_id": human["id"], "following_assistant_event_id": assistant["id"]}
                      for human, assistant in zip(events[::2], events[1::2])]}
