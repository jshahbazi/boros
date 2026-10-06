#!/usr/bin/env python3
"""Portable six-control grading checks; no dataset, model, or provider calls."""
from __future__ import annotations

import base64
from contextlib import ExitStack, redirect_stderr, redirect_stdout
import copy
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

import evaluate_answers as e
import evaluate_longmemeval as baseline
import evaluate_longmemeval_source_controls as runner
import local_longmemeval_qa as qa
import local_longmemeval_source_control_qa as control_qa
import longmemeval_source_controls as controls
from test_local_longmemeval_qa import response, source_fixture
from test_longmemeval_source_controls import report as native_fixture


class Fixture:
    def __init__(self, root, stack, *, failed=False, ineligible=False, continuity=True):
        self.root = root
        rows = source_fixture()
        for row in rows:
            first = row['haystack_sessions'][0]
            row['haystack_sessions'] = [first, [dict(turn, content=turn['content'] + ' second') for turn in first]]
            row['haystack_dates'] *= 2
            row['haystack_session_ids'] = ['evidence', 'second']
        raw = qa.canonical(rows)
        self.pins = qa.SourcePins(sha256=qa.digest(raw), byte_count=len(raw), record_count=7)
        self.source = root / 'source.json'; qa.private_write(self.source, raw)
        histories = controls.cases.prepare_rows(rows, self.pins.sha256)[:6]
        packs = {h['id']: [s['id'] for s in h['events']] for h in histories}
        stack.enter_context(patch.object(controls, 'PACKS', packs))
        docs = [controls.runner_input(h, runner.CONFIGURATION) for h in histories]
        stack.enter_context(patch.object(controls, 'PROJECTION_PINS', {
            h['id']: controls.projection_sha256(d) for h, d in zip(histories, docs)}))
        stack.enter_context(patch.object(controls, 'PACK_INVENTORY_PINS', {
            h['id']: qa.digest(qa.canonical(controls.source_inventory(h, packs[h['id']]))) for h in histories}))
        annotations = [controls.declaration_case(h, d) for h, d in zip(histories, docs)]
        directory = Path(control_qa.__file__).resolve().parent
        hashes = {'scripts/' + name: qa.digest(qa.read_file(directory / name)) for name in control_qa.HISTORICAL_DEPENDENCIES}
        hashes['Sources/Boros/AnswerEvaluationCommand.swift'] = 'a' * 64
        self.proof = root / 'proof.json'
        proof = {'terminal_passed': True, 'app_binary_sha256': 'b' * 64,
                 'source_hashes': {**hashes, 'Tests/synthetic.json': 'c' * 64}}
        qa.private_write(self.proof, qa.canonical(proof))
        declaration = {'version': 1, 'control_version': controls.CONTROL_VERSION, 'split': 'development',
            'declared_attempts': 6, 'runner_document_version': 6, 'strategy': 'hybrid', 'replicates': 1,
            'case_ids': list(controls.CASE_IDS), 'cases': annotations, 'source_revision': self.pins.revision,
            'source_sha256': self.pins.sha256, 'source_bytes': self.pins.byte_count, 'source_hashes': hashes,
            'configuration_sha256': qa.digest(qa.canonical(runner.CONFIGURATION)),
            'native_configuration_sha256': baseline.native_configuration_sha256(runner.CONFIGURATION),
            'system_sha256': qa.digest(runner.CONFIGURATION['system'].encode()), 'ordinary_recall_arm': False,
            'selection_uses_positive_annotations': True, 'semantic_sufficiency': None, 'provider_token_feasibility': None,
            'official_qa_status': 'not_run_source_control_judge', 'official_qa_score': None}
        measured, predictions = [], []
        for index, (history, doc, annotation) in enumerate(zip(histories, docs, annotations)):
            native = native_fixture(history, root / ('native-' + str(index)), doc)
            item = native['attempts'][0]; audit = item['preparation']['context_audit']
            audit['components'] = copy.deepcopy(item['preparation']['admission']['componentProof'])
            if failed and index == 0:
                item.update(episode_state='failed', invocation_status='partial', failure='incomplete_result')
            if ineligible and index == 1:
                item['delivered_ranges'].pop(0); audit['historical_sources'].pop(0)
                item['source_control_validation'].update(delivered_source_count=3,
                    complete_declared_sources_delivered=False, failure_code='declared_sources_not_delivered')
            item['preparation']['admission_audit']['context'] = base64.b64encode(qa.canonical(audit)).decode()
            row, prediction = runner.score_native(native, root / ('native-' + str(index)), history, doc,
                                                 source_ids=packs[history['id']])
            measured.append({'case': annotation, 'attempts': [row], 'driver': e.native_metadata(native)})
            predictions.append(prediction)
        self.exports = root / 'exports'; self.exports.mkdir(mode=0o700)
        export = b''.join(qa.canonical(v) + b'\n' for v in predictions)
        qa.private_write(self.exports / 'source_control.jsonl', export)
        self.report = {'source_control_evaluation_version': 1, 'control_version': controls.CONTROL_VERSION,
            'runner_document_version': 6, 'split': 'development', 'registration_status': 'unregistered_reused_development_source_control',
            'ordinary_recall_arm': False, 'implementation_continuity': continuity, 'declaration': declaration,
            'configuration': {k: v for k, v in runner.CONFIGURATION.items() if k != 'system'},
            'implementation': {'source_sha256': hashes, 'binary_sha256': 'b' * 64,
                'binary_verification_sha256': qa.digest(self.proof.read_bytes()),
                'source_binary_linkage': 'terminal_build_record_matches_all_native_sources',
                'python_dependencies_captured_before_compile': True},
            'histories': measured, 'summary': runner.summarize([v['attempts'][0] for v in measured]),
            'private_hypothesis_exports': {'source_control': {'records': 6, 'bytes': len(export), 'sha256': qa.digest(export)}}}
        self.report_path = root / 'answers.json'
        self.publish()
        self.protocol = root / 'protocol.py'
        self.protocol_raw = b"import unavailable_dependency\ndef get_anscheck_prompt(task, question, answer, hypothesis, abstention=False):\n    return f'{task}|{question}|{answer}|{hypothesis}|{abstention}'\n"
        qa.private_write(self.protocol, self.protocol_raw)
        stack.enter_context(patch.object(qa, 'PROTOCOL_SHA256', qa.digest(self.protocol_raw)))

    def publish(self):
        raw = qa.canonical(self.report['declaration']) + b'\n'
        self.report['declaration_sha256'] = qa.digest(raw)
        (self.exports / 'declaration.json').write_bytes(raw); os.chmod(self.exports / 'declaration.json', 0o600)
        self.report_path.write_bytes(qa.canonical(self.report)); os.chmod(self.report_path, 0o600)
        return qa.digest(self.report_path.read_bytes())

    def validated(self):
        return control_qa.validate_bundle(self.report_path, qa.digest(self.report_path.read_bytes()),
            self.exports, self.source, self.proof, self.pins)

    def valid_controls(self):
        # Publish matching existing-helper synthetic controls using fixed private
        # truth; the adapter never changes the helper's fingerprint contract.
        settings = qa.local_settings(qa.ANSWER_CONFIGURATION['endpoint'])
        specs = qa.control_specification()
        rows = [{'ordinal': i, 'category': s['category'], 'expected': s['expected'], 'scored': True,
                 'strict_yes_no_format_valid': True, 'terminal_status': 'completed',
                 'upstream_yes_substring_label': s['expected']} for i, s in enumerate(specs)]
        path = self.root / 'validated-controls.json'
        qa.private_write(path, qa.canonical({'local_qa_diagnostic_version': 1, 'mode': 'controls',
            'synthetic_controls_validated': True, 'fingerprints': qa.fingerprints(settings, self.protocol_raw), 'attempts': rows}))
        return path, qa.digest(path.read_bytes())

    def execute(self, bundle=None, transport=None, suffix='qa'):
        path, digest = self.valid_controls()
        return control_qa.run(bundle or self.validated(), self.protocol, path, digest,
            self.root / suffix, self.root / (suffix + '-private'), transport=transport or (lambda *_a, **_k: response()))


