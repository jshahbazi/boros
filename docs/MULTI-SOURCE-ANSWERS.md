# Multi-source answers for aggregation questions

Record date: October 13, 2026. On the 20-question BEAM comparison, summarization (gold spans 15 to 26 messages), event ordering (6 to 9), multi-session reasoning and contradiction resolution scored zero for every reader and every retrieval variant ([EXCHANGE-PACKED-ANSWERS.md](EXCHANGE-PACKED-ANSWERS.md), [READER-CHOICE.md](READER-CHOICE.md)). One bounded request cannot hold the sources these need. This record measures one multi-source path against today's ordinary Send on the [BEAM cohort](BEAM-COHORT.md) of 100 questions, with the same reader, grader and rule for both arms. Each section states whether it reports implemented behavior, measured results, inferences or proposed design.

## Summary

- **Baseline (measured).** Today's default (`exchange_packed`, V4-advice, Gemini 3.8 Flash reader) answers 49.7 percent of the 100-question BEAM cohort under the Gemini grader. Contradiction resolution and event ordering are 0 of 30 answers each, summarization 6.7 percent, multi-session reasoning 30; the single-fact, preference, instruction and temporal categories are 67 to 93 ([BEAM-COHORT.md](BEAM-COHORT.md)).
- **The path (implemented in the evaluation driver).** A deterministic router sends summary, ordering, count-across, "ever" and change-across questions (33 of 100) to a map step that reads a dated snippet of every exchange block in one to three Gemini calls and writes dated notes, then to the ordinary request with the notes beside it. A second design has the map select exchanges and the answer step quote their original text.
- **Paired result (measured).** Notes design: +4.3 points over the 100 questions (interval +1.0 to +8.3; 7 better, 1 worse), all of it summarization (6.7 to 53.3, +46.7, interval +23.3 to +70.0, 7 of 10 questions better); nothing for event ordering or contradiction resolution; one multi-session loss. Quotes design: +2.3 (summarization +20.0). Sonnet as a second grader on the summarization items gives +16.7 (0.0 to +40.0). The rule declared before generation (D at least +5 over all 100 questions) is not met by either design, so **nothing was promoted** and no runtime code changed.
- **Held-out confirmation (measured).** On 16 summarization questions from eight unused conversations, two replicates, the notes design gives +6.2 points (interval -12.5 to +28.1; 5 better, 4 worse) against a confirmation threshold of +15 with a positive lower bound. The cohort's summarization gain did not replicate at a detectable size.
- **Cost (measured).** A routed question costs 3.2 calls, about 57,000 input tokens and 16 s at the median against 1 call, 17,000 tokens and 3.6 s; $0.089 against $0.028 per answer at the standard rate.
- **Spend.** $37.33 at the declared standard rate across the pilot, two cohort runs, the held-out run and all grading, within the $40 allowed.

## The path (implemented, evaluation driver only: `scripts/beam_multi_source.py`)

The path is implemented in the evaluation driver, not in the application. Ordinary Send is unchanged. Three stages:

