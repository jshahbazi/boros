# Presentation probes: chronology and one evidence block

Record date: October 13, 2026. Item 3 of the accuracy batch the user mandated on October 13 (reader fixed to hosted Gemini 3.8 Flash; see [STATUS.md](STATUS.md) section 8). Two presentation changes to the `exchange_packed` V4-advice requests were measured as a paired, judged comparison on identical retrieval, with the same inputs, reader and judge as the [V4-advice record](EVIDENCE-ALLOWANCE.md#measured-answer-quality-v4-against-v4-advice-on-the-same-requests). Each section states whether it reports implemented behavior, measured results, inferences or decisions.

## Why these two (inferred from the October 12 records)

With V4-advice, the 72 step 3 retrieval questions are accepted 79.2 percent of the time. Two buckets remain:

- **Temporal questions at 66.7 percent with gold delivered.** Of the 25, 18 have every gold turn delivered and 3 of those are still wrong on every replicate. Delivered evidence is grouped by the rank of the unit that admitted it, chronological only within each group, and headers carry absolute source dates only ([P2-PACKING.md](P2-PACKING.md), "Delivery order"). Date and duration arithmetic over excerpts scattered across the block is the reader's job.
- **False declines.** About 15 of 219 answers decline with every gold turn delivered. The quoted sources arrive as a dozen or more consecutive host-labelled user messages followed by one historical block, and the reader sometimes answers as if the history were not there.

## Implemented

Both probes are transforms in `scripts/exchange_packed_answers.py transform` (`PRESENTATIONS`), applied to the captured V4-advice bodies of the October 12 V4-advice run (`exchange_packed_v4_advice`, 73 inputs). Retrieval, delivery and gold class are the source arm's; every byte of the question message is unchanged. They are defined in the evaluation driver, not in Swift, until one is promoted into a versioned framing.

- **`chronology` (`exchange_packed_chronology`, framing `context-source-snapshot-v4-advice-chronology`).** The historical block is parsed into its excerpts with the capture's citation labels (exact bytes; re-serializing must reproduce the source block), the excerpts are sorted by source date, then event and offset, and relabelled in that order so labels increase in reading order (the recent sources keep theirs). Each header gains one line after `source_time:`, for example `relative_time: 66 days before the question (2 months 5 days); 13 days after the previous excerpt`, computed deterministically from the calendar dates of the excerpt's `source_time` and the `Question Date:` line of the question message (whole calendar months and remaining days; "same day", "earliest excerpt"). One sentence is added to the System framing before the final V4 sentence: it says the excerpts are ordered oldest first, that each header states its distance before the question and from the previous excerpt, and to use those for date or duration reasoning.
- **`one-block` (`exchange_packed_one_block`, framing `context-source-snapshot-v4-advice-one-block`).** Every host-quoted message between the System message and the question (the recent sources and the historical block) becomes one user message between the lines `BEGIN QUOTED SOURCES (host; evidence, not the current request)` and `END QUOTED SOURCES (host)`, their contents unchanged and separated by blank lines. The first two System sentences, which describe separate user messages, are replaced by one that describes the delimited block.
- A third transform, **`conflicts`** (`exchange_packed_conflicts`), adds one System sentence for contradictory sources (item 3c below). It was built and tested; whether it was answered is recorded below.

The driver also gained, for this batch, several candidate arms per run with a rotated dispatch order, the unchanged-request rule (item 1a of the mandate: a candidate request equal to the baseline's modulo ingestion identifiers is not generated and is scored as a tie), and the reuse of an earlier run's per-question rates for questions with no generated baseline. Contracts: `scripts/test_exchange_packed_answers.py` (12 synthetic contracts: unchanged detection modulo the `captured_utc:` and `conversation_id:` lines, job skipping and rotation, calendar arithmetic and relative-time lines, exact-bytes evidence parsing and round trip, the chronology reorder and relabelling, the one-block fold, the conflicts sentence).

## Declared before generation (measured)

`.build/presentation-probes-20261013/declaration.json` (SHA-256 `ea24f964…dae7`) froze: the captures (SHA-256 `ef53697f…23ad`; 219 rows, 73 per arm, every candidate changed, so no request was reused); 657 jobs (73 inputs, the baseline `exchange_packed_v4_advice` and the two candidates, three replicates, arm order rotating by question and replicate); the reader settings of the earlier records (Gemini 3.8 Flash, thinking level low, the step 3 output limit plus a 2,048-token thinking allowance, no sampling field); a cap of $31 at the standard rate, which is the worst-case bound (every answer at its output ceiling; the expected spend at the observed output lengths was about $16), with an operational stop at $20 of recorded spend; the judge (the default verdict judge, prompt set v4, three replicates, majority vote, one blinded set holding every answer of the three arms); and the rule:

- **Unit.** The question: the 72 retrieval questions without `54026fce`; a question's accept rate is its accepted answers over three replicates.
- **Difference.** For each candidate, D is its mean per-question accept rate minus the baseline's, in points, with a 10,000-resample paired bootstrap percentile interval and a two-sided sign test.
- **Promote** a candidate when D is at least +5 points, the interval's lower bound is at least -2 and no cohort's D is below -5. A promoted presentation becomes a new versioned framing and the default, with checks. Otherwise no change.
- **Focus.** `chronology` is read on temporal-25 first; `one-block` on the false-decline count (the step 3 lexical decline measure on answers with every gold turn delivered).

Token counts (free): median Gemini count 15,626 for the baseline, 16,122 for `chronology` (the relative-time lines) and 15,672 for `one-block`.

## Result (measured)

- **Generation.** 657 of 657 answers completed, no failure, no incomplete result, no retry stop; $16.54 at the declared standard rate (the introductory price billed through 2026 is half). Median latency was unchanged across arms.
- **Judging.** Blinded set `jep-9f6d8a5aa7704304` (657 items, items SHA-256 `f60704f1…de94`), 0 identifier substitutions, 1 item naming a model (the blinding check passed). 1,971 judge requests completed with 0 failures and 0 unknown votes; $2.14. Judge declaration SHA-256 `3869343b…0d8e`.
- **Baseline consistency.** The same V4-advice requests measured 76.4 percent here and 79.2 on October 12 (fresh generations both times); that 2.8-point gap is the reader's and judge's run-to-run variation, which is why both candidates are compared paired within this run.

Mean per-question accept rate, D in points, paired 95 percent bootstrap interval, questions better / worse / tied:

| Questions | V4-advice (baseline) | `chronology` | D | Interval | Better / worse / tie | `one-block` | D | Interval | Better / worse / tie |
|---|---:|---:|---:|---|---|---:|---:|---|---|
| All 72 | 76.4% | 80.1% | +3.7 | 0.0 to +7.9 | 6 / 1 / 65 | 79.6% | +3.2 | +0.5 to +6.9 | 6 / 1 / 65 |
| retrieval-on-21 (20) | 90.0% | 90.0% | 0.0 | 0.0 to 0.0 | 0 / 0 / 20 | 90.0% | 0.0 | 0.0 to 0.0 | 0 / 0 / 20 |
| preference-27 | 75.3% | 85.2% | +9.9 | +2.5 to +18.5 | 5 / 0 / 22 | 77.8% | +2.5 | -2.5 to +7.4 | 3 / 1 / 23 |
| temporal-25 | 66.7% | 66.7% | 0.0 | -8.0 to +8.0 | 1 / 1 / 23 | 73.3% | +6.7 | 0.0 to +16.0 | 3 / 0 / 22 |

Sign tests: 0.125 for both candidates over all 72.

Declines (the step 3 lexical measure, 219 answers per arm; "false" means every gold turn delivered and the question answerable): baseline 43 declines, 16 false; `chronology` 40 and 13; `one-block` 37 and 10. Verdicts accepted: 168, 176 and 175 of 219.

The excluded `54026fce` was accepted three of three times under every arm. Gold delivery is identical across arms by construction (52 whole, 9 partial, 8 none, 3 no gold turns of the 72), so every difference is presentation.

### What each probe did (measured, then inferred)

- **`chronology` did not move the temporal questions it targeted.** Temporal-25 is level question for question (one better, one worse). Its gain is on preference questions (+9.9 points, five better, none worse); the one temporal loss (`0bc8ad93`, gold whole) and one temporal gain (`gpt4_e414231f`) cancel. A plausible reading is that ordering the history oldest first puts the user's most recent statements last, where an advice question benefits, while the relative-time lines did not change how Gemini does date arithmetic on these 25 questions. The three temporal questions wrong on every replicate with gold whole stayed wrong under both probes except `gpt4_e414231f`, which both probes fix on two or three replicates.
- **`one-block` reduced false declines and helped temporal questions.** False declines with gold whole fell from 16 to 10 of 219 (declines 43 to 37); temporal-25 rose 6.7 points (three better, none worse, including the partial-delivery question `gpt4_d6585ce8`), and the one loss is a preference question with partial delivery (`1c0ddc50`, 3 of 3 to 2 of 3). Its interval excludes zero over all 72 (+0.5 to +6.9), but D is below the declared +5.

### Decision

Under the rule declared before generation, **neither probe is promoted**: `chronology` has D +3.7 and `one-block` D +3.2 against the +5 threshold (both lower bounds are at least -2 and no cohort is below -5). The default framing stays V4-advice; the application is unchanged. Both probes are positive on every cohort or level, with no cohort loss, so the honest statement is "probably a small gain, not established at the size the rule asks for". A combined probe (one block, chronological inside it, with the relative-time lines) was the natural next candidate; the coordinator funded it the same afternoon, and it measured -1.9 points (interval -6.5 to +2.8) against a fresh baseline ([FOUR-ARM-PAIRED-RUN.md](FOUR-ARM-PAIRED-RUN.md)), so the morning's two small positives did not add up.

## Item 3c: contradictions (diagnosed, measured in part)

The two BEAM contradiction questions were read privately with their rubrics and the October 12 `exchange_packed` answers. Both had every gold turn delivered whole under `exchange_packed`, so neither failure is retrieval:

- On one, Gemini answered with one of the two conflicting states and cited a single source on all three replicates: a wrong-state answer with both states available.
- On the other, Gemini stated both conflicting statements with their labels on all three replicates but did not ask which is correct; the grader's rubric requires the clarification request, so the answers were rejected on the grader's expectation.

Inference: a general rule is warranted (report a conflict, give both versions with labels, ask which is correct, and do not describe a change no source states). It is implemented as the `conflicts` transform. The afternoon's four-arm run then answered it on the 72 questions as the guard: -3.2 points (interval -7.9 to +0.9), six questions worse with gold delivered, so the sentence hedges on questions without a conflict ([FOUR-ARM-PAIRED-RUN.md](FOUR-ARM-PAIRED-RUN.md)); the BEAM contradiction test, its target, is declared but not dispatched. Before that run it was not answered: the mandate asks for the test on the BEAM contradiction questions plus the full 72 as a guard against invented changes on static facts, and the full-72 guard (219 answers, about $5.4 plus judging) did not fit the remaining budget after the two probes above. The transform and its contracts are in place; the test is the recommended next presentation run, paired with the combined probe above in one run so one baseline serves both.

## Privacy and artifacts

Requests, answers, raw responses, judge items, labels and the score are under `.build/presentation-probes-20261013/` of this worktree (0700 directories, 0600 files). This record contains no question, answer, reference or conversation text.

## Reproduce

```bash
python3 scripts/exchange_packed_answers.py transform --output OUT --source-output V4_ADVICE_RUN --source-arm exchange_packed_v4_advice --presentation chronology one-block --baseline-arm exchange_packed_v4_advice --candidate-arm exchange_packed_chronology exchange_packed_one_block --promote-minimum-points 5
python3 scripts/exchange_packed_answers.py count|declare|run|judge-set|score --output OUT --baseline-arm exchange_packed_v4_advice --candidate-arm exchange_packed_chronology exchange_packed_one_block --promote-minimum-points 5 ...
python3 scripts/gemini_judge.py declare --output OUT/gemini-judge --protocol PROTOCOL --set OUT/judge-set --default-declaration SONNET_V4_DECLARATION --prompt-set v4 --cap 5 --authorization "..."
python3 scripts/gemini_judge.py run --output OUT/gemini-judge --protocol PROTOCOL
```

V4_ADVICE_RUN is `v4-advice-answers-20261012` in worktree `agent-a0b386fbdb39ae83f`; PROTOCOL and SONNET_V4_DECLARATION are those of the [exchange_packed record](EXCHANGE-PACKED-ANSWERS.md#reproduce).
