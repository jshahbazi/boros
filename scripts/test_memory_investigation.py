#!/usr/bin/env python3
"""Synthetic scripted-provider contracts, never a model evaluation."""
import copy
import json
import unittest
from dataclasses import replace

from history_navigation import NavigationHistory
from memory_investigation import (MemoryInvestigation, InvestigationLimits, parse_plan,
                                  validate_extraction, ExperimentError)


def sources():
    sessions = [[("user", "Where is the crimson compass?"), ("assistant", "The compass is in the north drawer.")],
                [("user", "I changed the compass location."), ("assistant", "It is now on the south shelf.")],
                [("user", "Today is rainy."), ("assistant", "Take an umbrella.")]]
    return [{"event_id": f"private_abs_{si}_{ti}", "original_session_id": f"private_abs_session_{si}",
             "role": role, "status": "complete", "session_index": si, "turn_index": ti,
             "content": text, "source_time": {"original_value": f"2026-09-{si + 1:02d}",
                                                "locator": f"/private_abs/{si}/{ti}"}}
            for si, session in enumerate(sessions) for ti, (role, text) in enumerate(session)]


def plan(action="finish", query="", region_id="", cursor=None, pins=(), missing=(), time_filter=None):
    return json.dumps({"action": action, "query": query, "region_id": region_id, "cursor": cursor,
                       "time_filter": time_filter, "pin_block_ids": list(pins), "missing_facts": list(missing)})


