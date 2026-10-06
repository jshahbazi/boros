#!/usr/bin/env python3
"""Portable independent QA contracts; synthetic private data and no provider calls."""
from __future__ import annotations

import base64
from contextlib import ExitStack, redirect_stderr, redirect_stdout
import copy
from dataclasses import replace
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

import evaluate_answers as evidence
import evaluate_longmemeval as baseline
import longmemeval_independent_cases as independent
import local_longmemeval_qa as qa
import local_longmemeval_independent_qa as adapter
from test_local_longmemeval_qa import response
from test_longmemeval_evaluation import native_report
from test_longmemeval_independent_cases import fixture_rows, fixture_projection


class Fixture:
    def __init__(self, root, stack, *, failed=False, missing=False, continuity=True):
        self.root = root
        self.rows = fixture_rows()
        for row in self.rows:
            row['haystack_dates'].append(row['haystack_dates'][0])
            row['haystack_session_ids'].append('later-' + row['question_id'])
            row['haystack_sessions'].append([{'role': 'user', 'content': 'PRIVATE later source ' + row['question_id']},
                {'role': 'assistant', 'content': 'PRIVATE later reply ' + row['question_id']}])
        selected, _manifest = independent.select_rows(self.rows)
        raw, types, histories, _cases = fixture_projection(self.rows, selected)
        self.source = root / 'source.json'; qa.private_write(self.source, raw)
        for key, value in {'SOURCE_SHA256': qa.digest(raw), 'SOURCE_BYTES': len(raw), 'SOURCE_RECORDS': len(self.rows),
            'CASE_IDS': selected, 'CASE_TYPES': types, 'PROJECTION_PINS': {history['id']: independent.projection_sha256(
                independent.runner_input(history, independent.CONFIGURATION)) for history in histories}}.items():
            stack.enter_context(patch.object(independent, key, value))
        self.histories, self.manifest = independent.prepare_with_manifest(self.source)
        self.documents = [independent.runner_input(history, independent.CONFIGURATION) for history in self.histories]
        annotations = [adapter._annotation(history, document) for history, document in zip(self.histories, self.documents)]
        # Historical Python hashes are intentionally different from current
        # files; native build evidence and current grader freezing are distinct.
        historical = {'Sources/Boros/AnswerEvaluationCommand.swift': 'a' * 64,
            'scripts/evaluate_longmemeval.py': 'c' * 64, 'scripts/longmemeval_independent_cases.py': 'd' * 64}
        self.proof = root / 'verification.json'
        qa.private_write(self.proof, qa.canonical({'terminal_passed': True, 'app_binary_sha256': 'b' * 64,
            'source_hashes': {**historical, 'Tests/synthetic.json': 'e' * 64}}))
        declaration = {'version': 2, 'split': 'development', 'declared_attempts': 28, 'runner_document_version': 7,
            'case_ids': list(selected), 'cases': annotations, 'source_revision': independent.SOURCE_REVISION,
            'source_sha256': independent.SOURCE_SHA256, 'source_hashes': historical,
            'configuration_sha256': qa.digest(qa.canonical(independent.CONFIGURATION)),
            'native_configuration_sha256': baseline.native_configuration_sha256(independent.CONFIGURATION),
            'system_sha256': qa.digest(independent.CONFIGURATION['system'].encode()),
            'protocol_commit': baseline.PROTOCOL_COMMIT, 'protocol_hashes': baseline.PROTOCOL_HASHES,
            'official_qa_score': None, 'official_qa_status': 'pending_official_judge',
            'cohort': independent.COHORT, 'selection_manifest': self.manifest}
        measured, self.predictions = [], {strategy: [] for strategy in qa.STRATEGIES}
        for index, (history, document, annotation) in enumerate(zip(self.histories, self.documents, annotations)):
            native_directory = root / ('native-' + str(index))
            native = native_report(history, document, native_directory)
            native['native_configuration_sha256'] = baseline.native_configuration_sha256(independent.CONFIGURATION)
            for ordinal, item in enumerate(native['attempts']):
                preparation = item['preparation']; receipt = preparation['admission']; audit = preparation['context_audit']
                receipt['outputReserve'] = receipt['componentProof']['outputReserve'] = 1024
                audit['components'] = copy.deepcopy(receipt['componentProof'])
                # Ordinary recent-only has no historical recall; hybrid has
                # only a prefix of one positive source. Both remain judgeable.
                if ordinal == 0:
                    item['delivered_ranges'] = item['delivered_ranges'][len(audit['historical_sources']):]
                    audit['historical_sources'] = []
                else:
                    original = history['events'][0]['text'].encode()[:8]
                    item['delivered_ranges'][0].update(byte_length=len(original), sha256=qa.digest(original))
                    audit['historical_sources'][0].update(excerpt_bytes=len(original), excerpt_sha256=qa.digest(original))
                preparation['admission_audit']['receipt'] = copy.deepcopy(receipt)
                preparation['admission_audit']['context'] = base64.b64encode(qa.canonical(audit)).decode()
                if failed and index == 0 and ordinal == 0:
                    item.update(episode_state='failed', invocation_status='partial', failure='incomplete_result')
            if missing and index == 1:
                native = {'version': 1, 'fatal_failure': 'runner_report_missing', 'attempts': []}
            attempts, predictions = baseline.score_native(native, native_directory, history, document,
                configuration=independent.CONFIGURATION, runner_document_version=7)
            measured.append({'case': annotation, 'attempts': attempts, 'driver': evidence.native_metadata(native)})
            for prediction in predictions:
                self.predictions[prediction['strategy']].append({key: prediction[key] for key in ('question_id', 'hypothesis')})
        self.exports = root / 'exports'; self.exports.mkdir(mode=0o700)
        self.report = {'longmemeval_evaluation_version': 2, 'runner_document_version': 7, 'cohort': independent.COHORT,
            'split': 'development', 'registration_status': 'predeclared_independent_development_subset',
            'replicates': 1, 'strategy_order': list(qa.STRATEGIES), 'implementation_continuity': continuity,
            'source': {'repository': 'https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned',
                'revision': independent.SOURCE_REVISION, 'path': independent.SOURCE_NAME,
                'sha256': independent.SOURCE_SHA256, 'bytes': independent.SOURCE_BYTES},
            'configuration': {key: value for key, value in independent.CONFIGURATION.items() if key != 'system'},
            'declaration': declaration, 'selection_manifest': self.manifest,
            'implementation': {'source_sha256': historical, 'binary_sha256': 'b' * 64,
                'binary_verification_sha256': qa.digest(self.proof.read_bytes()),
                'source_binary_linkage': 'terminal_build_record_matches_all_native_sources',
                'python_dependencies_captured_before_compile': True}, 'histories': measured,
            'official_qa_score': None, 'official_qa_status': 'pending_official_judge'}
        self.report_path = root / 'answers.json'
        self.publish_exports(); self.publish()
        self.protocol = root / 'protocol.py'
        self.protocol_raw = b"import unavailable_dependency\ndef get_anscheck_prompt(task, question, answer, hypothesis, abstention=False):\n    return f'{task}|{question}|{answer}|{hypothesis}|{abstention}'\n"
        qa.private_write(self.protocol, self.protocol_raw)
        stack.enter_context(patch.object(qa, 'PROTOCOL_SHA256', qa.digest(self.protocol_raw)))

    def publish_exports(self):
        exports = {}
        for strategy, rows in self.predictions.items():
            raw = b''.join(qa.canonical(row) + b'\n' for row in rows)
            path = self.exports / (strategy + '.jsonl'); path.write_bytes(raw); os.chmod(path, 0o600)
            exports[strategy] = {'records': 14, 'bytes': len(raw), 'sha256': qa.digest(raw)}
        self.report['private_hypothesis_exports'] = exports

    def publish(self):
        raw = qa.canonical(self.report['declaration']) + b'\n'
        self.report['declaration_sha256'] = qa.digest(raw)
        path = self.exports / 'declaration.json'; path.write_bytes(raw); os.chmod(path, 0o600)
        self.report['summary'] = baseline.summarize([row for measured in self.report['histories'] for row in measured['attempts']])
        self.report_path.write_bytes(qa.canonical(self.report)); os.chmod(self.report_path, 0o600)

    def validated(self):
        return adapter.validate_bundle(self.report_path, qa.digest(self.report_path.read_bytes()), self.exports,
            self.source, self.proof)

    def valid_controls(self):
        path = self.root / 'controls.json'
        rows = [{'ordinal': index, 'category': spec['category'], 'expected': spec['expected'], 'scored': True,
            'strict_yes_no_format_valid': True, 'terminal_status': 'completed',
            'upstream_yes_substring_label': spec['expected']} for index, spec in enumerate(qa.control_specification())]
        qa.private_write(path, qa.canonical({'local_qa_diagnostic_version': 1, 'mode': 'controls',
            'synthetic_controls_validated': True, 'fingerprints': qa.fingerprints(
                qa.local_settings(qa.ANSWER_CONFIGURATION['endpoint']), self.protocol_raw), 'attempts': rows}))
        return path, qa.digest(path.read_bytes())

    def execute(self, bundle=None, transport=None):
        controls, digest = self.valid_controls()
        return adapter.run(bundle or self.validated(), self.protocol, controls, digest,
            self.root / 'qa', self.root / 'qa-private', transport=transport or (lambda *_a, **_k: response()))


