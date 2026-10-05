#!/usr/bin/env python3
"""Content-free synthetic contracts for the pinned developer diagnostic."""
from __future__ import annotations

import argparse
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import sys
import subprocess
import threading
import time
from http.server import ThreadingHTTPServer
import tempfile
import unittest
from unittest.mock import patch

import devgpt_answer_cases as cases
import evaluate_developer_answers as developer
import evaluate_answers as e
from evaluation_fixtures import canonical_json


@contextlib.contextmanager
def controlled_source():
    # Synthetic structure exercises the production selectors. Explicit test
    # pins cannot authorize these inputs in the separately compiled native CLI.
    root = {"Sources": [{"ChatgptSharing": [{"URL": f"https://example.invalid/public-sharing-{h}", "Status": 200,
        "Conversations": [{"Prompt": f"Synthetic developer question {h}-{p} asks about a component.\nFurther detail.",
                           "Answer": f"Synthetic response fact {h}-{p} names the component exactly.\nFurther synthetic explanation.",
                           "ListOfCode": [{"Content": "synthetic code sidecar excluded"}]} for p in range(5)]}]} for h in range(3)]}
    data = canonical_json(root)
    with contextlib.ExitStack() as stack:
        stack.enter_context(patch.object(cases, "SOURCE_BYTES", len(data)))
        stack.enter_context(patch.object(cases, "SOURCE_SHA256", e.digest(data)))
        stack.enter_context(patch.object(cases, "CASES", ((0, 0), (1, 0), (2, 0))))
        read = stack.enter_context(patch.object(cases, "read_file", return_value=data))
        histories = cases.prepare(Path("controlled-public-source"))
        stack.enter_context(patch.object(cases, "PROJECTION_SHA256", tuple(e.digest(canonical_json(cases.projection(h))) for h in histories)))
        stack.enter_context(patch.object(cases, "ORACLE_SHA256", tuple(e.digest(canonical_json([p["oracle"] for p in h["episodes"]])) for h in histories)))
        yield histories, data, read


def answer_for(probe):
    oracle = probe["oracle"]
    value = oracle["expected_answers"] if oracle["kind"] == "cross_message_quotes" else (
        oracle["expected_answers"][0] if oracle["answerable"] else "")
    return json.dumps({"answer": value, "citations": oracle["required_source_ids"], "abstain": not oracle["answerable"]})


def ranges_for(probe):
    return [{"event_id": span["eventID"], "offset": span["offset"], "byte_length": span["byteLength"],
             "sha256": span["sha256"]} for span in probe["goldSpans"]]


def controlled_report(document, directory, *, count=None, partial=False):
    directory.mkdir(mode=0o700)
    rows = []
    for ordinal, request in enumerate(document["attempts"][:count]):
        # Correctness never follows from operational completion alone.
        encoded = json.dumps({"answer": "synthetic incorrect result", "citations": [], "abstain": False}).encode()
        filename = f"answer-{ordinal:04d}.txt"
        e.private_write(directory / filename, encoded)
        rows.append({"ordinal": ordinal, **{key: request[key] for key in ("probe_id", "strategy", "replicate")},
                     "answer_file": filename, "terminalized": True, "answer_bytes": len(encoded),
                     "answer_sha256": e.digest(encoded), "episode_state": "completed" if not partial else "cancelled",
                     "invocation_status": "complete" if not partial else "partial", "capture_healthy": True,
                     "accounting_healthy": True, "failure": None, "delivered_ranges": [],
                     "delivered_recent_source_ids": [], "episode": {"charged": {"inputTokens": 23}, "held": {"outputTokens": 0}}})
    return {"version": 1, "attempts": rows, "input_sha256": e.digest(canonical_json(document))}