class ScriptedProvider:
    def __init__(self, plans=None, extraction=None, count=None, failure=None):
        self.plans = list(plans or [plan()])
        self.extraction = extraction
        self.count_fn = count or (lambda messages: max(1, len(json.dumps(messages)) // 4))
        self.failure = failure
        self.requests = []
        self.count_requests = []

    def count(self, messages):
        self.count_requests.append(copy.deepcopy(messages))
        if self.failure == "count":
            raise RuntimeError("Sensitive provider error must not escape")
        return self.count_fn(messages)

    def generate(self, stage, messages, output_limit):
        self.requests.append((stage, copy.deepcopy(messages), output_limit))
        if self.failure == stage:
            raise RuntimeError("Sensitive provider error must not escape")
        if stage.startswith("plan_"):
            return self.plans.pop(0)
        data = json.loads(messages[-1]["content"])
        if stage == "extract":
            if self.extraction is not None:
                return json.dumps(self.extraction)
            rows = [row for row in data["original_records"] if "south shelf" in row["content"]]
            facts = [{"claim": "The assistant states the later location is the south shelf.",
                      "source_ids": [rows[0]["event_id"]],
                      "quotes": [{"source_id": rows[0]["event_id"], "text": "south shelf"}]}] if rows else []
            return json.dumps({"facts": facts, "unresolved": []})
        return "The later recorded location is the south shelf. [e000003]"


class InvestigationTests(unittest.TestCase):
    def setUp(self):
        self.history = NavigationHistory(sources())
        self.addCleanup(self.history.close)

    def test_orientation_precedes_deliberate_search_then_extract_then_answer(self):
        provider = ScriptedProvider([plan("search", "compass"), plan()])
        engine = MemoryInvestigation(self.history, provider, replace(InvestigationLimits(), recent_bytes=1))
        result = engine.run("Where is the compass now?", "2026-09-10")
        self.assertEqual([row[0] for row in provider.requests], ["plan_0", "plan_1", "extract", "answer"])
        first = json.loads(provider.requests[0][1][1]["content"])
        self.assertIn("history_map", first)
        self.assertEqual(first["history_map"]["header"]["source_records"], 6)
        self.assertEqual(result["receipt"]["termination"], "finished")
        self.assertEqual(result["receipt"]["tool_actions"], 1)
        self.assertFalse(result["receipt"]["extraction_semantics_validated"])
        final = json.loads(provider.requests[-1][1][1]["content"])
        self.assertNotIn("history_map", final)
        self.assertNotIn("tool_history", final)
        self.assertIn("south shelf", final["derived_extraction"]["facts"][0]["quotes"][0]["text"])

    def test_identifiers_and_locators_do_not_cross_any_model_boundary(self):
        provider = ScriptedProvider()
        result = MemoryInvestigation(self.history, provider).run("Where is the compass?", "2026-09-10")
        all_model_bytes = json.dumps(provider.requests + provider.count_requests)
        self.assertNotIn("private_abs", all_model_bytes)
        self.assertNotIn("locator", all_model_bytes)
        self.assertEqual(self.history.host_original_ids(["e000003"]), ["private_abs_1_1"])
        self.assertEqual(result["receipt"]["generation_calls"], 3)

    def test_unresolved_evidence_reaches_final_even_when_extractor_omits_it(self):
        provider = ScriptedProvider([plan(missing=["The date of the last move."])])
        result = MemoryInvestigation(self.history, provider).run("When did it move?", "")
        final = json.loads(provider.requests[-1][1][1]["content"])
        self.assertEqual(final["unresolved_facts"], ["The date of the last move."])
        self.assertEqual(result["receipt"]["termination"], "finished_with_gaps")
        self.assertFalse(final["search_coverage_is_exhaustive"])

    def test_tool_limit_is_visible_to_final_reader(self):
        provider = ScriptedProvider([plan("search", "compass"), plan("search", "location")])
        limits = replace(InvestigationLimits(), max_actions=1)
        result = MemoryInvestigation(self.history, provider, limits).run("Where?", "")
        self.assertEqual(result["receipt"]["termination"], "action_limit")
        final = json.loads(provider.requests[-1][1][1]["content"])
        self.assertEqual(final["investigation_termination"], "action_limit")
        self.assertEqual(result["receipt"]["tool_actions"], 1)

    def test_repeated_ineffective_action_stops_without_retry(self):
        provider = ScriptedProvider([plan("search", "nonexistent"), plan("search", "nonexistent")])
        result = MemoryInvestigation(self.history, provider).run("Where?", "")
        self.assertEqual(result["receipt"]["termination"], "no_progress")
        self.assertEqual(result["receipt"]["tool_actions"], 1)

    def test_provider_generation_failure_holds_reservation_and_fences(self):
        provider = ScriptedProvider(failure="plan_0")
        engine = MemoryInvestigation(self.history, provider)
        with self.assertRaisesRegex(ExperimentError, "^provider_generation_failed$"):
            engine.run("Where?", "")
        self.assertEqual(engine.generation_calls, 1)
        self.assertGreater(engine.reserved_input, 0)
        self.assertEqual(engine.reserved_output, 1024)
        self.assertFalse(engine.model_receipts[0]["completed"])
        with self.assertRaises(ExperimentError):
            engine._count([{"role": "user", "content": "Later"}])
        self.assertEqual(len(provider.requests), 1)

    def test_count_failure_is_content_free_and_dispatches_nothing(self):
        provider = ScriptedProvider(failure="count")
        engine = MemoryInvestigation(self.history, provider)
        with self.assertRaisesRegex(ExperimentError, "^provider_count_failed$"):
            engine.run("Where?", "")
        self.assertEqual(provider.requests, [])

    def test_invalid_or_unselected_extraction_aborts_before_final_answer(self):
        for extraction in [
            {"facts": [{"claim": "A claim", "source_ids": ["unknown"],
                        "quotes": [{"source_id": "unknown", "text": "south shelf"}]}], "unresolved": []},
            {"facts": [{"claim": "A claim", "source_ids": ["e000003"],
                        "quotes": [{"source_id": "e000003", "text": "fabricated quote"}]}], "unresolved": []},
        ]:
            provider = ScriptedProvider(extraction=extraction)
            engine = MemoryInvestigation(self.history, provider)
            with self.assertRaises(ExperimentError):
                engine.run("Where?", "")
            self.assertNotIn("answer", [request[0] for request in provider.requests])
            self.assertTrue(engine.failed)

    def test_every_cited_extraction_source_needs_an_exact_quote(self):
        rows = self.history.model_records
        value = {"facts": [{"claim": "Both sources", "source_ids": ["e000002", "e000003"],
                           "quotes": [{"source_id": "e000003", "text": "south shelf"}]}], "unresolved": []}
        with self.assertRaisesRegex(ExperimentError, "extraction_quote_coverage_invalid"):
            validate_extraction(json.dumps(value), self.history, rows)

    def test_undelivered_pin_fails_without_tools_or_final_dispatch(self):
        provider = ScriptedProvider([plan(pins=["b999999"])])
        with self.assertRaisesRegex(ExperimentError, "pin_not_delivered"):
            MemoryInvestigation(self.history, provider).run("Where?", "")
        self.assertEqual(len(provider.requests), 1)

    def test_actual_count_caps_precede_dispatch(self):
        provider = ScriptedProvider(count=lambda _: 25000)
        with self.assertRaises(ExperimentError):
            MemoryInvestigation(self.history, provider).run("Where?", "")
        self.assertEqual(provider.requests, [])

    def test_complete_request_fitting_removes_whole_unpinned_exchanges(self):
        def count(messages):
            if messages[0]["role"] == "system":
                data = json.loads(messages[-1]["content"])
                return 2500 if len(data["original_records"]) > 2 else 500
            return 100
        provider = ScriptedProvider(count=count)
        result = MemoryInvestigation(self.history, provider,
            replace(InvestigationLimits(), input_tokens=2000)).run("Where?", "")
        self.assertEqual(len(result["evidence"]), 2)
        self.history.validate_evidence(result["evidence"])
        self.assertTrue(result["receipt"]["request_reductions"])
        self.assertTrue(all(row["input_tokens"] <= 2000 for row in result["receipt"]["model_requests"]))
        for stage, messages, _ in provider.requests:
            data = json.loads(messages[-1]["content"])
            receipt = next(row for row in result["receipt"]["model_requests"] if row["stage"] == stage)
            self.assertEqual(receipt["prepared_source_ids"], [row["event_id"] for row in data["original_records"]])

    def test_custom_query_cursor_survives_changed_recent_exclusions(self):
        rows = sources()
        # Six exchanges, only the initial recent pair is excluded. A later
        # complete-request reduction changes that selection before continuation.
        for si in range(3, 6):
            for ti, (role, text) in enumerate([("user", "Crimson compass update"), ("assistant", "Still a compass.")]):
                rows.append({**rows[0], "event_id": f"opaque_source_{si}_{ti}", "original_session_id": f"opaque_session_{si}",
                             "session_index": si, "turn_index": ti, "role": role, "content": text})
        history = NavigationHistory(rows)
        self.addCleanup(history.close)
        class CursorProvider(ScriptedProvider):
            def generate(self, stage, messages, output_limit):
                if stage == "plan_0":
                    self.requests.append((stage, copy.deepcopy(messages), output_limit))
                    return plan("search", "crimson")
                if stage == "plan_1":
                    self.requests.append((stage, copy.deepcopy(messages), output_limit))
                    data = json.loads(messages[-1]["content"])
                    previous = data["tool_history"][-1]
                    assert previous["query"] == "crimson"
                    return plan("search", previous["query"], cursor=previous["next_cursor"])
                if stage == "plan_2":
                    self.requests.append((stage, copy.deepcopy(messages), output_limit))
                    return plan()
                return super().generate(stage, messages, output_limit)
        def count(messages):
            if messages[0]["role"] == "system":
                data = json.loads(messages[-1]["content"])
                # Force reduction AFTER a custom cursor has been issued.
                if "tool_history" in data and len(data["tool_history"]) >= 2:
                    return 2500 if data["original_records"] else 500
            return 100
        provider = CursorProvider(count=count)
        limits = replace(InvestigationLimits(), input_tokens=2000, page_size=1, recent_bytes=45)
        result = MemoryInvestigation(history, provider, limits).run("Crimson compass", "")
        self.assertEqual(result["receipt"]["termination"], "finished")
        self.assertEqual(result["receipt"]["tool_actions"], 2)
        self.assertTrue(any(row["component"] == "recent" for row in result["receipt"]["request_reductions"]))
        self.assertEqual(result["trace"][1]["query"], result["trace"][2]["query"])
        self.assertNotEqual(result["trace"][1]["receipt"]["candidate_offset"],
                            result["trace"][2]["receipt"]["candidate_offset"])

    def test_interrupt_fences_reusable_engine(self):
        provider = ScriptedProvider()
        def interrupted(*_):
            raise KeyboardInterrupt()
        provider.generate = interrupted
        engine = MemoryInvestigation(self.history, provider)
        with self.assertRaises(KeyboardInterrupt):
            engine.run("Compass", "")
        self.assertTrue(engine.failed)
        self.assertEqual(engine.reserved_output, 1024)

    def test_large_initial_question_can_be_reformulated_without_prefix_truncation(self):
        provider = ScriptedProvider([plan("search", "compass"), plan()])
        question = " ".join("syntheticword" + str(index) for index in range(300))
        result = MemoryInvestigation(self.history, provider).run(question, "")
        self.assertEqual(result["trace"][0]["receipt"]["reason"], "query_term_bound_exceeded")
        self.assertEqual(result["receipt"]["termination"], "finished")

    def test_final_fitting_cannot_evict_sources_referenced_by_extracted_facts(self):
        facts = [{"claim": "Recorded text", "source_ids": [row["event_id"]],
                  "quotes": [{"source_id": row["event_id"], "text": row["content"]}]}
                 for row in self.history.model_records]
        def count(messages):
            if messages[0]["role"] == "system":
                data = json.loads(messages[-1]["content"])
                return 2500 if "derived_extraction" in data else 500
            return 100
        provider = ScriptedProvider(extraction={"facts": facts, "unresolved": []}, count=count)
        engine = MemoryInvestigation(self.history, provider, replace(InvestigationLimits(), input_tokens=2000))
        with self.assertRaisesRegex(ExperimentError, "mandatory_request_budget_exceeded"):
            engine.run("Where?", "")
        self.assertEqual([row[0] for row in provider.requests], ["plan_0", "extract"])

    def test_aggregate_generation_reservations_precede_dispatch(self):
        provider = ScriptedProvider()
        limits = replace(InvestigationLimits(), reserved_output_tokens=1)
        with self.assertRaisesRegex(ExperimentError, "generation_budget_exhausted"):
            MemoryInvestigation(self.history, provider, limits).run("Where?", "")
        self.assertEqual(provider.requests, [])

    def test_cancellation_before_any_model_or_count_call(self):
        provider = ScriptedProvider()
        engine = MemoryInvestigation(self.history, provider, cancelled=lambda: True)
        with self.assertRaisesRegex(ExperimentError, "investigation_cancelled"):
            engine.run("Where?", "")
        self.assertFalse(provider.count_requests)
        self.assertFalse(provider.requests)

    def test_duplicate_json_keys_extra_fields_and_invalid_actions_rejected(self):
        raw = plan()
        for bad in [raw[:-1] + ',"action":"search"}', json.dumps({**json.loads(raw), "reference": "Forbidden"}),
                    plan("search"), plan("zoom"), plan("finish", query="unwanted")]:
            with self.assertRaises(ExperimentError):
                parse_plan(bad)

    def test_engine_single_use_and_limits_are_strict(self):
        engine = MemoryInvestigation(self.history, ScriptedProvider())
        engine.run("Where?", "")
        with self.assertRaisesRegex(ExperimentError, "investigation_already_started"):
            engine.run("Where?", "")
        for limits in [replace(InvestigationLimits(), max_actions=True),
                       replace(InvestigationLimits(), input_tokens=32768),
                       replace(InvestigationLimits(), page_size=129)]:
            with self.assertRaisesRegex(ExperimentError, "limits_invalid"):
                MemoryInvestigation(self.history, ScriptedProvider(), limits)


if __name__ == "__main__":
    unittest.main()
