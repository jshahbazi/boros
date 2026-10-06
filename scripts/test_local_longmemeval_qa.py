#!/usr/bin/env python3
"""Controlled synthetic checks. No sockets, provider calls, or content logs."""
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import local_longmemeval_qa as q

ROOT = Path(__file__).resolve().parents[1]
PROTOCOL = Path('unused-synthetic-protocol')


def response(content='yes', finish='stop', model=q.MODEL, usage=True):
    result = {'model': model, 'choices': [{'message': {'role': 'assistant', 'content': content}, 'finish_reason': finish}]}
    if usage:
        result['usage'] = {'prompt_tokens': 50, 'completion_tokens': 1, 'total_tokens': 51}
    return q.canonical(result)


def source_fixture():
    rows = []
    for i, (qid, kind) in enumerate(zip(q.CASE_IDS, q.CASE_TYPES)):
        rows.append({'question_id': qid, 'question_type': kind, 'question': 'PRIVATE synthetic query sentinel',
            'question_date': '2023/07/27 (Thu) 18:00', 'answer': 7 if i == 0 else 'PRIVATE synthetic reference sentinel',
            'answer_session_ids': ['evidence'], 'haystack_dates': ['2023/07/27 (Thu) 18:00'],
            'haystack_session_ids': ['evidence'], 'haystack_sessions': [[
                {'role': 'user', 'content': 'PRIVATE synthetic source sentinel π', 'has_answer': True},
                {'role': 'assistant', 'content': 'PRIVATE synthetic assistant sentinel'}]]})
    return rows


def bundle_fixture(root, version=5):
    source_raw = q.canonical(source_fixture())
    pins = q.SourcePins(sha256=q.digest(source_raw), byte_count=len(source_raw), record_count=7)
    source = root / 'source.json'; source.write_bytes(source_raw)
    cases = q.project_cases(source_raw, pins)
    configuration = q.ANSWER_CONFIGURATION
    normalized = {k: int(v) if type(v) is float and v.is_integer() else v for k, v in configuration.items()}
    annotations = [q.case_annotation(case, version, configuration) for case in cases]
    declaration = {'version': 1, 'split': 'development', 'declared_attempts': 14, 'case_ids': list(q.CASE_IDS),
        'source_revision': pins.revision, 'source_sha256': pins.sha256,
        'configuration_sha256': q.digest(q.canonical(configuration)),
        'native_configuration_sha256': q.digest(q.canonical(normalized)),
        'system_sha256': q.digest(configuration['system'].encode()), 'cases': annotations,
        'protocol_hashes': {'src/evaluation/evaluate_qa.py': q.PROTOCOL_SHA256}}
    if version == 5:
        declaration['runner_document_version'] = 5
    export = root / 'exports'; export.mkdir()
    declaration_raw = q.canonical(declaration) + b'\n'
    (export / 'declaration.json').write_bytes(declaration_raw)
    report = {'longmemeval_evaluation_version': 1, 'runner_document_version': version, 'split': 'development',
        'registration_status': 'unregistered_development_subset', 'declaration': declaration,
        'declaration_sha256': q.digest(declaration_raw), 'configuration': {k: v for k, v in configuration.items() if k != 'system'},
        'source': {'sha256': pins.sha256, 'bytes': pins.byte_count, 'revision': pins.revision, 'path': pins.name},
        'histories': [], 'private_hypothesis_exports': {}}
    hypothesis = 'PRIVATE synthetic answer sentinel'
    for strategy in q.STRATEGIES:
        raw = b''.join(q.canonical({'question_id': qid, 'hypothesis': hypothesis}) + b'\n' for qid in q.CASE_IDS)
        (export / (strategy + '.jsonl')).write_bytes(raw)
        report['private_hypothesis_exports'][strategy] = {'records': 7, 'bytes': len(raw), 'sha256': q.digest(raw)}
    for annotation in annotations:
        attempts = [{'question_id': annotation['question_id'], 'question_type': annotation['question_type'],
            'abstention': annotation['abstention'], 'strategy': strategy, 'ordinal': ordinal, 'replicate': 0,
            'operational_complete': True, 'answer_bytes': len(hypothesis.encode()), 'answer_sha256': q.digest(hypothesis.encode())}
            for ordinal, strategy in enumerate(q.STRATEGIES)]
        report['histories'].append({'case': annotation, 'attempts': attempts})
    path = root / 'report.json'; path.write_bytes(q.canonical(report))
    return path, export, source, pins, report


