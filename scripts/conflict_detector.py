#!/usr/bin/env python3
"""Lexical conflict detector in front of the conflicts sentence (docs/CONFLICT-DETECTOR.md).

The conflicts sentence (``exchange_packed_answers.CONFLICTS_SENTENCE``) turns BEAM contradiction questions
from 0 to about 57 percent correct and costs 3.2 points on ordinary questions that hold no conflict. This
detector decides, per request, whether the sentence is present. It reads the captured request only: the
question (the final user message) and the delivered user-role sources (the host-quoted recent messages
whose role is ``human`` and the historical excerpts whose header role is ``human``). Assistant turns are
never read: a contradiction is between two things the user said.

Rule (every parameter declared before the held-out measurement; the first two sets, the 72 step 3
questions and the cohort's 10 contradiction questions, were the tuning sets):

1. The question asks whether something is the case: its first word is a yes/no auxiliary
   (``YES_NO_AUXILIARIES``: have, has, had, did, do, does, am, is, are, was, were). Request forms such as
   "can you" and value questions ("what", "how many") are not gated: a conflict about a value is a
   knowledge update, where the latest statement answers, not a contradiction to report.
2. The question's content terms are its alphanumeric runs, case- and diacritic-folded, without the
   exchange stopwords and without the question words ``QUESTION_WORDS``, at least ``MINIMUM_TERM_LENGTH``
   characters. Each term also matches by a shared prefix of ``STEM_PREFIX`` characters, so "synchronized"
   matches "synchronize".
3. Every delivered user-role source is split into sentences at ``.``, ``!``, ``?`` and line breaks. A
   sentence is a *statement about the asked-for item* when it matches at least ``required_terms`` distinct
   question terms, where required_terms is ``max(MINIMUM_SHARED_TERMS, ceil(SHARED_FRACTION * |terms|))``.
4. A statement is *negated* when it contains a negation marker (``NEGATION_MARKERS``, whole words or the
   ``n't`` contraction).
5. The detector fires when a negated statement in one source and a non-negated statement in a different
   source both exist.

Tuning history (recorded, not hidden): the first form had no question-shape condition and a 50 percent
term share; it fired on 2 of 73 step 3 questions, 7 of the 10 cohort contradiction questions and 10 of
the cohort's other 90 (six knowledge updates). The shape condition removed every false fire on both tuning
sets, which let the share drop to 30 percent to reach the two misses whose affirmations share only two or
three terms with the question.

It reports counts, source labels and the matched term count, never text. It is deterministic and makes
no model call.
"""
from __future__ import annotations

import math
import re
import unicodedata

STOPWORDS = set("a an and are as at be been being but by can could did do does doing for from had has have having he "
                "her here hers him his how i if in into is it its just me more most my no not of on or our ours please "
                "s say she should so some t tell than that the their theirs them then there these they this those "
                "through to too us was we were what when where which who why will with would you your yours about".split())
# Words that shape a question but name no item ("have I ever ...", "did I ever ...", "do I").
QUESTION_WORDS = {"ever", "before", "any", "anything", "something", "already", "still", "yet", "really", "actually",
                  "question", "date", "please", "whether", "mention", "mentioned", "said", "told", "say", "tell",
                  "remember", "recall", "earlier", "previously", "used", "use", "using", "get", "got", "like", "want",
                  "one", "thing", "things", "way", "time", "times", "also"}
MINIMUM_TERM_LENGTH = 3
STEM_PREFIX = 5
MINIMUM_SHARED_TERMS = 2
SHARED_FRACTION = 0.3
YES_NO_AUXILIARIES = {"have", "has", "had", "did", "do", "does", "am", "is", "are", "was", "were"}
NEGATION_MARKERS = {"never", "not", "no", "none", "nothing", "without", "cannot", "neither", "nor", "haven", "hasn",
                    "hadn", "didn", "don", "doesn", "isn", "aren", "wasn", "weren", "won", "wouldn", "couldn", "shouldn",
                    "can", "unable", "yet"}
# "can" counts as negation only inside "can't"/"cannot"; the contraction split below leaves "can" + "t".
CONTRACTION_ONLY = {"can", "won", "don", "didn", "doesn", "isn", "aren", "wasn", "weren", "wouldn", "couldn", "shouldn",
                    "haven", "hasn", "hadn"}
VERSION = "conflict-detector-lexical-v1"

RECENT_HEADER = re.compile(r"\AEarlier conversation message \[(E\d+)\][^\n]*\nrole: (human|assistant)\n(?:[^\n]*\n)*?quoted_text:\n", re.S)
HISTORICAL_HEADER = re.compile(r"BEGIN HISTORICAL SOURCE \[(E\d+)\]\n(?:[^\n]*\n)?role: (human|assistant)\n")
EVIDENCE_PREFIX = "Historical source excerpts for reference:\n\n"
ONE_BLOCK_OPEN = "BEGIN QUOTED SOURCES"


