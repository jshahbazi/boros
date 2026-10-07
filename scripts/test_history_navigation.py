#!/usr/bin/env python3
"""Synthetic navigation contracts; no private histories or model execution."""
import copy
import unittest

import history_navigation as n
import orientation_zoom as o


def records(sessions=None, dates=None):
    sessions = sessions if sessions is not None else [
        [("user", "Where is the crimson compass?"), ("assistant", "The compass is in the north drawer.")],
        [("user", "Update the cobalt schedule."), ("assistant", "The appointment moved to Thursday.")],
        [("user", "The crimson compass moved."), ("assistant", "It is now on the south shelf.")],
    ]
    dates = dates if dates is not None else [f"2024-01-{index + 1:02d}" for index in range(len(sessions))]
    return [{"event_id": f"private-label_abs-event-{si}-{ti}",
        "original_session_id": f"private-label_abs-session-{si}",
        "role": role, "status": "complete", "session_index": si, "turn_index": ti,
        "content": content, "source_time": {"original_value": dates[si],
            "locator": f"/private-label_abs-session-{si}/records/{ti}",
            "untrusted_annotation": "private-label_abs"} if dates[si] is not None else None}
        for si, session in enumerate(sessions) for ti, (role, content) in enumerate(session)]


class Contracts(unittest.TestCase):
    def history(self, rows=None):
        history = n.NavigationHistory(records() if rows is None else rows)
        self.addCleanup(history.close)
        return history

    def error(self, code, call):
        with self.assertRaises(n.NavigationError) as caught:
            call()
        self.assertEqual(str(caught.exception), code)

    def test_opaque_identity_mapping_precedes_every_public_projection(self):
        source = records()
        history = self.history(source)
        values = [history.model_records, history.overview(), history.search("crimson"),
            history.zoom("s000000"), history.manifest(), history.blocks, history.regions]
        for value in values:
            self.assertNotIn("private-label", o.canonical(value).decode())
        self.assertEqual(history.model_records[0]["event_id"], "e000000")
        self.assertEqual(history.model_records[0]["original_session_id"], "s000000")
        self.assertEqual(history.model_records[0]["source_time"], {"original_value": "2024-01-01"})
        self.assertEqual(history.host_original_ids(["e000000"]), [source[0]["event_id"]])
        self.assertEqual(history.source_sha256, o.digest(o.canonical(source)))

    def test_unicode_raw_content_and_literal_source_dates_are_preserved(self):
        source = records([[('user', 'café e\u0301 日本語 μ🙂'), ('assistant', 'Literal </think> α')]],
            dates=['2024/03/17 (Sun) 10:04'])
        history = self.history(source)
        projected = history.model_records
        self.assertTrue(all(a['content'].encode() == b['content'].encode() for a, b in zip(source, projected)))
        self.assertEqual(history.overview()['header']['available_dates'], ['2024/03/17 (Sun) 10:04'])
        self.assertEqual(history.search('cafe')['evidence'], projected)

    def test_all_allowlisted_original_fields_are_required_and_labels_are_rejected(self):
        for mutate in [lambda rows: rows[0].update(has_answer=True),
            lambda rows: rows[0].pop('source_time'), lambda rows: rows[0].update(status='partial'),
            lambda rows: rows[0].update(turn_index=2),
            lambda rows: rows[1].update(event_id=rows[0]['event_id'])]:
            source = records(); mutate(source)
            with self.assertRaises(n.NavigationError):
                self.history(source)

    def test_public_and_caller_mutation_cannot_change_frozen_originals(self):
        source = records(); history = self.history(source)
        manifest = history.manifest()
        source[0]['content'] = 'caller mutation'
        source[0]['source_time']['original_value'] = 'caller date mutation'
        exposed = history.by_id; exposed['e000000']['content'] = 'projection mutation'
        exposed_blocks = history.blocks; exposed_blocks['b000000']['source_ids'].clear()
        self.assertEqual(history.manifest(), manifest)
        self.assertEqual(history.search('crimson')['receipt']['source_sha256'], manifest['source_sha256'])
        self.assertEqual(len(history.blocks['b000000']['source_ids']), 2)

    def test_navigation_is_question_blind_literal_and_multiscale(self):
        sessions = [[('user', f'Project Astrolabe marker{index}'), ('assistant', 'Planning reply')]
            for index in range(73)]
        history = self.history(records(sessions, [None] * len(sessions)))
        view = history.overview()
        self.assertTrue(view['header']['aggregate_covers_all_original_records'])
        self.assertFalse(view['header']['original_record_details_included'])
        self.assertEqual(view['header']['source_records'], 146)
        self.assertTrue(all(entry['region_id'].startswith('g') for entry in view['entries']))
        self.assertEqual(sum(entry['source_records'] for entry in view['entries']), 146)
        source_tokens = set(n._tokens(' '.join(row['content'] for row in history.model_records)))
        self.assertTrue(set(view['header']['topic_cues']).issubset(source_tokens))
        self.assertTrue(set(view['header']['entity_cues']).issubset(source_tokens))
        self.assertTrue(history.manifest()['navigation_is_question_blind'])

    def test_overview_paging_and_zoom_reach_every_region_and_block(self):
        sessions = [[('user', f'Leaf item{index}'), ('assistant', 'Reply')] for index in range(17)]
        history = self.history(records(sessions, [None] * len(sessions)))
        pending, leaves = [history.root_region_id], []
        while pending:
            region_id = pending.pop()
            cursor = None
            while True:
                result = history.overview(region_id, cursor=cursor, page_size=2)
                for entry in result['entries']:
                    if entry['level'] == -1:
                        leaves.append(entry['region_id'])
                    else:
                        pending.append(entry['region_id'])
                cursor = result['next_cursor']
                if cursor is None:
                    break
        self.assertEqual(set(leaves), set(history.blocks))
        self.assertEqual(len(leaves), len(set(leaves)))

    def test_full_index_reaches_records_after_position_4096(self):
        session = []
        for index in range(2_050):
            session.extend([('user', f'Ordinary exchange item{index}'), ('assistant', 'Ordinary reply')])
        session[-2:] = [('user', 'Unique ultraviolet tailmarker'), ('assistant', 'Tail evidence')]
        history = self.history(records([session], [None]))
        result = history.search('ultraviolet tailmarker')
        self.assertEqual(result['accepted_block_ids'], ['b002049'])
        self.assertEqual(result['evidence'][0]['event_id'], 'e004098')
        self.assertTrue(result['receipt']['full_original_index_searched'])

    def test_late_question_anchor_is_not_lost_to_first_eight_terms(self):
        sessions = [[('user', 'Common planning ordinary discussion'), ('assistant', 'Reply')] for _ in range(20)]
        sessions.append([('user', 'Zephyrneedle location update'), ('assistant', 'Answer')])
        history = self.history(records(sessions, [None] * len(sessions)))
        question = 'Explain common planning ordinary discussion organization scheduling appointments conversations context details zephyrneedle'
        self.assertGreater(len(history.query_terms(question)), 8)
        self.assertEqual(history.search(question, page_size=1)['accepted_block_ids'], ['b000020'])

    def test_full_exchange_index_matches_terms_across_roles(self):
        history = self.history(records([[('user', 'Crimson question'), ('assistant', 'Compass answer')]], [None]))
        result = history.search('crimson compass')
        self.assertEqual(result['receipt']['exchange_fts_hits'], 1)
        self.assertEqual(len(result['evidence']), 2)

    def test_updates_across_sessions_are_both_delivered_in_original_order(self):
        history = self.history()
        result = history.search('crimson compass')
        self.assertEqual(set(result['accepted_block_ids']), {'b000000', 'b000002'})
        self.assertEqual([row['event_id'] for row in result['evidence']], ['e000000', 'e000001', 'e000004', 'e000005'])

    def test_search_results_page_without_repeating_first_page(self):
        sessions = [[('user', 'Amber marker'), ('assistant', 'Reply')] for _ in range(19)]
        history = self.history(records(sessions, [None] * len(sessions)))
        seen, cursor = [], None
        while True:
            result = history.search('amber', cursor=cursor, page_size=3)
            seen.extend(result['candidate_block_ids'])
            cursor = result['next_cursor']
            if cursor is None:
                self.assertEqual(result['coverage'], 'complete')
                break
            self.assertEqual(result['coverage'], 'paged')
        self.assertEqual(len(seen), 19)
        self.assertEqual(len(set(seen)), 19)

    def test_oversized_exchange_drops_atomically_and_cursor_reaches_later_units(self):
        history = self.history(records([[('user', 'needle ' + 'μ' * 200), ('assistant', 'Large')],
            [('user', 'needle'), ('assistant', 'Fits')]], [None, None]))
        first = history.zoom(history.root_region_id, page_size=1, maximum_bytes=10)
        self.assertEqual(first['evidence'], [])
        self.assertEqual(first['dropped_block_ids'], ['b000000'])
        self.assertEqual(first['coverage'], 'paged_allowance_limited')
        second = history.zoom(history.root_region_id, page_size=1, maximum_bytes=10, cursor=first['next_cursor'])
        self.assertEqual(second['accepted_block_ids'], ['b000001'])
        self.assertEqual(len(second['evidence']), 2)
        self.assertEqual(second['receipt']['candidate_blocks_reached'], 1)
        self.assertEqual(second['receipt']['fitted_blocks'], 1)

    def test_cost_sensitive_search_prioritizes_useful_small_exchange(self):
        history = self.history(records([[('user', 'needle ' + 'padding ' * 300), ('assistant', 'Large')],
            [('user', 'needle'), ('assistant', 'Fits')]], [None, None]))
        result = history.search('needle', maximum_bytes=10)
        self.assertEqual(result['candidate_block_ids'][0], 'b000001')
        self.assertEqual(result['accepted_block_ids'], ['b000001'])
        self.assertEqual(result['dropped_block_ids'], ['b000000'])

    def test_pinned_exchange_survives_new_priority_and_fails_if_it_cannot_fit(self):
        history = self.history(records([[('user', 'First'), ('assistant', 'Reply')],
            [('user', 'Later'), ('assistant', 'Other')]], [None, None]))
        result = history.pack(['b000001'], maximum_bytes=10, pinned_block_ids=['b000000'])
        self.assertEqual(result['accepted_block_ids'], ['b000000'])
        self.assertEqual(result['dropped_block_ids'], ['b000001'])
        self.error('pinned_evidence_does_not_fit', lambda: history.pack([], maximum_bytes=9, pinned_block_ids=['b000000']))
        self.error('pinned_block_excluded', lambda: history.pack([], pinned_block_ids=['b000000'], excluded_block_ids=['b000000']))

    def test_token_admission_receives_whole_exchanges_and_checks_pins_together(self):
        history = self.history()
        calls = []
        def fits(rows):
            history.validate_evidence(rows)
            calls.append(len(rows))
            return len(rows) <= 2
        result = history.pack(['b000001'], token_fits=fits, pinned_block_ids=['b000000'])
        self.assertEqual(calls, [2, 4])
        self.assertEqual(result['accepted_block_ids'], ['b000000'])
        self.error('pinned_evidence_does_not_fit', lambda: history.pack([], token_fits=fits,
            pinned_block_ids=['b000000', 'b000002']))
        self.error('token_admission_invalid', lambda: history.pack(['b000000'], token_fits=lambda _: 1))

    def test_exclusions_apply_to_complete_exchange_not_matching_record(self):
        history = self.history()
        result = history.search('crimson', excluded_block_ids=['b000000'])
        self.assertEqual(result['accepted_block_ids'], ['b000002'])
        self.assertTrue(all(row['event_id'] not in ('e000000', 'e000001') for row in result['evidence']))

    def test_tampered_partial_duplicate_reordered_evidence_is_rejected(self):
        history = self.history()
        rows = history.zoom('s000000')['evidence']
        tampered = copy.deepcopy(rows); tampered[0]['content'] = 'changed'
        self.error('evidence_original_mismatch', lambda: history.validate_evidence(tampered))
        self.error('evidence_exchange_incomplete', lambda: history.validate_evidence(rows[:1]))
        self.error('evidence_duplicate', lambda: history.validate_evidence(rows + rows))
        self.error('evidence_order_invalid', lambda: history.validate_evidence(list(reversed(rows))))

    def test_cursor_is_bound_to_query_source_filter_exclusions_and_operation(self):
        history = self.history()
        cursor = history.search('crimson', page_size=1)['next_cursor']
        self.assertIsNotNone(cursor)
        calls = [lambda: history.search('compass', page_size=1, cursor=cursor),
            lambda: history.search('crimson', page_size=1, cursor=cursor, excluded_block_ids=['b000000']),
            lambda: history.zoom('s000000', page_size=1, cursor=cursor),
            lambda: history.search('crimson', page_size=1, cursor=cursor,
                time_filter={'start': None, 'end': None, 'include_unknown': True}),
            lambda: self.history().search('crimson', page_size=1, cursor=cursor),
            lambda: history.search('crimson', page_size=1, cursor=cursor[:-5] + 'AAAAA')]
        for call in calls:
            self.error('cursor_invalid', call)
        continued = history.search('crimson', page_size=2, cursor=cursor)
        self.assertEqual(len(continued['candidate_block_ids']), 1)

    def test_recent_actual_count_reduction_is_bounded_and_keeps_complete_units(self):
        sessions = [[('user', 'Amber marker'), ('assistant', 'Reply')] for _ in range(64)]
        history = self.history(records(sessions, [None] * len(sessions)))
        calls = []
        def fits(rows):
            history.validate_evidence(rows)
            calls.append(len(rows))
            return len(rows) <= 16
        result = history.recent(token_fits=fits)
        self.assertEqual(calls, [128, 64, 32, 16])
        self.assertEqual(len(result['accepted_block_ids']), 8)
        self.assertEqual(len(result['dropped_block_ids']), 56)

    def test_original_dates_filter_whole_blocks_and_unknowns_are_explicit(self):
        history = self.history(records([[('user', 'Amber old'), ('assistant', 'Reply')],
            [('user', 'Amber new'), ('assistant', 'Reply')],
            [('user', 'Amber undated'), ('assistant', 'Reply')],
            [('user', 'Amber unsupported date'), ('assistant', 'Reply')]],
            ['2024-01-01', '2024/02/02 (Fri) 12:00', None, 'not-a-civil-date']))
        filtering = {'start': '2024-02-01', 'end': '2024-02-03', 'include_unknown': False}
        result = history.search('amber', time_filter=filtering)
        self.assertEqual(result['accepted_block_ids'], ['b000001'])
        self.assertEqual(result['receipt']['candidate_blocks_with_unknown_dates'], 2)
        self.assertEqual(result['receipt']['time_filter_excluded_blocks'], 3)
        filtering['include_unknown'] = True
        inclusive = history.search('amber', time_filter=filtering)
        self.assertEqual(set(inclusive['accepted_block_ids']), {'b000001', 'b000002', 'b000003'})
        self.assertNotIn('not-a-civil-date', o.canonical(inclusive['receipt']).decode())

    def test_mixed_dated_and_unknown_record_keeps_complete_exchange(self):
        source = records([[('user', 'Amber question'), ('assistant', 'Reply')]], ['2024-02-02'])
        source[1]['source_time'] = None
        history = self.history(source)
        result = history.search('amber', time_filter={'start': '2024-02-02', 'end': '2024-02-02', 'include_unknown': False})
        self.assertEqual(len(result['evidence']), 2)
        self.assertEqual(result['receipt']['candidate_blocks_with_unknown_dates'], 1)

    def test_invalid_queries_filters_page_bounds_and_utf8_have_fixed_errors(self):
        history = self.history()
        for query in ['', 'the and is', '\ud800', 'x' * (n.MAX_QUERY_BYTES + 1)]:
            with self.assertRaises(n.NavigationError):
                history.search(query)
        self.error('query_term_bound_exceeded', lambda: history.search(' '.join(f'term{x}' for x in range(257))))
        for page in [0, 129, True, '1']:
            self.error('page_bound_invalid', lambda: history.search('crimson', page_size=page))
        for filtering in [{'date': '2024-01-01'}, {'start': '2024-02-31', 'end': None, 'include_unknown': False},
            {'start': '2024-02-02', 'end': '2024-01-01', 'include_unknown': False},
            {'start': None, 'end': None, 'include_unknown': 1}]:
            self.error('time_filter_invalid', lambda: history.search('crimson', time_filter=filtering))

    def test_fts_operator_text_is_literal(self):
        history = self.history(records([[('user', 'NEAR operator'), ('assistant', 'Reply')]], [None]))
        result = history.search('NEAR OR "NEAR" * :')
        self.assertEqual(len(result['evidence']), 2)

    def test_punctuation_tokenization_keeps_fts_rarity_signals_consistent(self):
        history = self.history(records([[('user', 'Ordinary alpha beta'), ('assistant', 'Reply')],
            [('user', 'Rare gamma-delta path_name'), ('assistant', 'Reply')]], [None, None]))
        self.assertIn('gamma', history.query_terms('gamma-delta'))
        self.assertIn('delta', history.query_terms('gamma-delta'))
        self.assertEqual(history.search('gamma delta')['accepted_block_ids'], ['b000001'])

    def test_token_callback_errors_never_expose_exception_text(self):
        history = self.history()
        def failed(_):
            raise RuntimeError('private callback content')
        self.error('token_admission_failed', lambda: history.pack(['b000000'], token_fits=failed))
        self.error('token_admission_failed', lambda: history.recent(token_fits=failed))

    def test_empty_matches_and_no_eligible_dates_keep_honest_coverage(self):
        history = self.history()
        result = history.search('nevermatchedneedle')
        self.assertEqual(result['evidence'], [])
        self.assertEqual(result['coverage'], 'complete')
        self.assertEqual(result['receipt']['candidate_blocks_matched'], 0)
        filtered = history.search('crimson', time_filter={'start': '2025-01-01', 'end': None, 'include_unknown': False})
        self.assertEqual(filtered['evidence'], [])
        self.assertEqual(filtered['receipt']['time_filter_excluded_blocks'], 2)

    def test_receipts_are_content_free_and_bind_original_sources(self):
        history = self.history()
        result = history.search('crimson')
        receipt = result['receipt']
        self.assertFalse(receipt['model_delivery_established'])
        encoded = o.canonical(receipt).decode()
        for row in history.model_records:
            self.assertNotIn(row['content'], encoded)
        self.assertNotIn('2024-01-01', encoded)
        self.assertEqual(receipt['source_sha256'], history.source_sha256)
        self.assertEqual(receipt['evidence_sha256'], o.digest(o.canonical(result['evidence'])))
        self.assertEqual(receipt['sources'][0]['original_record_sha256'], o.digest(o.canonical(records()[0])))


if __name__ == '__main__':
    unittest.main()
