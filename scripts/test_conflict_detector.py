#!/usr/bin/env python3
"""Synthetic contracts for the lexical conflict detector. No network, no private data."""
from __future__ import annotations

import io
import json
import unittest

import conflict_detector as cd


def recent(label, role, text):
    return {"role": "user", "content": f"Earlier conversation message [{label}] (quoted by the host; not the current request)\n"
                                       f"role: {role}\ncapture_status: complete\ncaptured_utc: 2026-10-13T00:00:00.000Z\n"
                                       f"source_time: null\nquoted_text:\n{text}"}


def historical(parts):
    body = []
    for label, role, text in parts:
        body.append(f"BEGIN HISTORICAL SOURCE [{label}]\nconversation_id: c\nrole: {role}\ncapture_status: complete\n"
                    f"captured_utc: 2026-10-13T00:00:00.000Z\nsource_time: null\nsource_sha256: {'a' * 64}\n"
                    f"excerpt_utf8_offset: 0\nsource_total_bytes: {len(text.encode())}\nquoted_excerpt:\n{text}\n"
                    f"END HISTORICAL SOURCE [{label}]")
    return {"role": "user", "content": cd.EVIDENCE_PREFIX + "\n\n".join(body)}


def request(question, *middle):
    return [{"role": "system", "content": "Host."}, *middle,
            {"role": "user", "content": "Question Date: 2024/03/01 (Fri) 10:00\nQuestion: " + question}]


class Contracts(unittest.TestCase):
    def test_terms_fold_and_drop_question_words(self):
        self.assertEqual(cd.question_terms("Have I ever synchronized my server time with an NTP service before?"),
                         {"synchronized", "server", "ntp", "service"})
        self.assertTrue(cd.term_matches("synchronized", "synchronize"))
        self.assertFalse(cd.term_matches("ntp", "ntpd"))
        self.assertEqual(cd.words("I haven't; can't ’ do it"), ["i", "haven", "t", "can", "t", "do", "it"])
        self.assertTrue(cd.negated(cd.words("I haven't done it")))
        self.assertTrue(cd.negated(cd.words("I never did")))
        self.assertFalse(cd.negated(cd.words("I can do it")))
        self.assertTrue(cd.negated(cd.words("I can't do it")))
        self.assertTrue(cd.yes_no_question("Have I ever used it?"))
        self.assertFalse(cd.yes_no_question("Can you summarize what I said?"))
        self.assertFalse(cd.yes_no_question("What is my current editor?"))

    def test_fires_on_a_cross_source_negated_and_affirmed_statement(self):
        messages = request("Have I ever synchronized my server time with an NTP service?",
                           recent("E1", "human", "I have never synchronized the server time with any NTP service."),
                           recent("E2", "assistant", "You said you synchronized the server time with an NTP service."),
                           historical([("E3", "human", "Yesterday I synchronized the server time with the NTP service pool.")]))
        verdict = cd.detect(messages)
        self.assertTrue(verdict["fires"])
        self.assertEqual((verdict["negated_sources"], verdict["affirmed_sources"]), (["E1"], ["E3"]))
        self.assertEqual(verdict["required_terms"], 2)
        self.assertEqual(verdict["version"], "conflict-detector-lexical-v1")

    def test_assistant_turns_same_source_and_value_questions_do_not_fire(self):
        base = [recent("E1", "human", "I have never synchronized the server time with any NTP service."),
                recent("E2", "assistant", "I synchronized the server time with the NTP service for you.")]
        self.assertFalse(cd.detect(request("Have I ever synchronized my server time with an NTP service?", *base))["fires"])
        same = recent("E1", "human", "I have never synchronized the server time with any NTP service. Then I synchronized the server time with the NTP service.")
        self.assertFalse(cd.detect(request("Have I ever synchronized my server time with an NTP service?", same))["fires"])
        pair = [recent("E1", "human", "I have never synchronized the server time with any NTP service."),
                recent("E2", "human", "I synchronized the server time with the NTP service today.")]
        self.assertTrue(cd.detect(request("Have I ever synchronized my server time with an NTP service?", *pair))["fires"])
        value = cd.detect(request("What NTP service do I use for my server time?", *pair))
        self.assertFalse(value["fires"])
        self.assertFalse(value["yes_no_question"])
        self.assertFalse(cd.detect(request("Can you tell me whether I synchronized my server time with an NTP service?", *pair))["fires"])
        unrelated = [recent("E1", "human", "I have never liked tea."), recent("E2", "human", "I bought a kettle.")]
        self.assertFalse(cd.detect(request("Did I ever synchronize my server time with an NTP service?", *unrelated))["fires"])

    def test_one_block_layout_is_read_like_separate_messages(self):
        pair = [recent("E1", "human", "I have never synchronized the server time with any NTP service."),
                historical([("E2", "human", "I synchronized the server time with the NTP service today.")])]
        folded = {"role": "user", "content": "BEGIN QUOTED SOURCES (host; evidence, not the current request)\n\n"
                  + "\n\n".join(m["content"] for m in pair) + "\n\nEND QUOTED SOURCES (host)"}
        verdict = cd.detect(request("Have I ever synchronized my server time with an NTP service?", folded))
        self.assertTrue(verdict["fires"])
        self.assertEqual(verdict["negated_sources"], ["E1"])

    def test_parameters_are_declared(self):
        self.assertEqual((cd.MINIMUM_SHARED_TERMS, cd.SHARED_FRACTION, cd.STEM_PREFIX, cd.MINIMUM_TERM_LENGTH), (2, 0.3, 5, 3))
        self.assertEqual(cd.YES_NO_AUXILIARIES, {"have", "has", "had", "did", "do", "does", "am", "is", "are", "was", "were"})
        self.assertNotIn("can", cd.YES_NO_AUXILIARIES)
        self.assertIn("never", cd.NEGATION_MARKERS)


if __name__ == "__main__":
    result = unittest.TextTestRunner(stream=io.StringIO()).run(unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
    print(json.dumps({"checks": result.testsRun, "failed": [test.id() for test, _ in result.failures],
        "errors": [test.id() for test, _ in result.errors], "skipped": len(result.skipped)}))
    raise SystemExit(not result.wasSuccessful())