1. **Router.** A deterministic classifier (`route`) sends a question to the multi-source path when it asks for a summary (`summar`, `overview`, `recap`, `synthesi`), an order or timeline (`chronolog`, `timeline`, `sequence`, `order in which`, `what/which/correct/right/exact order`, `order that/of`, `walk me through`), a count or total (`how many`, `total`, `combined`, `altogether`, `sum of`, `in all`, except `how many` followed by a time unit, which is temporal arithmetic over two sources), whether something was ever said (`ever`, `at any point`, `at any time`, `any of our sessions`), or how something changed across the history (one of `across`, `throughout`, `over the course`, `over time`, `so far`, `every time`, `each time` together with one of `evolv`, `progress`, `develop`, `chang`). Every other question keeps the ordinary single call. The rules were chosen from per-category hit counts over all 1,100 BEAM probe questions of both scales (counts only, no question text was recorded): they fire on 100 percent of summarization, 94 percent of event ordering, 64 percent of multi-session reasoning and 73 percent of contradiction resolution questions, on 25 percent of knowledge update ("how many" questions) and on 7 percent or fewer of the other categories; 38 percent of all questions route. On the cohort, 33 of 100 route: all 10 summarization, 9 of 10 event ordering, 7 of 10 multi-session, 5 of 10 contradiction and 2 of 10 knowledge-update questions, and none of the other five categories.
2. **Map step.** Every human-led exchange block of the history contributes one snippet in chronological order: the block's date and turn number, a query-centered window of at most 320 characters of the user message, and, for the 120 blocks that the question's content terms rank best (a Python port of the exchange index scoring, `ExchangeBlockQuery.rank`, `idf-term-coverage-sqrt-byte-cost-v2`, and `ExchangeTerms`; the application's scoring is unchanged), a 120-character window of the reply. Whitespace is collapsed and cuts are marked. Snippets are labelled `[S<n>]` and split into consecutive map calls of at most 56,000 characters (one call at the 100K scale, three at 500K, about 40,000 input tokens in all at 500K); a history above four calls would drop its unmatched and lowest-ranked blocks first. Reading every block was decided offline before any paid run: at the 500K scale the top 120 ranked blocks held 51 percent of the gold blocks of the routed questions, the top 300 held 87 percent, and every block 97 percent (four gold blocks match no question term), while at 100K the top 120 blocks are the whole history (96 percent). Two map designs were declared:
   - **notes** (the first design): each map call writes dated notes, one per line in the form `YYYY-MM-DD [S<n>]: fact`, at most 50 per call and 120 in all; lines without that form or with a label that does not resolve are dropped and counted. The prompt asks for what the user said, did, decided, planned, preferred or changed, keeps conflicting and revised statements without reconciling them, adds nothing from outside the snippets, and does not answer.
   - **quotes** (the second design, declared after the pilot below): each map call only lists the labels of the snippets a later step must read in full, at most 20 per call and 36 in all (an equal share per call); the answer step then quotes those exchanges' original text, the user message cut at 1,200 characters and a 240-character query-centered window of the reply, under their labels, dates and turn numbers, in chronological order.
3. **Answer step.** The ordinary `exchange_packed` request, exactly as captured (its recent messages, packed excerpts and question under the V4-advice framing), receives one more host-labelled user message before the question (the notes, or the quoted exchanges) under a heading that names it as host-derived, and one sentence appended to the System framing that gives it the standing of quoted sources and asks for its labels to be cited. Citations are checked offline: `[E<n>]` must be a delivered label and `[S<n>]` a snippet label. A routed question whose map produced nothing keeps its ordinary answer.

Per routed question the path costs one to three extra calls (the map, one per 56,000 characters of snippets) and about 10,000 (100K) to 40,000 (500K) extra input tokens plus the notes or quotes, at the edge of the plan's interim allowance of three extra calls and 40,000 extra tokens. An unrouted question costs nothing extra.

### Pilot of the notes design (measured, October 13)

Six routed questions of the comparison's conversation (two contradiction, one event ordering, one multi-session, two summarization; all six were wrong under every earlier arm), one replicate, the same reader and grader: $0.83 of answers (30 calls) and $0.16 of grading at the standard rate. The grader's calibration passed on this subset (6 of 6 positives, including the two summarization ideal summaries, and 6 of 6 fabricated negatives). Every one of the 12 answers, six per arm, was rejected. Content-free diagnosis: the contradiction answers were unchanged by the notes (one byte-identical to its baseline), the reader limit the [context diagnostic](reviews/CONTEXT-DIAGNOSTIC-RESPONSE-20261012.md) found; the notes of the ordering question cited 2 of its 9 gold snippets and those of the multi-session question none of its 2, although every gold turn was in the snippets; and the long summarization's notes hit the 120-note cap with 3 of its 18 key-element terms present. The extraction step, not coverage, lost the facts, which is why the quotes design replaces it: the map selects, the answer step reads original text.

What is reused from the experimental investigation route ([MEMORY-INVESTIGATION.md](MEMORY-INVESTIGATION.md)): its exchange-block search and term function (through the exchange index that ported them), the idea of a source-bound extraction step whose output cites delivered labels, and the separation of derived notes from original text in the final request. What is not reused: the planner loop, the history map and cursors (about 15 calls and 77,000 tokens per turn). The map here is one call over a fixed snippet set.

## Declared before generation

Each run's `declaration.json` froze, before any answer existed: the routing of every question, the snippet sets and map bodies (by hash), the Gemini token counts, the job list in a seeded order, the worst case and the cap, the reader settings (Gemini 3.8 Flash, thinking "low", 2,048 output tokens plus a 2,048-token thinking allowance for answers, 1,536 plus 2,048 for notes, 512 plus 2,048 for selection), and the rule:

- **Unit.** The question. Each question's accept rate is its correct answers over three replicates under the grader's majority of three; an unrouted question's multi-source answer is its ordinary answer of the same replicate.
- **Difference.** D is the mean accept rate of `multi_source` minus `ordinary_send` over the 100 questions, in points, with a 95 percent paired bootstrap percentile interval over questions (10,000 resamples seeded by the declaration digest) and a two-sided sign test.
- **Promote** when D is at least +5, the interval's lower bound is at least -2, and no category's D is below -5. The routed subset and each category are reported beside the decision.
- **Cost.** Calls, input and output tokens and seconds per question, for the routed questions and overall.

The caps were worst-case bounds (every request reserves its whole output allowance until its usage is known): $40 for each answer run (worst case $34.10 for the notes run, $16.74 for the quotes run, which reused the notes run's baseline answers) and $40 for each Gemini grading (worst case $37.77). Measured spend is far below them (next section).

## Results (measured)

Reader and grader as in [BEAM-COHORT.md](BEAM-COHORT.md); the baseline column is the same 300 ordinary answers in both runs, and the quotes run reused their 1,440 identical grade verdicts. Every answer and grade request completed; no verdict was unknown. Grader calibration: 78 of 80 positives and 100 of 100 negatives, so paired comparisons under one grader, not calibrated scores.

Mean per-question accept rate in percent, D in points with its interval, and questions better / worse:

| Questions | n | Ordinary Send | Notes design | D | Interval | Better / worse | Quotes design | D | Interval | Better / worse |
|---|---:|---:|---:|---:|---|---|---:|---:|---|---|
| All | 100 | 49.7 | 54.0 | +4.3 | +1.0 to +8.3 | 7 / 1 | 52.0 | +2.3 | +0.3 to +5.0 | 4 / 0 |
| Routed | 33 | 14.1 | 27.3 | +13.1 | +3.0 to +24.2 | 7 / 1 | 21.2 | +7.1 | +1.0 to +15.2 | 4 / 0 |
| Unrouted | 67 | 67.2 | 67.2 | 0 | | 0 / 0 | 67.2 | 0 | | 0 / 0 |
| 100K scale | 40 | 58.3 | 60.0 | +1.7 | 0.0 to +4.2 | 2 / 0 | 58.3 | 0 | | 0 / 0 |
| 500K scale | 60 | 43.9 | 50.0 | +6.1 | +0.6 to +12.8 | 5 / 1 | 47.8 | +3.9 | +0.6 to +8.3 | 4 / 0 |

By category (routed questions in parentheses; unrouted categories are unchanged by construction):

| Category | Routed | Ordinary Send | Notes design | D | Interval | Better / worse | Quotes design | D |
|---|---:|---:|---:|---:|---|---|---:|---:|
| Abstention | 0 | 66.7 | 66.7 | 0 | | | 66.7 | 0 |
| Contradiction resolution | 5 | 0.0 | 0.0 | 0 | | 0 / 0 | 3.3 | +3.3 |
| Event ordering | 9 | 0.0 | 0.0 | 0 | | 0 / 0 | 0.0 | 0 |
| Information extraction | 0 | 76.7 | 76.7 | 0 | | | 76.7 | 0 |
| Instruction following | 0 | 66.7 | 66.7 | 0 | | | 66.7 | 0 |
| Knowledge update | 2 | 93.3 | 93.3 | 0 | | 0 / 0 | 93.3 | 0 |
| Multi-session reasoning | 7 | 30.0 | 26.7 | -3.3 | -10.0 to 0.0 | 0 / 1 | 30.0 | 0 |
| Preference following | 0 | 80.0 | 80.0 | 0 | | | 80.0 | 0 |
| Summarization | 10 | 6.7 | 53.3 | +46.7 | +23.3 to +70.0 | 7 / 0 | 26.7 | +20.0 (0.0 to +43.3) |
| Temporal reasoning | 0 | 76.7 | 76.7 | 0 | | | 76.7 | 0 |

**Second grader (measured).** Vertex Sonnet 5.5 graded the ten summarization questions' items of the notes run (10 positives, 10 negatives, 60 answers, three replicates): 9 of 10 ideal summaries accepted, 10 of 10 negatives rejected, 1 of 240 requests failed (its item still had a majority). Under Sonnet the ordinary answers score 0.0 and the notes design 16.7 (D +16.7, interval 0.0 to +40.0; 2 questions better, 0 worse). Sonnet is the stricter grader, as on October 12; the gain keeps its direction and loses size.

Sign tests: p = 0.070 (notes) and 0.125 (quotes) over all questions. Verdicts were unanimous across replicates on 92 of 100 baseline questions and 26 of 33 routed notes-design questions.

Map stage of the notes design: 219 calls, every reply in the declared form (0 dropped lines), a median of 23 notes per routed replicate, one reply cut at its output limit, one replicate with no notes (its question kept the ordinary answer). The notes cited 77 percent of the gold snippet labels at 100K and 45 percent at 500K (event ordering 41 percent, summarization 59, multi-session 72, contradiction 70). Of the quotes design: 219 calls, 0 dropped lines, a median of 20 labels selected per replicate, 68 percent of the gold labels selected at 100K and 30 percent at 500K (event ordering 32, summarization 34). Citations: every one of the 1,445 citations in the notes-design answers and 1,308 in the quotes-design answers resolved to a delivered or snippet label; 549 and 383 of them cited snippet labels. Declines fell from 39 of 300 ordinary answers to 8 of 98 notes-design candidate answers.

## Cost and latency (measured)

Per answer, at the declared standard rate ($1.50 and $7.50 per million tokens), medians unless noted:

| Arm | Calls | Input tokens | Output tokens | Seconds (median / mean) | USD (mean) |
|---|---:|---:|---:|---|---:|
| Ordinary Send, all 100 questions | 1 | 16,969 | 172 | 3.6 / 5.0 | 0.028 |
| Ordinary Send, the 33 routed | 1 | 17,072 | 237 | 3.5 / 5.2 | 0.029 |
| Notes design, the 33 routed (map plus answer) | 3.2 | 57,021 | 1,076 | 15.9 / 22.3 | 0.089 |
| of which the map calls | 2.2 | 39,259 | 841 | 10.3 / 15.4 | 0.056 |
| Quotes design, the 33 routed (select plus answer) | 3.2 | 59,226 | 620 | 11.5 / 14.7 | 0.085 |

A routed question therefore costs about 2.2 extra calls and 40,000 extra input tokens, three times the ordinary cost and three to four times its latency; the map calls were dispatched in parallel here (six workers), which is what a product path would do, so the added latency per turn is one map call plus the answer call, about 10 s. Across the whole cohort the notes design added 0.73 calls and 13,200 input tokens per question. Spend at the standard rate (half of it is billed through 2026): pilot $0.99 (answers and grading); notes run $17.19 of answers, $2.97 of Gemini grading and $1.60 of Sonnet grading of the summarization subset; quotes run $8.36 of answers (its baseline reused) and $0.70 of grading (1,440 identical verdicts reused); held-out confirmation $4.67 of answers and $0.85 of grading. Total $37.33 against the $40 the brief allowed. The held-out answers cost more per question than the cohort's because its summarization notes were long (median 1,936 map output tokens per call).

## Held-out confirmation (measured)

The summarization gain was the one positive result, so before the decision it was tested on fresh conversations under a rule written before the run: confirm it when D on held-out summarization questions is at least +15 points with the interval's lower bound above 0. `beam_cohort.py build --conversations 100K:3,100K:4,100K:5,100K:6,500K:4,500K:5,500K:6,500K:7 --categories summarization` built 16 questions (155 gold turns; the ordinary request delivered none whole and reached 5 partially), captured as before; the notes design ran with two replicates (`declare --design notes --replicates 2`), the same reader, grader and prompts, in a separate private directory (`.build/beam-heldout-20261013/`).

| Questions | n | Ordinary Send | Notes design | D | Interval | Better / worse |
|---|---:|---:|---:|---:|---|---|
| Held-out summarization | 16 | 28.1 | 34.4 | +6.2 | -12.5 to +28.1 | 5 / 4 |
| of which 100K | 8 | 37.5 | 31.2 | -6.2 | -31.2 to +18.8 | 2 / 3 |
| of which 500K | 8 | 18.8 | 37.5 | +18.8 | -12.5 to +50.0 | 3 / 1 |

Calibration on this subset: 15 of 16 ideal summaries accepted, 16 of 16 negatives rejected. All 132 answer calls and 288 grade requests completed (two map replies cut at their output limit; 14 note lines dropped for form). Spend $5.52. The ordinary baseline on these fresh summarization questions (28.1 percent) is well above the cohort's (6.7), and four questions got worse under the notes. **Not confirmed**: the cohort's +46.7 does not replicate at a detectable size, and the 500K-only +18.8 is a post-hoc split of eight questions.

## Interpretation (inferred)

- **The gain is a summarization gain.** Seven of the eight questions that improved under the notes design are summarization questions (six to nine gold messages each, spread over the history); the eighth is at the 500K scale. Summarization went from 6.7 to 53.3 percent under the Gemini grader and from 0 to 16.7 under Sonnet, with no question worse under either. The notes design reads a dated snippet of every user message in the history and hands the answer step a chronological digest; that is exactly what a summary over a long history needs and what a 12,000-token excerpt component cannot hold (the ordinary request delivered 14 of the 139 summarization gold turns whole).
- **Event ordering and contradiction resolution did not move at all**: 0 of 30 answers in every arm and design, as on October 12. For ordering, the notes cited 41 percent of the gold snippets and the selection design 32 percent; a complete ordering needs every item, so partial recall produces a wrong order, and the answer model has no instruction that the snippet labels are in chronological order. For contradiction, the notes design's answers were often byte-identical to the ordinary answers with the gold already delivered whole in 6 of 10 cases: the reader's conclusion, not its evidence, is what fails, as the [context diagnostic](reviews/CONTEXT-DIAGNOSTIC-RESPONSE-20261012.md) found with an oracle pack.
- **Multi-session reasoning lost one question** under the notes design (30.0 to 26.7) and was unchanged under quotes; the counting questions need every mention, and 72 percent gold-snippet recall is not enough for a count.
- **Lossy notes beat selected quotes.** The quotes design was declared to fix the notes' lost facts, but its map selected only a third of the gold snippets at the 500K scale (median 34 selected of about 400 blocks), so the answer step read original text of mostly the wrong exchanges; the notes, which cover up to 120 snippets, carried more of the right facts despite their thinness. Selection from 320-character windows is the weak step in both designs.
- **The declared rule was not met**, by 0.7 points: D over all 100 questions is +4.3 against the +5 threshold, with the lower bound +1.0 and no category below -5. The rule diluted a 33-question effect over 67 questions that cannot change by construction; on the routed questions D is +13.1 (lower bound +3.0). The rule was written that way deliberately, to measure the whole product path, so the outcome stands: no promotion from this run.
- **Cost.** The path triples the per-question cost and latency of a routed question (3.2 calls, 57,000 input tokens, 16 s median) and adds 0.7 calls and 13,000 tokens per question over the cohort. At the 500K scale it sits at the edge of the plan's interim allowance.

## Decision

- **No default change.** The pre-declared rule gives `no_default_change` for both designs; nothing is wired into ordinary Send, and `AggregationRouter` and a versioned multi-source policy stay proposed (next section).
- **What is established:** on the cohort, reading every user turn of the history in dated snippets and summarizing them before the answer call raised summarization from 6.7 to 53.3 percent under the Gemini grader and from 0 to 16.7 under Sonnet, with no summarization question worse; it costs about three ordinary calls per routed question. On 16 held-out summarization questions the same path gave +6.2 points with an interval from -12.5 to +28.1 and four questions worse, so the size of the effect is not established and may be specific to the cohort's harder summarization questions (baseline 6.7 there against 28.1 held out).
- **What is not established:** any effect on event ordering, contradiction resolution or multi-session reasoning, where the designs as built do not reach the facts (ordering, counting) or cannot change the reader's conclusion (contradiction); and a summarization effect that survives fresh conversations.

## Proposed next work

1. **Do not wire the path as built.** The held-out run did not confirm the summarization gain, so the product path stays proposed. If a later design clears a held-out confirmation, the wiring is: `AggregationRouter` (the `summarize` rule, which routed exactly the summarization questions on this cohort) in `AnswerAttemptCoordinator` before component preparation; a `multi-source-map-notes-v1` policy that renders the snippets from the exchange index's blocks, dispatches the map calls through the selected model's endpoint as private stages the way the native investigation route does (`InvestigationStagePreparation`), and appends the notes as one more host-labelled user message with the framing sentence; journal validation for the new message; a Settings toggle until it is measured in the application.
2. **Event ordering needs complete recall and an ordered presentation.** Two cheap changes to measure next: tell the answer step that `[S<n>]` labels are in chronological order (the notes keep the label but the model has only the day-precision date), and let ordering questions' map calls list every mention of each item named in the question instead of free-form notes.
3. **Contradiction resolution is a reader problem**, not a retrieval one; it belongs with the reader decision, as the diagnostic response said.
4. **The map's selection step is the lever.** Both designs lost most of the gold at the 500K scale between the snippets and the answer step. Richer snippets for matched blocks (the whole user message where it matches a question term) or a two-pass map (select from thin snippets, then extract from whole messages) are the next designs, at 60,000 to 80,000 extra tokens per routed question.

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
