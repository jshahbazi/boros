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
import copy
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

    def test_source_time_normalization_preserves_precision_and_zone(self):
        expected = [
            ("2024-02-29", "2024-02-29", "day", "unspecified"),
            ("2024-02-29T12:03", "2024-02-29T12:03", "minute", "unspecified"),
            ("2024-02-29T12:03:04Z", "2024-02-29T12:03:04", "second", "Z"),
            ("2024-02-29T12:03:04.000001+05:30", "2024-02-29T12:03:04.000001", "fractional_second", "+05:30"),
            ("2024/02/29 (Thu) 12:03", "2024-02-29T12:03", "minute", "unspecified"),
            ("2024/02/29 (Thu)", "2024-02-29", "day", "unspecified"),
        ]
        for literal, value, precision, zone in expected:
            self.assertTrue(self.converter.normalize_time(literal) == {
                "value": value, "precision": precision, "timezone": zone}, "source_calendar_evidence_preserved")

    def test_source_time_rejects_guessing_invalid_calendar_and_zone(self):
        for literal in (None, 1700000000, "1700000000", "2023-02-29", "2024-13-01", "0000-01-01",
                        "2024-01-01T24:00", "2024-01-01T00:60", "2024-01-01T00:00:60Z",
                        "2024-01-01T00:00-00:00", "2024-01-01T00:00+14:01", "2024-01-01T00:00+15:00",
                        "2024-01-01T00:00:00.1234567890Z", "2024/02/29 (Fri) 12:03", " 2024-01-01", "2024-01-01\n"):
            self.assertRejects(literal, self.converter.normalize_time)
        self.assertRejects([{"role": "user", "content": "x", "timestamp": None}], self.converter.normalize)

    def test_source_time_binding_uses_selected_original_locations(self):
        dated = {"role": "user", "content": "  e\u0301\n", "timestamp": "2024-02-29T12:03+05:30"}
        shapes = [([dated], 0, "/0/timestamp"),
                  ({"messages": [dated]}, 0, "/messages/0/timestamp"),
                  ([{"conversation": [{"role": "user", "content": "other"}]}, {"conversation": [dated]}], 1, "/1/conversation/0/timestamp")]
        for original, selection, pointer in shapes:
            raw = json.dumps(original, ensure_ascii=False).encode()
            parsed = self.converter._parse(raw)
            chat = self.converter.conversations(parsed, "openai")[selection]
            converted = self.converter.dated_messages(parsed, chat, raw)
            self.assertTrue(converted[0]["content"] == dated["content"], "dated_payload_unchanged")
            evidence = converted[0]["source_time"]
            self.assertTrue(evidence["locator"] == pointer, "original_pointer_exact")
            self.assertTrue(evidence["original_value"] == dated["timestamp"], "original_literal_exact")
            self.assertEqual(evidence["source_sha256"], hashlib.sha256(raw).hexdigest())
            self.assertNotIn("timestamp", converted[0])
        absent = {"messages": [{"role": "user", "content": "x"}]}
        self.assertNotIn("source_time", self.converter.dated_messages(absent, absent["messages"], json.dumps(absent).encode())[0])

    def test_source_time_jsonl_selected_pointer_and_no_anchor_inference(self):
        records = [{"messages": [{"role": "user", "content": "other"}]},
                   {"messages": [{"role": "assistant", "content": "x", "timestamp": "2024/02/29 (Thu) 12:03"}]}]
        raw = ("\n".join(json.dumps(record) for record in records) + "\n").encode()
        parsed = self.converter._parse(raw)
        converted = self.converter.dated_messages(parsed, self.converter.conversations(parsed)[1], raw)
        self.assertEqual(converted[0]["source_time"]["locator"], "/1/messages/0/timestamp")
        beam = [{"time_anchor": "2024-02-29", "turns": [[{"role": "user", "content": "x", "time_anchor": "2024-02-29"}]]}]
        self.assertNotIn("source_time", self.converter.dated_messages(beam, self.converter.conversations(beam, "beam")[0], json.dumps(beam).encode())[0])

    def test_source_time_all_messages_validated_before_prefix(self):
        self.assertRejects([{"role": "user", "content": "x", "timestamp": "2024-01-01"},
                            {"role": "assistant", "content": "y", "timestamp": "2024-02-30"}], self.converter.normalize)


