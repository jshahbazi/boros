# Multi-source answers for aggregation questions

Record date: October 13, 2026. On the 20-question BEAM comparison, summarization (gold spans 15 to 26 messages), event ordering (6 to 9), multi-session reasoning and contradiction resolution scored zero for every reader and every retrieval variant ([EXCHANGE-PACKED-ANSWERS.md](EXCHANGE-PACKED-ANSWERS.md), [READER-CHOICE.md](READER-CHOICE.md)). One bounded request cannot hold the sources these need. This record measures one multi-source path against today's ordinary Send on the [BEAM cohort](BEAM-COHORT.md) of 100 questions, with the same reader, grader and rule for both arms. Each section states whether it reports implemented behavior, measured results, inferences or proposed design.

## Summary

SUMMARY_PLACEHOLDER

## The path (implemented, evaluation driver only: `scripts/beam_multi_source.py`)

The path is implemented in the evaluation driver, not in the application. Ordinary Send is unchanged. Three stages:

1. **Router.** A deterministic classifier (`route`) sends a question to the multi-source path when it asks for a summary (`summar`, `overview`, `recap`, `synthesi`), an order or timeline (`chronolog`, `timeline`, `sequence`, `order in which`, `what/which/correct/right/exact order`, `order that/of`, `walk me through`), a count or total (`how many`, `total`, `combined`, `altogether`, `sum of`, `in all`, except `how many` followed by a time unit, which is temporal arithmetic over two sources), whether something was ever said (`ever`, `at any point`, `at any time`, `any of our sessions`), or how something changed across the history (one of `across`, `throughout`, `over the course`, `over time`, `so far`, `every time`, `each time` together with one of `evolv`, `progress`, `develop`, `chang`). Every other question keeps the ordinary single call. The rules were chosen from per-category hit counts over all 1,100 BEAM probe questions of both scales (counts only, no question text was recorded): they fire on 100 percent of summarization, 94 percent of event ordering, 64 percent of multi-session reasoning and 73 percent of contradiction resolution questions, on 25 percent of knowledge update ("how many" questions) and on 7 percent or fewer of the other categories; 38 percent of all questions route. On the cohort, 33 of 100 route (ROUTED_BY_CATEGORY_PLACEHOLDER).
2. **Map step.** Every human-led exchange block of the history contributes one snippet in chronological order: the block's date and turn number, a query-centered window of at most 320 characters of the user message, and, for the 120 blocks that the question's content terms rank best (a Python port of the exchange index scoring, `ExchangeBlockQuery.rank`, `idf-term-coverage-sqrt-byte-cost-v2`, and `ExchangeTerms`; the application's scoring is unchanged), a 120-character window of the reply. Whitespace is collapsed and cuts are marked. Snippets are labelled `[S<n>]` and split into consecutive map calls of at most 56,000 characters (one call at the 100K scale, three at 500K, about 40,000 input tokens in all at 500K); a history above four calls would drop its unmatched and lowest-ranked blocks first. Reading every block was decided offline before any paid run: at the 500K scale the top 120 ranked blocks held 51 percent of the gold blocks of the routed questions, the top 300 held 87 percent, and every block 97 percent (four gold blocks match no question term), while at 100K the top 120 blocks are the whole history (96 percent). Two map designs were declared:
   - **notes** (the first design): each map call writes dated notes, one per line in the form `YYYY-MM-DD [S<n>]: fact`, at most 50 per call and 120 in all; lines without that form or with a label that does not resolve are dropped and counted. The prompt asks for what the user said, did, decided, planned, preferred or changed, keeps conflicting and revised statements without reconciling them, adds nothing from outside the snippets, and does not answer.
   - **quotes** (the second design, declared after the pilot below): each map call only lists the labels of the snippets a later step must read in full, at most 20 per call and 36 in all (an equal share per call); the answer step then quotes those exchanges' original text, the user message cut at 1,200 characters and a 240-character query-centered window of the reply, under their labels, dates and turn numbers, in chronological order.
3. **Answer step.** The ordinary `exchange_packed` request, exactly as captured (its recent messages, packed excerpts and question under the V4-advice framing), receives one more host-labelled user message before the question (the notes, or the quoted exchanges) under a heading that names it as host-derived, and one sentence appended to the System framing that gives it the standing of quoted sources and asks for its labels to be cited. Citations are checked offline: `[E<n>]` must be a delivered label and `[S<n>]` a snippet label. A routed question whose map produced nothing keeps its ordinary answer.

Per routed question the path costs one to three extra calls (the map, one per 56,000 characters of snippets) and about 10,000 (100K) to 40,000 (500K) extra input tokens plus the notes or quotes, at the edge of the plan's interim allowance of three extra calls and 40,000 extra tokens. An unrouted question costs nothing extra.

### Pilot of the notes design (measured, October 13)

Six routed questions of the comparison's conversation (two contradiction, one event ordering, one multi-session, two summarization; all six were wrong under every earlier arm), one replicate, the same reader and grader: $0.83 of answers (30 calls) and $0.16 of grading at the standard rate. The grader's calibration passed on this subset (6 of 6 positives, including the two summarization ideal summaries, and 6 of 6 fabricated negatives). Every one of the 12 answers, six per arm, was rejected. Content-free diagnosis: the contradiction answers were unchanged by the notes (one byte-identical to its baseline), the reader limit the [context diagnostic](reviews/CONTEXT-DIAGNOSTIC-RESPONSE-20261012.md) found; the notes of the ordering question cited 2 of its 9 gold snippets and those of the multi-session question none of its 2, although every gold turn was in the snippets; and the long summarization's notes hit the 120-note cap with 3 of its 18 key-element terms present. The extraction step, not coverage, lost the facts, which is why the quotes design replaces it: the map selects, the answer step reads original text.

What is reused from the experimental investigation route ([MEMORY-INVESTIGATION.md](MEMORY-INVESTIGATION.md)): its exchange-block search and term function (through the exchange index that ported them), the idea of a source-bound extraction step whose output cites delivered labels, and the separation of derived notes from original text in the final request. What is not reused: the planner loop, the history map and cursors (about 15 calls and 77,000 tokens per turn). The map here is one call over a fixed snippet set.

## Declared before generation

DECLARATION_PLACEHOLDER

## Results (measured)

RESULTS_PLACEHOLDER

## Cost and latency (measured)

COST_PLACEHOLDER

## Interpretation (inferred)

INTERPRETATION_PLACEHOLDER

## Decision

DECISION_PLACEHOLDER

## Privacy and artifacts

Snippets, notes, request bodies, answers, grades and the declaration are in `.build/beam-cohort-20261013/` of worktree `agent-ab324e6f37c8d1b84` (0700 directories, 0600 files). This record contains no question, answer, note, snippet, reference or conversation text.

## Reproduce

```bash
/Users/johnshahbazian/.venv-vllm-metal/bin/python3 scripts/beam_multi_source.py declare --output .build/beam-cohort-20261013
/Users/johnshahbazian/.venv-vllm-metal/bin/python3 scripts/beam_multi_source.py run --output .build/beam-cohort-20261013
/Users/johnshahbazian/.venv-vllm-metal/bin/python3 scripts/beam_multi_source.py grade-declare --output .build/beam-cohort-20261013
/Users/johnshahbazian/.venv-vllm-metal/bin/python3 scripts/beam_multi_source.py grade-run --output .build/beam-cohort-20261013
/Users/johnshahbazian/.venv-vllm-metal/bin/python3 scripts/beam_multi_source.py score --output .build/beam-cohort-20261013
```

`declare` takes `--labels` and `--replicates` for a pilot. Tests: `scripts/test_beam_multi_source.py` (10 synthetic contracts), run by `check.py`.