class Contracts(unittest.TestCase):
    def fixture(self, **kwargs):
        temporary = self.enterContext(tempfile.TemporaryDirectory())
        stack = self.enterContext(ExitStack())
        return Fixture(Path(temporary).resolve(), stack, **kwargs)

    def test_exact_six_inputs_and_separate_dates_pack_pins(self):
        f = self.fixture(); bundle = f.validated()
        self.assertEqual(len(bundle.attempts), 6)
        self.assertEqual(tuple(a['category'] for a in bundle.attempts), qa.CASE_TYPES[:6])
        self.assertTrue(all(a['judge_eligible'] for a in bundle.attempts))
        self.assertEqual(len(bundle.pins['source_inventory_sha256']), 6)
        self.assertEqual(len(bundle.pins['oracle_projection_sha256']), 6)
        self.assertTrue(all(not a['abstention'] for a in bundle.attempts))

    def test_report_declaration_projection_inventory_and_shape_tamper(self):
        mutations = [lambda r: r.__setitem__('runner_document_version', 5),
            lambda r: r['declaration']['cases'][0].__setitem__('question_time_sha256', '0' * 64),
            lambda r: r['declaration']['cases'][0]['source_inventory'][0].__setitem__('sha256', '0' * 64),
            lambda r: r['declaration']['cases'][0].__setitem__('public_projection_sha256', '0' * 64),
            lambda r: r['histories'].reverse(), lambda r: r['histories'][0]['attempts'].append(copy.deepcopy(r['histories'][0]['attempts'][0])),
            lambda r: r['histories'][0]['attempts'][0].__setitem__('replicate', True),
            lambda r: r['histories'][0]['attempts'][0].__setitem__('strategy', 'recent_only'),
            lambda r: r['configuration'].__setitem__('maximum_output', 1024)]
        for mutate in mutations:
            with self.subTest(mutation=mutations.index(mutate)):
                f = self.fixture(); mutate(f.report); f.publish()
                with self.assertRaises(qa.GradeError): f.validated()

    def test_report_source_proof_and_export_hash_tamper(self):
        for target in ('report', 'source', 'proof', 'export'):
            f = self.fixture()
            paths = {'report': f.report_path, 'source': f.source, 'proof': f.proof,
                     'export': f.exports / 'source_control.jsonl'}
            paths[target].write_bytes(paths[target].read_bytes() + b' ')
            with self.assertRaises(qa.GradeError):
                control_qa.validate_bundle(f.report_path, '0' * 64 if target == 'report' else qa.digest(f.report_path.read_bytes()),
                    f.exports, f.source, f.proof, f.pins)

    def test_historical_proof_native_subset_and_loaded_projection_dependency_pins(self):
        for kind in ('native', 'dependency', 'terminal'):
            f = self.fixture(); proof = qa.strict_json(f.proof.read_bytes())
            if kind == 'native': proof['source_hashes']['Sources/Boros/AnswerEvaluationCommand.swift'] = 'f' * 64
            elif kind == 'dependency':
                f.report['declaration']['source_hashes']['scripts/longmemeval_cases.py'] = 'f' * 64
                proof['source_hashes']['scripts/longmemeval_cases.py'] = 'f' * 64
            else: proof['terminal_passed'] = False
            f.proof.write_bytes(qa.canonical(proof)); f.report['implementation']['binary_verification_sha256'] = qa.digest(f.proof.read_bytes()); f.publish()
            with self.assertRaises(qa.GradeError): f.validated()

    def test_historical_inventory_does_not_compare_all_current_new_grader_files(self):
        f = self.fixture()
        self.assertNotIn('scripts/local_longmemeval_source_control_qa.py', f.report['declaration']['source_hashes'])
        with patch.object(baseline, 'code_inventory', side_effect=AssertionError('must not compare current inventory')):
            self.assertEqual(len(f.validated().attempts), 6)

    def test_range_digest_and_declared_binding_and_receipt_tamper(self):
        for kind in ('range', 'selection', 'receipt', 'context'):
            f = self.fixture(); m = f.report['histories'][0]['attempts'][0]['metadata']; p = m['preparation']
            if kind == 'range': m['delivered_ranges'][0]['field_sha256_' + qa.digest(b'sha256')] = '0' * 64
            elif kind == 'selection': p['context_audit']['retrieval']['declared_source_ids_sha256'] = '0' * 64
            elif kind == 'receipt': p['admission']['bodyDigest'] = '0' * 64
            else: control_qa.field(control_qa.field(p, 'admission_audit'), 'context')['sha256'] = 'invalid'
            f.publish()
            with self.assertRaises(qa.GradeError): f.validated()

    def test_eligible_denominator_and_private_capture_and_exact_official_requests(self):
        f = self.fixture(failed=True, ineligible=True); bundle = f.validated(); calls = []
        def transport(settings, raw, timeout):
            calls.append(raw); return response('yes')
        result = f.execute(bundle, transport)
        summary = result['summary']['all']
        self.assertEqual((summary['declared_attempts'], summary['eligible_attempts'], summary['scored_attempts']), (6, 4, 4))
        self.assertEqual((summary['operational_failed_attempts'], summary['delivery_ineligible_attempts']), (1, 1))
        self.assertEqual(summary['accepted_fraction_declared'], 4 / 6)
        private = f.root / 'qa-private'; captured = [qa.strict_json(v) for v in (private / 'requests.jsonl').read_bytes().splitlines()]
        self.assertEqual(len(captured), 6); self.assertEqual(len(calls), 4)
        self.assertTrue(all(qa.canonical(v) == raw for v, raw in zip(captured[2:], calls)))
        self.assertEqual(len(list(private.glob('judgment-*.json'))), 4)
        self.assertEqual(stat.S_IMODE(private.stat().st_mode), 0o700)
        self.assertTrue(all(stat.S_IMODE(v.stat().st_mode) == 0o600 for v in private.iterdir()))
        public = (f.root / 'qa/report.json').read_bytes() + (f.root / 'qa/declaration.json').read_bytes()
        self.assertNotIn(b'PRIVATE', public); self.assertNotIn(b'private generated', public)
        self.assertIsNone(result['semantic_sufficiency']); self.assertIsNone(result['official_qa_score'])

    def test_failed_continuity_retains_six_and_never_calls(self):
        f = self.fixture(continuity=False)
        result = f.execute(transport=lambda *_a, **_k: self.fail('ineligible call'))
        self.assertEqual(result['summary']['all']['implementation_unverified_attempts'], 6)
        self.assertEqual(result['summary']['all']['scored_attempts'], 0)
        self.assertEqual(result['summary']['all']['declared_attempts'], 6)

    def test_failed_continuity_with_genuine_unavailable_metadata_retains_six(self):
        f = self.fixture(continuity=False)
        raw = f.source.read_bytes(); histories = controls.cases.prepare_rows(qa.strict_json(raw), f.pins.sha256)[:6]
        rows = [qa.strict_json(v) for v in (f.exports / 'source_control.jsonl').read_bytes().splitlines()]
        for index in range(2, 6):
            doc = controls.runner_input(histories[index], runner.CONFIGURATION)
            row = runner._empty_attempt(histories[index], doc['attempts'][0], 'implementation_changed')
            self.assertIsNone(row['metadata'])
            f.report['histories'][index]['attempts'] = [row]
            f.report['histories'][index]['driver'] = {'version': 1, 'fatal_failure': 'implementation_changed'}
            rows[index]['hypothesis'] = ''
        raw = b''.join(qa.canonical(v) + b'\n' for v in rows)
        (f.exports / 'source_control.jsonl').write_bytes(raw)
        f.report['private_hypothesis_exports']['source_control'] = {'records': 6, 'bytes': len(raw), 'sha256': qa.digest(raw)}
        f.report['summary'] = runner.summarize([h['attempts'][0] for h in f.report['histories']]); f.publish()
        result = f.execute(transport=lambda *_a, **_k: self.fail('continuity-unverified call'))
        self.assertEqual(result['summary']['all']['implementation_unverified_attempts'], 6)
        self.assertEqual(result['summary']['all']['declared_attempts'], 6)

    def test_native_setup_acceptance_and_nonterminal_unavailable_rows_retained(self):
        f = self.fixture(); histories = controls.cases.prepare_rows(qa.strict_json(f.source.read_bytes()), f.pins.sha256)[:6]
        predictions = [qa.strict_json(v) for v in (f.exports / 'source_control.jsonl').read_bytes().splitlines()]
        for index in range(3):
            history = histories[index]; doc = controls.runner_input(history, runner.CONFIGURATION)
            row = f.report['histories'][index]['attempts'][0]; meta = row['metadata']
            outcome = runner.unavailable_control(history, doc['attempts'][0])
            row.update(operational_complete=False, full_pack_delivery_eligible=False,
                       source_control_validation=outcome, failure_code='native_attempt_incomplete', delivery=None)
            meta.update(preparation=None, delivered_ranges=[], delivered_recent_source_ids=[],
                        source_control_validation=outcome, episode_state='failed', invocation_status='failed')
            for key in ('capture_healthy', 'accounting_healthy', 'invocation_started'): meta.pop(key)
            if index == 2:
                meta['terminalized'] = False
                f.report['histories'][index]['driver']['completed_attempts'] = 0
            predictions[index]['hypothesis'] = ''
        raw = b''.join(qa.canonical(v) + b'\n' for v in predictions)
        (f.exports / 'source_control.jsonl').write_bytes(raw)
        f.report['private_hypothesis_exports']['source_control'] = {'records': 6, 'bytes': len(raw), 'sha256': qa.digest(raw)}
        f.report['summary'] = runner.summarize([h['attempts'][0] for h in f.report['histories']]); f.publish()
        calls = []
        result = f.execute(transport=lambda *_a, **_k: calls.append(1) or response())
        self.assertEqual(len(calls), 3)
        self.assertEqual(result['summary']['all']['operational_failed_attempts'], 3)
        self.assertEqual(result['summary']['all']['declared_attempts'], 6)

    def test_failed_export_must_be_empty_and_completed_hash_must_match(self):
        for failed in (False, True):
            f = self.fixture(failed=failed); path = f.exports / 'source_control.jsonl'
            rows = [qa.strict_json(v) for v in path.read_bytes().splitlines()]; rows[0]['hypothesis'] = 'changed synthetic hypothesis'
            raw = b''.join(qa.canonical(v) + b'\n' for v in rows); path.write_bytes(raw)
            f.report['private_hypothesis_exports']['source_control'] = {'records': 6, 'bytes': len(raw), 'sha256': qa.digest(raw)}; f.publish()
            with self.assertRaises(qa.GradeError): f.validated()

    def test_export_unknown_fields_order_and_duplicate_json_refused(self):
        for kind in ('field', 'order', 'duplicate'):
            f = self.fixture(); path = f.exports / 'source_control.jsonl'; rows = [qa.strict_json(v) for v in path.read_bytes().splitlines()]
            if kind == 'field': rows[0]['oracle'] = 'forbidden'
            elif kind == 'order': rows.reverse()
            raw = b''.join(qa.canonical(v) + b'\n' for v in rows)
            if kind == 'duplicate': raw = raw.replace(b'"hypothesis":', b'"hypothesis":"x","hypothesis":', 1)
            path.write_bytes(raw); f.report['private_hypothesis_exports']['source_control'] = {'records': 6, 'bytes': len(raw), 'sha256': qa.digest(raw)}; f.publish()
            with self.assertRaises(qa.GradeError): f.validated()

    def test_judge_unknown_and_fixed_diagnostics_retain_denominator(self):
        f = self.fixture(); calls = []
        def transport(*_args, **_kwargs):
            calls.append(1)
            if len(calls) == 1: raise ValueError('PRIVATE synthetic error sentinel')
            return response('yes, explanation')
        result = f.execute(transport=transport)
        self.assertEqual(result['summary']['all']['judge_unknown_attempts'], 6)
        self.assertEqual(result['summary']['all']['declared_attempts'], 6)
        self.assertNotIn('PRIVATE', qa.canonical(result).decode())

    def test_input_mutation_after_declaration_stops_future_calls(self):
        f = self.fixture(); bundle = f.validated(); calls = []
        def transport(*_args, **_kwargs):
            calls.append(1); f.source.write_bytes(f.source.read_bytes() + b' '); return response()
        result = f.execute(bundle, transport)
        self.assertEqual(len(calls), 1)
        self.assertEqual(result['summary']['all']['scored_attempts'], 1)
        self.assertEqual(result['summary']['all']['judge_unknown_attempts'], 5)

    def test_input_mutation_before_declaration_is_refused_without_output(self):
        f = self.fixture(); bundle = f.validated()
        f.proof.write_bytes(f.proof.read_bytes() + b' ')
        with self.assertRaises(qa.GradeError): f.execute(bundle, lambda *_a, **_k: self.fail('changed input call'))
        self.assertFalse((f.root / 'qa').exists())

    def test_in_memory_attempt_and_pin_changes_before_run_refused(self):
        for kind in ('hypothesis', 'eligibility', 'pins'):
            f = self.fixture(); bundle = f.validated()
            if kind == 'hypothesis': bundle.attempts[0]['hypothesis'] = 'changed synthetic hypothesis'
            elif kind == 'eligibility': bundle.attempts[0]['judge_eligible'] = False
            else: bundle.pins['binary_sha256'] = '0' * 64
            with self.assertRaises(qa.GradeError): f.execute(bundle, lambda *_a, **_k: self.fail('mutated bundle call'))
            self.assertFalse((f.root / 'qa').exists())

    def test_external_pin_mutation_during_transport_cannot_change_declaration(self):
        f = self.fixture(); bundle = f.validated()
        original = copy.deepcopy(bundle.pins)
        def transport(*_a, **_k):
            bundle.pins['binary_sha256'] = '0' * 64
            bundle.attempts[0]['hypothesis'] = 'changed after private materialization'
            return response()
        result = f.execute(bundle, transport)
        raw = (f.root / 'qa/declaration.json').read_bytes(); declaration = qa.strict_json(raw)
        self.assertEqual(result['declaration_sha256'], qa.digest(raw))
        self.assertEqual(declaration['input_pins'], original)
        self.assertEqual(result['summary']['all']['scored_attempts'], 6)

    def test_canonical_request_drift_never_dispatches(self):
        f = self.fixture(); bundle = f.validated(); real = qa.make_request; constructed = []
        def make(*args, **kwargs):
            raw = real(*args, **kwargs); constructed.append(1)
            return raw if len(constructed) <= 6 else raw + b' '
        with patch.object(qa, 'make_request', side_effect=make):
            result = f.execute(bundle, lambda *_a, **_k: self.fail('changed request call'))
        self.assertEqual(result['summary']['all']['judge_unknown_attempts'], 6)

    def test_dependency_drift_before_call_stops_dispatch(self):
        f = self.fixture(); bundle = f.validated(); real = control_qa.fingerprints; reads = []
        def fingerprint(*args):
            value = real(*args); reads.append(1)
            if len(reads) > 1: value['adapter_version'] = 'changed'
            return value
        with patch.object(control_qa, 'fingerprints', side_effect=fingerprint):
            result = f.execute(bundle, lambda *_a, **_k: self.fail('changed dependency call'))
        self.assertEqual(result['summary']['all']['judge_unknown_attempts'], 6)

    def test_fake_http_reuses_no_proxy_no_redirect_and_strict_parser(self):
        f = self.fixture(); raw = response('no'); observed = []
        class Stream:
            def __enter__(self): return self
            def __exit__(self, *_): return False
            def read(self, _): return raw
        class Opener:
            def open(self, request, timeout):
                observed.append((request.data, timeout)); return Stream()
        def build(*handlers):
            self.assertEqual(handlers[0].proxies, {})
            self.assertIsInstance(handlers[1], qa.NoRedirect)
            return Opener()
        with patch.object(qa, 'build_opener', side_effect=build): result = f.execute(transport=qa.call_local)
        self.assertEqual(len(observed), 6)
        self.assertEqual(result['summary']['all']['accepted_count'], 0)
        self.assertEqual(result['summary']['all']['scored_attempts'], 6)

    def test_matching_control_report_required_and_endpoint_and_destinations_refused(self):
        f = self.fixture(); bundle = f.validated(); path, digest = f.valid_controls()
        with self.assertRaises(qa.GradeError):
            control_qa.run(bundle, f.protocol, path, '0' * 64, f.root / 'qa', f.root / 'private')
        for endpoint in ('https://localhost:11234/v1/', 'http://example.com:11234/v1/'):
            with self.assertRaises(qa.GradeError):
                control_qa.run(bundle, f.protocol, path, digest, f.root / 'qa', f.root / 'private', endpoint=endpoint)
        for output, private in (('relative', f.root / 'private'), (f.root / 'same', f.root / 'same'),
                                (f.root / 'parent', f.root / 'parent/child')):
            with self.assertRaises(qa.GradeError):
                control_qa.run(bundle, f.protocol, path, digest, output, private)

    def test_control_settings_mismatch_and_input_destination_collision_refused(self):
        f = self.fixture(); bundle = f.validated(); path, digest = f.valid_controls()
        value = qa.strict_json(path.read_bytes()); value['fingerprints']['model_settings_sha256'] = '0' * 64
        path.write_bytes(qa.canonical(value))
        with self.assertRaises(qa.GradeError):
            control_qa.run(bundle, f.protocol, path, qa.digest(path.read_bytes()), f.root / 'qa', f.root / 'private')
        value['fingerprints'] = qa.fingerprints(qa.local_settings(qa.ANSWER_CONFIGURATION['endpoint']), f.protocol_raw)
        path.write_bytes(qa.canonical(value))
        with self.assertRaises(qa.GradeError):
            control_qa.run(bundle, f.protocol, path, qa.digest(path.read_bytes()), f.root, f.root.parent / 'forbidden-private')
        self.assertFalse((f.root.parent / 'forbidden-private').exists())

    def test_cli_requires_explicit_execute_and_never_prints_arguments(self):
        args = []
        for name in ('source', 'answer-report', 'answer-report-sha256', 'hypotheses-directory', 'binary-verification',
                     'protocol', 'controls-report', 'controls-report-sha256', 'output-directory', 'private-directory'):
            args.extend(['--' + name, 'PRIVATE-unused'])
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err), patch.object(control_qa, 'validate_bundle', side_effect=AssertionError('must not read')):
            self.assertEqual(control_qa.main(args), 1)
        self.assertNotIn('PRIVATE', out.getvalue() + err.getvalue())


if __name__ == '__main__':
    result = unittest.TextTestRunner(stream=io.StringIO()).run(unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    print(json.dumps({'checks': result.testsRun, 'failed': [t.id() for t, _ in result.failures],
                     'errors': [t.id() for t, _ in result.errors], 'skipped': len(result.skipped)}))
    raise SystemExit(not result.wasSuccessful())
