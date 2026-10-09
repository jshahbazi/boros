#!/usr/bin/env python3
"""Offline equivalence of `--answer-evaluation --retrieval-arm ordinary_send` with the retrieval harness.

Both binaries run on the same public synthetic development history and questions against the
retrieval harness's loopback endpoint (`retrieval_harness.OfflineEndpoint`) with a synthetic
one-token-per-byte tokenizer injected. The endpoint answers model metadata, token counts and the
1-token admission calibration, and refuses every other completion request, so no answer is
generated: the harness stops at the answering boundary, and the evaluation command's answer
request is refused. No model files, tokenizer files, datasets, private histories or remote
endpoints are used.

Checks:
- the ordinary Send arm builds no semantic index, passes none, and records the policy;
- its delivered recent sources, historical excerpts and traced candidates equal the harness
  `ordinary_send` and `lexical` arms for every question;
- without the flag, the command's recent-only and hybrid attempts keep their behavior: the
  hybrid attempt still builds and passes the index, the reports carry no arm fields, and both
  arms deliver what the harness `recent_only` and `hybrid` arms deliver.

The harness binary is compiled into the same cache as `retrieval_floor.py`
(`.build/retrieval-harness`), so check.py compiles it at most once per source state.
Output is counts, booleans and test names only.
"""
from __future__ import annotations

import argparse
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import evaluate_answers as e  # noqa: E402
import retrieval_harness as harness  # noqa: E402

BINARY = None
HARNESS_CACHE = ROOT / ".build/retrieval-harness"
HARNESS_ARMS = ["recent_only", "lexical", "hybrid", "ordinary_send"]


class ByteTokenizer:
    """Synthetic vocabulary: one token per UTF-8 byte."""

    class Encoding:
        def __init__(self, ids):
            self.ids = ids

    def encode(self, text, add_special_tokens=False):
        return self.Encoding(list(text.encode()))


def run_command(input_path: Path, output: Path, *extra):
    process = subprocess.run([str(BINARY), "--answer-evaluation", str(input_path), "--output-directory", str(output),
                              *extra], capture_output=True, timeout=600,
                             env={**os.environ, "BOROS_DATA_DIR": str(output.parent / ("app-runtime-" + output.name))})
    report = json.loads((output / "report.json").read_text()) if (output / "report.json").exists() else None
    return process.returncode, report


def command_delivery(item):
    """Delivered recent IDs, historical excerpts in delivery order and traced candidates."""
    audit = (item.get("preparation") or {}).get("context_audit") or {}
    historical = [(source["event_id"], source["excerpt_offset"], source["excerpt_bytes"])
                  for source in audit.get("historical_sources") or []]
    trace = (audit.get("retrieval") or {}).get("selection_trace") or {}
    candidates = [(c.get("event_id"), c.get("rank"), c.get("offset"), c.get("byte_length"))
                  for c in trace.get("candidates") or []]
    return {"recent": list(item.get("delivered_recent_source_ids") or []), "historical": historical,
            "candidates": candidates}


def harness_delivery(attempt):
    return {"recent": list(attempt.get("recent_source_ids") or []),
            "historical": [(source["event_id"], source["offset"], source["bytes"]) for source in attempt.get("evidence") or []],
            "candidates": [(c.get("event_id"), c.get("rank"), c.get("offset"), c.get("bytes"))
                           for c in attempt.get("candidates") or []]}


