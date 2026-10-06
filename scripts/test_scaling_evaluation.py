#!/usr/bin/env python3
"""Portable scaling runner contracts; builds and native execution are stubbed."""
import contextlib
import copy
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import evaluate_scaling as scaling
from evaluation_fixtures import generate, corpus_summary


def native_fixture(mode, fixtures):
    fixture = fixtures["histories"][0]
    summary = corpus_summary(fixtures)
    episodes = []
    for episode in fixture["episodes"]:
        probes = {}
        for name in scaling.retrieval.PROTOCOLS:
            coverage = [True for _ in episode["goldSpans"]]
            probes[name] = {"terminalStatus": "selected", "memoryPathMilliseconds": 1.0,
                "coverageLimited": False, "coverageLimits": [], "scopeViolations": 0,
                "goldSpanCoverage": coverage, "allRequiredSpansPresent": bool(coverage),
                "episodeAccounting": {"fullEpisodeMilliseconds": 2.0,
                    "receipt": {"state": "completed", "charged": {key: 0 for key in scaling.RESOURCE_KEYS}}},
                "accounting": {"modelCalls": 0}}
            if name == "raw_source_probe":
                probes[name].update(exactReadBytesVerified=True, lexicalEndpointMilliseconds=0.5,
                    literalEndpointMilliseconds=0.4, literalSourceIDs=[], lexicalSourceIDs=[])
                probes[name]["accounting"].update(returnedSourceBytes=8, sourceReadCalls=1, memoryServiceCalls=3)
        episodes.append({"episodeID": episode["id"], "historyID": fixture["id"],
            "category": episode["category"], "answerable": episode["answerable"],
            "prototypeByteFeasible": episode["prototypeByteFeasible"], "goldSpanCount": len(episode["goldSpans"]),
            "goldSourceIDs": [span["eventID"] for span in episode["goldSpans"]], "protocols": probes})
    return {"schemaVersion": 2, "mode": mode, "fixtureVersion": fixtures["version"], "split": fixtures["split"],
        "seed": fixtures["seed"], "episodeAccountingVersion": "standalone-read-episode-v1", "elapsedMilliseconds": 10,
        "histories": [{"historyID": fixture["id"], "eventCount": summary["eventCount"],
            "sourceBytes": summary["sourceBytes"], "storeBytes": 4096, "storeOpenMilliseconds": 1,
            "ingestionMilliseconds": 5 if mode == "warm" else None, "episodes": episodes}]}


