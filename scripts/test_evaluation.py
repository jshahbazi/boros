#!/usr/bin/env python3
"""Check fixture, clustered-estimand and actual Swift retrieval contracts."""
from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import re
import os
import sqlite3

from evaluation_fixtures import canonical_json, corpus_summary, generate
from evaluation_statistics import (clustered_recall, paired_score_interval, trajectory_cost_ratio, percentile,
                                   minimum_power_histories, quality_joint_power_histories, tree_gate_decision, PRIMARY_CATEGORIES)
from evaluate_retrieval import (ROOT, PREREGISTRATION, PROTOCOL_AMENDMENT, CORE_FILES, PYTHON_FILES,
                               compile_harness, execute, rows, binary_coverage, summarize)


class EvaluationContracts(unittest.TestCase):
    def test_frozen_development_hash(self):
        registration = json.loads(PREREGISTRATION.read_text())
        self.assertEqual(corpus_summary(generate("development")), registration["fixtureSets"]["development"])
        self.assertEqual(hashlib.sha256((ROOT / "scripts/evaluation_fixtures.py").read_bytes()).hexdigest(), registration["generatorSHA256"])

    def test_splits_have_disjoint_history_and_source_ids(self):
        development = generate("development", history_count=1)
        validation = generate("validation", history_count=1)
        self.assertNotEqual(development["seed"], validation["seed"])
        self.assertTrue({item["id"] for item in development["histories"][0]["events"]}.isdisjoint(
            {item["id"] for item in validation["histories"][0]["events"]}))

    def test_gold_byte_ranges_and_hashes(self):
        fixtures = generate("development", history_count=2)
        for history in fixtures["histories"]:
            sources = {source["id"]: source for source in history["events"]}
            for episode in history["episodes"]:
                for gold in episode["goldSpans"]:
                    source = sources[gold["eventID"]]
                    self.assertEqual(source["projectID"], episode["projectID"])
                    recovered = source["text"].encode()[gold["offset"]:gold["offset"] + gold["byteLength"]]
                    self.assertEqual(hashlib.sha256(recovered).hexdigest(), gold["sha256"])
                    recovered.decode()

    def test_macro_estimate_weights_histories_and_categories(self):
        observations = [
            {"historyID": "h1", "category": "a", "success": 0},
            {"historyID": "h1", "category": "a", "success": 1},
            {"historyID": "h1", "category": "b", "success": 1},
            {"historyID": "h2", "category": "a", "success": 1},
            {"historyID": "h2", "category": "b", "success": 0},
        ]
        result = clustered_recall(observations, "success", resamples=100)
        self.assertAlmostEqual(result["pointEstimate"], 0.625)
        self.assertAlmostEqual(result["categories"]["a"]["pointEstimate"], 0.75)
        self.assertEqual(result["independentHistories"], 2)

    def test_bootstrap_repeatability(self):
        observations = [{"historyID": str(index), "category": "a", "x": index % 2} for index in range(8)]
        self.assertEqual(clustered_recall(observations, "x", resamples=100), clustered_recall(observations, "x", resamples=100))

    def test_missing_category_resamples_are_inconclusive(self):
        observations = [{"historyID": "h1", "category": "a", "x": 1},
                        {"historyID": "h2", "category": "b", "x": 1}]
        self.assertIsNone(clustered_recall(observations, "x", resamples=100)["interval95"])

    def test_no_gold_is_unknown(self):
        self.assertIsNone(clustered_recall([], "x")["pointEstimate"])

    def test_paired_grid_not_extra_independent_histories(self):
        row = {"historyID": "one", "B": {PRIMARY_CATEGORIES[0]: 0.5}, "D": {PRIMARY_CATEGORIES[0]: 0.7}}
        with self.assertRaises(ValueError):
            paired_score_interval([row, copy.deepcopy(row)], resamples=100)

    def test_paired_difference_uses_category_macro_average(self):
        observations = [{"historyID": history, "B": dict.fromkeys(PRIMARY_CATEGORIES, 0.5),
                         "D": {category: 0.7 if category == PRIMARY_CATEGORIES[0] else 0.5 for category in PRIMARY_CATEGORIES}}
                        for history in ("one", "two")]
        result = paired_score_interval(observations, resamples=100)
        self.assertAlmostEqual(result["overall"]["pointEstimate"], 0.04)

    def test_paired_histories_can_cover_different_categories(self):
        result = paired_score_interval([
            {"historyID": "one", "B": {PRIMARY_CATEGORIES[0]: 0.5}, "D": {PRIMARY_CATEGORIES[0]: 0.7}},
            {"historyID": "two", "B": {PRIMARY_CATEGORIES[1]: 0.5}, "D": {PRIMARY_CATEGORIES[1]: 0.5}},
        ], resamples=100)
        self.assertIsNone(result["overall"]["pointEstimate"])
        self.assertIsNone(result["overall"]["interval95"])

    def test_missing_frozen_task_category_cannot_improve_macro_score(self):
        categories = PRIMARY_CATEGORIES[:-1]
        observations = [{"historyID": str(index), "B": dict.fromkeys(categories, 0), "D": dict.fromkeys(categories, 1)} for index in range(3)]
        result = paired_score_interval(observations, resamples=100)
        self.assertIsNone(result["overall"]["pointEstimate"])
        self.assertIsNone(result[PRIMARY_CATEGORIES[-1]]["interval95"])

    @staticmethod
    def costs(b_success=1.0, d_success=1.0):
        return [{"historyID": "one", "B": {"facts": {"successRate": b_success, "marginalCost": 1.0}},
                 "D": {"facts": {"successRate": d_success, "marginalCost": 1.0}}}]

    def test_production_shared_cost_charged_once(self):
        result = trajectory_cost_ratio(self.costs(), category_mix={"facts": 1}, shared_cost={"B": 100, "D": 50}, query_count=10, resamples=100)
        self.assertAlmostEqual(result["pointEstimate"], 6 / 11)

    def test_zero_success_cost_draws_retained(self):
        result = trajectory_cost_ratio(self.costs(d_success=0), category_mix={"facts": 1}, shared_cost={"B": 100, "D": 50}, query_count=10, resamples=100)
        self.assertEqual(result["infiniteResamples"], 100)
        self.assertEqual(result["decision"], "fails_cost_gate")

    def test_undefined_cost_draws_inconclusive(self):
        result = trajectory_cost_ratio(self.costs(b_success=0), category_mix={"facts": 1}, shared_cost={"B": 100, "D": 50}, query_count=10, resamples=100)
        self.assertEqual(result["undefinedResamples"], 100)
        self.assertEqual(result["decision"], "inconclusive")

    def test_missing_usage_not_zero_cost(self):
        observations = self.costs()
        observations[0]["D"]["facts"]["marginalCost"] = None
        with self.assertRaises(ValueError):
            trajectory_cost_ratio(observations, category_mix={"facts": 1}, shared_cost={"B": 100, "D": 50}, query_count=10, resamples=100)

    def test_boolean_cost_fields_are_rejected_individually(self):
        for field in ("weight", "shared", "success", "marginal", "queries", "resamples", "seed"):
            for boolean in (True, False):
                observations = self.costs()
                arguments = {"category_mix": {"facts": 1.0}, "shared_cost": {"B": 100.0, "D": 50.0},
                             "query_count": 10, "resamples": 100, "seed": 1}
                if field == "weight": arguments["category_mix"]["facts"] = boolean
                if field == "shared": arguments["shared_cost"]["D"] = boolean
                if field == "success": observations[0]["D"]["facts"]["successRate"] = boolean
                if field == "marginal": observations[0]["D"]["facts"]["marginalCost"] = boolean
                if field == "queries": arguments["query_count"] = boolean
                if field in ("resamples", "seed"): arguments[field] = boolean
                with self.subTest(field=field, boolean=boolean), self.assertRaises(ValueError):
                    trajectory_cost_ratio(observations, **arguments)

    def test_boolean_only_cost_fixture_cannot_claim_free_success(self):
        malformed = [{"historyID": "one", "B": {"facts": {"successRate": True, "marginalCost": True}},
                      "D": {"facts": {"successRate": True, "marginalCost": False}}}]
        with self.assertRaises(ValueError):
            trajectory_cost_ratio(malformed, category_mix={"facts": True}, shared_cost={"B": False, "D": False}, query_count=True, resamples=100)

    def test_cost_counts_ranges_and_finite_values(self):
        for queries in (0, -1, 1.5, float("inf"), float("nan"), "10", None):
            with self.subTest(queries=queries), self.assertRaises(ValueError):
                trajectory_cost_ratio(self.costs(), category_mix={"facts": 1}, shared_cost={"B": 100, "D": 50}, query_count=queries, resamples=100)
        for bad in (-0.1, float("nan"), float("inf"), "1", None):
            observations = self.costs()
            observations[0]["D"]["facts"]["marginalCost"] = bad
            with self.subTest(marginal=bad), self.assertRaises(ValueError):
                trajectory_cost_ratio(observations, category_mix={"facts": 1}, shared_cost={"B": 100, "D": 50}, query_count=10, resamples=100)

    def test_recall_and_percentile_reject_numeric_boolean_coercion(self):
        with self.assertRaises(ValueError): percentile([True], 0.5)
        with self.assertRaises(ValueError): percentile([1.0], True)
        with self.assertRaises(ValueError): clustered_recall([{"historyID": "one", "category": "facts", "x": True}], "x", resamples=100)
        for parameter in ("resamples", "seed"):
            with self.subTest(parameter=parameter), self.assertRaises(ValueError):
                clustered_recall([{"historyID": "one", "category": "facts", "x": 1}], "x", **{parameter: True})
        self.assertEqual(binary_coverage({"allRequiredSpansPresent": True}), 1)
        for malformed in (1, 0, "true", None):
            with self.subTest(coverage=malformed), self.assertRaises(ValueError):
                binary_coverage({"allRequiredSpansPresent": malformed})

    def test_held_out_execution_is_blocked(self):
        process = subprocess.run(["python3", str(ROOT / "scripts/evaluate_retrieval.py"), "--split", "held-out"], capture_output=True, text=True)
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("held-out execution is blocked", process.stderr)

    def test_missing_pilot_variance_leaves_power_pending(self):
        self.assertIsNone(minimum_power_histories(None, 0.05, 200)["requiredHistories"])

    def test_power_uses_independent_clusters_and_floors(self):
        self.assertEqual(minimum_power_histories(0.0, 0.05, 200)["requiredHistories"], 200)
        self.assertGreater(minimum_power_histories(0.5, 0.05, 200)["requiredHistories"], 200)

    def test_quality_point_threshold_alternative_does_not_claim_joint_power(self):
        self.assertIsNone(quality_joint_power_histories(0.5, 0.05)["requiredHistories"])
        self.assertGreater(quality_joint_power_histories(0.5, 0.06)["requiredHistories"],
                           quality_joint_power_histories(0.5, 0.1)["requiredHistories"])

    def test_power_numeric_fields_reject_booleans_with_and_without_pilot(self):
        for parameter in ("cluster_standard_deviation", "margin", "minimum", "power"):
            arguments = {"cluster_standard_deviation": 0.5, "margin": 0.05, "minimum": 200, "power": 0.9}
            arguments[parameter] = True
            with self.subTest(helper="individual", parameter=parameter), self.assertRaises(ValueError):
                minimum_power_histories(**arguments)
        for parameter in ("cluster_standard_deviation", "assumed_true_difference", "minimum", "power"):
            arguments = {"cluster_standard_deviation": 0.5, "assumed_true_difference": 0.1, "minimum": 200, "power": 0.9}
            arguments[parameter] = True
            with self.subTest(helper="joint", parameter=parameter), self.assertRaises(ValueError):
                quality_joint_power_histories(**arguments)
        for helper in (minimum_power_histories, quality_joint_power_histories):
            with self.subTest(helper=helper.__name__, pilot="unknown"), self.assertRaises(ValueError):
                helper(None, None if helper is quality_joint_power_histories else 0.05, minimum=True)

    def test_power_minima_are_positive_integers(self):
        for minimum in (False, 0, -1, 200.5, float("nan"), float("inf"), "200"):
            for helper in (minimum_power_histories, quality_joint_power_histories):
                with self.subTest(helper=helper.__name__, minimum=minimum), self.assertRaises(ValueError):
                    helper(0.5, 0.1, minimum)

    @staticmethod
    def gates():
        return {"primaryMode": "quality-first", "allApplicableInvariantsPassed": True,
                "minimumHistoriesAndPowerSatisfied": True, "eachReplicateBuildFeasibleRecall": [0.95, 0.99],
                "declared100kWarmEndpointP95Milliseconds": 999,
                "pairedTaskScore": {"point": 0.05, "lower95": 0.001},
                "targetCostPerSuccessRatio95Upper": 1.25,
                "criticalCategoryDifference95Lower": {"immediate_exact_followups": -0.019,
                    "scoped_instruction_lifecycle": -0.019, "appropriate_abstention": -0.019},
                "worstReplicateProfiles": {profile: {"addedMemoryPathP95Milliseconds": 500, "fullEpisodeP95Ratio": 1.1}
                                           for profile in ("warm", "cold_restart", "paused")}}

    def test_all_tree_gates_are_conjunctive(self):
        self.assertEqual(tree_gate_decision(self.gates())["outcome"], "passes")
        evidence = self.gates()
        evidence["worstReplicateProfiles"]["paused"]["fullEpisodeP95Ratio"] = 1.11
        self.assertEqual(tree_gate_decision(evidence)["outcome"], "fails")

    def test_missing_cost_keeps_decision_inconclusive(self):
        evidence = self.gates()
        evidence["targetCostPerSuccessRatio95Upper"] = None
        self.assertEqual(tree_gate_decision(evidence)["outcome"], "inconclusive")

    def test_strict_regression_margin(self):
        evidence = self.gates()
        evidence["criticalCategoryDifference95Lower"]["appropriate_abstention"] = -0.02
        self.assertEqual(tree_gate_decision(evidence)["outcome"], "fails")

    def test_cost_first_is_single_frozen_branch(self):
        evidence = self.gates()
        evidence["primaryMode"] = "cost-first"
        evidence["pairedTaskScore"] = {"point": 0.0, "lower95": -0.019}
        evidence["targetCostPerSuccessRatio95Upper"] = 0.8
        self.assertEqual(tree_gate_decision(evidence)["outcome"], "passes")

    def test_gate_boolean_evidence_has_no_truthiness_coercion(self):
        for field in ("allApplicableInvariantsPassed", "minimumHistoriesAndPowerSatisfied"):
            for value in (1, 0, "true", "false", [], {}):
                evidence = self.gates()
                evidence[field] = value
                with self.assertRaises(ValueError):
                    tree_gate_decision(evidence)

    def test_gate_numeric_evidence_validates_ranges(self):
        for field, value in (("declared100kWarmEndpointP95Milliseconds", -1),
                             ("declared100kWarmEndpointP95Milliseconds", float("nan")),
                             ("targetCostPerSuccessRatio95Upper", -1),
                             ("eachReplicateBuildFeasibleRecall", [1.01]),
                             ("eachReplicateBuildFeasibleRecall", [True]),
                             ("pairedTaskScore", {"point": 1.01, "lower95": 0.2})):
            evidence = self.gates()
            evidence[field] = value
            with self.assertRaises(ValueError):
                tree_gate_decision(evidence)
        evidence = self.gates()
        evidence["worstReplicateProfiles"]["warm"]["fullEpisodeP95Ratio"] = -1
        with self.assertRaises(ValueError):
            tree_gate_decision(evidence)

    def test_unknown_partial_observations_stay_inconclusive_and_infinity_fails(self):
        evidence = self.gates()
        evidence["eachReplicateBuildFeasibleRecall"] = [1, None]
        self.assertEqual(tree_gate_decision(evidence)["outcome"], "inconclusive")
        evidence["targetCostPerSuccessRatio95Upper"] = float("inf")
        self.assertEqual(tree_gate_decision(evidence)["outcome"], "fails")


class SwiftRetrievalContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="boros-evaluation-contract-")
        cls.scratch = Path(cls.temporary.name)
        cls.fixtures = generate("development", history_count=2)
        cls.input = cls.scratch / "fixtures.json"
        cls.input.write_bytes(canonical_json(cls.fixtures))
        cls.binary, cls.implementation = compile_harness(cls.scratch)
        runtime = cls.scratch / "store"
        cls.runtime = runtime
        cls.warm = execute(cls.binary, "warm", cls.input, runtime, cls.scratch)
        cls.restart = execute(cls.binary, "restart", cls.input, runtime, cls.scratch)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_targeted_gold_survives_store_and_restart(self):
        for report in (self.warm, self.restart):
            for episode in rows(report):
                if episode["answerable"] and episode["prototypeByteFeasible"]:
                    self.assertTrue(episode["protocols"]["targeted_lexical"]["allRequiredSpansPresent"])
                    self.assertTrue(episode["protocols"]["raw_source_probe"]["allRequiredSpansPresent"])

    def test_scope_and_exact_source_page_provenance(self):
        for report in (self.warm, self.restart):
            for episode in rows(report):
                for protocol in episode["protocols"].values():
                    self.assertEqual(protocol["scopeViolations"], 0)
                self.assertTrue(episode["protocols"]["raw_source_probe"]["exactReadBytesVerified"])

    def test_questions_are_not_captured_into_later_memory(self):
        self.assertEqual([history["eventCount"] for history in self.warm["histories"]],
                         [history["eventCount"] for history in self.restart["histories"]])
        # Harness output keeps original IDs and counts; queries don't receive
        # source IDs or appear in either stable source list.
        for episode in rows(self.restart):
            self.assertNotIn(episode["episodeID"], episode["protocols"]["raw_source_probe"]["lexicalSourceIDs"])

    def test_read_episodes_change_only_ledger_not_sources_or_invocations(self):
        for history in self.fixtures["histories"]:
            directory = self.runtime / history["id"]
            databases = list(directory.glob("*.sqlite3")) + list(directory.glob("*.sqlite"))
            self.assertEqual(len(databases), 1)
            with sqlite3.connect(f"file:{databases[0]}?mode=ro", uri=True) as database:
                self.assertEqual(database.execute("PRAGMA user_version").fetchone()[0], 5)
                self.assertEqual(database.execute("SELECT count(*) FROM events").fetchone()[0], len(history["events"]))
                self.assertEqual(database.execute("SELECT count(*) FROM invocations").fetchone()[0], 0)
                origins = database.execute("SELECT origin_json FROM episodes").fetchall()
                self.assertEqual(len(origins), len(history["episodes"]) * 5 * 2)
                self.assertTrue(all(json.loads(row[0])["kind"] == "localRead" for row in origins))

    def test_each_protocol_has_authoritative_bounded_read_accounting(self):
        ids = []
        projects = {episode["id"]: episode["projectID"] for history in self.fixtures["histories"] for episode in history["episodes"]}
        for report in (self.warm, self.restart):
            self.assertEqual(report["episodeAccountingVersion"], "standalone-read-episode-v1")
            for episode in rows(report):
                for protocol in episode["protocols"].values():
                    journal = protocol["episodeAccounting"]
                    receipt = journal["receipt"]
                    ids.append(receipt["id"])
                    self.assertNotEqual(receipt["state"], "active")
                    self.assertEqual(receipt["origin"]["kind"], "localRead")
                    self.assertNotIn("conversationID", receipt)
                    self.assertEqual(receipt["projectID"], projects[episode["episodeID"]])
                    for resource, cap in receipt["limits"]["resources"].items():
                        self.assertLessEqual(receipt["charged"][resource] + receipt["held"][resource], cap)
                    self.assertGreaterEqual(journal["fullEpisodeMilliseconds"], 0)
                    self.assertIsNone(journal["modelFeasibility"])
                    self.assertIsNone(journal["billedCost"])
        self.assertEqual(len(ids), len(set(ids)))

    def test_budget_failures_remain_in_all_protocol_denominators(self):
        scratch = self.scratch / "zero-memory-budget"
        scratch.mkdir()
        report = execute(self.binary, "warm", self.input, scratch / "stores", scratch,
                         env={**os.environ, "BOROS_EVALUATION_MEMORY_OPERATION_CAP": "0"})
        self.assertEqual(len(rows(report)), len(rows(self.warm)))
        for episode in rows(report):
            self.assertEqual(len(episode["protocols"]), 5)
            for protocol in episode["protocols"].values():
                self.assertEqual(protocol["terminalStatus"], "error")
                self.assertEqual(protocol["errorCode"], "episode_budget_exceeded")
                self.assertFalse(protocol["allRequiredSpansPresent"])
                receipt = protocol["episodeAccounting"]["receipt"]
                self.assertEqual(receipt["state"], "budgetExceeded")
                self.assertEqual(receipt["charged"]["memoryOperations"], 0)
                self.assertEqual(receipt["held"]["memoryOperations"], 0)
        summary = summarize(report)
        eligible = sum(episode["answerable"] and episode["prototypeByteFeasible"] for episode in rows(self.warm))
        for protocol in summary.values():
            self.assertEqual(protocol["eligibleProbeCount"], eligible)
            self.assertEqual(protocol["successfulProbeCount"], 0)
            self.assertEqual(protocol["selectionFailures"], len(rows(report)))

    def test_semantic_unavailable_notice_is_not_a_coverage_limit(self):
        complete = []
        for episode in rows(self.warm):
            gui = episode["protocols"]["gui_lexical_anyterm"]
            self.assertTrue(gui["retrievalNoticePresent"])
            self.assertEqual(gui["coverageLimited"], bool(gui["coverageLimits"]))
            if not gui["coverageLimits"]:
                complete.append(gui)
                self.assertFalse(gui["coverageLimited"])
        self.assertTrue(complete, "fixture must contain a complete lexical result despite its availability notice")

    def test_byte_infeasible_gold_not_silently_counted_as_success(self):
        for episode in rows(self.warm):
            if episode["answerable"] and not episode["prototypeByteFeasible"]:
                for protocol in episode["protocols"].values():
                    self.assertFalse(protocol["allRequiredSpansPresent"])
            self.assertIsNone(episode["providerTokenFeasible"])

    def test_absence_report_does_not_claim_model_abstention(self):
        for episode in rows(self.warm):
            if not episode["answerable"]:
                raw = episode["protocols"]["raw_source_probe"]
                self.assertEqual(raw["literalSourceIDs"], [])
                self.assertEqual(raw["lexicalSourceIDs"], [])
                self.assertFalse(raw["allRequiredSpansPresent"])
                self.assertIsNone(episode["taskScore"])

    def test_known_probe_caps_and_unknown_provider_cost(self):
        for episode in rows(self.warm):
            accounting = episode["protocols"]["raw_source_probe"]["accounting"]
            self.assertLessEqual(accounting["memoryServiceCalls"], 24)
            self.assertLessEqual(accounting["returnedSourceBytes"], 12000)
            self.assertEqual(accounting["modelCalls"], 0)
            self.assertIsNone(accounting["billedCost"])
            self.assertIsNone(accounting["rawSourceScanBytes"])
            for name, protocol in episode["protocols"].items():
                if name != "raw_source_probe":
                    self.assertLessEqual(protocol["serializedContextBytes"], 65536)

    def test_metadata_report_omits_fixture_text(self):
        output = canonical_json(self.warm).decode()
        for history in self.fixtures["histories"]:
            for source in history["events"]:
                self.assertNotIn(source["text"], output)
            for episode in history["episodes"]:
                self.assertNotIn(episode["prompt"], output)

    def test_actual_gui_helper_source_references_and_separate_oracle_timing(self):
        for episode in rows(self.warm):
            gui = episode["protocols"]["gui_lexical_anyterm"]
            self.assertEqual(gui["terminalStatus"], "selected")
            self.assertEqual(len(gui["recentSourceIDs"]), gui["recentMessages"])
            self.assertTrue(gui["sourceReferencesResolvable"])
            for protocol in episode["protocols"].values():
                self.assertGreaterEqual(protocol["oracleScoringMilliseconds"], 0)

    def test_compile_dependency_closure_is_copied_and_hashed(self):
        hashes = self.implementation["sourceSHA256"]
        self.assertEqual(set(hashes), set(CORE_FILES) | set(PYTHON_FILES))
        for relative, expected in hashes.items():
            captured = self.scratch / "source" / relative
            self.assertEqual(hashlib.sha256(captured.read_bytes()).hexdigest(), expected)
        for dependency in ("EpisodeBudget.swift", "EpisodeLease.swift", "EpisodeSQLFence.swift", "MeteredRetrieval.swift"):
            self.assertIn("Sources/Boros/" + dependency, hashes)

    def test_registered_runner_preserves_historical_source_pin_refusal(self):
        destination = self.scratch / "refused-registered-manifest.json"
        historical = PROTOCOL_AMENDMENT.read_bytes()
        process = subprocess.run(["python3", str(ROOT / "scripts/evaluate_retrieval.py"),
            "--history-count", "1", "--profile", "warm", "--output", str(destination)],
            capture_output=True, text=True, timeout=30)
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("Frozen v4 evaluation implementation changed", process.stderr)
        self.assertFalse(destination.exists())
        self.assertEqual(PROTOCOL_AMENDMENT.read_bytes(), historical)

    def test_contract_runner_emits_unregistered_manifest_and_implementation_hashes(self):
        destination = self.scratch / "manifest-contract.json"
        process = subprocess.run(["python3", str(ROOT / "scripts/evaluate_retrieval.py"),
            "--contract-only", "--history-count", "1", "--profile", "warm", "--output", str(destination)],
            capture_output=True, text=True, timeout=30)
        self.assertEqual(process.returncode, 0, "synthetic manifest runner failed")
        report = json.loads(destination.read_text())
        schema = json.loads((ROOT / "Tests/fixtures/evaluation/run-manifest-schema-v4.json").read_text())
        self.assertNotIn("reportSchemaVersion", report)
        self.assertNotIn("protocolAmendmentSHA256", report)
        self.assertEqual(report["contractReportSchemaVersion"], 1)
        self.assertEqual(report["executionMode"], "contract-only-current-source")
        self.assertEqual(report["registrationStatus"], "unregistered")
        self.assertIs(report["registeredProtocolApplied"], False)
        self.assertEqual(report["comparisonUse"], "prohibited")
        self.assertTrue(re.fullmatch(r"[0-9a-f]{64}", report["historicalPreregistrationSHA256"]))
        self.assertTrue(re.fullmatch(r"[0-9a-f]{64}", report["historicalProtocolAmendmentSHA256"]))
        self.assertEqual(set(report["fixtureSet"]), set(schema["properties"]["fixtureSet"]["required"]))
        self.assertEqual(set(report["hardware"]), set(schema["properties"]["hardware"]["required"]))
        self.assertEqual(report["hardware"]["concurrency"], 1)
        self.assertEqual(report["hardware"]["providerRequests"], 0)
        hashes = report["implementation"]["sourceSHA256"]
        self.assertTrue(all(re.fullmatch(r"[0-9a-f]{64}", value) for value in hashes.values()))
        for name in (*CORE_FILES, *PYTHON_FILES):
            self.assertIn(name, hashes)
        for profile in report["profiles"].values():
            self.assertNotIn("summary", profile)
            for episode in rows(profile["report"]):
                self.assertIsNone(episode["taskScore"])
                self.assertIsNone(episode["providerTokenFeasible"])

    def test_contract_only_scope_is_bounded_and_nondevelopment_runs_remain_blocked(self):
        for arguments in ([], ["--history-count", "3"], ["--history-count", "1", "--scale-events", "1000"],
                          ["--history-count", "1", "--split", "validation"],
                          ["--history-count", "1", "--split", "held-out"]):
            with self.subTest(arguments=arguments):
                process = subprocess.run(["python3", str(ROOT / "scripts/evaluate_retrieval.py"),
                    "--contract-only", *arguments], capture_output=True, text=True, timeout=30)
                self.assertNotEqual(process.returncode, 0)
                self.assertIn("contract-only mode requires", process.stderr)

    def test_contract_only_output_cannot_replace_existing_evidence(self):
        destination = self.scratch / "preserved-evidence.json"
        original = b'{"reportSchemaVersion":4,"syntheticSentinel":true}\n'
        destination.write_bytes(original)
        process = subprocess.run(["python3", str(ROOT / "scripts/evaluate_retrieval.py"),
            "--contract-only", "--history-count", "1", "--output", str(destination)],
            capture_output=True, text=True, timeout=30)
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("contract-only output already exists", process.stderr)
        self.assertEqual(destination.read_bytes(), original)


if __name__ == "__main__":
    unittest.main(verbosity=2)