class Contracts(unittest.TestCase):
    def fixture(self, **kwargs):
        root = Path(self.enterContext(tempfile.TemporaryDirectory())).resolve()
        return Fixture(root, self.enterContext(ExitStack()), **kwargs)

    def test_exact_twenty_eight_ordered_inputs_and_two_absence_cases(self):
        fixture = self.fixture(); bundle = fixture.validated()
        self.assertEqual(len(bundle.attempts), 28)
        self.assertEqual(tuple(attempt['strategy'] for attempt in bundle.attempts), qa.STRATEGIES * 14)
        self.assertEqual(tuple(attempt['question_id'] for attempt in bundle.attempts), tuple(qid for qid in independent.CASE_IDS for _ in qa.STRATEGIES))
        self.assertEqual(sum(attempt['abstention'] for attempt in bundle.attempts), 4)
        self.assertEqual(len(bundle.pins['projection_sha256']), 14)
        self.assertEqual(len(bundle.pins['oracle_projection_sha256']), 14)

    def test_delivery_partial_and_zero_gold_do_not_gate_ordinary_recall(self):
        fixture = self.fixture(); bundle = fixture.validated()
        self.assertEqual(fixture.report['histories'][0]['attempts'][0]['delivery']['fully_delivered_evidence_turn_count'], 0)
        self.assertFalse(fixture.report['histories'][0]['attempts'][1]['delivery']['all_evidence_turns_delivered'])
        self.assertTrue(all(attempt['judge_eligible'] for attempt in bundle.attempts))
        report = fixture.execute(bundle)
        self.assertEqual(report['summary']['all']['scored_attempts'], 28)

    def test_new_contract_report_configuration_order_and_shape_tamper(self):
        mutations = [lambda value: value.__setitem__('longmemeval_evaluation_version', 1),
            lambda value: value.__setitem__('runner_document_version', True), lambda value: value.__setitem__('cohort', 'pilot'),
            lambda value: value.__setitem__('replicates', True), lambda value: value['strategy_order'].reverse(),
            lambda value: value['configuration'].__setitem__('maximum_output', 512), lambda value: value['histories'].reverse(),
            lambda value: value['histories'][0]['attempts'].reverse(),
            lambda value: value['histories'][0]['attempts'][0].__setitem__('replicate', True),
            lambda value: value['histories'][0]['attempts'][0].__setitem__('abstention', True),
            lambda value: value.__setitem__('implementation_continuity', 1)]
        for index, mutate in enumerate(mutations):
            with self.subTest(mutation=index):
                fixture = self.fixture(); mutate(fixture.report); fixture.publish()
                with self.assertRaises(qa.GradeError): fixture.validated()

    def test_manifest_declaration_projection_source_and_oracle_tamper(self):
        for target in ('manifest', 'case', 'projection', 'oracle', 'source', 'protocol'):
            fixture = self.fixture()
            if target == 'manifest': fixture.report['selection_manifest']['slots'][0]['inspected_count'] += 1
            elif target == 'case': fixture.report['declaration']['case_ids'].reverse()
            elif target == 'projection': fixture.report['declaration']['cases'][0]['public_projection_sha256'] = '0' * 64
            elif target == 'oracle': fixture.report['declaration']['cases'][0]['scorer_annotations_sha256'] = '0' * 64
            elif target == 'source': fixture.report['source']['revision'] = '0' * 40
            else: fixture.report['declaration']['protocol_hashes'] = {'src/evaluation/evaluate_qa.py': '0' * 64}
            fixture.publish()
            with self.assertRaises(qa.GradeError): fixture.validated()

    def test_exact_native_projection_pins_are_reconstructed(self):
        fixture = self.fixture(); pins = dict(independent.PROJECTION_PINS); pins[independent.CASE_IDS[0]] = '0' * 64
        with patch.object(independent, 'PROJECTION_PINS', pins):
            with self.assertRaises(qa.GradeError): fixture.validated()

    def test_source_report_declaration_export_and_proof_byte_tamper(self):
        for target in ('source', 'report', 'declaration', 'recent_only', 'hybrid', 'proof'):
            fixture = self.fixture(); digest = qa.digest(fixture.report_path.read_bytes())
            paths = {'source': fixture.source, 'report': fixture.report_path, 'declaration': fixture.exports / 'declaration.json',
                'recent_only': fixture.exports / 'recent_only.jsonl', 'hybrid': fixture.exports / 'hybrid.jsonl', 'proof': fixture.proof}
            paths[target].write_bytes(paths[target].read_bytes() + b' ')
            with self.assertRaises(qa.GradeError): adapter.validate_bundle(fixture.report_path, digest, fixture.exports, fixture.source, fixture.proof)

    def test_historical_native_build_proof_and_inventory_tamper(self):
        for target in ('native', 'binary', 'terminal', 'script', 'implementation', 'linkage'):
            fixture = self.fixture(); proof = qa.strict_json(fixture.proof.read_bytes())
            if target == 'native': proof['source_hashes']['Sources/Boros/AnswerEvaluationCommand.swift'] = 'f' * 64
            elif target == 'binary': proof['app_binary_sha256'] = 'f' * 64
            elif target == 'terminal': proof['terminal_passed'] = False
            elif target == 'script': proof['source_hashes']['scripts/evaluate_longmemeval.py'] = 'f' * 64
            elif target == 'implementation': fixture.report['implementation']['source_sha256'] = {'Sources/Boros/Other.swift': 'f' * 64}
            else: fixture.report['implementation']['source_binary_linkage'] = 'other'
            fixture.proof.write_bytes(qa.canonical(proof))
            fixture.report['implementation']['binary_verification_sha256'] = qa.digest(fixture.proof.read_bytes()); fixture.publish()
            with self.assertRaises(qa.GradeError): fixture.validated()

    def test_historical_python_and_current_grader_dependencies_are_separate(self):
        fixture = self.fixture()
        self.assertNotIn('scripts/local_longmemeval_independent_qa.py', fixture.report['declaration']['source_hashes'])
        with patch.object(baseline, 'code_inventory', side_effect=AssertionError('current inventory forbidden')):
            self.assertEqual(len(fixture.validated().attempts), 28)

    def test_native_driver_report_projection_and_attempt_count_tamper(self):
        for key, value in (('input_sha256', '0' * 64), ('public_projection_sha256', '0' * 64),
            ('native_configuration_sha256', '0' * 64), ('declared_attempts', True), ('completed_attempts', 1)):
            fixture = self.fixture(); fixture.report['histories'][0]['driver'][key] = value; fixture.publish()
            with self.assertRaises(qa.GradeError): fixture.validated()

    def test_metadata_original_ranges_receipts_identifiers_and_opaque_shape_tamper(self):
        for target in ('range', 'utf8', 'recent', 'receipt', 'version', 'context', 'work', 'episode', 'components'):
            fixture = self.fixture(); metadata = fixture.report['histories'][0]['attempts'][1]['metadata']
            preparation = metadata['preparation']; admission = adapter.field(preparation, 'admission_audit')
            if target == 'range': metadata['delivered_ranges'][0]['field_sha256_' + qa.digest(b'sha256')] = '0' * 64
            elif target == 'utf8': metadata['delivered_ranges'][0]['offset'] = 1
            elif target == 'recent': metadata['delivered_recent_source_ids'].reverse()
            elif target == 'receipt': preparation['admission']['bodyDigest'] = '0' * 64
            elif target == 'version': admission['version'] = True
            elif target == 'context': adapter.field(admission, 'context')['sha256'] = 'invalid'
            elif target == 'work': preparation['answer_work_id'] = 'invalid'
            elif target == 'episode': metadata['identifiers']['episodeID'] = 'invalid'
            else: preparation['context_audit']['components']['bodyDigest'] = '0' * 64
            fixture.publish()
            with self.assertRaises(qa.GradeError): fixture.validated()

    def test_completed_metadata_requires_health_episode_invocation_and_v3_receipt(self):
        for target in ('metadata', 'health', 'episode', 'invocation', 'admission'):
            fixture = self.fixture(); row = fixture.report['histories'][0]['attempts'][0]
            if target == 'metadata': row['metadata'] = None
            elif target == 'health': row['metadata'].pop('capture_healthy')
            elif target == 'episode': row['metadata']['episode_state'] = 'failed'
            elif target == 'invocation': row['metadata']['invocation_status'] = 'partial'
            else: row['metadata']['preparation'].pop('field_sha256_' + qa.digest(b'admission_audit'))
            fixture.publish()
            with self.assertRaises(qa.GradeError): fixture.validated()

    def test_cross_project_source_scope_and_project_receipt_tamper(self):
        fixture = self.fixture()
        changed = copy.deepcopy(fixture.histories[0]); changed['events'][0]['project_id'] = 'other-project'
        request = fixture.documents[0]['attempts'][1]
        metadata = fixture.report['histories'][0]['attempts'][1]['metadata']
        ranges = [{key: adapter.field(span, key) for key in ('event_id', 'offset', 'byte_length', 'sha256')}
            for span in metadata['delivered_ranges']]
        with self.assertRaises(evidence.EvaluationError): baseline.validated_intervals(changed, request, ranges,
            metadata['delivered_recent_source_ids'])
        metadata['preparation']['admission']['componentProof']['projectID'] = {'sha256': qa.digest(b'other-project'), 'bytes': 13}
        fixture.publish()
        with self.assertRaises(qa.GradeError): fixture.validated()

    def test_available_nonterminal_metadata_receipt_still_validated(self):
        fixture = self.fixture(); row = fixture.report['histories'][0]['attempts'][0]
        row.update(operational_complete=False, failure_code='native_attempt_interrupted',
            delivery=adapter._unknown_delivery(fixture.histories[0], fixture.documents[0]['attempts'][0]))
        row['metadata']['terminalized'] = False
        fixture.report['histories'][0]['driver']['completed_attempts'] = 1
        fixture.predictions['recent_only'][0]['hypothesis'] = ''
        fixture.publish_exports(); fixture.publish()
        self.assertFalse(fixture.validated().attempts[0]['judge_eligible'])
        row['metadata']['preparation']['admission']['bodyDigest'] = '0' * 64
        fixture.publish()
        with self.assertRaises(qa.GradeError): fixture.validated()

    def test_failed_and_missing_answers_retain_twenty_eight_denominator(self):
        fixture = self.fixture(failed=True, missing=True); calls = []
        report = fixture.execute(transport=lambda *_a, **_k: calls.append(1) or response())
        summary = report['summary']['all']
        self.assertEqual((summary['declared_attempts'], summary['scored_attempts'], summary['operational_failed_attempts']), (28, 25, 3))
        self.assertEqual(len(calls), 25)
        self.assertEqual(summary['accepted_fraction_declared'], 25 / 28)
        self.assertEqual(summary['accepted_fraction_scored'], 1)
        self.assertEqual(report['strategy_summary']['recent_only']['all']['declared_attempts'], 14)
        self.assertEqual(report['strategy_summary']['hybrid']['all']['declared_attempts'], 14)

    def test_nonterminal_and_setup_failure_metadata_can_omit_preparation(self):
        fixture = self.fixture()
        for ordinal in (0, 1):
            row = fixture.report['histories'][0]['attempts'][ordinal]; metadata = row['metadata']
            row.update(operational_complete=False, failure_code='native_attempt_incomplete')
            metadata.update(episode_state='failed', invocation_status='failed', invocation_started=False,
                preparation=None, delivered_ranges=[], delivered_recent_source_ids=[])
            for key in ('capture_healthy', 'accounting_healthy'): metadata.pop(key)
            if ordinal == 0:
                metadata['terminalized'] = False
                row['delivery'] = adapter._unknown_delivery(fixture.histories[0], fixture.documents[0]['attempts'][0])
                fixture.report['histories'][0]['driver']['completed_attempts'] = 1
            else:
                row['delivery'] = baseline.delivery_diagnostic(fixture.histories[0], fixture.documents[0]['attempts'][1], [], [])
            fixture.predictions[qa.STRATEGIES[ordinal]][0]['hypothesis'] = ''
        fixture.publish_exports(); fixture.publish()
        self.assertEqual(fixture.execute()['summary']['all']['operational_failed_attempts'], 2)

    def test_failed_exports_must_be_empty_and_completed_exports_hash_bound(self):
        for failed in (True, False):
            fixture = self.fixture(failed=failed); fixture.predictions['recent_only'][0]['hypothesis'] = 'PRIVATE changed hypothesis'
            fixture.publish_exports(); fixture.publish()
            with self.assertRaises(qa.GradeError): fixture.validated()

    def test_export_order_unknown_fields_duplicate_json_and_denominator_refused(self):
        for target in ('order', 'field', 'duplicate', 'missing'):
            fixture = self.fixture()
            if target == 'order': fixture.predictions['hybrid'].reverse()
            elif target == 'field': fixture.predictions['hybrid'][0]['extra'] = 'PRIVATE forbidden'
            elif target == 'missing': fixture.predictions['hybrid'].pop()
            fixture.publish_exports()
            if target == 'duplicate':
                path = fixture.exports / 'hybrid.jsonl'; raw = path.read_bytes().replace(b'{', b'{"question_id":"duplicate",', 1)
                path.write_bytes(raw); fixture.report['private_hypothesis_exports']['hybrid'] = {'records': 14, 'bytes': len(raw), 'sha256': qa.digest(raw)}
            fixture.publish()
            with self.assertRaises(qa.GradeError): fixture.validated()

    def test_unverified_implementation_retains_all_and_never_calls(self):
        fixture = self.fixture(continuity=False, missing=True)
        report = fixture.execute(transport=lambda *_a, **_k: self.fail('unverified call'))
        self.assertEqual(report['summary']['all']['implementation_unverified_attempts'], 28)
        self.assertEqual(report['summary']['all']['scored_attempts'], 0)

    def test_deep_frozen_bundle_and_identity_guard(self):
        fixture = self.fixture(); bundle = fixture.validated()
        for change in (lambda: bundle.attempts[0].__setitem__('hypothesis', 'PRIVATE mutation'),
            lambda: bundle.pins['projection_sha256'].__setitem__(0, '0' * 64)):
            with self.assertRaises((TypeError, AttributeError)): change()
        changed = replace(bundle, implementation_continuity=False)
        with self.assertRaises(qa.GradeError): fixture.execute(changed)

    def test_predeclare_materialize_all_requests_capture_private_permissions_and_privacy(self):
        fixture = self.fixture(failed=True); calls = []
        def transport(_settings, raw, timeout):
            private = fixture.root / 'qa-private'
            declaration = qa.strict_json((fixture.root / 'qa/declaration.json').read_bytes())
            requests = (private / 'requests.jsonl').read_bytes().splitlines()
            self.assertEqual(len(requests), 28); self.assertEqual(len(declaration['pre_execution_status']), 28)
            self.assertEqual(len(declaration['request_sha256']), 28)
            self.assertEqual(raw, requests[len(calls) + 1]); calls.append(raw)
            return response()
        report = fixture.execute(transport=transport)
        self.assertEqual(len(calls), 27)
        for name in ('qa', 'qa-private'):
            directory = fixture.root / name
            self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
            self.assertTrue(all(stat.S_IMODE(path.stat().st_mode) == 0o600 for path in directory.iterdir()))
        public = (fixture.root / 'qa/report.json').read_bytes() + (fixture.root / 'qa/declaration.json').read_bytes()
        for sentinel in (b'PRIVATE', b'private generated natural answer sentinel', qa.MODEL.encode(),
            fixture.rows[0]['question_date'].encode(), str(fixture.root).encode()): self.assertNotIn(sentinel, public)
        self.assertIsNone(report['official_qa_score'])
        self.assertEqual(report['performance_trust'], 'same_answerer_self_judge_uncalibrated')
        self.assertEqual(report['real_judge_calibration_status'], 'unrun')

    def test_usage_and_categories_preserve_strategy_denominators(self):
        fixture = self.fixture(); report = fixture.execute()
        summary = report['summary']['all']
        self.assertEqual((summary['observed_prompt_tokens'], summary['observed_completion_tokens']), (1400, 28))
        self.assertEqual(summary['usage_observed_attempts'], 28)
        self.assertEqual(report['summary']['abstention']['declared_attempts'], 4)
        for strategy in qa.STRATEGIES:
            self.assertEqual(report['strategy_summary'][strategy]['all']['observed_prompt_tokens'], 700)

    def test_transport_parse_unknowns_and_no_retries(self):
        fixture = self.fixture(); calls = []
        def transport(*_args, **_kwargs):
            calls.append(1)
            if len(calls) == 1: raise RuntimeError('PRIVATE credential sentinel')
            if len(calls) == 2: return response(finish='length')
            if len(calls) == 3: return b'invalid PRIVATE response'
            return response(usage=False)
        report = fixture.execute(transport=transport)
        self.assertEqual(len(calls), 28)
        self.assertEqual(report['summary']['all']['judge_unknown_attempts'], 3)
        self.assertEqual(report['summary']['all']['scored_attempts'], 25)
        self.assertEqual(report['summary']['all']['usage_unknown_attempts'], 27)
        self.assertNotIn(b'PRIVATE', (fixture.root / 'qa/report.json').read_bytes())

    def test_source_drift_before_execution_refused(self):
        fixture = self.fixture(); bundle = fixture.validated(); fixture.source.write_bytes(fixture.source.read_bytes() + b' ')
        with self.assertRaises(qa.GradeError): fixture.execute(bundle)
        self.assertFalse((fixture.root / 'qa').exists())

    def test_input_protocol_controls_and_dependency_drift_midcall_stop_future_calls(self):
        for target in ('source', 'report', 'proof', 'export', 'protocol', 'controls', 'dependency'):
            fixture = self.fixture(); bundle = fixture.validated(); controls, controls_sha = fixture.valid_controls(); calls = []
            original_fp = adapter.fingerprints
            def fingerprint(settings, raw):
                value = original_fp(settings, raw)
                if target == 'dependency' and calls: value['dependencies_sha256']['scripts/import_chat.py'] = '0' * 64
                return value
            def transport(*_args, **_kwargs):
                calls.append(1)
                paths = {'source': fixture.source, 'report': fixture.report_path, 'proof': fixture.proof,
                    'export': fixture.exports / 'hybrid.jsonl', 'protocol': fixture.protocol, 'controls': controls}
                if target != 'dependency': paths[target].write_bytes(paths[target].read_bytes() + b' ')
                return response()
            with patch.object(adapter, 'fingerprints', side_effect=fingerprint):
                report = adapter.run(bundle, fixture.protocol, controls, controls_sha, fixture.root / 'qa',
                    fixture.root / 'qa-private', transport=transport)
            self.assertEqual(len(calls), 1)
            self.assertEqual(report['summary']['all']['judge_unknown_attempts'], 28)
            self.assertEqual(report['attempts'][0]['raw_response_sha256'], qa.digest(response()))
            self.assertEqual(report['attempts'][0]['usage']['prompt_tokens'], 50)

    def test_bundle_mutation_bypass_midcall_stops_future_calls(self):
        fixture = self.fixture(); bundle = fixture.validated(); calls = []
        def transport(*_args, **_kwargs):
            calls.append(1); dict.__setitem__(bundle.attempts[0], 'hypothesis', 'PRIVATE mutation'); return response()
        report = fixture.execute(bundle, transport)
        self.assertEqual(len(calls), 1); self.assertEqual(report['summary']['all']['judge_unknown_attempts'], 28)

    def test_final_eligible_response_drift_preserves_capture_usage_without_credit(self):
        for target in ('source', 'report', 'proof', 'export', 'protocol', 'controls', 'dependency', 'bundle'):
            fixture = self.fixture(); bundle = fixture.validated(); controls, controls_sha = fixture.valid_controls(); calls = []
            original_fp = adapter.fingerprints
            def fingerprint(settings, raw):
                value = original_fp(settings, raw)
                if target == 'dependency' and len(calls) == 28:
                    value['dependencies_sha256']['scripts/import_chat.py'] = '0' * 64
                return value
            def transport(*_args, **_kwargs):
                calls.append(1)
                if len(calls) == 28:
                    paths = {'source': fixture.source, 'report': fixture.report_path, 'proof': fixture.proof,
                        'export': fixture.exports / 'hybrid.jsonl', 'protocol': fixture.protocol, 'controls': controls}
                    if target == 'bundle': dict.__setitem__(bundle.pins, 'source_sha256', '0' * 64)
                    elif target != 'dependency': paths[target].write_bytes(paths[target].read_bytes() + b' ')
                return response()
            with patch.object(adapter, 'fingerprints', side_effect=fingerprint):
                report = adapter.run(bundle, fixture.protocol, controls, controls_sha, fixture.root / 'qa',
                    fixture.root / 'qa-private', transport=transport)
            self.assertEqual(len(calls), 28)
            self.assertEqual(report['summary']['all']['scored_attempts'], 27)
            self.assertEqual(report['summary']['all']['judge_unknown_attempts'], 1)
            final = report['attempts'][-1]
            self.assertFalse(final['scored']); self.assertIsNone(final['upstream_yes_substring_label'])
            self.assertEqual(final['raw_response_sha256'], qa.digest(response()))
            self.assertEqual(final['usage']['prompt_tokens'], 50)
            self.assertEqual((fixture.root / 'qa-private/judgment-0027.json').read_bytes(), response())

    def test_matching_controls_are_required_with_unchanged_shared_fingerprint(self):
        for target in ('settings', 'result', 'count'):
            fixture = self.fixture(); bundle = fixture.validated(); controls, digest = fixture.valid_controls()
            report = qa.strict_json(controls.read_bytes())
            if target == 'settings': report['fingerprints']['model_settings_sha256'] = '0' * 64
            elif target == 'result': report['attempts'][0]['upstream_yes_substring_label'] = False
            else: report['attempts'].pop()
            controls.write_bytes(qa.canonical(report))
            with self.assertRaises(qa.GradeError): adapter.run(bundle, fixture.protocol, controls, qa.digest(controls.read_bytes()),
                fixture.root / 'qa', fixture.root / 'qa-private', transport=lambda *_a, **_k: self.fail('control-invalid call'))

    def test_absolute_fresh_separate_paths_and_input_collisions(self):
        fixture = self.fixture(); bundle = fixture.validated(); controls, digest = fixture.valid_controls()
        existing = fixture.root / 'existing'; existing.mkdir()
        for output, private in (('relative', fixture.root / 'private'), (fixture.root / 'same', fixture.root / 'same'),
            (fixture.root / 'parent', fixture.root / 'parent/child'), (existing, fixture.root / 'private'),
            (fixture.root, fixture.root.parent / 'unused-independent-private')):
            with self.assertRaises(qa.GradeError): adapter.run(bundle, fixture.protocol, controls, digest, output, private)
        self.assertFalse((fixture.root.parent / 'unused-independent-private').exists())

    def test_symlink_inputs_destinations_and_remote_endpoint_refused(self):
        fixture = self.fixture(); bundle = fixture.validated(); controls, digest = fixture.valid_controls()
        link = fixture.root / 'linked'; link.symlink_to(fixture.root / 'exports', target_is_directory=True)
        with self.assertRaises(qa.GradeError): adapter.run(bundle, fixture.protocol, controls, digest,
            link / 'qa', fixture.root / 'private')
        source = fixture.root / 'source-link'; source.symlink_to(fixture.source)
        with self.assertRaises(qa.GradeError): adapter.validate_bundle(fixture.report_path, qa.digest(fixture.report_path.read_bytes()),
            fixture.exports, source, fixture.proof)
        for endpoint in ('https://localhost:11234/v1/', 'http://example.com:11234/v1/', 'http://user:secret@localhost:11234/v1/'):
            with self.assertRaises(qa.GradeError): adapter.run(bundle, fixture.protocol, controls, digest,
                fixture.root / 'qa', fixture.root / 'private', endpoint=endpoint)

    def test_cli_requires_execute_and_suppresses_private_parse_errors(self):
        args = []
        for name in ('source', 'answer-report', 'answer-report-sha256', 'hypotheses-directory', 'binary-verification',
            'protocol', 'controls-report', 'controls-report-sha256', 'output-directory', 'private-directory'):
            args.extend(['--' + name, 'PRIVATE-unused'])
        for arguments in (args, args + ['--timeout', 'PRIVATE-credential'], args + ['--PRIVATE-invalid']):
            out, err = io.StringIO(), io.StringIO()
            with redirect_stdout(out), redirect_stderr(err), patch.object(adapter, 'validate_bundle', side_effect=AssertionError('must not read')):
                self.assertEqual(adapter.main(arguments), 1)
            self.assertNotIn('PRIVATE', out.getvalue() + err.getvalue())


if __name__ == '__main__':
    result = unittest.TextTestRunner(stream=io.StringIO()).run(unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    print(json.dumps({'checks': result.testsRun, 'failed': [test.id() for test, _ in result.failures],
        'errors': [test.id() for test, _ in result.errors], 'skipped': len(result.skipped)}))
    raise SystemExit(not result.wasSuccessful())
