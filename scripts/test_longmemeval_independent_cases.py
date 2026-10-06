#!/usr/bin/env python3
"""Portable answer-blind independent cohort contracts; no dataset or model calls."""
from contextlib import ExitStack
import copy
import io
import json
from pathlib import Path
import random
import re
import tempfile
import unittest
from unittest.mock import patch

import local_longmemeval_qa as qa
import longmemeval_independent_cases as cohort


def source_row(question_id, category, *, session_id=None, content=None, question=None):
    return {'question_id': question_id, 'question_type': category,
        'question': question or ('PRIVATE original synthetic question ' + question_id),
        'question_date': '2023/07/27 (Thu) 18:00', 'answer': 'PRIVATE original synthetic answer ' + question_id,
        'answer_session_ids': [session_id or ('session-' + question_id)],
        'haystack_dates': ['2023/07/26 (Wed) 17:00'],
        'haystack_session_ids': [session_id or ('session-' + question_id)],
        'haystack_sessions': [[{'role': 'user', 'content': content or ('PRIVATE full original source ' + question_id + ' π'),
                               'has_answer': True},
                              {'role': 'assistant', 'content': 'PRIVATE original assistant ' + question_id}]]}


def fixture_rows():
    rows = [source_row(qid, category) for qid, category in zip(qa.CASE_IDS, qa.CASE_TYPES)]
    for index, category in enumerate(qa.CASE_TYPES[:6]):
        rows.extend(source_row(f'fresh-{index}-{candidate}', category) for candidate in range(3))
    rows.extend(source_row(f'fresh-absence-{candidate}_abs', qa.CASE_TYPES[candidate]) for candidate in range(3))
    return rows


def fixture_projection(rows, selected):
    raw = qa.canonical(rows); by_id = {r['question_id']: index for index, r in enumerate(rows)}
    types = tuple(rows[by_id[qid]]['question_type'] for qid in selected)
    pins = qa.SourcePins(sha256=qa.digest(raw), byte_count=len(raw), record_count=len(rows), case_ids=selected, case_types=types)
    cases = qa.project_cases(raw, pins)
    histories = [cohort._history_from_case(case, by_id[case['id']]) for case in cases]
    return raw, types, histories, cases


