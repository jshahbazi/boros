#!/usr/bin/env python3
"""Contract checks for the public-chat converter and native import command.

The checks deliberately report only fixed check names and aggregate metadata.
They never print fixture content or imported payloads.
"""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import argparse
import hashlib
import time


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "import_chat.py"


def load_module():
    spec = importlib.util.spec_from_file_location("boros_import_chat", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("import_chat.py is unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ChatImportContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.converter = load_module()

    def assertRejects(self, value, operation):
        with self.assertRaises((ValueError, TypeError, json.JSONDecodeError)):
            operation(value)

    def test_openai_normalization_preserves_roles_unicode_and_whitespace(self):
        root = {"title": "fixture", "messages": [
            {"role": "user", "content": "  lead\n\u00e9  "},
            {"role": "assistant", "content": "answer\n\t", "status": "partial"},
        ]}
        messages = self.converter.conversations(root, "openai")[0]
        normalized = self.converter.normalize(messages)
        self.assertEqual([m["role"] for m in normalized], ["user", "assistant"])
        self.assertTrue(normalized[0]["content"] == "  lead\n\u00e9  ", "unicode_whitespace_preserved")
        self.assertEqual(normalized[1]["status"], "partial")

    def test_role_aliases_and_default_status(self):
        messages = self.converter.normalize([
            {"role": "human", "content": "u"},
            {"role": "gpt", "content": "a"},
        ])
        self.assertEqual([(m["role"], m["status"]) for m in messages],
                         [("user", "complete"), ("assistant", "complete")])

    def test_rejects_system_tool_unknown_and_extra_fields(self):
        for role in ("system", "tool", "developer", "unknown"):
            self.assertRejects([{"role": role, "content": "x"}], self.converter.normalize)
        self.assertRejects([{"role": "user", "content": "x", "extra": 1}], self.converter.normalize)
        self.assertRejects([{"role": "user", "content": [{"type": "text", "text": "x"}]}], self.converter.normalize)
        self.assertRejects([{"role": "user", "content": "x", "tool_calls": []}], self.converter.normalize)

    def test_rejects_empty_malformed_status_and_oversize_content(self):
        self.assertRejects([], self.converter.normalize)
        self.assertRejects([{"role": "user", "content": "x", "status": "unknown"}], self.converter.normalize)
        self.assertRejects([{"role": "user", "content": "x"}, "bad"], self.converter.normalize)
        self.assertRejects([{"role": "user", "content": "x" * (4 * 1024 * 1024 + 1)}], self.converter.normalize)

    def test_duplicate_json_keys_are_rejected(self):
        with tempfile.TemporaryDirectory(prefix="boros-import-contract-") as directory:
            path = Path(directory) / "duplicate.json"
            path.write_text('{"messages": [], "messages": []}', encoding="utf-8")
            self.assertRejects(path, self.converter.load_input)

    def test_invalid_utf8_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="boros-import-contract-") as directory:
            path = Path(directory) / "invalid.json"
            path.write_bytes(b'{"messages": [\xff]}')
            self.assertRejects(path, self.converter.load_input)

    def test_beam_flattens_batches_and_sharegpt_preserves_order(self):
        beam = [{"batch_number": 1, "time_anchor": "t", "turns": [[
            {"role": "user", "id": "u", "content": "u"},
            {"role": "assistant", "id": "a", "content": "a"},
        ]]}]
        self.assertEqual([m["role"] for m in self.converter.normalize(self.converter.conversations(beam, "beam")[0])], ["user", "assistant"])
        sharegpt = [{"conversations": [{"from": "human", "value": "u"}, {"from": "gpt", "value": "a"}]}]
        self.assertTrue([m["content"] for m in self.converter.normalize(self.converter.conversations(sharegpt, "sharegpt")[0])] == ["u", "a"], "sharegpt_order_preserved")

    def test_devgpt_collects_prompt_answer_pairs(self):
        root = {"Sources": [{"ChatgptSharing": [{"URL": "https://example.test", "Status": "", "Conversations": [{"Prompt": "u", "Answer": "a", "ListOfCode": [], "ConvIndex": 0}]}]}]}
        messages = self.converter.normalize(self.converter.conversations(root, "devgpt")[0])
        self.assertEqual([m["role"] for m in messages], ["user", "assistant"])


class NativeImportContractTests(unittest.TestCase):
    """Run native checks only when the caller supplies a built binary."""

    def test_native_import_contract_when_binary_is_supplied(self):
        binary = os.environ.get("BOROS_IMPORT_BINARY")
        if not binary:
            self.skipTest("BOROS_IMPORT_BINARY not supplied")
        with tempfile.TemporaryDirectory(prefix="boros-import-native-") as directory:
            root = Path(directory).resolve()
            destination = root / "store"
            source = {
                "schema_version": 1,
                "title": "Imported test chat",
                "source": {"dataset": "public-fixture", "url": "https://example.test/chat", "sha256": "0" * 64, "selection": 0},
                "messages": [
                    {"role": "user", "content": "  first\n\u00e9 e\u0301 \U0001f9ea\u0000\t", "status": "complete"},
                    {"role": "assistant", "content": "reply\r\n\t", "status": "partial"},
                    {"role": "user", "content": "last", "status": "complete"},
                ],
            }
            source_path = root / "chat-import.json"
            source_path.write_text(json.dumps(source, ensure_ascii=False), encoding="utf-8")
            command = [binary, "--import-chat", str(source_path), "--destination", str(destination)]
            result = subprocess.run(command, capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0)
            report = json.loads(result.stdout)
            self.assertEqual(report["status"], "verified")
            self.assertEqual(report["messages"], 3)
            self.assertEqual(report["user_messages"], 2)
            self.assertEqual(report["assistant_messages"], 1)
            self.assertEqual(len(report["import_sha256"]), 64)
            self.assertNotIn("first", result.stdout + result.stderr)
            self.assertTrue(destination.is_dir())
            self.assertEqual(destination.stat().st_mode & 0o777, 0o700)
            manifest = destination / "import-manifest.json"
            self.assertEqual(manifest.stat().st_mode & 0o777, 0o600)
            self.assertTrue((destination / "chat-import.json").is_file())
            with sqlite3.connect(destination / "memory.sqlite3") as database:
                rows = database.execute("SELECT role, status, payload, digest FROM events ORDER BY sequence").fetchall()
                self.assertTrue([(r[0], r[1]) for r in rows] == [("human", "complete"), ("assistant", "partial"), ("human", "complete")], "sqlite_roles_status_order")
                self.assertTrue(all(bytes(row[2]) == message["content"].encode() for row, message in zip(rows, source["messages"])), "sqlite_exact_payloads")
                self.assertTrue(all(row[3] == hashlib.sha256(bytes(row[2])).hexdigest() for row in rows), "sqlite_payload_digests")
                self.assertEqual(database.execute("SELECT count(*) FROM invocations").fetchone()[0], 0)
                self.assertEqual(database.execute("SELECT count(*) FROM episodes").fetchone()[0], 0)
                self.assertGreaterEqual(database.execute("SELECT count(*) FROM event_fts").fetchone()[0], 3)
            second = subprocess.run(command, capture_output=True, text=True, check=False)
            self.assertNotEqual(second.returncode, 0)
            prefix = root / "prefix"
            result = subprocess.run([binary, "--import-chat", str(source_path), "--destination", str(prefix), "--through-message", "2"], capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(json.loads(result.stdout)["messages"], 2)
            with sqlite3.connect(prefix / "memory.sqlite3") as database:
                self.assertEqual(database.execute("SELECT count(*) FROM events").fetchone()[0], 2)
            self.assertTrue(len(json.loads((prefix / "chat-import.json").read_text(encoding="utf-8"))["messages"]) == 3, "prefix_retains_original_source")

            invalid_prefix = root / "invalid-prefix"
            bad = subprocess.run([binary, "--import-chat", str(source_path), "--destination", str(invalid_prefix), "--through-message", "0"], capture_output=True, text=True, check=False)
            self.assertNotEqual(bad.returncode, 0)
            existing = root / "existing"
            existing.mkdir(mode=0o700)
            marker = existing / "marker"
            marker.write_bytes(b"keep")
            bad = subprocess.run([binary, "--import-chat", str(source_path), "--destination", str(existing)], capture_output=True, text=True, check=False)
            self.assertNotEqual(bad.returncode, 0)
            self.assertEqual(marker.read_bytes(), b"keep")

    def test_native_rejects_strict_schema_and_path_failures(self):
        binary = os.environ.get("BOROS_IMPORT_BINARY")
        if not binary:
            self.skipTest("BOROS_IMPORT_BINARY not supplied")
        with tempfile.TemporaryDirectory(prefix="boros-import-invalid-") as directory:
            root = Path(directory).resolve()
            valid = {"schema_version": 1, "title": "fixture", "source": {"dataset": "x", "sha256": "0" * 64, "selection": 0}, "messages": [{"role": "user", "content": "u", "status": "complete"}]}

            def run(document, name="destination", extra=()):
                source = root / (name + ".json")
                source.write_text(document if isinstance(document, str) else json.dumps(document), encoding="utf-8")
                result = subprocess.run([binary, "--import-chat", str(source), "--destination", str(root / name), *extra], capture_output=True, text=True, check=False)
                self.assertFalse((root / name).exists(), "invalid_input_never_published")
                self.assertFalse(list(root.glob('.boros-import-*')), "invalid_input_no_staging")
                return result

            duplicate = '{"schema_version":1,"title":"x","source":{"dataset":"x","sha256":"' + "0" * 64 + '","selection":0},"messages":[],"messages":[]}'
            self.assertNotEqual(run(duplicate, "duplicate").returncode, 0)
            escaped_duplicate = json.dumps(valid)[:-1] + ', "\\u0073chema_version": 1}'
            self.assertNotEqual(run(escaped_duplicate, "escaped-duplicate").returncode, 0)
            unknown = dict(valid); unknown["messages"] = [{"role": "system", "content": "x", "status": "complete"}]
            self.assertNotEqual(run(unknown, "unknown").returncode, 0)
            malformed_later = dict(valid); malformed_later["messages"] = [{"role": "user", "content": "u", "status": "complete"}, {"role": "bogus", "content": "x", "status": "complete"}]
            self.assertNotEqual(run(malformed_later, "malformed-later", ["--through-message", "1"]).returncode, 0)
            oversized = dict(valid); oversized["messages"] = [{"role": "user", "content": "x" * (4 * 1024 * 1024 + 1), "status": "complete"}]
            self.assertNotEqual(run(oversized, "oversized").returncode, 0)
            unsupported = dict(valid); unsupported["unexpected"] = True
            self.assertNotEqual(run(unsupported, "unsupported").returncode, 0)
            mismatched_source = dict(valid); mismatched_source["original_json"] = "{\"messages\":[]}"
            self.assertNotEqual(run(mismatched_source, "mismatched-source").returncode, 0)
            missing_parent = root / "missing" / "store"
            source = root / "missing-source.json"; source.write_text(json.dumps(valid), encoding="utf-8")
            self.assertNotEqual(subprocess.run([binary, "--import-chat", str(source), "--destination", str(missing_parent)], capture_output=True, text=True).returncode, 0)
            symlink_parent = root / "link-parent"; symlink_parent.symlink_to(root)
            self.assertNotEqual(subprocess.run([binary, "--import-chat", str(source), "--destination", str(symlink_parent / "store")], capture_output=True, text=True).returncode, 0)

    def test_wrapper_selects_jsonl_preserves_original_and_opens_no_model(self):
        binary = os.environ.get("BOROS_IMPORT_BINARY")
        if not binary:
            self.skipTest("BOROS_IMPORT_BINARY not supplied")
        with tempfile.TemporaryDirectory(prefix="boros-import-wrapper-") as directory:
            root = Path(directory).resolve()
            records = [{"messages": [{"role": "user", "content": "other"}]},
                       {"messages": [{"role": "user", "content": "  e\u0301\n"},
                                     {"role": "assistant", "content": "\u00e9\r\n", "status": "cancelled"}]}]
            raw = ("\n".join(json.dumps(record, ensure_ascii=False) for record in records) + "\n").encode()
            source = root / "corpus.jsonl"; source.write_bytes(raw)
            command = [sys.executable, str(MODULE_PATH), "--input", str(source), "--select", "1",
                       "--destination", str(root / "store"), "--binary", binary]
            result = subprocess.run(command, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, "wrapper_native_success")
            report = json.loads(result.stdout)
            self.assertEqual(report["messages"], 2)
            destination = root / "store"
            self.assertTrue((destination / "chat-source.json").read_bytes() == raw, "original_file_exact")
            manifest = json.loads((destination / "import-manifest.json").read_bytes())
            self.assertEqual(manifest["source"]["selection"], 1)
            self.assertTrue(manifest["original_source_verified"])
            self.assertTrue(manifest["source"]["sha256"] == hashlib.sha256(raw).hexdigest(), "original_hash_verified")
            canonical = (destination / "chat-import.json").read_bytes()
            self.assertTrue(report["import_sha256"] == hashlib.sha256(canonical).hexdigest(), "canonical_hash_verified")
            with sqlite3.connect(destination / "memory.sqlite3") as database:
                rows = database.execute("SELECT payload FROM events ORDER BY sequence").fetchall()
                self.assertTrue([bytes(row[0]) for row in rows] == [m["content"].encode() for m in records[1]["messages"]], "selected_chat_exact")
                self.assertEqual(database.execute("SELECT count(*) FROM invocations").fetchone()[0], 0)
            listed = subprocess.run([sys.executable, str(MODULE_PATH), "--input", str(source), "--list"], capture_output=True, timeout=30)
            self.assertEqual(listed.returncode, 0)
            summaries = [json.loads(line) for line in listed.stdout.splitlines()]
            self.assertEqual([item["messages"] for item in summaries], [1, 2])
            self.assertTrue(all(set(item) == {"selection", "messages", "user_messages", "assistant_messages", "source_bytes", "maximum_message_bytes"} for item in summaries), "list_metadata_only")

    def test_sigkill_leaves_no_published_partial_store(self):
        binary = os.environ.get("BOROS_IMPORT_BINARY")
        if not binary:
            self.skipTest("BOROS_IMPORT_BINARY not supplied")
        with tempfile.TemporaryDirectory(prefix="boros-import-kill-") as directory:
            root = Path(directory).resolve()
            document = {"schema_version": 1, "title": "fixture", "source": {"dataset": "synthetic", "sha256": "0" * 64, "selection": 0},
                        "messages": [{"role": "user" if i % 2 == 0 else "assistant", "content": "x" * 4096, "status": "complete"} for i in range(4000)]}
            source = root / "source.json"; source.write_text(json.dumps(document))
            destination = root / "store"
            process = subprocess.Popen([binary, "--import-chat", str(source), "--destination", str(destination)],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 30
                staged = []
                while time.monotonic() < deadline and process.poll() is None:
                    staged = list(root.glob(".boros-import-*"))
                    if staged and (staged[0] / "memory.sqlite3-wal").exists():
                        break
                    time.sleep(0.005)
                self.assertTrue(bool(staged) and process.poll() is None, "reached_unpublished_staging")
                process.kill(); process.communicate(timeout=5)
                self.assertEqual(process.returncode, -9)
                self.assertFalse(destination.exists(), "no_partial_destination_after_kill")
                self.assertTrue(all(path.stat().st_mode & 0o777 == 0o700 for path in staged), "interrupted_staging_private")
            finally:
                if process.poll() is None:
                    process.kill(); process.communicate(timeout=5)


class SafeResult(unittest.TestResult):
    def __init__(self):
        super().__init__(); self.failed_names = []; self.error_names = []
    def addFailure(self, test, err):
        super().addFailure(test, err); self.failed_names.append(test.id().rsplit(".", 1)[-1])
    def addError(self, test, err):
        super().addError(test, err); self.error_names.append(test.id().rsplit(".", 1)[-1])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--binary")
    options, _ = parser.parse_known_args()
    if options.binary:
        os.environ["BOROS_IMPORT_BINARY"] = str(Path(options.binary).resolve())
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    result = SafeResult(); suite.run(result)
    print(json.dumps({"checks": result.testsRun, "failed": result.failed_names, "errors": result.error_names,
                      "skipped": len(result.skipped)}, sort_keys=True))
    raise SystemExit(0 if result.wasSuccessful() else 1)