class Contracts(unittest.TestCase):
    def test_source_hash_and_size_refusal(self):
        with controlled_source() as (_histories, data, read):
            read.return_value = data[:-1]
            with self.assertRaises(e.EvaluationError): cases.prepare(Path("controlled-public-source"))
            read.return_value = data[:-1] + bytes([data[-1] ^ 1])
            with self.assertRaises(e.EvaluationError): cases.prepare(Path("controlled-public-source"))

    def test_source_rejects_unavailable_or_duplicate_sharings(self):
        with controlled_source() as (_histories, data, read):
            for mutate in (lambda root: root["Sources"][1]["ChatgptSharing"][0].update(Status=404),
                           lambda root: root["Sources"][1]["ChatgptSharing"][0].update(URL=root["Sources"][0]["ChatgptSharing"][0]["URL"])):
                root = json.loads(data)
                mutate(root)
                changed = canonical_json(root)
                read.return_value = changed
                with patch.object(cases, "SOURCE_BYTES", len(changed)), patch.object(cases, "SOURCE_SHA256", e.digest(changed)):
                    with self.assertRaises(e.EvaluationError): cases.prepare(Path("controlled-public-source"))

    def test_source_rejects_duplicate_messages_and_empty_pairs(self):
        with controlled_source() as (_histories, data, read):
            for field, value in (("Prompt", None), ("Answer", "")):
                root = json.loads(data)
                pairs = root["Sources"][0]["ChatgptSharing"][0]["Conversations"]
                pairs[1][field] = pairs[0][field] if value is None else value
                changed = canonical_json(root)
                read.return_value = changed
                with patch.object(cases, "SOURCE_BYTES", len(changed)), patch.object(cases, "SOURCE_SHA256", e.digest(changed)):
                    with self.assertRaises(e.EvaluationError): cases.prepare(Path("controlled-public-source"))

    def test_all_histories_pairs_and_source_serialization_are_retained(self):
        with controlled_source() as (histories, _data, _read):
            self.assertTrue(len(histories) == 3)
            documents = [cases.runner_input(h, developer.CONFIGURATION) for h in histories]
            self.assertTrue(sum(len(d["attempts"]) for d in documents) == 24)
            self.assertTrue(all(len(h["events"]) == 10 for h in histories))
            self.assertTrue(all([r["strategy"] for r in d["attempts"]] == list(e.STRATEGIES) * 4 for d in documents))
            self.assertTrue(all(not h["provenance"]["code_sidecars_injected"] and not h["provenance"]["original_time_indexed"] for h in histories))
            self.assertTrue(not any("synthetic code sidecar excluded" in event["text"] for h in histories for event in h["events"]))

    def test_runner_projection_has_no_oracle_fields(self):
        with controlled_source() as (histories, _data, _read):
            document = cases.runner_input(histories[0], developer.CONFIGURATION)
            def keys(value):
                if isinstance(value, dict): return set(value).union(*(keys(item) for item in value.values()))
                if isinstance(value, list): return set().union(*(keys(item) for item in value))
                return set()
            forbidden = {"goldSpans", "oracle", "expected_answers", "required_source_ids", "forbidden_answers", "answerable", "category"}
            self.assertTrue(not forbidden & keys(document))
            self.assertTrue(document["split"] == "development")

    def test_projection_tampering_is_refused(self):
        with controlled_source() as (histories, _data, _read):
            for mutate in (lambda h: h["events"][0].update(text="synthetic changed source"),
                           lambda h: h["episodes"][0].update(prompt="synthetic changed request"),
                           lambda h: h.update(id="synthetic changed identity")):
                history = copy.deepcopy(histories[0]); mutate(history)
                with self.assertRaises(e.EvaluationError): cases.runner_input(history, developer.CONFIGURATION)

    def test_oracle_tampering_is_refused(self):
        with controlled_source() as (histories, _data, _read):
            for field, value in (("expected_answers", ["synthetic changed gold"]), ("required_source_ids", ["synthetic changed citation"]),
                                 ("forbidden_answers", ["synthetic obsolete"]), ("rubric_version", "unknown")):
                history = copy.deepcopy(histories[0]); history["episodes"][0]["oracle"][field] = value
                with self.assertRaises(e.EvaluationError): cases.runner_input(history, developer.CONFIGURATION)

    def test_gold_digest_and_expected_text_are_verified(self):
        with controlled_source() as (histories, _data, _read):
            history = histories[0]
            for mutate in (lambda p: p["goldSpans"][0].update(sha256="0" * 64),
                           lambda p: p["oracle"].update(expected_answers=["synthetic changed gold"])):
                probe = copy.deepcopy(history["episodes"][0]); mutate(probe)
                with self.assertRaises(e.EvaluationError): developer.score(history, probe, "", False, {"all_required_spans_delivered": False})

    def test_gold_source_identity_matches_oracle_citations(self):
        with controlled_source() as (histories, _data, _read):
            history = histories[0]; probe = copy.deepcopy(history["episodes"][0])
            probe["oracle"]["required_source_ids"] = [history["events"][-1]["id"]]
            with self.assertRaises(e.EvaluationError):
                developer.score(history, probe, answer_for(probe), True, {"all_required_spans_delivered": True})

    def test_validated_source_ranges_support_exact_answer(self):
        with controlled_source() as (histories, _data, _read):
            history = histories[0]
            for probe in history["episodes"]:
                coverage = e.delivered_coverage(history, probe, ranges_for(probe), [])
                row = developer.score(history, probe, answer_for(probe), True, coverage)
                self.assertTrue(row["score"] == 1)

    def test_partial_or_absent_delivery_does_not_support_citations(self):
        with controlled_source() as (histories, _data, _read):
            history = histories[0]; probe = history["episodes"][1]
            for ranges in ([], ranges_for(probe)[:1]):
                coverage = e.delivered_coverage(history, probe, ranges, [])
                row = developer.score(history, probe, answer_for(probe), True, coverage)
                self.assertTrue(row["answer_correct"] and not row["citation_correct"] and row["score"] == 0)
                self.assertTrue(row["delivered_required_source_count"] == len(ranges))

    def test_recent_delivery_covers_only_exact_source(self):
        with controlled_source() as (histories, _data, _read):
            history = histories[0]; probe = history["episodes"][0]
            good = e.delivered_coverage(history, probe, [], probe["oracle"]["required_source_ids"])
            bad = e.delivered_coverage(history, probe, [], [history["events"][-1]["id"]])
            self.assertTrue(developer.score(history, probe, answer_for(probe), True, good)["score"] == 1)
            self.assertTrue(developer.score(history, probe, answer_for(probe), True, bad)["score"] == 0)

    def test_adjacent_ranges_jointly_cover_gold(self):
        with controlled_source() as (histories, _data, _read):
            history = histories[0]; probe = history["episodes"][0]
            gold = probe["goldSpans"][0]
            source = next(row["text"].encode() for row in history["events"] if row["id"] == gold["eventID"])
            midpoint = gold["offset"] + gold["byteLength"] // 2
            rows = [{"event_id": gold["eventID"], "offset": start, "byte_length": stop - start,
                     "sha256": e.digest(source[start:stop])} for start, stop in (
                        (gold["offset"], midpoint), (midpoint, gold["offset"] + gold["byteLength"]))]
            partial = e.delivered_coverage(history, probe, rows[:1], [])
            complete = e.delivered_coverage(history, probe, rows, [])
            self.assertTrue(not partial["covered_required_source_ids"])
            self.assertTrue(developer.score(history, probe, answer_for(probe), True, complete)["score"] == 1)

    def test_every_gold_span_in_one_source_must_be_delivered(self):
        with controlled_source() as (histories, _data, _read):
            history = histories[0]; probe = copy.deepcopy(history["episodes"][0])
            source = next(row["text"].encode() for row in history["events"] if row["id"] == probe["goldSpans"][0]["eventID"])
            first = probe["goldSpans"][0]
            start = first["offset"] + first["byteLength"] + 1
            probe["goldSpans"].append({"eventID": first["eventID"], "offset": start, "byteLength": len(source) - start,
                                       "sha256": e.digest(source[start:])})
            coverage = e.delivered_coverage(history, probe, ranges_for(probe)[:1], [])
            self.assertTrue(coverage["covered_span_count"] == 1 and not coverage["covered_required_source_ids"])

    def test_mismatched_delivery_digest_refused(self):
        with controlled_source() as (histories, _data, _read):
            history = histories[0]; probe = history["episodes"][0]
            rows = ranges_for(probe); rows[0]["sha256"] = "0" * 64
            with self.assertRaises(e.EvaluationError): e.delivered_coverage(history, probe, rows, [])

    def test_partial_and_failed_invocations_receive_zero(self):
        with controlled_source() as (histories, _data, _read):
            history = histories[0]
            for probe in history["episodes"]:
                coverage = e.delivered_coverage(history, probe, ranges_for(probe), [])
                row = developer.score(history, probe, answer_for(probe), False, coverage)
                self.assertTrue(row["score"] == 0 and row["failure_code"] == "invocation_incomplete")

    def test_report_no_clobber_precedes_source_reads_and_compilation(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "report.json"; output.write_bytes(b"preserved")
            with patch.object(cases, "prepare") as prepare, patch.object(e, "compile_driver") as compile_driver:
                with self.assertRaises(e.EvaluationError): developer.run(Path("unused"), output, timeout=60)
                self.assertTrue(not prepare.called and not compile_driver.called and output.read_bytes() == b"preserved")

    def test_source_gold_is_verified_before_compilation(self):
        with controlled_source() as (histories, _data, _read), tempfile.TemporaryDirectory() as temporary:
            tampered = copy.deepcopy(histories)
            tampered[0]["episodes"][0]["goldSpans"][0]["sha256"] = "0" * 64
            with patch.object(cases, "prepare", return_value=tampered), patch.object(e, "compile_driver") as compiler:
                with self.assertRaises(e.EvaluationError):
                    developer.run(Path("controlled-public-source"), Path(temporary) / "report.json", timeout=60)
                self.assertTrue(not compiler.called)

    def test_malformed_timeout_precedes_source_reads(self):
        with tempfile.TemporaryDirectory() as temporary:
            with patch.object(cases, "prepare") as prepare:
                for timeout in (True, 0, 21601, 60.0):
                    with self.assertRaises(e.EvaluationError): developer.run(Path("unused"), Path(temporary) / "report.json", timeout=timeout)
                self.assertTrue(not prepare.called)

    def run_controlled(self, *, mode="complete"):
        with controlled_source() as (histories, _data, _read), tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "report.json"
            input_paths = []
            def execute(_binary, input_path, directory, _timeout):
                input_paths.append(input_path)
                document = e.strict_json(e.read_file(input_path))
                self.assertTrue(set(document) == {"version", "split", "history_id", "events", "attempts", "configuration"})
                if mode == "fatal": return {"version": 1, "fatal_failure": "runner_process_timeout", "attempts": []}
                if mode == "invalid": return {"version": 1, "attempts": [None]}
                native = controlled_report(document, directory, count=1 if mode == "missing" else None, partial=mode == "partial")
                if mode == "provenance": native["input_sha256"] = "0" * 64
                if mode == "unterminalized":
                    native["attempts"][0]["terminalized"] = False
                    (directory / native["attempts"][0]["answer_file"]).unlink()
                return native
            with patch.object(e, "compile_driver", return_value=(Path("unused"), {"source_sha256": {}})), \
                 patch.object(e, "execute", side_effect=execute), contextlib.redirect_stdout(io.StringIO()) as logs:
                report = developer.run(Path("controlled-public-source"), output, timeout=60)
            encoded = output.read_text()
            self.assertTrue(os.stat(output).st_mode & 0o777 == 0o600)
            self.assertTrue(all(not path.exists() for path in input_paths))
            forbidden = ["synthetic incorrect result", e.DEFAULTS["system"]]
            forbidden += [event["text"] for h in histories for event in h["events"]]
            forbidden += [probe["prompt"] for h in histories for probe in h["episodes"]]
            self.assertTrue(not any(text in encoded or text in logs.getvalue() for text in forbidden))
            self.assertTrue(report["five_category_quality_gate"] == "inconclusive")
            self.assertTrue(len(report["histories"]) == 3 and sum(len(h["attempts"]) for h in report["histories"]) == 24)
            self.assertTrue(sum(sum(a["attempts"] for a in h["summary"].values()) for h in report["histories"]) == 24)
            return report

    def test_completed_wrong_answers_retain_operational_state(self):
        report = self.run_controlled()
        self.assertTrue(all(row["operational_complete"] and row["task_score"]["score"] == 0 for h in report["histories"] for row in h["attempts"]))

    def test_missing_attempts_retain_all_declared_denominators(self):
        report = self.run_controlled(mode="missing")
        self.assertTrue(sum(row["operational_complete"] for h in report["histories"] for row in h["attempts"]) == 3)
        self.assertTrue(all(h["attempts"][-1]["metadata"]["resources"] is None for h in report["histories"]))

    def test_fatal_attempts_retain_all_declared_denominators(self):
        report = self.run_controlled(mode="fatal")
        self.assertTrue(all(not row["operational_complete"] and row["task_score"]["score"] == 0 for h in report["histories"] for row in h["attempts"]))

    def test_invalid_report_retains_all_declared_denominators(self):
        report = self.run_controlled(mode="invalid")
        self.assertTrue(all(h["driver"]["fatal_failure"] == "runner_report_invalid" for h in report["histories"]))

    def test_report_input_provenance_refused(self):
        report = self.run_controlled(mode="provenance")
        self.assertTrue(all(h["driver"]["fatal_failure"] == "runner_report_invalid" for h in report["histories"]))

    def test_unterminalized_attempt_never_reads_answer_ipc(self):
        report = self.run_controlled(mode="unterminalized")
        self.assertTrue(all(h["attempts"][0]["answer_bytes"] is None and h["attempts"][0]["task_score"]["score"] == 0 for h in report["histories"]))

    def test_partial_invocations_retain_zero_scores(self):
        report = self.run_controlled(mode="partial")
        self.assertTrue(all(not row["operational_complete"] and row["task_score"]["score"] == 0 for h in report["histories"] for row in h["attempts"]))

    def test_arbitrary_provider_metadata_is_content_free(self):
        sentinel = "synthetic private metadata sentinel with spaces"
        row = e.content_free_metadata({"failure": sentinel, sentinel: {"projectID": sentinel}})
        self.assertTrue(sentinel not in json.dumps(row))


NATIVE_BINARY = None
PUBLIC_SOURCE = None


class QuietTestServer(ThreadingHTTPServer):
    daemon_threads = True
    def handle_error(self, _request, _client_address):
        # Child kill/disconnect must not print request or traceback material.
        pass


class NativeContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import test_component_preparation as fixture
        cls.temporary = tempfile.TemporaryDirectory(prefix="boros-developer-answer-native-")
        cls.directory = Path(cls.temporary.name).resolve()
        cls.observed = {"answers": 0, "prior_overlay_leaked": False}
        observed = cls.observed
        sentinel = "boroscontrolleddeveloperwronganswersentinel"
        class Handler(fixture.Handler):
            def do_POST(self):
                if self.path != "/v1/chat/completions":
                    return super().do_POST()
                data = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                body = json.loads(data)
                count = fixture.synthetic_count(fixture.FIXTURE.render(body))
                if body.get("stream") is not True:
                    self.send_json({"model": fixture.MODEL, "choices": [{"message": {"content": "4"}, "finish_reason": "stop"}],
                                    "usage": {"prompt_tokens": count, "completion_tokens": 1, "total_tokens": count + 1}})
                    return
                observed["answers"] += 1
                observed["prior_overlay_leaked"] |= any(sentinel in item.get("content", "") for item in body.get("messages", []))
                wrong = json.dumps({"answer": sentinel, "citations": [], "abstain": False})
                chunks = [{"model": fixture.MODEL, "choices": [{"delta": {"content": wrong}, "finish_reason": None}]},
                          {"model": fixture.MODEL, "choices": [{"delta": {}, "finish_reason": "stop"}],
                           "usage": {"prompt_tokens": count, "completion_tokens": 1, "total_tokens": count + 1}}]
                encoded = b"".join(b"data: " + json.dumps(chunk).encode() + b"\n\n" for chunk in chunks) + b"data: [DONE]\n\n"
                self.send_response(200); self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(encoded))); self.end_headers(); self.wfile.write(encoded)
        cls.server = QuietTestServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True); cls.thread.start()
        cls.histories = cases.prepare(PUBLIC_SOURCE)
        configuration = {**developer.CONFIGURATION, "endpoint": f"http://127.0.0.1:{cls.server.server_port}/v1"}
        cls.documents = [cases.runner_input(history, configuration) for history in cls.histories]
        cls.results = []
        for index, (history, document) in enumerate(zip(cls.histories, cls.documents)):
            input_path = cls.directory / f"input-{index}.json"; output = cls.directory / f"output-{index}"
            e.private_write(input_path, canonical_json(document))
            native = e.execute(NATIVE_BINARY, input_path, output, 300)
            rows = e.score_driver_report(native, output, history, document["attempts"], developer.score)
            cls.results.append((native, rows, output))

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown(); cls.server.server_close(); cls.thread.join(timeout=2); cls.temporary.cleanup()

    def test_native_accepts_all_three_exact_projections_and_inputs(self):
        self.assertTrue(len(self.results) == 3 and sum(len(rows) for _native, rows, _output in self.results) == 24)
        for index, (native, rows, _output) in enumerate(self.results):
            self.assertTrue(native.get("public_projection_sha256") == cases.PROJECTION_SHA256[index])
            self.assertTrue(native.get("input_sha256") == e.digest(canonical_json(self.documents[index])))
            self.assertTrue(all(row["operational_complete"] and row["task_score"]["score"] == 0 for row in rows))
        self.assertTrue(self.observed["answers"] == 24 and not self.observed["prior_overlay_leaked"])

    def test_native_overlay_background_and_accounting(self):
        for native, _rows, _output in self.results:
            self.assertTrue(len(native.get("attempts", [])) == 8)
            for item in native["attempts"]:
                self.assertTrue(item["overlay_events"] == 2)
                self.assertTrue(item["background"]["quiescent_during_answer"])
                self.assertTrue(item["background"]["performed"] == (item["strategy"] == "hybrid"))
                self.assertTrue(item["episode"]["charged"]["modelCalls"] >= 2)
                self.assertTrue(item["episode"]["charged"]["httpAttempts"] > 0)

    def test_native_reports_are_private_and_content_free(self):
        for history, (_native, rows, output) in zip(self.histories, self.results):
            encoded = json.dumps(rows) + (output / "report.json").read_text()
            forbidden = ["boroscontrolleddeveloperwronganswersentinel", e.DEFAULTS["system"]]
            forbidden += [event["text"] for event in history["events"]]
            forbidden += [probe["prompt"] for probe in history["episodes"]]
            forbidden += [answer for probe in history["episodes"] for answer in probe["oracle"]["expected_answers"]]
            self.assertTrue(not any(value in encoded for value in forbidden))
            self.assertTrue(os.stat(output).st_mode & 0o777 == 0o700)
            self.assertTrue(all(os.stat(path).st_mode & 0o777 == 0o600 for path in output.iterdir()))

    def test_native_killed_child_runtime_remains_supervisor_owned(self):
        import test_component_preparation as fixture
        entered, release = threading.Event(), threading.Event()
        class BlockingHandler(fixture.Handler):
            def block(self):
                entered.set()
                release.wait(20)
                self.send_json({"error": "controlled blocked endpoint"}, status=503)
            def do_GET(self): self.block()
            def do_POST(self): self.block()
        server = QuietTestServer(("127.0.0.1", 0), BlockingHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        process = None
        scratch = None
        try:
            with tempfile.TemporaryDirectory(prefix="boros-killed-answer-owner-") as temporary:
                scratch = Path(temporary).resolve()
                input_path, output = scratch / "input.json", scratch / "output"
                configuration = {**developer.CONFIGURATION, "endpoint": f"http://127.0.0.1:{server.server_port}/v1"}
                document = cases.runner_input(self.histories[0], configuration)
                e.private_write(input_path, canonical_json(document))
                process = subprocess.Popen([str(NATIVE_BINARY), "--answer-evaluation", str(input_path),
                                            "--output-directory", str(output)],
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                           env={**os.environ, "BOROS_DATA_DIR": str(scratch / "unused-app-runtime")})
                deadline = time.monotonic() + 15
                while not entered.is_set() and process.poll() is None and time.monotonic() < deadline:
                    entered.wait(0.03)
                self.assertTrue(entered.is_set() and process.poll() is None)
                runtimes = list(output.glob(".runtime-*"))
                self.assertTrue(len(runtimes) == 1 and runtimes[0].is_dir() and runtimes[0].parent == output)
                self.assertTrue((runtimes[0] / "baseline").is_dir())
                files = [path for path in runtimes[0].rglob("*") if path.is_file()]
                self.assertTrue(bool(files) and all(path.is_relative_to(output) for path in files))
                self.assertTrue(not (output / "report.json").exists())
                process.kill()
                stdout, stderr = process.communicate(timeout=10)
                self.assertTrue(process.returncode is not None and process.returncode < 0)
                self.assertTrue(runtimes[0].exists())
                self.assertTrue(not any(event["text"].encode() in stdout + stderr for event in self.histories[0]["events"]))
            self.assertTrue(scratch is not None and not scratch.exists())
        finally:
            if process is not None and process.poll() is None:
                process.kill(); process.communicate(timeout=10)
            release.set(); server.shutdown(); server.server_close(); thread.join(timeout=2)

    def test_native_rejects_corruption_and_oracle_before_output_creation(self):
        document = self.documents[0]
        corrupted = copy.deepcopy(document); corrupted["events"][0]["text"] += " synthetic corruption"
        injected = {**document, "oracle": self.histories[0]["episodes"][0]["oracle"]}
        for index, value in enumerate((corrupted, injected)):
            input_path = self.directory / f"rejected-{index}.json"; output = self.directory / f"rejected-output-{index}"
            e.private_write(input_path, canonical_json(value))
            process = subprocess.run([str(NATIVE_BINARY), "--answer-evaluation", str(input_path),
                                      "--output-directory", str(output)], capture_output=True, timeout=10)
            self.assertTrue(process.returncode != 0 and not output.exists())
            self.assertTrue(not any(event["text"].encode() in process.stdout + process.stderr for event in self.histories[0]["events"]))


def load_tests(loader, _suite, _pattern):
    suite = loader.loadTestsFromTestCase(Contracts)
    if NATIVE_BINARY is not None:
        suite.addTests(loader.loadTestsFromTestCase(NativeContracts))
    return suite


class SafeResult(unittest.TestResult):
    def __init__(self):
        super().__init__(); self.failed_names = []; self.error_names = []
    def addFailure(self, test, err):
        super().addFailure(test, err); self.failed_names.append(test.id().rsplit(".", 1)[-1])
    def addError(self, test, err):
        super().addError(test, err); self.error_names.append(test.id().rsplit(".", 1)[-1])


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path); parser.add_argument("--public-source", type=Path)
    arguments = parser.parse_args()
    if bool(arguments.binary) != bool(arguments.public_source):
        parser.error("both native test inputs are required together")
    NATIVE_BINARY = arguments.binary.resolve() if arguments.binary else None
    PUBLIC_SOURCE = arguments.public_source.resolve() if arguments.public_source else None
    result = SafeResult(); unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__]).run(result)
    print(json.dumps({"checks": result.testsRun, "failed": result.failed_names, "errors": result.error_names,
                      "skipped": len(result.skipped)}, sort_keys=True))
    raise SystemExit(0 if result.wasSuccessful() else 1)