class NativeImportContractTests(unittest.TestCase):
    """Run native checks only when the caller supplies a built binary."""

    def test_native_dated_source_roundtrip_and_strict_provenance(self):
        binary = os.environ.get("BOROS_IMPORT_BINARY")
        if not binary:
            self.skipTest("BOROS_IMPORT_BINARY not supplied")
        converter = load_module()
        with tempfile.TemporaryDirectory(prefix="boros-import-dated-") as directory:
            root = Path(directory).resolve()
            original = {"messages": [{"role": "user", "content": "  e\u0301\n", "timestamp": "2024-02-29T12:03:04.000001+05:30"},
                                     {"role": "assistant", "content": "reply\r\n"},
                                     {"role": "user", "content": "last", "timestamp": "2024/03/01 (Fri) 01:02"}],
                        "meta/~date": "2024-02-29"}
            raw = json.dumps(original, ensure_ascii=False).encode()
            parsed = converter._parse(raw)
            document = {"schema_version": 2, "title": "fixture", "source": {
                "dataset": "synthetic", "sha256": hashlib.sha256(raw).hexdigest(), "selection": 0},
                "messages": converter.dated_messages(parsed, converter.conversations(parsed)[0], raw),
                "original_json": raw.decode()}

            def run(value, name, prefix=None):
                path = root / (name + ".json")
                path.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
                command = [binary, "--import-chat", str(path), "--destination", str(root / name)]
                if prefix is not None:
                    command.extend(["--through-message", str(prefix)])
                result = subprocess.run(command, capture_output=True, timeout=30)
                self.assertNotIn(original["messages"][0]["content"].encode(), result.stdout + result.stderr)
                return result

            result = run(document, "dated")
            self.assertEqual(result.returncode, 0, "dated_import_success")
            self.assertEqual(json.loads(result.stdout)["messages"], 3)
            with sqlite3.connect(root / "dated" / "memory.sqlite3") as database:
                rows = database.execute("SELECT payload, source_time_json FROM events ORDER BY sequence").fetchall()
                self.assertTrue([bytes(row[0]) for row in rows] == [m["content"].encode() for m in original["messages"]], "dated_payload_exact")
                self.assertTrue([json.loads(bytes(row[1])) if row[1] else None for row in rows] == [m.get("source_time") for m in document["messages"]], "reopened_source_time_exact")
                self.assertEqual(database.execute("SELECT count(*) FROM invocations").fetchone()[0], 0)
            manifest = json.loads((root / "dated" / "import-manifest.json").read_bytes())
            self.assertEqual(manifest["version"], 2)
            self.assertTrue([m.get("source_time") for m in manifest["imported_messages"]] == [m.get("source_time") for m in document["messages"]], "manifest_dates_exact")
            self.assertTrue((root / "dated" / "chat-source.json").read_bytes() == raw, "dated_artifact_bytes_exact")
            self.assertEqual(run(document, "dated-prefix", 1).returncode, 0)
            with sqlite3.connect(root / "dated-prefix" / "memory.sqlite3") as database:
                self.assertEqual(database.execute("SELECT count(*) FROM events").fetchone()[0], 1)

            mutations = []
            for field, value in (("locator", "/messages/00/timestamp"), ("locator", "/messages/8/timestamp"),
                                 ("locator", "/messages/~2/timestamp"), ("source_sha256", "0" * 64),
                                 ("original_value", "2024-02-29T12:03:05.000001+05:30"),
                                 ("value", "2024-02-28T12:03:04.000001"), ("timezone", "Z"),
                                 ("precision", "second"), ("unexpected", "x")):
                bad = copy.deepcopy(document); bad["messages"][0]["source_time"][field] = value; mutations.append(bad)
            bad = copy.deepcopy(document); bad.pop("original_json"); mutations.append(bad)
            bad = copy.deepcopy(document); bad["messages"][0]["source_time"] = None; mutations.append(bad)
            bad = copy.deepcopy(document); bad["schema_version"] = 1; mutations.append(bad)
            bad = copy.deepcopy(document); bad["messages"][2]["source_time"]["timezone"] = "Z"; mutations.append(bad)
            for index, bad in enumerate(mutations):
                name = f"invalid-{index}"
                self.assertNotEqual(run(bad, name, 1).returncode, 0, "invalid_date_rejected_before_prefix")
                self.assertFalse((root / name).exists(), "invalid_dates_never_published")
            escaped = copy.deepcopy(document)
            escaped["messages"][0]["source_time"] = {**converter.normalize_time("2024-02-29"),
                "source_sha256": document["source"]["sha256"], "locator": "/meta~1~0date", "original_value": "2024-02-29"}
            self.assertEqual(run(escaped, "escaped-pointer").returncode, 0, "rfc6901_escaped_pointer_supported")
            for index, source_text in enumerate((
                '{"timestamp":"2024-02-29","timestamp":"2024-03-01"}',
                '{"\u00e9":"2024-02-29","e\u0301":"2024-03-01"}',
            )):
                bad = copy.deepcopy(escaped)
                digest = hashlib.sha256(source_text.encode()).hexdigest()
                bad["original_json"] = source_text; bad["source"]["sha256"] = digest
                bad["messages"] = [bad["messages"][0]]
                bad["messages"][0]["source_time"]["source_sha256"] = digest
                bad["messages"][0]["source_time"]["locator"] = "/timestamp" if index == 0 else "/\u00e9"
                self.assertNotEqual(run(bad, f"ambiguous-original-{index}").returncode, 0, "ambiguous_original_keys_rejected")

            # A JSON pointer is byte exact even when Swift considers two
            # Unicode spellings canonically equal.
            unicode_original = '{"\u00e9":"2024-02-29"}'
            unicode_date = copy.deepcopy(escaped)
            unicode_date["messages"] = [unicode_date["messages"][0]]
            unicode_date["original_json"] = unicode_original
            digest = hashlib.sha256(unicode_original.encode()).hexdigest()
            unicode_date["source"]["sha256"] = digest
            evidence = unicode_date["messages"][0]["source_time"]
            evidence["source_sha256"] = digest; evidence["locator"] = "/\u00e9"
            self.assertEqual(run(unicode_date, "unicode-pointer-exact").returncode, 0)
            evidence["locator"] = "/e\u0301"
            self.assertNotEqual(run(unicode_date, "unicode-pointer-folded").returncode, 0)

    def test_wrapper_dated_jsonl_is_native_verified(self):
        binary = os.environ.get("BOROS_IMPORT_BINARY")
        if not binary:
            self.skipTest("BOROS_IMPORT_BINARY not supplied")
        with tempfile.TemporaryDirectory(prefix="boros-import-dated-wrapper-") as directory:
            root = Path(directory).resolve()
            records = [{"messages": [{"role": "user", "content": "other"}]},
                       {"conversation": [{"role": "user", "content": "x", "timestamp": "2024/02/29 (Thu) 12:03"},
                                         {"role": "assistant", "content": "y"}]}]
            raw = ("\n".join(json.dumps(record) for record in records) + "\n").encode()
            source = root / "dated.jsonl"; source.write_bytes(raw)
            result = subprocess.run([sys.executable, str(MODULE_PATH), "--input", str(source), "--select", "1",
                "--destination", str(root / "store"), "--binary", binary], capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, "dated_jsonl_wrapper_success")
            canonical = json.loads((root / "store" / "chat-import.json").read_bytes())
            self.assertEqual(canonical["schema_version"], 2)
            self.assertEqual(canonical["messages"][0]["source_time"]["locator"], "/1/conversation/0/timestamp")
            self.assertTrue((root / "store" / "chat-source.json").read_bytes() == raw, "dated_jsonl_artifact_exact")
            with sqlite3.connect(root / "store" / "memory.sqlite3") as database:
                rows = database.execute("SELECT source_time_json FROM events ORDER BY sequence").fetchall()
                self.assertTrue(json.loads(bytes(rows[0][0])) == canonical["messages"][0]["source_time"], "dated_jsonl_reopened_exact")
                self.assertIsNone(rows[1][0])

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