def publish_fixture(path, export, report):
    declaration_raw = q.canonical(report['declaration']) + b'\n'
    report['declaration_sha256'] = q.digest(declaration_raw)
    (export / 'declaration.json').write_bytes(declaration_raw)
    path.write_bytes(q.canonical(report))
    return q.digest(path.read_bytes())


class Contracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = tempfile.TemporaryDirectory()
        path = Path(cls.fixture.name).resolve() / 'protocol.py'
        cls.protocol_raw = b"import openai\nimport np\ndef get_anscheck_prompt(task, question, answer, hypothesis, abstention=False):\n    return f'{task} | {question} | {answer} | {hypothesis} | {abstention}'\n"
        path.write_bytes(cls.protocol_raw)
        cls.fixture_sha = q.digest(cls.protocol_raw)
        function, _ = q.load_prompt_function(path, expected_sha=cls.fixture_sha)
        cls.prompt_function = staticmethod(function)

    @classmethod
    def tearDownClass(cls):
        cls.fixture.cleanup()

    def test_pinned_ast_function_loads_without_imports(self):
        self.assertNotIn('openai', self.prompt_function.__globals__)
        self.assertNotIn('np', self.prompt_function.__globals__)
        self.assertEqual(q.digest(self.protocol_raw), self.fixture_sha)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary).resolve() / 'protocol'; path.write_bytes(self.protocol_raw + b'\n')
            with self.assertRaises(q.GradeError): q.load_prompt_function(path, expected_sha=self.fixture_sha)

    def test_all_requests_match_exact_official_function(self):
        settings = q.local_settings(q.ANSWER_CONFIGURATION['endpoint'])
        specs = q.control_specification()
        self.assertEqual(len(specs), 14)
        self.assertEqual(len({r['category'] for r in specs}), 7)
        for spec in specs:
            payload = q.strict_json(q.make_request(self.prompt_function, spec['task'], spec['question'], spec['reference'],
                spec['hypothesis'], spec['abstention'], settings))
            self.assertEqual(payload['messages'], [{'role': 'user', 'content': self.prompt_function(
                spec['task'], spec['question'], spec['reference'], spec['hypothesis'], abstention=spec['abstention'])}])
            self.assertEqual({k: payload[k] for k in ('temperature', 'n', 'max_tokens', 'enable_thinking')},
                             {'temperature': 0, 'n': 1, 'max_tokens': 10, 'enable_thinking': False})
            self.assertNotIn('expected', payload)
            self.assertNotIn('seed', payload)
            self.assertNotIn('response_format', payload)
            self.assertEqual(set(payload), {'model', 'temperature', 'n', 'max_tokens', 'enable_thinking', 'messages'})

    def test_local_routing_only(self):
        for endpoint in ('https://localhost:11234/v1', 'http://example.com:11234/v1', 'http://127.0.0.1/v1',
                         'http://user:password@127.0.0.1:11234/v1', 'http://127.0.0.1:11234/v1?key=x',
                         'http://127.0.0.1:11234/v1#x', 'http://127.0.0.1:11234/private'):
            with self.assertRaises(q.GradeError): q.local_settings(endpoint)
        self.assertIn('127.0.0.1', q.local_settings('http://localhost:11234/v1')['endpoint'])
        self.assertIn('[::1]', q.local_settings('http://[::1]:11234/v1')['endpoint'])
        with self.assertRaises(q.GradeError): q.NoRedirect().redirect_request(None, None, 302, '', {}, 'remote')

    def test_http_transport_uses_frozen_body_no_proxy_and_no_redirect(self):
        settings = q.local_settings(q.ANSWER_CONFIGURATION['endpoint'])
        body = b'{"synthetic":"request"}'
        raw = response()
        class Stream:
            def __enter__(self): return self
            def __exit__(self, *_): return False
            def read(self, limit):
                self_limit.append(limit)
                return raw
        self_limit = []
        class Opener:
            def open(self, request, timeout):
                self_request.append((request, timeout))
                return Stream()
        self_request = []
        with patch.object(q, 'build_opener', return_value=Opener()) as build:
            self.assertEqual(q.call_local(settings, body, timeout=3), raw)
        handlers = build.call_args.args
        self.assertEqual(handlers[0].proxies, {})
        self.assertIsInstance(handlers[1], q.NoRedirect)
        request, timeout = self_request[0]
        self.assertEqual(request.full_url, settings['endpoint'])
        self.assertEqual(request.data, body)
        self.assertEqual(timeout, 3)
        self.assertEqual(request.get_method(), 'POST')
        self.assertNotIn('Authorization', request.headers)
        self.assertEqual(self_limit, [2 * 1024 * 1024 + 1])

    def test_exact_yes_no_and_upstream_substring(self):
        for content, label, valid in (('yes', True, True), (' NO \n', False, True), ('not yes', True, False),
                                      ('yesterday', True, False), ('yes, but no', True, False), ('', False, False)):
            grade = q.parse_judgment(response(content))
            self.assertIs(grade['upstream_yes_substring_label'], label)
            self.assertIs(grade['strict_yes_no_format_valid'], valid)
            self.assertIs(grade['scored'], valid)

    def test_truncation_wrong_model_and_finish_reason_unscored(self):
        for kwargs, terminal in (({'finish': 'length'}, 'output_truncated'),
                                 ({'finish': 'tool_calls'}, 'invalid_finish_reason'),
                                 ({'model': 'different'}, 'model_identity_mismatch')):
            grade = q.parse_judgment(response(**kwargs))
            self.assertFalse(grade['scored'])
            self.assertEqual(grade['terminal_status'], terminal)

    def test_provider_usage_or_unknown(self):
        self.assertEqual(q.parse_judgment(response())['usage_status'], 'observed_provider_receipt')
        self.assertIsNone(q.parse_judgment(response(usage=False))['usage'])
        parsed = q.strict_json(response())
        for usage in ({'prompt_tokens': True, 'completion_tokens': 1, 'total_tokens': 2},
                      {'prompt_tokens': 50, 'completion_tokens': -1, 'total_tokens': 49},
                      {'prompt_tokens': 50, 'completion_tokens': 1, 'total_tokens': 52}):
            parsed['usage'] = usage
            self.assertIsNone(q.parse_judgment(q.canonical(parsed))['usage'])
        parsed['usage'] = {'prompt_tokens': 50, 'completion_tokens': 11, 'total_tokens': 61}
        self.assertEqual(q.parse_judgment(q.canonical(parsed))['terminal_status'], 'output_limit_violation')

    def test_duplicate_and_nonfinite_response_json_refused(self):
        for raw in (b'{"model":"x","model":"y"}', b'{"value":NaN}', b'not-json'):
            self.assertFalse(q.parse_judgment(raw)['scored'])

    def test_strict_bundle_accepts_both_versions(self):
        with tempfile.TemporaryDirectory() as temporary:
            for version in (4, 5):
                root = Path(temporary).resolve() / str(version); root.mkdir()
                path, export, source, pins, report = bundle_fixture(root, version)
                bundle = q.validate_bundle(path, q.digest(path.read_bytes()), export, source, pins)
                self.assertEqual(len(bundle.attempts), 14)
                self.assertEqual(bundle.raw_source, source.read_bytes())

    def test_missing_duplicate_foreign_and_extra_export_records_refused_even_rehashed(self):
        for kind in ('missing', 'duplicate', 'foreign', 'extra', 'oracle'):
            with tempfile.TemporaryDirectory() as temporary:
                path, export, source, pins, report = bundle_fixture(Path(temporary).resolve())
                target = export / 'hybrid.jsonl'
                rows = [q.strict_json(line) for line in target.read_bytes().splitlines()]
                if kind == 'missing': rows.pop()
                elif kind == 'duplicate': rows[1] = rows[0]
                elif kind == 'foreign': rows[0]['question_id'] = 'foreign'
                elif kind == 'extra': rows.append(rows[0])
                else: rows[0]['answer'] = 'forbidden'
                raw = b''.join(q.canonical(row) + b'\n' for row in rows); target.write_bytes(raw)
                report['private_hypothesis_exports']['hybrid'] = {'records': 7, 'bytes': len(raw), 'sha256': q.digest(raw)}
                sha = publish_fixture(path, export, report)
                with self.assertRaises(q.GradeError): q.validate_bundle(path, sha, export, source, pins)

    def test_report_export_declaration_case_oracle_and_answer_pins(self):
        for kind in ('report', 'export', 'declaration', 'case', 'oracle', 'answer', 'source', 'version'):
            with tempfile.TemporaryDirectory() as temporary:
                path, export, source, pins, report = bundle_fixture(Path(temporary).resolve())
                expected = q.digest(path.read_bytes())
                if kind == 'report': path.write_bytes(path.read_bytes() + b' ')
                elif kind == 'export': (export / 'hybrid.jsonl').write_bytes(b'')
                elif kind == 'declaration': (export / 'declaration.json').write_bytes(b'{}')
                elif kind in ('case', 'oracle'):
                    field = 'public_projection_sha256' if kind == 'case' else 'scorer_annotations_sha256'
                    report['declaration']['cases'][0][field] = '0' * 64
                    expected = publish_fixture(path, export, report)
                elif kind == 'answer':
                    report['histories'][0]['attempts'][0]['answer_sha256'] = '0' * 64
                    expected = publish_fixture(path, export, report)
                elif kind == 'source': source.write_bytes(b'[]')
                else:
                    report['runner_document_version'] = True
                    expected = publish_fixture(path, export, report)
                with self.assertRaises(q.GradeError): q.validate_bundle(path, expected, export, source, pins)

    def test_failed_native_attempt_empty_export_does_not_match_partial_answer_hash(self):
        with tempfile.TemporaryDirectory() as temporary:
            path, export, source, pins, report = bundle_fixture(Path(temporary).resolve())
            attempt = report['histories'][0]['attempts'][1]
            attempt.update(operational_complete=False, answer_bytes=123, answer_sha256='b' * 64)
            target = export / 'hybrid.jsonl'; rows = [q.strict_json(line) for line in target.read_bytes().splitlines()]
            rows[0]['hypothesis'] = ''
            raw = b''.join(q.canonical(row) + b'\n' for row in rows); target.write_bytes(raw)
            report['private_hypothesis_exports']['hybrid'].update(bytes=len(raw), sha256=q.digest(raw))
            bundle = q.validate_bundle(path, publish_fixture(path, export, report), export, source, pins)
            self.assertFalse(bundle.attempts[1]['native_operational_complete'])
            self.assertEqual(bundle.attempts[1]['hypothesis'], '')

    def run_controls(self, root, transport=None, private=None):
        specification = q.control_specification()
        counter = iter(specification)
        def correct(_settings, _request, timeout):
            return response('yes' if next(counter)['expected'] else 'no')
        return q.run('controls', q.local_settings(q.ANSWER_CONFIGURATION['endpoint']), self.prompt_function,
            self.protocol_raw, root / 'controls', specification, {'synthetic_inputs_sha256': q.digest(q.canonical(specification))},
            private_directory=private, transport=transport or correct)

    def test_declaration_precedes_calls_private_no_clobber_and_no_content_publication(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); private = root / 'private'; counter = iter(q.control_specification())
            def transport(_settings, request, timeout):
                self.assertTrue((root / 'controls/declaration.json').is_file())
                self.assertTrue((private / 'requests.jsonl').is_file())
                return response('yes' if next(counter)['expected'] else 'no')
            report = self.run_controls(root, transport, private)
            self.assertTrue(report['synthetic_controls_validated'])
            self.assertEqual(report['real_judge_calibration_status'], 'unrun')
            self.assertEqual(report['performance_trust'], 'unvalidated_real_judge')
            self.assertEqual(private.stat().st_mode & 0o777, 0o700)
            self.assertTrue(all(p.stat().st_mode & 0o777 == 0o600 for p in private.iterdir()))
            public = (root / 'controls/report.json').read_bytes() + (root / 'controls/declaration.json').read_bytes()
            for spec in q.control_specification():
                for key in ('question', 'reference', 'hypothesis'):
                    self.assertNotIn(spec[key].encode(), public)
            self.assertNotIn(q.MODEL.encode(), public)
            self.assertNotIn(q.ANSWER_CONFIGURATION['endpoint'].encode(), public)
            with self.assertRaises(q.GradeError): self.run_controls(root)

    def test_transport_failures_malformed_and_truncated_retain_denominator(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); count = 0
            def transport(_settings, _request, timeout):
                nonlocal count
                count += 1
                if count == 1: raise RuntimeError('PRIVATE transport sentinel')
                if count == 2: return response('not yes')
                return response('yes', finish='length')
            report = self.run_controls(root, transport)
            total = report['summary']['all']
            self.assertEqual((total['declared_attempts'], total['scored_attempts'], total['unknown_judgment_attempts']), (14, 0, 14))
            self.assertFalse(report['synthetic_controls_validated'])
            self.assertNotIn('PRIVATE transport sentinel', (root / 'controls/report.json').read_text())

    def test_false_accept_reject_counts_by_category(self):
        with tempfile.TemporaryDirectory() as temporary:
            counter = iter(q.control_specification())
            def transport(_settings, _request, timeout):
                return response('no' if next(counter)['expected'] else 'yes')
            report = self.run_controls(Path(temporary).resolve(), transport)
            for category, summary in report['summary'].items():
                expected = 7 if category == 'all' else 1
                self.assertEqual(summary['false_accept_count'], expected)
                self.assertEqual(summary['false_reject_count'], expected)
            self.assertFalse(report['synthetic_controls_validated'])

    def test_qa_requires_matching_validated_controls_and_skips_failed_native_attempt(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            path, export, source, pins, input_report = bundle_fixture(root)
            bundle = q.validate_bundle(path, q.digest(path.read_bytes()), export, source, pins)
            args = ('qa', q.local_settings(q.ANSWER_CONFIGURATION['endpoint']), self.prompt_function,
                    self.protocol_raw, root / 'qa', bundle.attempts, bundle.pins)
            with self.assertRaises(q.GradeError): q.run(*args, transport=lambda *_: self.fail('unexpected call'))
            self.run_controls(root)
            control_path = root / 'controls/report.json'; control_sha = q.digest(control_path.read_bytes())
            attempts = tuple({**attempt, 'native_operational_complete': index != 1} for index, attempt in enumerate(bundle.attempts))
            calls = []
            def transport(_settings, request, timeout):
                calls.append(request); return response('yes')
            report = q.run(*args[:5], attempts, bundle.pins, controls_report=control_path, controls_sha=control_sha, transport=transport)
            total = report['summary']['all']
            self.assertEqual(len(calls), 13)
            self.assertEqual(total['declared_attempts'], 14)
            self.assertEqual(total['operational_failed_attempts'], 1)
            self.assertEqual(total['unknown_judgment_attempts'], 0)
            self.assertEqual(total['scored_attempts'], 13)
            self.assertEqual(total['accepted_fraction_declared'], 13 / 14)
            self.assertIsNone(report['official_qa_score'])
            self.assertIsNone(total['false_accept_count'])
            self.assertIsNone(total['false_reject_count'])
            public = (root / 'qa/report.json').read_text() + (root / 'qa/declaration.json').read_text()
            for value in ('PRIVATE synthetic', *q.CASE_IDS, q.ANSWER_CONFIGURATION['system']):
                self.assertNotIn(value, public)

    def test_control_report_hash_settings_and_invalid_labels_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); self.run_controls(root)
            path = root / 'controls/report.json'; sha = q.digest(path.read_bytes())
            fp = q.fingerprints(q.local_settings(q.ANSWER_CONFIGURATION['endpoint']), self.protocol_raw)
            self.assertEqual(q.validate_controls(path, sha, fp), sha)
            with self.assertRaises(q.GradeError): q.validate_controls(path, '0' * 64, fp)
            with self.assertRaises(q.GradeError): q.validate_controls(path, sha, {**fp, 'model_settings_sha256': '0' * 64})
            report = q.strict_json(path.read_bytes()); report['attempts'][1]['upstream_yes_substring_label'] = True
            path.write_bytes(q.canonical(report))
            with self.assertRaises(q.GradeError): q.validate_controls(path, q.digest(path.read_bytes()), fp)

    def test_cli_requires_explicit_execution_and_fixed_content_free_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr), patch.object(q, 'call_local') as transport:
                result = q.main(['controls', '--protocol', str(PROTOCOL), '--output-directory', str(Path(temporary).resolve() / 'new')])
            self.assertEqual(result, 1)
            self.assertFalse(transport.called)
            self.assertEqual(stderr.getvalue(), 'Local QA diagnostic failed validation.\n')

    def test_symlink_inputs_and_existing_output_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); target = root / 'target'; target.write_bytes(b'private')
            link = root / 'link'; link.symlink_to(target)
            with self.assertRaises(q.GradeError): q.read_file(link)
            with self.assertRaises(q.GradeError): q.new_directory(root)
            directory = root / 'dir'; directory.mkdir(); dirlink = root / 'dirlink'; dirlink.symlink_to(directory)
            with self.assertRaises(q.GradeError): q.new_directory(dirlink / 'new')


    def test_runtime_output_refuses_tracked_tree_and_allows_build_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            (root / '.git').mkdir()
            (root / 'Sources').mkdir()
            with self.assertRaises(q.GradeError): q.new_directory(root / 'Sources' / 'private-runtime')
            self.assertFalse((root / 'Sources' / 'private-runtime').exists())
            (root / '.build').mkdir()
            self.assertEqual(q.new_directory(root / '.build' / 'private-runtime'), root / '.build' / 'private-runtime')


if __name__ == '__main__':
    result = unittest.TextTestRunner(stream=io.StringIO()).run(unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    print(json.dumps({'checks': result.testsRun, 'failed': [t.id() for t, _ in result.failures],
                     'errors': [t.id() for t, _ in result.errors], 'skipped': len(result.skipped)}))
    raise SystemExit(not result.wasSuccessful())
