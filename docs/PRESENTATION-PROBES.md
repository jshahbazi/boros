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

`.build/presentation-probes-20261013/declaration.json` (SHA-256 `DECLARATION_SHA`) froze: the captures (SHA-256 `ef53697f…23ad`; 219 rows, 73 per arm, every candidate changed, so no request was reused); 657 jobs (73 inputs, the baseline `exchange_packed_v4_advice` and the two candidates, three replicates, arm order rotating by question and replicate); the reader settings of the earlier records (Gemini 3.8 Flash, thinking level low, the step 3 output limit plus a 2,048-token thinking allowance, no sampling field); a cap of $31 at the standard rate, which is the worst-case bound (every answer at its output ceiling; the expected spend at the observed output lengths was about $16), with an operational stop at $20 of recorded spend; the judge (the default verdict judge, prompt set v4, three replicates, majority vote, one blinded set holding every answer of the three arms); and the rule:

- **Unit.** The question: the 72 retrieval questions without `54026fce`; a question's accept rate is its accepted answers over three replicates.
- **Difference.** For each candidate, D is its mean per-question accept rate minus the baseline's, in points, with a 10,000-resample paired bootstrap percentile interval and a two-sided sign test.
- **Promote** a candidate when D is at least +5 points, the interval's lower bound is at least -2 and no cohort's D is below -5. A promoted presentation becomes a new versioned framing and the default, with checks. Otherwise no change.
- **Focus.** `chronology` is read on temporal-25 first; `one-block` on the false-decline count (the step 3 lexical decline measure on answers with every gold turn delivered).

Token counts (free): median Gemini count 15,626 for the baseline, 16,122 for `chronology` (the relative-time lines) and 15,672 for `one-block`.

## Result (measured)

RESULTS_SECTION

## Item 3c: contradictions (diagnosed, measured in part)

The two BEAM contradiction questions were read privately with their rubrics and the October 12 `exchange_packed` answers. Both had every gold turn delivered whole under `exchange_packed`, so neither failure is retrieval:

- On one, Gemini answered with one of the two conflicting states and cited a single source on all three replicates: a wrong-state answer with both states available.
- On the other, Gemini stated both conflicting statements with their labels on all three replicates but did not ask which is correct; the grader's rubric requires the clarification request, so the answers were rejected on the grader's expectation.

Inference: a general rule is warranted (report a conflict, give both versions with labels, ask which is correct, and do not describe a change no source states). It is implemented as the `conflicts` transform. CONFLICTS_RESULT

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