class Contracts(unittest.TestCase):
    def synthetic_prepare(self, rows=None):
        rows = fixture_rows() if rows is None else rows
        selected, _manifest = cohort.select_rows(rows)
        raw, types, histories, cases = fixture_projection(rows, selected)
        temporary = self.enterContext(tempfile.TemporaryDirectory()); directory = Path(temporary).resolve()
        path = directory / 'source.json'; qa.private_write(path, raw)
        stack = self.enterContext(ExitStack())
        for field, value in {'SOURCE_SHA256': qa.digest(raw), 'SOURCE_BYTES': len(raw), 'SOURCE_RECORDS': len(rows),
                'CASE_IDS': selected, 'CASE_TYPES': types,
                'PROJECTION_PINS': {h['id']: cohort.projection_sha256(cohort.runner_input(h, cohort.CONFIGURATION)) for h in histories}}.items():
            stack.enter_context(patch.object(cohort, field, value))
        return path, rows, histories, cases

    def test_exact_fixed_production_cohort_shape_and_exclusions(self):
        self.assertEqual(len(cohort.CASE_IDS), 14)
        self.assertEqual(len(set(cohort.CASE_IDS)), 14)
        self.assertFalse(set(cohort.CASE_IDS) & set(qa.CASE_IDS))
        self.assertEqual(cohort.CASE_TYPES[:12], tuple(t for t in qa.CASE_TYPES[:6] for _ in range(2)))
        self.assertEqual(tuple(cohort.PROJECTION_PINS), cohort.CASE_IDS)
        self.assertEqual(sum(qid.endswith('_abs') for qid in cohort.CASE_IDS), 2)
        self.assertEqual(cohort.VERSION, 7)

    def test_native_production_pins_and_normalized_configuration_match(self):
        source = (Path(__file__).resolve().parents[1] / 'Sources/Boros/AnswerEvaluationCommand.swift').read_text()
        match = re.search(r'independentLongMemoryCorpusProjectionSHA256[^=]*=\s*\[(.*?)\]', source, re.S)
        self.assertIsNotNone(match)
        self.assertEqual(set(re.findall(r'"([0-9a-f]{64})"', match.group(1))), set(cohort.PROJECTION_PINS.values()))
        configuration = {key: int(value) if type(value) is float and value.is_integer() else value
                         for key, value in cohort.CONFIGURATION.items()}
        match = re.search(r'independentLongMemoryConfigurationSHA256\s*=\s*"([0-9a-f]{64})"', source)
        self.assertIsNotNone(match)
        self.assertEqual(match.group(1), qa.digest(qa.canonical(configuration)))

    def test_rank_is_exact_domain_nul_utf8_hash(self):
        self.assertEqual(cohort.rank_sha256('case-π'), qa.digest((cohort.DOMAIN + '\0case-π').encode()))
        self.assertNotEqual(cohort.rank_sha256('a'), qa.digest((cohort.DOMAIN + 'a').encode()))

    def test_deterministic_rank_and_slot_order_under_root_row_reordering(self):
        rows = fixture_rows(); selected, manifest = cohort.select_rows(rows)
        changed = copy.deepcopy(rows); random.Random(17).shuffle(changed)
        self.assertEqual(cohort.select_rows(changed)[0], selected)
        self.assertEqual([s['category'] for s in manifest['slots']], list(cohort.SLOTS))
        for index, category in enumerate(qa.CASE_TYPES[:6]):
            expected = sorted((r['question_id'] for r in rows if r['question_type'] == category
                and r['question_id'] not in qa.CASE_IDS and not r['question_id'].endswith('_abs')),
                key=lambda qid: (cohort.rank_sha256(qid), qid))[:2]
            self.assertEqual(list(selected[2*index:2*index+2]), expected)

    def test_answers_positive_annotations_and_gold_labels_do_not_affect_selection(self):
        rows = fixture_rows(); selected, manifest = cohort.select_rows(rows)
        changed = copy.deepcopy(rows)
        for row in changed:
            row['answer'] = {'malformed': 'not read by selector'}
            row['answer_session_ids'] = ['not read by selector']
            for session in row['haystack_sessions']:
                for turn in session: turn['has_answer'] = 'not read by selector'
        again, proof = cohort.select_rows(changed)
        self.assertEqual(again, selected)
        self.assertEqual(qa.digest(qa.canonical(proof)), qa.digest(qa.canonical(manifest)))

    def test_same_session_id_with_different_payload_is_excluded_against_old_cases(self):
        rows = fixture_rows(); category = qa.CASE_TYPES[0]
        candidate = min((r for r in rows if r['question_type'] == category and r['question_id'] not in qa.CASE_IDS),
                        key=lambda r: cohort.rank_sha256(r['question_id']))
        candidate['haystack_session_ids'] = list(rows[0]['haystack_session_ids'])
        selected, manifest = cohort.select_rows(rows)
        self.assertNotIn(candidate['question_id'], selected)
        self.assertGreaterEqual(manifest['slots'][0]['session_id_overlap'], 1)

    def test_different_session_id_with_same_whole_payload_is_excluded(self):
        rows = fixture_rows(); candidate = min((r for r in rows if r['question_type'] == qa.CASE_TYPES[0]
            and r['question_id'] not in qa.CASE_IDS), key=lambda r: cohort.rank_sha256(r['question_id']))
        candidate['haystack_sessions'] = copy.deepcopy(rows[0]['haystack_sessions'])
        candidate['haystack_sessions'][0][0]['has_answer'] = False
        selected, manifest = cohort.select_rows(rows)
        self.assertNotIn(candidate['question_id'], selected)
        self.assertGreaterEqual(manifest['slots'][0]['session_payload_overlap'], 1)

    def test_same_question_utf8_digest_is_excluded(self):
        rows = fixture_rows(); candidate = min((r for r in rows if r['question_type'] == qa.CASE_TYPES[0]
            and r['question_id'] not in qa.CASE_IDS), key=lambda r: cohort.rank_sha256(r['question_id']))
        candidate['question'] = rows[0]['question']
        selected, manifest = cohort.select_rows(rows)
        self.assertNotIn(candidate['question_id'], selected)
        self.assertGreaterEqual(manifest['slots'][0]['question_overlap'], 1)

    def test_previous_new_selection_overlap_is_excluded(self):
        rows = fixture_rows()
        candidates = sorted((r for r in rows if r['question_type'] == qa.CASE_TYPES[0]
            and r['question_id'] not in qa.CASE_IDS), key=lambda r: cohort.rank_sha256(r['question_id']))
        candidates[1]['haystack_sessions'] = copy.deepcopy(candidates[0]['haystack_sessions'])
        selected, manifest = cohort.select_rows(rows)
        self.assertEqual(selected[0], candidates[0]['question_id'])
        self.assertNotIn(candidates[1]['question_id'], selected)
        self.assertGreaterEqual(manifest['slots'][1]['session_payload_overlap'], 1)

    def test_same_payload_different_role_or_order_has_distinct_digest(self):
        session = fixture_rows()[0]['haystack_sessions'][0]
        changed = copy.deepcopy(session); changed[0]['role'] = 'assistant'
        self.assertNotEqual(cohort.session_payload_sha256(session), cohort.session_payload_sha256(changed))
        self.assertNotEqual(cohort.session_payload_sha256(session), cohort.session_payload_sha256(list(reversed(session))))
        changed = copy.deepcopy(session); changed[0].pop('has_answer')
        self.assertEqual(cohort.session_payload_sha256(session), cohort.session_payload_sha256(changed))

    def test_duplicate_selected_session_ids_rejected(self):
        rows = fixture_rows(); selected, _ = cohort.select_rows(rows); row = next(r for r in rows if r['question_id'] == selected[0])
        row['haystack_session_ids'] *= 2
        row['haystack_sessions'].append([{'role': 'user', 'content': 'PRIVATE different unique full session'}])
        with self.assertRaises(qa.GradeError): cohort.select_rows(rows)

    def test_duplicate_selected_whole_payloads_under_distinct_ids_rejected(self):
        rows = fixture_rows(); selected, _ = cohort.select_rows(rows); row = next(r for r in rows if r['question_id'] == selected[0])
        row['haystack_session_ids'].append('different-id')
        row['haystack_sessions'].append(copy.deepcopy(row['haystack_sessions'][0]))
        with self.assertRaises(qa.GradeError): cohort.select_rows(rows)

    def test_exhausted_category_and_abstention_slots_refused(self):
        rows = fixture_rows()
        for absent in (False, True):
            pool = [r for r in rows if r['question_id'] in qa.CASE_IDS or
                (not r['question_id'].endswith('_abs') if absent else r['question_type'] != qa.CASE_TYPES[0])]
            with self.assertRaises(qa.GradeError): cohort.select_rows(pool)

    def test_missing_old_case_and_duplicate_record_identity_refused(self):
        rows = fixture_rows()
        for changed in (rows[1:], rows + [copy.deepcopy(rows[-1])]):
            with self.assertRaises(qa.GradeError): cohort.select_rows(changed)

    def test_project_preserves_full_text_order_roles_dates_indices_and_original_question(self):
        path, rows, expected, cases = self.synthetic_prepare()
        histories, manifest = cohort.prepare_with_manifest(path)
        self.assertTrue(qa.canonical(histories) == qa.canonical(expected))
        by_id = {r['question_id']: (i, r) for i, r in enumerate(rows)}
        for history, case in zip(histories, cases):
            index, source = by_id[history['id']]; probe = history['episodes'][0]
            self.assertEqual(history['source_index'], index)
            self.assertTrue(probe['prompt'] == source['question'])
            self.assertTrue(probe['question_time']['original_value'] == source['question_date'])
            self.assertTrue(history['events'] == case['events'])
            self.assertEqual(cohort.scorer_annotations_sha256(history), case['oracle_sha256'])
            self.assertEqual(probe['question_time']['locator'], f'/{index}/question_date')
        self.assertTrue(all(manifest['disjointness'].values()))

    def test_paired_v7_input_excludes_oracle_and_preserves_question_time_separately(self):
        _path, _rows, histories, _cases = self.synthetic_prepare(); history = histories[0]
        document = cohort.runner_input(history, cohort.CONFIGURATION)
        self.assertEqual([r['strategy'] for r in document['attempts']], ['recent_only', 'hybrid'])
        self.assertEqual([r['replicate'] for r in document['attempts']], [0, 0])
        self.assertEqual(document['version'], 7)
        for request in document['attempts']:
            self.assertTrue(request['prompt'] == history['episodes'][0]['prompt'])
            self.assertTrue(request['question_time'] == history['episodes'][0]['question_time'])
            self.assertEqual(set(request), {'probe_id', 'project_id', 'conversation_key', 'prompt', 'question_time', 'strategy', 'replicate'})
        raw = qa.canonical(document)
        for forbidden in ('answer', 'answer_session_ids', 'source_labels', 'has_answer', 'question_type', 'abstention'):
            self.assertNotIn(('"' + forbidden + '":').encode(), raw)

    def test_projection_covers_source_order_role_bytes_question_and_dates(self):
        _p, _r, histories, _c = self.synthetic_prepare(); document = cohort.runner_input(histories[0], cohort.CONFIGURATION)
        original = cohort.projection_sha256(document)
        for mutate in (lambda d: d['events'].reverse(), lambda d: d['events'][0].__setitem__('text', 'changed'),
            lambda d: d['events'][0].__setitem__('role', 'assistant'),
            lambda d: d['events'][0]['source_time'].__setitem__('locator', '/changed'),
            lambda d: d['attempts'][0].__setitem__('prompt', 'changed'),
            lambda d: d['attempts'][0]['question_time'].__setitem__('original_value', 'changed')):
            changed = copy.deepcopy(document); mutate(changed)
            self.assertNotEqual(cohort.projection_sha256(changed), original)
        changed = copy.deepcopy(document); changed['configuration']['seed'] += 1
        self.assertEqual(cohort.projection_sha256(changed), original)

    def test_native_projection_case_inventory_and_source_pins_are_enforced(self):
        path, _rows, _histories, _cases = self.synthetic_prepare()
        with patch.object(cohort, 'SOURCE_SHA256', '0' * 64):
            with self.assertRaises(qa.GradeError): cohort.prepare(path)
        with patch.object(cohort, 'CASE_IDS', tuple(reversed(cohort.CASE_IDS))):
            with self.assertRaises(qa.GradeError): cohort.prepare(path)
        pins = dict(cohort.PROJECTION_PINS); pins[cohort.CASE_IDS[0]] = '0' * 64
        with patch.object(cohort, 'PROJECTION_PINS', pins):
            with self.assertRaises(qa.GradeError): cohort.prepare(path)

    def test_selected_original_fields_still_strictly_validated_after_selection(self):
        for field, value in (('answer', {}), ('answer_session_ids', ['not-present']),
                             ('question_date', 'invalid literal')):
            rows = fixture_rows(); selected, _ = cohort.select_rows(rows)
            row = next(r for r in rows if r['question_id'] == selected[0]); row[field] = value
            raw = qa.canonical(rows); types = tuple(next(r['question_type'] for r in rows if r['question_id'] == qid) for qid in selected)
            with self.assertRaises(qa.GradeError):
                qa.project_cases(raw, qa.SourcePins(sha256=qa.digest(raw), byte_count=len(raw), record_count=len(rows), case_ids=selected, case_types=types))

    def test_manifest_is_content_free_and_binds_counts_dates_projections_and_oracles(self):
        path, rows, histories, _cases = self.synthetic_prepare(); projected, manifest = cohort.prepare_with_manifest(path)
        raw = qa.canonical(manifest)
        self.assertNotIn(b'PRIVATE', raw)
        self.assertNotIn(rows[0]['question_date'].encode(), raw)
        self.assertEqual((manifest['declared_cases'], manifest['declared_attempts']), (14, 28))
        self.assertEqual(manifest['source']['sha256'], cohort.SOURCE_SHA256)
        self.assertEqual(len(manifest['cases']), 14)
        self.assertEqual(len(manifest['excluded_inventory']), 7)
        for history, annotation in zip(projected, manifest['cases']):
            self.assertEqual(annotation['scorer_annotations_sha256'], cohort.scorer_annotations_sha256(history))
            self.assertEqual(annotation['question_time_sha256'], qa.digest(qa.canonical(history['episodes'][0]['question_time'])))
            self.assertEqual(annotation['source_count'], len(history['events']))
            self.assertEqual(annotation['source_bytes'], sum(len(r['text'].encode()) for r in history['events']))

    def test_source_file_tamper_and_symlink_are_refused(self):
        path, _rows, _histories, _cases = self.synthetic_prepare()
        link = path.parent / 'link'; link.symlink_to(path)
        with self.assertRaises(qa.GradeError): cohort.prepare(link)
        path.write_bytes(path.read_bytes() + b' ')
        with self.assertRaises(qa.GradeError): cohort.prepare(path)

    def test_output_reserve_remains_exact_1024(self):
        _p, _r, histories, _c = self.synthetic_prepare()
        for value in (512, 2048, 1024.0, True):
            with self.assertRaises(qa.GradeError): cohort.runner_input(histories[0], {**cohort.CONFIGURATION, 'maximum_output': value})

    def test_selection_does_not_mutate_original_source(self):
        rows = fixture_rows(); before = qa.digest(qa.canonical(rows)); cohort.select_rows(rows)
        self.assertEqual(qa.digest(qa.canonical(rows)), before)


if __name__ == '__main__':
    result = unittest.TextTestRunner(stream=io.StringIO()).run(unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    print(json.dumps({'checks': result.testsRun, 'failed': [t.id() for t, _ in result.failures],
                     'errors': [t.id() for t, _ in result.errors], 'skipped': len(result.skipped)}))
    raise SystemExit(not result.wasSuccessful())
