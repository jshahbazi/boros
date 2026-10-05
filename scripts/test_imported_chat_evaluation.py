#!/usr/bin/env python3
"""Content-free contract checks for evaluate_imported_chat.py."""
from __future__ import annotations

import argparse
import contextlib
import importlib.util
import io
import json
import os
import tempfile
import sqlite3
from pathlib import Path
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / "scripts" / "evaluate_imported_chat.py"


def load_target():
    spec = importlib.util.spec_from_file_location("boros_imported_eval", TARGET)
    if spec is None or spec.loader is None:
        raise RuntimeError("evaluation script unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class EvaluationContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.e = load_target()
        cls.messages = [
            {"id": "import-a", "role": "human", "status": "complete", "text": "Alpha Unicode é source phrase.", "sha256": cls.e.digest("Alpha Unicode é source phrase.".encode())},
            {"id": "import-b", "role": "assistant", "status": "partial", "text": "Beta implementation detail.", "sha256": cls.e.digest(b"Beta implementation detail.")},
            {"id": "import-c", "role": "human", "status": "complete", "text": "Gamma later source phrase.", "sha256": cls.e.digest(b"Gamma later source phrase.")},
        ]

    def assertRejects(self, action):
        with self.assertRaises((self.e.EvaluationError, UnicodeDecodeError)):
            action()

    def test_strict_json_rejects_duplicate_nonfinite_and_invalid_utf8(self):
        self.assertRejects(lambda: self.e.strict_json(b'{"a":1,"a":2}'))
        self.assertRejects(lambda: self.e.strict_json(b'{"a":NaN}'))
        self.assertRejects(lambda: self.e.strict_json(b"\xff"))

    def test_automatic_probes_are_deterministic_and_hash_bound(self):
        first = self.e.automatic_probes(self.messages, 2)
        second = self.e.automatic_probes(self.messages, 2)
        self.assertTrue(self.e.canonical(first) == self.e.canonical(second), "automatic_probes_deterministic")
        self.assertTrue(len(first) == 3 and first[-1]["kind"] == "absent", "automatic_absence_probe")
        for probe in first:
            for gold in probe["gold"]:
                source = self.messages[gold["message"]]["text"].encode()
                self.assertTrue(self.e.digest(source[gold["offset"]:gold["offset"] + gold["bytes"]]) == gold["sha256"], "automatic_gold_digest")

    def test_validate_probes_rejects_wrong_hash_role_and_extra_fields(self):
        probes = [{key: value for key, value in probe.items() if key in ("prompt", "query", "literal", "gold")}
                  for probe in self.e.automatic_probes(self.messages, 1)]
        document = {"schema_version": 1, "import_sha256": "a" * 64, "probes": probes}
        validated = self.e.validate_probes(document, self.messages, "a" * 64)
        self.assertTrue(len(validated) == 2, "validated_probe_count")
        wrong = json.loads(json.dumps(document)); wrong["probes"][0]["gold"][0]["sha256"] = "b" * 64
        self.assertRejects(lambda: self.e.validate_probes(wrong, self.messages, "a" * 64))
        extra = json.loads(json.dumps(document)); extra["probes"][0]["unexpected"] = 1
        self.assertRejects(lambda: self.e.validate_probes(extra, self.messages, "a" * 64))

    def test_summary_keeps_budget_failures_in_denominator(self):
        protocols = {}
        for name in self.e.PROTOCOLS:
            protocols[name] = {"status": "error", "allRequiredSpansPresent": False,
                               "coverageLimits": ["memory_operations"], "sourceCount": 0,
                               "fullEpisodeMilliseconds": 2}
        report = {"probes": [{"kind": "answerable", "region": "early", "protocols": protocols},
                              {"kind": "absent", "region": "absent", "protocols": protocols}]}
        summary = self.e.summarize(report)
        self.assertTrue(summary["lexical_context"]["answerableProbes"] == 1, "summary_answerable_denominator")
        self.assertTrue(summary["lexical_context"]["failures"] == 2, "summary_failure_denominator")
        self.assertTrue(summary["lexical_context"]["coverageLimited"] == 2, "summary_coverage_denominator")

    def test_probe_types_utf8_boundaries_and_import_binding(self):
        text = self.messages[0]["text"].encode()
        valid = {"schema_version": 1, "import_sha256": "a" * 64, "probes": [{"prompt": "Find earlier evidence", "gold": [
            {"message": 0, "offset": 0, "bytes": len(text), "sha256": self.e.digest(text)}]}]}
        for key in ("message", "offset", "bytes"):
            bad = json.loads(json.dumps(valid)); bad["probes"][0]["gold"][0][key] = True
            self.assertRejects(lambda: self.e.validate_probes(bad, self.messages, "a" * 64))
        bad = json.loads(json.dumps(valid)); bad["schema_version"] = True
        self.assertRejects(lambda: self.e.validate_probes(bad, self.messages, "a" * 64))

        self.assertRejects(lambda: self.e.validate_probes(valid, self.messages, "b" * 64))
        offset = text.index("é".encode()) + 1
        bad = json.loads(json.dumps(valid)); gold = bad["probes"][0]["gold"][0]
        gold.update(offset=offset, bytes=1, sha256=self.e.digest(text[offset:offset + 1]))
        self.assertRejects(lambda: self.e.validate_probes(bad, self.messages, "a" * 64))

    def test_existing_report_is_preserved_before_source_access(self):
        with tempfile.TemporaryDirectory(prefix="boros-report-preservation-") as temporary:
            output = Path(temporary) / "report.json"
            sentinel = b'{"preserved":true}\n'
            output.write_bytes(sentinel)
            with self.assertRaises(self.e.EvaluationError): self.e.run(SimpleNamespace(output=output))
            self.assertTrue(output.read_bytes() == sentinel, "report_not_overwritten")


class NativeContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.e = load_target()
        cls.temp = tempfile.TemporaryDirectory(prefix="boros-import-eval-contract-")
        cls.scratch = Path(cls.temp.name).resolve()
        cls.binary, _ = cls.e.compile_harness(cls.scratch)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_warm_restart_and_budget_reports_are_content_free(self):
        source = [
            {"id": "import-a", "role": "human", "status": "complete", "text": "Alpha offline source."},
            {"id": "import-b", "role": "assistant", "status": "partial", "text": "Beta assistant source."},
            {"id": "import-c", "role": "human", "status": "complete", "text": "Gamma historical source."},
        ]
        for row in source:
            row["sha256"] = self.e.digest(row["text"].encode())
        probes = [{"prompt": "Find Alpha", "query": "Alpha", "literal": "Alpha", "region": "early", "kind": "answerable",
                   "gold": [{"message": 0, "offset": 0, "bytes": 5, "sha256": self.e.digest(b"Alpha")}]},
                  {"prompt": "Find absent marker", "query": "borosabsent", "literal": "borosabsent", "region": "absent", "kind": "absent", "gold": []}]
        fixture = {"version": 1, "messages": source, "probes": probes, "semanticChunks": 0, "indexSeconds": 1, "memoryOperationCap": 24}
        input_path = self.scratch / "fixture.json"; input_path.write_bytes(self.e.canonical(fixture))
        runtime = self.scratch / "runtime"; warm_path = self.scratch / "warm.json"; restart_path = self.scratch / "restart.json"
        warm = self.e.execute(self.binary, "warm", input_path, runtime, warm_path)
        restart = self.e.execute(self.binary, "restart", input_path, runtime, restart_path)
        with sqlite3.connect(runtime / "memory.sqlite3") as database:
            rows = database.execute("SELECT role,status,payload FROM events ORDER BY sequence").fetchall()
            self.assertTrue(len(rows) == 3, "native_sqlite_event_count")
            self.assertTrue([(row[0], row[1]) for row in rows] == [("human", "complete"), ("assistant", "partial"), ("human", "complete")], "native_sqlite_roles_status")
            self.assertTrue(bytes(rows[0][2]) == b"Alpha offline source.", "native_sqlite_payload")
            self.assertTrue(database.execute("SELECT count(*) FROM invocations").fetchone()[0] == 0, "native_sqlite_no_invocations")
            origins = database.execute("SELECT origin_json FROM episodes").fetchall()
            self.assertTrue(len(origins) == 12 and all(json.loads(row[0])["kind"] == "localRead" for row in origins), "native_sqlite_local_read_episodes")
        for report in (warm, restart):
            encoded = json.dumps(report, ensure_ascii=False, sort_keys=True)
            self.assertTrue(all(text not in encoded for text in ("Alpha offline source", "Beta assistant source", "Find Alpha")), "native_report_content_free")
            self.assertTrue(report["sourcesVerifiedBeforeAndAfter"] and report["questionsCaptured"] == 0 and report["answeringInvocations"] == 0, "native_provenance_and_capture_counts")
            self.assertTrue(report["messageCount"] == 3, "native_message_count")
        self.assertTrue(warm["semanticIndex"]["status"] == "disabled", "semantic_disabled_without_model")
        self.assertTrue(restart["mode"] == "restart", "native_restart_profile")
        fixture["memoryOperationCap"] = 0
        limited_input = self.scratch / "limited.json"; limited_input.write_bytes(self.e.canonical(fixture))
        limited_runtime = self.scratch / "limited-runtime"; limited_output = self.scratch / "limited.json.report"
        limited = self.e.execute(self.binary, "warm", limited_input, limited_runtime, limited_output)
        rows = [probe["protocols"]["lexical_context"] for probe in limited["probes"]]
        self.assertTrue(all(row["status"] == "error" for row in rows), "budget_failures_retained")
        self.assertTrue(all(row["status"] == "error" for row in [probe["protocols"]["raw_pages"] for probe in limited["probes"]]), "raw_budget_failures_retained")
        for probe in limited["probes"]:
            for name in ("recent_only", "lexical_context", "raw_pages"):
                receipt = probe["protocols"][name]["episodeReceipt"]
                self.assertTrue(receipt["state"] == "budgetExceeded" and receipt["charged"]["memoryOperations"] == 0, "zero_budget_receipt")
        for probe in warm["probes"]:
            for name in ("recent_only", "lexical_context", "raw_pages"):
                receipt = probe["protocols"][name]["episodeReceipt"]
                self.assertTrue(receipt["charged"]["httpAttempts"] == 0 and receipt["charged"]["modelCalls"] == 0, "no_provider_work")
                self.assertTrue(all(receipt["charged"][key] + receipt["held"][key] <= cap for key, cap in receipt["limits"]["resources"].items()), "bounded_receipt")

    def test_prompt_echo_and_same_text_in_wrong_source_do_not_score(self):
        texts = ["Originalmarker confidential synthetic value.", "ordinary filler " * 2500,
                 "Originalmarker confidential synthetic value."]
        source = [{"id": f"import-provenance-{i}", "role": "human" if i != 1 else "assistant", "status": "complete",
                   "text": text, "sha256": self.e.digest(text.encode())} for i, text in enumerate(texts)]
        gold = {"message": 0, "offset": 0, "bytes": len(texts[0].encode()), "sha256": source[0]["sha256"]}
        fixture = {"version": 1, "messages": source, "probes": [{"prompt": texts[0], "query": "borosneverfoundmarker",
                   "literal": None, "region": "early", "kind": "answerable", "gold": [gold]}],
                   "semanticChunks": 0, "indexSeconds": 1, "memoryOperationCap": 24}
        input_path = self.scratch / "provenance.json"
        self.e.private_write(input_path, self.e.canonical(fixture))
        report = self.e.execute(self.binary, "warm", input_path, self.scratch / "provenance-store", self.scratch / "provenance-report.json")
        self.assertTrue(report["probes"][0]["protocols"]["recent_only"]["allRequiredSpansPresent"] is False, "wrong_source_does_not_score")
        self.assertTrue(report["probes"][0]["protocols"]["raw_pages"]["allRequiredSpansPresent"] is False, "prompt_echo_does_not_score")

    def test_read_only_snapshot_verifies_import_and_rejects_corruption(self):
        texts = ["Snapshot exact café\r\n\t\x00 value.", "Preserved partial source."]
        declaration = {"dataset": "synthetic", "sha256": "a" * 64, "selection": 0, "url": None}
        document = {"schema_version": 1, "title": "Synthetic", "source": declaration,
                    "messages": [{"role": "user" if i == 0 else "assistant", "content": text,
                                  "status": "complete" if i == 0 else "partial"} for i, text in enumerate(texts)]}
        canonical_bytes = self.e.canonical(document)
        import_hash = self.e.digest(canonical_bytes)
        source = [{"id": f"import-{import_hash}-{i}", "role": "human" if i == 0 else "assistant",
                   "text": text, "status": "complete" if i == 0 else "partial", "sha256": self.e.digest(text.encode())} for i, text in enumerate(texts)]
        fixture = {"version": 1, "messages": source, "probes": self.e.automatic_probes(source, 1),
                   "semanticChunks": 0, "indexSeconds": 1, "memoryOperationCap": 24}
        input_path = self.scratch / "snapshot-fixture.json"
        self.e.private_write(input_path, self.e.canonical(fixture))
        runtime = self.scratch / "snapshot-source"
        self.e.execute(self.binary, "warm", input_path, runtime, self.scratch / "snapshot-native.json")
        conversation = json.loads((runtime / "diagnostic-conversation.json").read_bytes())
        manifest = {"version": 1, "import_sha256": import_hash, "source": declaration, "input_messages": 2,
                    "original_source_verified": False, "conversation_id": conversation, "project_id": "default",
                    "imported_messages": [{"ordinal": i, "event_id": row["id"], "turn_id": f"diagnostic-turn-{i}",
                        "role": "user" if i == 0 else "assistant", "status": row["status"],
                        "sha256": row["sha256"], "source_bytes": len(row["text"].encode())} for i, row in enumerate(source)]}
        self.e.private_write(runtime / "import-manifest.json", self.e.canonical(manifest))
        self.e.private_write(runtime / "chat-import.json", canonical_bytes)
        with sqlite3.connect(runtime / "memory.sqlite3") as database:
            database.execute("INSERT INTO events(id,conversation_id,project_id,role,status,turn_id,created_at,digest,byte_count,payload) VALUES (?,?,?,?,?,?,?,?,?,?)",
                ("later-test-turn", conversation, "default", "human", "complete", "later", "2026-10-05", self.e.digest(b"later"), 5, b"later"))
        original_hash = self.e.digest((runtime / "memory.sqlite3").read_bytes())
        destination = self.scratch / "snapshot-copy"; destination.mkdir(mode=0o700)
        loaded, provenance = self.e.load_import(runtime, destination)
        self.assertTrue([row["text"] for row in loaded] == texts and provenance["messageCount"] == 2, "snapshot_only_verified_messages")
        self.assertTrue(self.e.digest((runtime / "memory.sqlite3").read_bytes()) == original_hash, "source_database_unchanged")
        self.assertTrue(os.stat(destination / "source-snapshot.sqlite3").st_mode & 0o777 == 0o600, "snapshot_private")
        output = self.scratch / "wrapper-report.json"
        args = SimpleNamespace(store=runtime, output=output, probe_file=None, probes=2,
                               profile="both", semantic_chunks=0, index_seconds=1, memory_operations=24)
        with patch.object(self.e, "compile_harness", return_value=(self.binary, {"sourceSHA256": {}})), contextlib.redirect_stdout(io.StringIO()):
            wrapper = self.e.run(args)
        self.assertTrue(wrapper["source"]["messageCount"] == 2 and wrapper["providerRequests"] == 0, "wrapper_uses_verified_import")
        self.assertTrue(os.stat(output).st_mode & 0o777 == 0o600, "report_private")
        encoded = output.read_text()
        self.assertTrue(all(text not in encoded for text in texts), "wrapper_report_content_free")
        self.assertTrue(self.e.digest((runtime / "memory.sqlite3").read_bytes()) == original_hash, "wrapper_source_unchanged")
        # Changing canonical bytes must fail before a source snapshot is opened.
        canonical_path = runtime / "chat-import.json"
        canonical_path.write_bytes(canonical_bytes + b" ")
        bad_canonical = self.scratch / "snapshot-bad-canonical"; bad_canonical.mkdir(mode=0o700)
        with self.assertRaises(self.e.EvaluationError): self.e.load_import(runtime, bad_canonical)
        self.assertTrue(not (bad_canonical / "source-snapshot.sqlite3").exists(), "canonical_rejected_before_source_access")
        canonical_path.write_bytes(canonical_bytes)
        with sqlite3.connect(runtime / "memory.sqlite3") as database:
            database.execute("UPDATE events SET payload=? WHERE id=?", (b"X" * len(texts[0].encode()), source[0]["id"]))
        bad = self.scratch / "snapshot-bad"; bad.mkdir(mode=0o700)
        with self.assertRaises(self.e.EvaluationError): self.e.load_import(runtime, bad)


class SafeResult(unittest.TestResult):
    def __init__(self):
        super().__init__(); self.failed_names = []; self.error_names = []
    def addFailure(self, test, err):
        super().addFailure(test, err); self.failed_names.append(test.id().rsplit(".", 1)[-1])
    def addError(self, test, err):
        super().addError(test, err); self.error_names.append(test.id().rsplit(".", 1)[-1])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.parse_known_args()
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    result = SafeResult(); suite.run(result)
    print(json.dumps({"checks": result.testsRun, "failed": result.failed_names,
                      "errors": result.error_names, "skipped": len(result.skipped)}, sort_keys=True))
    raise SystemExit(0 if result.wasSuccessful() else 1)