class OrdinarySendArm(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="boros-ordinary-send-arm-")
        cls.directory = Path(cls.temporary.name).resolve()
        cls.endpoint = harness.OfflineEndpoint(Path("unused"), 0, tokenizer=ByteTokenizer()).start()
        fixtures = e.generate("development", history_count=1)
        cls.document = e.runner_input(fixtures, dict(e.DEFAULTS, endpoint=cls.endpoint.url))
        cls.input_path = cls.directory / "input.json"
        e.private_write(cls.input_path, e.canonical_json(cls.document))
        cls.flag_code, cls.flagged = run_command(cls.input_path, cls.directory / "flagged",
                                                 "--retrieval-arm", "ordinary_send")
        cls.default_code, cls.default = run_command(cls.input_path, cls.directory / "default")
        HARNESS_CACHE.mkdir(mode=0o700, parents=True, exist_ok=True)
        binary, _ = harness.compile_harness(HARNESS_CACHE)
        scratch = cls.directory / "harness"
        scratch.mkdir(mode=0o700)
        cache = scratch / "store-cache"
        cls.harness = {}
        for attempt in cls.document["attempts"]:
            if attempt["strategy"] != "hybrid":
                continue
            question = {key: attempt[key] for key in ("project_id", "conversation_key", "prompt")}
            question["question_time"] = None
            result = harness.run_process(binary, "select", {
                "version": 1, "cache_directory": str(cache), "events": cls.document["events"], "question": question,
                "arms": HARNESS_ARMS, "declared_source_ids": None, "configuration": cls.document["configuration"]},
                scratch, "select")
            cls.harness[attempt["probe_id"]] = {item["arm"]: item for item in result.get("attempts", [])}
        cls.counters = dict(cls.endpoint.counters)

    @classmethod
    def tearDownClass(cls):
        cls.endpoint.stop()
        cls.temporary.cleanup()

    def items(self, report, strategy):
        return {item["probe_id"]: item for item in report["attempts"] if item["strategy"] == strategy}

    def test_runs_terminalized_and_no_answer_was_generated(self):
        self.assertEqual((self.flag_code, self.default_code), (0, 0))
        attempts = len(self.document["attempts"])
        for report in (self.flagged, self.default):
            self.assertEqual(report["fatal_failure"], None)
            self.assertEqual(report["completed_attempts"], attempts)
            self.assertTrue(all(item["answer_bytes"] == 0 for item in report["attempts"]))
        started = sum(1 for report in (self.flagged, self.default) for item in report["attempts"] if item["invocation_started"])
        # Every answer request reached the endpoint and was refused; calibration is the 1-token count.
        self.assertEqual(self.counters["refused_generation"], started)
        self.assertGreater(self.counters["calibration"], 0)
        self.assertEqual(len(self.harness), attempts // 2)
        self.assertTrue(all(set(arms) == set(HARNESS_ARMS) for arms in self.harness.values()))
        self.assertTrue(all(not item.get("runner_started") and item.get("preparation_completed")
                            for arms in self.harness.values() for item in arms.values()))

    def test_ordinary_send_arm_builds_and_passes_no_index_and_records_policy(self):
        self.assertEqual(self.flagged["retrieval_arm_override"], "ordinary_send")
        self.assertEqual(self.flagged["semantic_retrieval_policy"], "disabled_by_policy")
        self.assertEqual(self.flagged["retrieval_arm_applies_to"], "declared_hybrid_attempts")
        for item in self.items(self.flagged, "hybrid").values():
            self.assertEqual((item["retrieval_arm"], item["semantic_retrieval_policy"]), ("ordinary_send", "disabled_by_policy"))
            background = item["background"]
            self.assertEqual(background["schedule"], "skipped_ordinary_send_semantic_disabled_by_policy")
            self.assertIs(background["performed"], False)
            self.assertIs(background["host_index_opened"], False)
            self.assertEqual(background["budget_before"], background["budget_after"])
            self.assertIs(item["preparation_received_semantic_index"], False)
            self.assertIs(item["semantic_sidecar_present"], False)
            self.assertIs(item["retrieval_arm_receipt_validated"], True)
            retrieval = item["preparation"]["context_audit"]["retrieval"]
            self.assertEqual((retrieval["mode"], retrieval["semantic_retrieval"], retrieval["semantic_available"]),
                             ("lexical", "disabled_by_policy", False))
            self.assertNotIn("manifest_id", retrieval)
        for item in self.items(self.flagged, "recent_only").values():
            self.assertEqual((item["retrieval_arm"], item["semantic_retrieval_policy"]), ("recent_only", "enabled"))
            self.assertIs(item["background"]["performed"], False)
            self.assertIs(item["semantic_sidecar_present"], False)

    def test_ordinary_send_delivery_equals_harness_ordinary_send_and_lexical(self):
        delivered_history = 0
        for probe, item in self.items(self.flagged, "hybrid").items():
            command = command_delivery(item)
            ordinary = harness_delivery(self.harness[probe]["ordinary_send"])
            lexical = harness_delivery(self.harness[probe]["lexical"])
            self.assertEqual(ordinary, lexical, probe)
            self.assertEqual(command, ordinary, probe)
            self.assertEqual(self.harness[probe]["ordinary_send"]["retrieval"].get("semantic_retrieval"), "disabled_by_policy")
            self.assertIs(self.harness[probe]["ordinary_send"]["preparation_received_semantic_index"], False)
            delivered_history += bool(command["historical"])
        # Not vacuous: lexical selection delivered historical evidence for most questions.
        self.assertGreaterEqual(delivered_history, len(self.harness) // 2)

    def test_default_run_keeps_existing_arms(self):
        self.assertFalse({"retrieval_arm_override", "semantic_retrieval_policy", "retrieval_arm_applies_to"} & set(self.default))
        for item in self.default["attempts"]:
            self.assertFalse({"retrieval_arm", "semantic_retrieval_policy", "preparation_received_semantic_index",
                              "semantic_sidecar_present", "retrieval_arm_receipt_validated"} & set(item))
        for probe, item in self.items(self.default, "hybrid").items():
            self.assertEqual(item["background"]["schedule"], "per_hybrid_attempt_before_acceptance")
            self.assertIs(item["background"]["performed"], True)
            retrieval = item["preparation"]["context_audit"]["retrieval"]
            self.assertEqual(retrieval["mode"], "hybrid")
            self.assertNotIn("semantic_retrieval", retrieval)
            self.assertEqual(command_delivery(item), harness_delivery(self.harness[probe]["hybrid"]), probe)
        flagged_recent = self.items(self.flagged, "recent_only")
        for probe, item in self.items(self.default, "recent_only").items():
            self.assertIs(item["background"]["performed"], False)
            self.assertEqual(command_delivery(item), harness_delivery(self.harness[probe]["recent_only"]), probe)
            self.assertEqual(command_delivery(item), command_delivery(flagged_recent[probe]), probe)
            self.assertEqual(item["preparation"]["request_sha256"] is not None, True)

    def test_flag_refused_before_output_when_no_hybrid_attempt_is_selected(self):
        recent = [index for index, attempt in enumerate(self.document["attempts"]) if attempt["strategy"] == "recent_only"][0]
        output = self.directory / "refused"
        code, report = run_command(self.input_path, output, "--retrieval-arm", "ordinary_send", "--attempt", str(recent))
        self.assertEqual((code, report), (2, None))
        self.assertFalse(output.exists())
        for value in ("hybrid", "lexical", "ordinary-send"):
            output = self.directory / ("refused-" + value)
            code, report = run_command(self.input_path, output, "--retrieval-arm", value)
            self.assertEqual((code, report, output.exists()), (2, None, False))

    def test_reports_are_content_free(self):
        encoded = json.dumps(self.flagged) + json.dumps(self.default) + json.dumps(self.harness)
        self.assertFalse(any(event["text"] in encoded for event in self.document["events"] if len(event["text"]) > 24))
        self.assertFalse(any(attempt["prompt"] in encoded for attempt in self.document["attempts"]))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    arguments = parser.parse_args()
    BINARY = arguments.binary.resolve()
    result = unittest.TextTestRunner(stream=io.StringIO()).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(OrdinarySendArm))
    print(json.dumps({"checks": result.testsRun, "failed": [test.id().rsplit(".", 1)[-1] for test, _ in result.failures],
                      "errors": [test.id().rsplit(".", 1)[-1] for test, _ in result.errors],
                      "skipped": len(result.skipped)}))
    raise SystemExit(not result.wasSuccessful())