class Contracts(unittest.TestCase):
    def execute_fixture(self, root, *, scales=(1000,), fail=None, drift=None, compile_failure=False):
        files = ("native.swift", "helper.py", "runner.py")
        for name in files:
            (root / name).write_bytes(b"synthetic SOURCE_SENTINEL")
        pins = {name: scaling.digest(root / name) for name in files}
        output = root / ".build" / "measurement"
        calls = []

        def compile_native(directory, flags):
            declaration = json.loads((directory / "declaration.json").read_bytes())
            self.assertEqual(declaration["declared_attempts"], len(scales) * 2)
            self.assertEqual(declaration["source_sha256"], pins)
            self.assertEqual(declaration["compile_flags"], ["-O", "synthetic"])
            self.assertTrue(declaration["source_captured_before_compile"])
            self.assertEqual(len(declaration["corpora"]), len(scales))
            self.assertEqual(scaling.inventory(directory / "source"), pins)
            calls.append("compile")
            if compile_failure:
                raise ValueError("PRIVATE_FAILURE_SENTINEL")
            binary = directory / "retrieval-scaling"
            binary.write_bytes(b"synthetic binary")
            return binary

        def execute_native(binary, mode, input_path, runtime, path, timeout):
            declaration = json.loads((output / "declaration.json").read_bytes())
            self.assertEqual(declaration["profile_timeout_seconds"], timeout)
            fixtures = json.loads(input_path.read_bytes())
            scale = fixtures["scaleEvents"]
            self.assertEqual(len(fixtures["histories"][0]["events"]), scale)
            self.assertEqual(scaling.digest(input_path), declaration["corpora"][str(scale)]["sha256"])
            calls.append((scale, mode))
            if fail == (scale, mode):
                raise subprocess.TimeoutExpired("PRIVATE_FAILURE_SENTINEL", timeout)
            result = native_fixture(mode, fixtures)
            path.write_text(json.dumps(result))
            if drift == (scale, mode, "source"):
                (root / "helper.py").write_bytes(b"changed")
            if drift == (scale, mode, "copy"):
                (output / "source" / "helper.py").write_bytes(b"changed")
            if drift == (scale, mode, "binary"):
                binary.write_bytes(b"changed")
            if drift == (scale, mode, "declaration"):
                (output / "declaration.json").write_bytes(b"changed")
            if drift == (scale, mode, "corpus"):
                input_path.write_bytes(b"changed")
            return result

        with patch.object(scaling, "ROOT", root), patch.object(scaling, "FILES", files), \
             patch.object(scaling, "IMPORT_HASHES", pins), patch.object(scaling, "compile_flags", return_value=["-O", "synthetic"]), \
             patch.object(scaling, "compile_harness", side_effect=compile_native), patch.object(scaling, "execute", side_effect=execute_native):
            result = scaling.run(output, scales)
        return result, calls, output

    def test_all_scales_declared_before_compile_and_modes_ordered(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, calls, output = self.execute_fixture(Path(temporary), scales=scaling.SCALES)
            self.assertEqual(result["completed_attempts"], 6)
            self.assertEqual(calls, ["compile", (1000, "warm"), (1000, "restart"), (10000, "warm"),
                                    (10000, "restart"), (100000, "warm"), (100000, "restart")])
            self.assertTrue(result["implementation_continuity"])
            self.assertFalse(result["registered_measurement"])
            self.assertFalse(result["n5_complete"])
            self.assertEqual(result["provider_requests"], 0)
            self.assertEqual(result["attempts"][-1]["summary"]["event_count"], 100000)

    def test_warm_failure_keeps_two_denominators_without_restart_retry(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, calls, _ = self.execute_fixture(Path(temporary), scales=(1000, 10000), fail=(1000, "warm"))
            self.assertEqual([a["status"] for a in result["attempts"]], ["timed_out", "prerequisite_failed", "completed", "completed"])
            self.assertEqual(result["declared_attempts"], 4)
            self.assertNotIn((1000, "restart"), calls)

    def test_restart_failure_keeps_successful_warm_and_no_retry(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, calls, _ = self.execute_fixture(Path(temporary), fail=(1000, "restart"))
            self.assertEqual(result["completed_attempts"], 1)
            self.assertEqual(len(calls), 3)
            self.assertEqual(result["attempts"][1]["status"], "timed_out")

    def test_compile_failure_retains_all_declared_profiles(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, calls, _ = self.execute_fixture(Path(temporary), compile_failure=True)
            self.assertEqual(calls, ["compile"])
            self.assertEqual(result["declared_attempts"], 2)
            self.assertTrue(all(a["status"] == "compile_failed" for a in result["attempts"]))

    def test_last_profile_drift_revokes_prior_credit_for_each_dependency(self):
        for target in ("source", "copy", "binary", "declaration", "corpus"):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as temporary:
                result, calls, _ = self.execute_fixture(Path(temporary), drift=(1000, "restart", target))
                self.assertEqual(result["completed_attempts"], 0)
                self.assertFalse(result["implementation_continuity"])
                self.assertTrue(all(a["summary"] is None for a in result["attempts"]))
                self.assertTrue(all(a["status"] == "implementation_unverified" for a in result["attempts"]))

    def test_early_drift_prevents_following_execution(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, calls, _ = self.execute_fixture(Path(temporary), drift=(1000, "warm", "source"))
            self.assertEqual(calls, ["compile", (1000, "warm")])
            self.assertEqual(result["completed_attempts"], 0)

    def test_output_no_clobber_and_private_permissions(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _, _, output = self.execute_fixture(root)
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)
            for filename in ("declaration.json", "report.json", "1000/fixtures.json", "source/helper.py"):
                self.assertEqual((output / filename).stat().st_mode & 0o777, 0o600)
            with patch.object(scaling, "ROOT", root), self.assertRaises(FileExistsError):
                scaling.new_directory(output)

    def test_paths_reject_relative_source_tree_and_caller_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / ".build").mkdir()
            (root / "link").symlink_to(root / ".build")
            with patch.object(scaling, "ROOT", root):
                for path in (Path("relative"), root / "source", root / "link" / "measurement", root / ".build" / ".." / "outside"):
                    with self.subTest(path=path), self.assertRaises(scaling.ScalingError):
                        scaling.new_directory(path)

    def test_invalid_sizes_duplicates_bool_and_timeout_refused_before_mutation(self):
        for scales, timeout in (((), 900), ((1,), 900), ((True,), 900), ((1000, 1000), 900), ((1000,), 901), ((1000,), True)):
            with self.subTest(scales=scales, timeout=timeout), patch.object(scaling, "new_directory") as create:
                with self.assertRaises(scaling.ScalingError):
                    scaling.run(Path("/unused"), scales, timeout=timeout)
                self.assertFalse(create.called)

    def test_imported_dependency_drift_refused_before_destination_creation(self):
        with patch.object(scaling, "compile_flags", return_value=["-O"]), patch.object(scaling, "inventory", return_value={}), patch.object(scaling, "new_directory") as create:
            with self.assertRaises(scaling.ScalingError):
                scaling.run(Path("/unused"))
            self.assertFalse(create.called)

    def test_native_aggregates_are_actual_metrics_and_semantic_unknown(self):
        fixtures = generate("development", scale_events=1000)
        report = native_fixture("warm", fixtures)
        summary = scaling.summarize(report, "warm", corpus_summary(fixtures), fixtures)
        raw = summary["protocols"]["raw_source_probe"]
        self.assertEqual(raw["memory_path_milliseconds"], {"observations": 9, "p50": 1.0, "p95": 1.0, "maximum": 1.0})
        self.assertEqual(raw["returnedSourceBytes"]["total"], 72)
        self.assertEqual(raw["full_read_episode_milliseconds"]["p95"], 2.0)
        self.assertEqual(raw["byte_feasible_answerable_probes"], 7)
        self.assertIsNone(summary["semantic_chunks"])
        self.assertIsNone(summary["indexing_backlog"])
        self.assertIsNone(summary["rss_bytes"])

    def test_native_malformed_identity_counts_nonfinite_metrics_and_provider_work_refused(self):
        fixtures = generate("development", scale_events=1000)
        native = native_fixture("warm", fixtures)
        mutations = [lambda r: r.update(mode="restart"), lambda r: r["histories"][0].update(eventCount=10000),
            lambda r: r["histories"][0]["episodes"].pop(),
            lambda r: r["histories"][0]["episodes"][0]["protocols"]["recent_only"].update(memoryPathMilliseconds=float("nan")),
            lambda r: r["histories"][0]["episodes"][0]["protocols"]["recent_only"].update(goldSpanCoverage=[1]),
            lambda r: r["histories"][0]["episodes"][0]["protocols"]["recent_only"]["episodeAccounting"]["receipt"]["charged"].update(modelCalls=1)]
        for mutation in mutations:
            report = copy.deepcopy(native); mutation(report)
            with self.assertRaises(scaling.ScalingError):
                scaling.summarize(report, "warm", corpus_summary(fixtures), fixtures)

    def test_missing_receipts_and_selection_failures_retained_as_observed(self):
        fixtures = generate("development", scale_events=1000)
        native = native_fixture("warm", fixtures)
        probe = native["histories"][0]["episodes"][0]["protocols"]["recent_only"]
        probe.update(terminalStatus="error", goldSpanCoverage=[False], allRequiredSpansPresent=False,
            episodeAccounting=None, coverageLimited=True, coverageLimits=["episode_budget"])
        summary = scaling.summarize(native, "warm", corpus_summary(fixtures), fixtures)["protocols"]["recent_only"]
        self.assertEqual(summary["selection_failures"], 1)
        self.assertEqual(summary["missing_episode_receipts"], 1)
        self.assertEqual(summary["declared_probes"], 9)
        self.assertEqual(summary["coverage_limits"], {"episode_budget": 1})

    def test_reports_and_cli_never_emit_corpus_or_failure_bodies(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, _, output = self.execute_fixture(Path(temporary), compile_failure=True)
            report = (output / "report.json").read_text()
            self.assertNotIn("SOURCE_SENTINEL", report)
            self.assertNotIn("PRIVATE_FAILURE_SENTINEL", report)
            self.assertNotIn("What nonce was recorded", report)
            self.assertNotIn("synthetic SOURCE_SENTINEL", report)
        out = io.StringIO()
        with contextlib.redirect_stdout(out), patch.object(scaling, "run", side_effect=ValueError("PRIVATE_FAILURE_SENTINEL")):
            self.assertEqual(scaling.main(["--execute", "--output-directory", "/PRIVATE_DEST"]), 1)
        self.assertNotIn("PRIVATE", out.getvalue())

    def test_cli_requires_explicit_execute(self):
        with contextlib.redirect_stdout(io.StringIO()), patch.object(scaling, "run") as run:
            self.assertEqual(scaling.main(["--output-directory", "/unused"]), 1)
        self.assertFalse(run.called)


if __name__ == "__main__":
    result = unittest.TextTestRunner(stream=io.StringIO()).run(unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    print(json.dumps({"checks": result.testsRun, "failed": [test.id() for test, _ in result.failures],
        "errors": [test.id() for test, _ in result.errors], "skipped": len(result.skipped)}))
    raise SystemExit(not result.wasSuccessful())