def fold(text: str) -> str:
    decomposed = unicodedata.normalize("NFKD", text.lower())
    return "".join(character for character in decomposed if not unicodedata.combining(character))


def words(text: str) -> list:
    """Alphanumeric runs of the folded text, with English contractions split at the apostrophe so
    "haven't" yields "haven" and "t"."""
    return re.findall(r"[0-9a-z]+", fold(text).replace("’", "'").replace("'", " "))


def question_terms(question: str) -> set:
    terms = set()
    for word in words(question):
        if len(word) >= MINIMUM_TERM_LENGTH and word not in STOPWORDS and word not in QUESTION_WORDS:
            terms.add(word)
    return terms


def term_matches(term: str, word: str) -> bool:
    if term == word:
        return True
    return len(term) >= STEM_PREFIX and len(word) >= STEM_PREFIX and term[:STEM_PREFIX] == word[:STEM_PREFIX]


def sentences(text: str) -> list:
    return [piece.strip() for piece in re.split(r"[.!?\n]+", text) if piece.strip()]


def negated(sentence_words: list) -> bool:
    for index, word in enumerate(sentence_words):
        if word in NEGATION_MARKERS and word not in CONTRACTION_ONLY:
            return True
        if word in CONTRACTION_ONLY and index + 1 < len(sentence_words) and sentence_words[index + 1] == "t":
            return True
    return False


def question_text(messages: list) -> str:
    content = messages[-1]["content"]
    match = re.match(r"\AQuestion Date: [^\n]+\nQuestion: (.*)\Z", content, re.S)
    return match.group(1) if match else content


def user_sources(messages: list) -> list:
    """(label, text) of every delivered user-role source in the request, from the quoted recent messages, the
    historical block (role header ``human``) and, for the one-block presentation, the same inside the block."""
    out = []
    for message in messages[1:-1]:
        content = message["content"]
        if content.startswith(ONE_BLOCK_OPEN):
            # The folded layout: parse its parts as if they were separate messages.
            inner = content.split("\n\n", 1)[1].rsplit("\n\nEND QUOTED SOURCES", 1)[0]
            parts, buffer = [], []
            for chunk in inner.split("\n\n"):
                if chunk.startswith("Earlier conversation message [") or chunk.startswith(EVIDENCE_PREFIX.strip()):
                    if buffer:
                        parts.append("\n\n".join(buffer))
                    buffer = [chunk]
                else:
                    buffer.append(chunk)
            if buffer:
                parts.append("\n\n".join(buffer))
            out += user_sources([None] + [{"content": part} for part in parts] + [None])
            continue
        match = RECENT_HEADER.match(content)
        if match:
            if match.group(2) == "human":
                out.append((match.group(1), content[match.end():]))
            continue
        if content.startswith(EVIDENCE_PREFIX):
            pieces = re.split(r"(?=BEGIN HISTORICAL SOURCE \[E\d+\]\n)", content[len(EVIDENCE_PREFIX):])
            for piece in pieces:
                header = HISTORICAL_HEADER.match(piece)
                if not header or header.group(2) != "human":
                    continue
                body = piece.split("quoted_excerpt:\n", 1)
                if len(body) == 2:
                    excerpt = body[1].rsplit("\nEND HISTORICAL SOURCE [", 1)[0]
                    out.append((header.group(1), excerpt))
    return out


def yes_no_question(question: str) -> bool:
    first = words(question)[:1]
    return bool(first) and first[0] in YES_NO_AUXILIARIES


def detect(messages: list) -> dict:
    """Content-free verdict for one captured request's messages."""
    question = question_text(messages)
    shape = yes_no_question(question)
    terms = question_terms(question) if shape else set()
    required = max(MINIMUM_SHARED_TERMS, math.ceil(SHARED_FRACTION * len(terms))) if terms else None
    negated_sources, affirmed_sources, statements = set(), set(), 0
    for label, text in user_sources(messages):
        for sentence in sentences(text):
            sentence_words = words(sentence)
            matched = sum(1 for term in terms if any(term_matches(term, word) for word in sentence_words))
            if required is None or matched < required:
                continue
            statements += 1
            if negated(sentence_words):
                negated_sources.add(label)
            else:
                affirmed_sources.add(label)
    # A negated statement in one source and a non-negated statement in a different source.
    fires = any(left != right for left in negated_sources for right in affirmed_sources)
    return {"version": VERSION, "fires": fires, "yes_no_question": shape, "question_terms": len(terms), "required_terms": required,
            "statements": statements, "negated_sources": sorted(negated_sources), "affirmed_sources": sorted(affirmed_sources)}
