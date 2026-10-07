#!/usr/bin/env python3
"""Synthetic contracts; no private corpus, model, credential or provider calls."""
import copy
import json
import unittest

import orientation_zoom as o


def records(sessions=None):
    sessions = sessions or [
        [("user", "Where is the crimson compass?"), ("assistant", "The crimson compass is in the north drawer.")],
        [("user", "Update the cobalt schedule."), ("assistant", "The cobalt appointment moved to Thursday.")],
        [("user", "What about the crimson compass?"), ("assistant", "It moved to the south shelf; keep that later correction.")],
    ]
    return [{"event_id": f"synthetic-s{si}-m{ti}", "original_session_id": f"synthetic-session-{si}",
        "role": role, "status": "complete", "session_index": si, "turn_index": ti,
        "content": content, "source_time": {"original_value": f"synthetic-date-{si}", "locator": f"/sessions/{si}"}}
        for si, session in enumerate(sessions) for ti, (role, content) in enumerate(session)]


def orientation(history):
    return {"regions": [{"region_id": region_id, "summary": "Synthetic navigation only.",
        "source_ids": region["source_ids"][:1]} for region_id, region in history.regions.items()]}


class Contracts(unittest.TestCase):
    def setUp(self):
        self.history = o.History(records())
        self.addCleanup(self.history.close)

    def test_whole_history_coverage_preserves_exact_unicode_originals_and_dates(self):
        source = records([[('assistant', 'Leading evidence α🙂'), ('user', 'Literal </think> μ'),
            ('assistant', 'Exact bytes café, no normalization.')], [('user', 'Second session'), ('assistant', 'Reply')]])
        history = o.History(source); self.addCleanup(history.close)
        body = o.strict_json(history.orientation_messages()[1]["content"])
        self.assertEqual([row for region in body["regions"] for row in region["records"]], source)
        manifest = history.manifest()
        self.assertEqual(manifest["source_records"], len(source))
        self.assertEqual([event_id for region in manifest["regions"] for event_id in region["source_ids"]],
            [row["event_id"] for row in source])
        self.assertEqual(manifest["source_sha256"], o.digest(o.canonical(source)))
        self.assertEqual(len(history.blocks), 3)

    def test_source_order_identity_status_and_annotation_contamination_fail_closed(self):
        mutations = [lambda rows: rows[0].update(has_answer=True),
            lambda rows: rows[0].update(status='partial'),
            lambda rows: rows[0].update(session_index=1),
            lambda rows: rows[1].update(turn_index=2),
            lambda rows: rows[1].update(event_id=rows[0]['event_id']),
            lambda rows: rows[1].update(original_session_id='other-session'),
            lambda rows: rows[2].update(original_session_id=rows[0]['original_session_id'])]
        for mutation in mutations:
            rows = records(); mutation(rows)
            with self.assertRaises(o.ExperimentError):
                o.History(rows)

    def test_source_caller_mutation_cannot_change_indexed_originals(self):
        rows = records(); history = o.History(rows); self.addCleanup(history.close)
        original = history.source_sha256
        rows[0]['content'] = 'Caller mutation'
        rows[0]['source_time']['original_value'] = 'Caller date mutation'
        self.assertEqual(history.source_sha256, original)
        self.assertEqual(history.records[0]['content'], 'Where is the crimson compass?')
        self.assertEqual(history.records[0]['source_time']['original_value'], 'synthetic-date-0')

    def test_orientation_exact_inventory_source_links_and_character_cap(self):
        view = orientation(self.history)
        validated = self.history.parse_orientation(o.canonical(view))
        self.assertEqual(validated['receipt']['region_count'], 3)
        self.assertEqual(validated['receipt']['source_records_covered'], 6)
        # The limit is Unicode characters, not bytes.
        view['regions'][0]['summary'] = 'μ' * 240
        self.history.parse_orientation(o.canonical(view))
        mutations = [lambda value: value['regions'].pop(),
            lambda value: value['regions'].append(copy.deepcopy(value['regions'][0])),
            lambda value: value['regions'][0].update(summary='μ' * 241),
            lambda value: value['regions'][0].update(source_ids=['synthetic-s1-m0']),
            lambda value: value['regions'][0].update(source_ids=['unknown']),
            lambda value: value['regions'][0].update(source_ids=['synthetic-s0-m0'] * 2),
            lambda value: value.update(reference='Forbidden extra field')]
        for mutation in mutations:
            bad = orientation(self.history); mutation(bad)
            with self.assertRaises(o.ExperimentError):
                self.history.parse_orientation(o.canonical(bad))

    def test_orientation_request_is_question_blind_and_has_only_original_fields(self):
        body = o.strict_json(self.history.orientation_messages()[1]['content'])
        self.assertEqual(set(body), {'regions'})
        for region in body['regions']:
            self.assertEqual(set(region), {'region_id', 'records'})
            self.assertTrue(all(set(row) == o.RECORD_KEYS for row in region['records']))

    def test_quoted_anchors_round_robin_precede_prompt_terms(self):
        terms = o.literal_terms('Please explain ordinary text "crimson compass north" and `cobalt schedule` now.')
        self.assertEqual(terms[:5], ['crimson', 'cobalt', 'compass', 'schedule', 'north'])
        self.assertEqual(len(terms), 8)
        self.assertEqual(o.literal_terms('the and is what'), [])

    def test_fts_syntax_is_literal_and_search_returns_complete_exchanges(self):
        history = o.History(records([[('user', 'NEAR operator is literal here.'), ('assistant', 'Operator reply.')],
            [('user', 'Unrelated record'), ('assistant', 'Unrelated reply')]]))
        self.addCleanup(history.close)
        selected = history.baseline('NEAR OR "NEAR" * :')
        self.assertEqual([row['event_id'] for row in selected['evidence']], ['synthetic-s0-m0', 'synthetic-s0-m1'])
        self.assertEqual(selected['receipt']['source_records'], 2)
        self.assertEqual(selected['receipt']['sources'][0]['offset'], 0)
        self.assertEqual(selected['receipt']['sources'][0]['content_sha256'], o.digest(history.records[0]['content'].encode()))

    def test_whole_index_reaches_last_session_and_bm25_ties_prefer_latest(self):
        sessions = [[('user', 'Equivalent amber needle.'), ('assistant', 'Equivalent reply.')] for _ in range(70)]
        sessions[-1] = [('user', 'Unique ultraviolet tail.'), ('assistant', 'Tail answer.')]
        history = o.History(records(sessions)); self.addCleanup(history.close)
        tail = history.baseline('ultraviolet')
        self.assertEqual([row['session_index'] for row in tail['evidence']], [69, 69])
        ties = history.baseline('amber')
        self.assertEqual(ties['accepted_block_ids'][0], 'r0068-b0000')
        self.assertEqual(ties['receipt']['candidates'], 64)

    def test_byte_budget_never_delivers_half_exchange_or_half_utf8(self):
        history = o.History(records([[('user', 'needle ' + 'μ' * 50), ('assistant', 'Oversized answer')],
            [('user', 'needle'), ('assistant', 'Fits')]]))
        self.addCleanup(history.close)
        packed = history.pack_blocks(['r0000-b0000', 'r0001-b0000'], maximum_bytes=10)
        self.assertEqual(packed['accepted_block_ids'], ['r0001-b0000'])
        self.assertEqual(packed['remaining_block_ids'], ['r0000-b0000'])
        self.assertEqual([row['content'] for row in packed['evidence']], ['needle', 'Fits'])
        self.assertEqual(packed['content_bytes'], 10)

    def test_actual_token_guard_receives_complete_original_candidate_units(self):
        admitted_sizes = []
        def fits(rows):
            admitted_sizes.append(len(rows))
            self.assertTrue(all(set(row) == o.RECORD_KEYS for row in rows))
            return len(rows) <= 2
        selected = self.history.pack_blocks(list(self.history.blocks), token_fits=fits)
        self.assertEqual(admitted_sizes, [2, 4, 4])
        self.assertEqual(len(selected['evidence']), 2)
        with self.assertRaises(o.ExperimentError):
            self.history.pack_blocks(list(self.history.blocks), token_fits=lambda _: 1)

    def test_zoom_preserves_exact_original_session_and_reports_remaining_blocks(self):
        history = o.History(records([[('user', 'First'), ('assistant', 'Reply'),
            ('user', 'Later'), ('assistant', 'Other')]]))
        self.addCleanup(history.close)
        action = {'action': 'zoom', 'query': '', 'region_id': 'r0000'}
        limited = history.execute(action, [], maximum_bytes=10)
        self.assertEqual(limited['tool_result']['coverage'], 'allowance_limited')
        self.assertEqual(limited['tool_result']['remaining_region_ids'], ['r0000-b0001'])
        self.assertEqual(limited['tool_result']['records'], history.records[:2])
        narrowed = history.execute({'action': 'zoom', 'query': '', 'region_id': 'r0000-b0001'},
            limited['evidence'], maximum_bytes=20)
        self.assertEqual(narrowed['evidence'], history.records)
        self.assertEqual(narrowed['tool_result']['records'], history.records[2:])
        self.assertEqual(narrowed['tool_result']['coverage'], 'complete')

    def test_existing_evidence_is_retained_and_untrusted_or_partial_rows_are_rejected(self):
        initial = self.history.pack_blocks(['r0000-b0000'])['evidence']
        searched = self.history.execute({'action': 'search', 'query': 'cobalt', 'region_id': ''}, initial)
        self.assertTrue(set(row['event_id'] for row in initial).issubset(row['event_id'] for row in searched['evidence']))
        for evidence in (initial[:1], initial + initial, [{**initial[0], 'content': 'Tampered'}, initial[1]]):
            with self.assertRaises(o.ExperimentError):
                self.history.execute({'action': 'finish', 'query': '', 'region_id': ''}, evidence)
        with self.assertRaises(o.ExperimentError):
            self.history.execute({'action': 'zoom', 'query': '', 'region_id': 'r9999'}, initial)
        limited = self.history.execute({'action': 'search', 'query': 'cobalt', 'region_id': ''}, initial, maximum_bytes=1)
        self.assertEqual(limited['evidence'], [])
        self.assertEqual(limited['evicted_block_ids'], ['r0000-b0000'])

    def test_new_tool_evidence_can_displace_a_full_initial_pack_with_explicit_receipt(self):
        history = o.History(records([[('user', 'First'), ('assistant', 'Reply')],
            [('user', 'Later'), ('assistant', 'Other')]]))
        self.addCleanup(history.close)
        initial = history.pack_blocks(['r0000-b0000'], maximum_bytes=10)['evidence']
        zoomed = history.execute({'action': 'zoom', 'query': '', 'region_id': 'r0001'}, initial, maximum_bytes=10)
        self.assertEqual(zoomed['evidence'], history.records[2:])
        self.assertEqual(zoomed['evicted_block_ids'], ['r0000-b0000'])
        self.assertEqual(zoomed['receipt']['evicted_block_ids'], ['r0000-b0000'])
        self.assertEqual(zoomed['tool_result']['records'], history.records[2:])

    def test_recent_exclusions_apply_before_candidate_limit_and_union_preserves_originals(self):
        history = o.History(records([[('user', 'Shared needle'), ('assistant', 'Reply')] for _ in range(70)]))
        self.addCleanup(history.close)
        excluded = [row['event_id'] for row in history.records[12:]]
        selected = history.baseline('needle', excluded_ids=excluded)
        self.assertEqual(selected['receipt']['candidates'], 6)
        self.assertEqual(selected['evidence'], history.records[:12])
        self.assertEqual(history.block_source_ids('synthetic-s0-m1'), ['synthetic-s0-m0', 'synthetic-s0-m1'])
        self.assertEqual(history.union(history.records[:2], history.records[:4], history.records[2:4]), history.records[:4])
        with self.assertRaises(o.ExperimentError):
            history.union(history.records[:1])
        with self.assertRaises(o.ExperimentError):
            history.baseline('needle', excluded_ids=['unknown'])

    def test_prior_tool_results_show_only_metadata_and_originals_appear_once(self):
        selected = self.history.execute({'action': 'zoom', 'query': '', 'region_id': 'r0000'}, [])
        messages = self.history.action_messages('Synthetic question', 'synthetic-date', selected['evidence'],
            tool_results=[selected['tool_result']])
        data = o.strict_json(messages[1]['content'])
        self.assertEqual(data['prior_tool_results'][0]['returned_source_ids'], ['synthetic-s0-m0', 'synthetic-s0-m1'])
        self.assertNotIn('records', data['prior_tool_results'][0])
        self.assertEqual(messages[1]['content'].count(self.history.records[0]['content']), 1)
        with self.assertRaises(o.ExperimentError):
            self.history.action_messages('Synthetic question', 'synthetic-date', selected['evidence'],
                tool_results=[selected['tool_result']] * 3)

    def test_action_shape_and_unknown_or_conflicting_actions_fail_closed(self):
        self.assertEqual(o.parse_action('{"action":"search","query":"compass","region_id":""}')['action'], 'search')
        bad = [b'{"action":"finish","action":"search","query":"","region_id":""}',
            '{"action":"shell","query":"compass","region_id":""}',
            '{"action":"finish","query":"compass","region_id":""}',
            '{"action":"zoom","query":"compass","region_id":"r0000"}',
            '{"action":"search","query":"the and is","region_id":""}',
            '{"action":"finish","query":"","region_id":"","reference":"extra"}',
            '```json {"action":"finish","query":"","region_id":""} ```']
        for content in bad:
            with self.assertRaises(o.ExperimentError):
                o.parse_action(content)

    def test_final_reader_has_identical_framing_and_no_navigation_summary(self):
        selected = self.history.baseline('compass')['evidence']
        final = self.history.final_messages('Where is it now?', 'synthetic-question-date', selected)
        navigation = self.history.action_messages('Where is it now?', 'synthetic-question-date', selected,
            orientation=orientation(self.history))
        self.assertEqual(final[0], {'role': 'system', 'content': o.SYSTEM})
        self.assertEqual(o.strict_json(final[1]['content'].split('\n', 1)[1]), selected)
        self.assertNotIn('Synthetic navigation only.', o.canonical(final).decode())
        self.assertIn('Synthetic navigation only.', o.canonical(navigation).decode())
        self.assertNotIn('reference', o.strict_json(navigation[1]['content']))

    def test_strict_json_refuses_duplicate_and_nonfinite_fields(self):
        for content in ('{"x":1,"x":2}', '{"x":NaN}', '{"x":Infinity}'):
            with self.assertRaises(o.ExperimentError):
                o.strict_json(content)


if __name__ == '__main__':
    unittest.main()
