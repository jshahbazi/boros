# The record path: reading at save time, answering aggregation questions from the dated record

Record date: October 13, 2026. On the [BEAM cohort](BEAM-COHORT.md) today's ordinary Send answers about half of the questions; the weak categories (summarization 6.7 percent, event ordering 0, contradiction resolution 0, multi-session reasoning 30) need nearly every relevant message of a long history, and nothing that reads at question time has reached them: lexical search ranks about half of the needed messages at the 500K scale, and a question-time map over 320-character snippets recovered 30 to 45 percent of them ([MULTI-SOURCE-ANSWERS.md](MULTI-SOURCE-ANSWERS.md)). This record measures the alternative the user approved: read every exchange once, when it is stored, and answer the aggregation questions from the complete dated record. Each section states whether it reports implemented behavior, measured results, inferences or proposed design.

## Summary

- **The design (implemented in the evaluation driver).** One Gemini 3.8 Flash call per stored exchange writes compact dated entries (speaker, kind, subject, entities, a statement of at most 25 words and an exact quote); an entry is kept only when its quote is an exact substring of its source. Aggregation questions (the multi-source router, unchanged) are answered from the record: one selection call per 100,000 characters of the compact listing names the relevant entries, the lexical ranks fill the budget, and the ordinary request receives the selected entries in chronological order with their quotes. Nothing is compressed or overwritten.
- **Extraction (measured).** 3,923 exchanges of 13 conversations, 13,501 verified entries, no failed call, $18.81 ($0.0024 per stored message, $0.48 to $2.85 per conversation). 96.9 percent of the cohort's gold messages and 95.3 percent of the held-out gold have at least one entry.
- **Selection recall (measured).** The offline lexical methods reach 54 percent of the gold on the routed cohort questions (the record's subjects are singletons and the missed messages share no term with the question). The selection call alone reaches 66 percent; with the lexical fill, 75 percent on the cohort and 81 on the held-out questions (500K: 70 and 73). Event ordering and summarization, which need everything, are not complete for most questions.
- **Cohort (measured).** On the 33 routed questions the record path scores 25.3 against 14.1 percent, D +11.1 (interval +1.0 to +23.2; 4 better, 1 worse): the declared rule is met by one point. All of it is summarization (6.7 to 46.7); event ordering and contradiction resolution stay at 0 of 30 answers; multi-session reasoning loses one question.
- **Held out (measured).** On the 42 routed questions of eight fresh conversations, D +4.8 (interval -6.3 to +15.1; 8 better, 4 worse); summarization +16.7 (-6.3 to +39.6), multi-session -6.2, event ordering +2.1. The confirmation rule (D at least +10 with a positive lower bound, no category below -5) is **not met**, so **nothing was promoted** and the application is unchanged.
- **Cost (measured).** A routed question costs 2.8 to 3.2 calls, 63,000 to 115,000 input tokens, 15 s and $0.15 at the median against 1 call, 17,000 tokens, 3.5 s and $0.03; the write-time extraction is $0.0024 per stored message.
- **Spend.** $49.64 at the declared standard rate across extraction, selection, answers and grading, within the $60 allowed.

## The design (implemented in the evaluation driver, `scripts/beam_record.py`; the application is unchanged)

The path is implemented in the evaluation driver only. Ordinary Send is unchanged, and so are the step 3 framing and the exchange packer.

1. **Extract, at write time.** One Gemini 3.8 Flash call per human-led exchange (the user's message and the reply, under headings, with the exchange date, session and turn numbers) writes the record of that exchange: compact atomic entries, one JSON object per line, each with `speaker` (user or assistant), `kind` (fact, event, decision, plan, preference, change, question, recommendation), `subject` (a short noun phrase), `entities` (names as written), `statement` (one self-contained sentence of at most 25 words with the names, numbers and dates stated) and `quote` (an exact copy of a span of at most 20 words from that speaker's message). The prompt asks for every fact, event, decision, plan, preference, change and correction in the user's message and only the substantive contributions of the reply (recommendations, options, names, figures, steps, conclusions); it forbids reconciling conflicting statements, adding anything from outside the exchange, and commentary. At most 24 entries per exchange; the reply holds nothing but the JSON lines or `NO ENTRIES`.
2. **Verify.** An entry is kept only when its quote is an exact substring of its speaker's message. A quote the extractor re-spaced, re-cased or re-quoted is located in the source after whitespace, quote-mark and case folding and replaced by the exact original span (counted as `recovered`); a quote that cannot be located is rejected and counted. Every kept entry carries its source message sequence (the harness event ID), the source date (the message's `source_time`), session, exchange and speaker. The original history stays the ground truth: nothing is compressed or overwritten, and every entry links to its source. This is not a rolling summary.
3. **Route.** The deterministic router of the multi-source driver (`beam_multi_source.route`, unchanged: summary, ordering, count-across, "ever" and change-across rules) sends a question to the record; every other question keeps today's single call.
4. **Select.** The selection is the hard part at the 500K scale, where the record holds thousands of entries. Three offline methods were measured first (BM25 over the entries' subject, entities, statement and quote; the same with the seeds' subjects and entities pulling in every entry under them; the same plus the rest of each chosen exchange). The pilot on 100K-1 (next section) showed that they cannot close the gap: the paid method is one selection call per 100,000 characters of the compact record listing (every entry's label `[R<n>]`, date, turn, speaker, kind and statement, in chronological order, no quotes; labels are global so a selection resolves across chunks) that lists the labels of every entry a later step must read, at most 120 per chunk; the 24 best lexical matches are added as a floor; at most 250 entries or 64,000 characters go forward, in chronological order. The selection runs once per question, not per replicate.
5. **Answer.** The ordinary `exchange_packed` request, exactly as captured for the baseline, receives one more host-labelled user message before the question: the selected entries, each as `[R<n>] date, turn, speaker, kind: statement Quote: "..."`, under a heading that names them as host-derived, says they cover the whole conversation in chronological order and that turn numbers increase with time, and one sentence appended to the System framing that gives them the standing of quoted sources and asks for their labels to be cited. A routed question whose selection is empty keeps its ordinary answer.

## Pilot on one 100K conversation (measured, October 13)

Extraction over the 94 exchanges of 100K conversation 1: 94 calls, no failure, $0.53 at the declared standard rate ($0.0028 per stored message, $0.0056 per exchange), median 3.4 s per call, 179,123 input and 34,564 output tokens; 395 verified entries (4.2 per exchange; 221 from user messages, 174 from replies), 393 quotes exact and 2 recovered, 17 rejected; no malformed line. 179 of the 188 messages have at least one entry. Extraction coverage of the gold messages of the conversation's 20 questions: 50 of 53 (94.3 percent; summarization 20 of 21, every other category with gold complete except information extraction and instruction following at 2 of 3).

Offline selection recall of the gold messages on the 7 routed questions, at most 250 entries per question:

| Method | Recall, routed | Summarization | Event ordering | Multi-session | Entries selected (median) |
|---|---:|---:|---:|---:|---:|
| Lexical (BM25) | 63.9 | 47.6 | 71.4 | 100 | 89 |
| Lexical with subject and entity expansion | 66.7 | 52.4 | 71.4 | 100 | 108 |
| The same plus the rest of each chosen exchange | 66.7 | 47.6 | 85.7 | 100 | 188 |

Why the offline methods stop there (inferred from content-free counts): 373 of the 383 distinct subjects name one entry, because the extractor sees one exchange at a time and writes a fresh subject for each statement, so subject expansion has nothing to expand; and every missed gold message has entries (one to four each) none of which contains a term of the question. The gap is paraphrase, not coverage. That is why the paid selection reads the statements: the listing of a 100K record is about 395 lines, of a 500K record about 1,700, which one to three Gemini calls cover.

## Extraction over the cohort and the held-out conversations (measured, October 13)

| Set | Conversations | Messages | Exchanges (calls) | Failures | Verified entries | Per exchange | Quotes exact / recovered / rejected | Malformed lines | USD | USD per message |
|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|
| Cohort | 5 | 2,836 | 1,418 | 0 | 5,548 | 3.9 | 5,512 / 36 / 424 | 21 | 7.35 | 0.0026 |
| Held out | 8 | 5,010 | 2,505 | 0 | 7,953 | 3.2 | 7,872 / 81 / 909 | 28 | 11.46 | 0.0023 |

Per conversation the cost is $0.48 to $0.59 at 100K and $1.99 to $2.85 at 500K; a call takes 3.2 to 3.7 s at the median; no call was cut at its output limit; no thought tokens were billed. Rejected quotes (6 to 10 percent of the entries the extractor wrote, more in the two held-out 500K conversations with short user turns) are the honesty check doing its work: an entry whose quote is not in its source does not enter the record. Extraction coverage of the gold messages: cohort 341 of 352 (96.9 percent; summarization 95.0, information extraction 85.7, instruction following 86.7, every other category 100); held out 321 of 337 (95.3; summarization 90.3, multi-session 98.5, event ordering 100).

## Declared before generation

Each run's `declaration.json` froze, before any answer existed: the routing of every question, the record listing chunks (by hash) and their Gemini token counts, the lexical seeds, the job list in a seeded order (baseline answers, one selection per routed question, candidate answers), the worst case and the cap, the reader settings (Gemini 3.8 Flash, thinking "low", 2,048 output tokens plus a 2,048-token thinking allowance for answers, 1,024 plus 2,048 for selection, no sampling field) and the rule:

- **Unit.** The question; its accept rate is its correct answers over three replicates under the grader's majority of three. An unrouted question's record answer is its ordinary answer of the same replicate.
- **Difference.** D is the mean accept rate of the record path minus ordinary Send over the **routed** questions, in points, with a 95 percent paired bootstrap percentile interval over questions (10,000 resamples seeded by the declaration digest) and a two-sided sign test. Unrouted questions are unchanged by construction and are reported beside the decision, not diluted into it (the dilution is why the multi-source rule misfired).
- **Promote** when D on the routed questions is at least +10, the interval's lower bound is above 0, and no category's D over all its questions is below -5. **Confirm** with the same rule on the routed questions of the held-out conversations, declared before that run.
- **Amendment.** The cohort's declaration was amended once, before any candidate answer existed and after the 73 selection calls had finished, from content-free recall counts of their outputs: the first composition took an equal share of labels per chunk (which cut large selections) and left the budget unfilled, reaching 55.3 percent of the gold; composition v2 takes every label the selection calls listed, then the lexical seeds, then the remaining lexical ranks, to at most 400 entries or 100,000 characters, and reaches 74.6 percent. The earlier declaration is kept beside the amended one (`declaration-before-amend-1.json`); the selection outputs are unchanged. The held-out run was declared with composition v2 from the start.
- **Caps** were worst-case bounds (every call reserves its whole output allowance until its usage is known) except for extraction, whose bound is far above its measured cost (the API allows 4,608 output tokens per call against 370 used); there the cap was set against the expected cost at the pilot's rate and enforced at run time. Cohort answers: worst case $14.91 under $15 (300 ordinary answers and their 1,440 grade verdicts reused from the multi-source run, byte-identical requests and candidates); cohort grading $6.94 under $10; held-out answers $26.59 under $31; held-out extraction expected $14.03 under $20; cohort extraction $3.61 under $4 (pilot) and expected $7.41 under $12.

## Selection recall (measured, content-free counts against the gold messages)

The selection calls: cohort 73 calls over 33 routed questions (one at 100K, three at 500K; listing median 70,857 Gemini tokens per routed question; 8.0 s and $0.0875 per question at the median; every reply in the declared form, 0 dropped lines; a median of 58 labels gathered per question). Recall of the gold messages of the routed questions, cohort:

| Selection | Routed | 100K | 500K | Summarization | Event ordering | Multi-session | Contradiction |
|---|---:|---:|---:|---:|---:|---:|---:|
| In the record (extraction ceiling) | 97.1 | 97.1 | 97.2 | 95.0 | 100 | 100 | 100 |
| Selection calls alone | 65.6 | 77.9 | 60.8 | 64.0 | 61.8 | 86.4 | 63.6 |
| Lexical seeds alone (24) | 26.2 | | | | | | |
| Composition v2 (what the answer step received) | 74.6 | 86.8 | 69.9 | 66.2 | 80.9 | 100 | 81.8 |

14 of the 33 routed questions received every gold message; the record message held a median of 259 entries (65,867 characters, about 21,000 tokens). The held-out numbers are in the confirmation section.

## Cohort results (measured)

Reader and grader as in [BEAM-COHORT.md](BEAM-COHORT.md); the baseline column is the same 300 ordinary answers and 900 verdicts as the multi-source record (reused by digest). All 99 candidate answers and 1,737 grade requests completed; no verdict was unknown. Calibration: 78 of 80 positives and 100 of 100 negatives, as before, so paired comparisons under one grader.

| Questions | n | Ordinary Send | Record path | D | Interval | Better / worse |
|---|---:|---:|---:|---:|---|---|
| **Routed (the decision)** | 33 | 14.1 | 25.3 | **+11.1** | **+1.0 to +23.2** | 4 / 1 |
| Unrouted | 67 | 67.2 | 67.2 | 0 | | 0 / 0 |
| All | 100 | 49.7 | 53.3 | +3.7 | +0.3 to +8.0 | 4 / 1 |
| Routed, 100K | 13 | 20.5 | 35.9 | +15.4 | 0.0 to +38.5 | 2 / 0 |
| Routed, 500K | 20 | 10.0 | 18.3 | +8.3 | -3.3 to +25.0 | 2 / 1 |

By category (routed questions in parentheses):

| Category | Routed | Ordinary Send | Record path | D | Interval | Better / worse |
|---|---:|---:|---:|---:|---|---|
| Summarization | 10 | 6.7 | 46.7 | +40.0 | +10.0 to +70.0 | 4 / 0 |
| Multi-session reasoning | 7 | 30.0 | 26.7 | -3.3 | -10.0 to 0.0 | 0 / 1 |
| Event ordering | 9 | 0.0 | 0.0 | 0 | | 0 / 0 |
| Contradiction resolution | 5 | 0.0 | 0.0 | 0 | | 0 / 0 |
| Knowledge update | 2 | 93.3 | 93.3 | 0 | | 0 / 0 |
| The five unrouted categories | 0 | unchanged | | | | |

The declared cohort rule is met (D +11.1, lower bound +1.0, no category below -5), by a margin of one point and five questions. Sign test p = 0.375. Citations: every one of the 1,155 citations in the record-path answers resolved to a delivered or record label, 305 of them record labels.

Cost per answer, medians (mean for USD), at the declared standard rate:

| Arm | Calls | Input tokens | Output tokens | Seconds (median / mean) | USD |
|---|---:|---:|---:|---|---:|
| Ordinary Send, all 100 questions | 1 | 16,969 | 172 | 3.6 / 5.0 | 0.028 |
| Ordinary Send, the 33 routed | 1 | 17,072 | 237 | 3.5 / 5.2 | 0.029 |
| Record path, the 33 routed: answer call only | 1 | 38,374 | 280 | 6.1 / 8.7 | 0.062 |
| Record path, the 33 routed: selection plus answer | 3.2 | 114,708 | 776 | 15.2 / 19.1 | 0.150 |

The write-time cost is separate: $0.0026 per stored message, paid once.

## Held-out confirmation (measured)

The confirmation rule was declared before the run: the same rule as the cohort's, on the routed questions of conversations outside the cohort. `beam_cohort.py build --conversations 100K:3,100K:4,100K:5,100K:6,500K:4,500K:5,500K:6,500K:7 --categories summarization,event_ordering,multi_session_reasoning` built 48 questions (337 gold turns) from the eight conversations the multi-source record used for its summarization confirmation; the ordinary request delivered 6 of them whole, 23 partially and 18 not at all. The whole path ran again from scratch in a separate private directory: extraction (above), 144 ordinary answers (the earlier held-out baselines could not be reused: the re-captured requests differ from that run's by a fixed-width token in every source header, 27 more tokens, so the byte-identity rule rejects them), 75 selection calls over 42 routed questions (15 of 16 event ordering, 11 of 16 multi-session, all 16 summarization), 126 candidate answers, three replicates, the same reader, grader and prompts. All 345 answer calls completed; 3 of 1,098 grade requests failed and every item still had a majority of valid verdicts. Calibration: 47 of 48 positives (one ideal summary rejected) and 48 of 48 negatives.

Selection recall on the held-out routed questions: selection calls alone 64.7 percent of the gold, composition v2 81.3 (100K 89.0, 500K 73.3; summarization 81.3, event ordering 76.2, multi-session 95.0); complete for 19 of 42 questions (summarization 3 of 16, event ordering 7 of 15, multi-session 9 of 11); a median of 294 entries (74,377 characters) per question; $0.078 and 8.2 s per selection.

| Questions | n | Ordinary Send | Record path | D | Interval | Better / worse |
|---|---:|---:|---:|---:|---|---|
| **Routed (the confirmation)** | 42 | 19.8 | 24.6 | **+4.8** | **-6.3 to +15.1** | 8 / 4 |
| Unrouted | 6 | 61.1 | 61.1 | 0 | | 0 / 0 |
| All | 48 | 25.0 | 29.2 | +4.2 | -5.6 to +13.2 | 8 / 4 |
| Routed, 100K | 23 | 31.9 | 27.5 | -4.3 | -18.8 to +8.7 | 3 / 3 |
| Routed, 500K | 19 | 5.3 | 21.1 | +15.8 | +1.8 to +31.6 | 5 / 1 |

| Category (all its questions) | Routed | Ordinary Send | Record path | D | Interval | Better / worse |
|---|---:|---:|---:|---:|---|---|
| Summarization | 16 | 22.9 | 39.6 | +16.7 | -6.3 to +39.6 | 6 / 2 |
| Event ordering | 15 | 0.0 | 2.1 | +2.1 | 0.0 to +6.2 | 1 / 0 |
| Multi-session reasoning | 11 | 52.1 | 45.8 | -6.2 | -20.8 to +4.2 | 1 / 2 |

**Not confirmed.** D on the routed held-out questions is +4.8 with an interval that spans zero, and multi-session reasoning is below -5. Sign test p = 0.39. The scale split is post hoc and is reported for the next design, not for the decision: at 500K, where ordinary Send answers 1 routed question in 20, the record path answers 4, while at 100K it is a wash.

Cost per answer on the held-out routed questions, medians (mean for USD): ordinary Send 1 call, 17,770 input tokens, 5.4 s, $0.031; record path answer call only 42,905 tokens, 7.0 s, $0.067; selection plus answer 2.8 calls, 63,149 tokens, 15.6 s, $0.145. Spend on the held-out run: extraction $11.46, baselines $4.47, selection $3.28, candidates $8.49, grading $2.52.

## Decision

- **No promotion; the application is unchanged.** The cohort rule was met by one point and the held-out rule was not met, and the brief required both. No derived sidecar, background extraction job, router or record path was wired into ordinary Send; those stay proposed (next section). The Swift sources are untouched; the step 3 framing and the exchange packer are untouched.
- **What is established (measured, two runs):** write-time extraction is cheap ($0.0024 per stored message), reliable (no failed call in 3,923; quotes verified) and nearly complete (96.9 and 95.3 percent of the gold messages have an entry). The selection step, not the record, is what bounds the path: 70 to 73 percent of the gold at the 500K scale, complete for 3 of 26 summarization questions across both runs. Summarization improved in the same direction in both runs (+40.0 on the cohort, +16.7 held out; 10 questions better, 2 worse, over 26), and the held-out interval includes zero.
- **What is not established:** any effect on event ordering (1 question of 25 better, with 76 to 81 percent of its gold delivered: a complete order needs every item, and the reader did not produce it from the entries it had) or contradiction resolution (0 of 15 answers in every arm, the reader-judgment problem left to the other agent); and multi-session reasoning got worse in both runs (-3.3 and -6.2; 3 questions worse, 1 better), which the counts recorded here cannot explain; one plausible and unverified mechanism is that the record carries an entry from the user's message and one from the reply about the same event, so a count over entries double-counts. The held-out grading had 2 `GRADER_FORMAT` and 1 `UNEXPECTED_GROUNDING_SCORE` failures among 1,098 requests; the cohort grading none.

## Interpretation (inferred)

- **Reading at write time works; choosing at question time does not yet.** The record holds the facts (97 percent coverage, exact quotes) at a fifth of a cent per message, and the answer call that received the right entries answered summaries that the ordinary request cannot hold. But the selection call, reading one-line statements, judged 35 percent of the gold entries irrelevant, and the lexical fill recovers some of them only by volume (a median of 260 to 290 entries, 20,000 tokens, per routed question). Where the ordinary path has nothing (500K), the partial record still helps; where it already has half the sources (100K), the extra 20,000 tokens of partially relevant entries do not.
- **The three weak categories are three different problems.** Summarization needs coverage and gets some of it from the record; event ordering needs complete coverage and an ordered presentation of the named items, which neither the selection nor the reader provided; contradiction resolution is a reader problem; and counting across sessions needs one entry per event, not one per speaker.

## Proposed next work

1. **Selection recall at 500K is the lever**, as it was for the snippet map: a more inclusive selection prompt (the calls listed a median of 58 labels against a cap of 120 per chunk), a second pass that reads the whole exchanges of the selected entries, or, at the 100K scale, no selection at all (the whole record is about 400 entries, 25,000 tokens, and fits beside the ordinary request). Each is measurable offline against the gold with `recall` before any answer is paid for; the cohort and held-out records already exist in `.build/` and cost nothing to reuse.
2. **De-duplicate per event before the answer call** (one entry per source exchange, the user's statement first) and tell the reader that a user statement and the reply about it are one event, then re-measure multi-session reasoning, which the record made worse.
3. **Event ordering needs its own presentation:** list, for each item the question names, the entries that mention it with their turn numbers, and ask for the order of first mentions. That is a question-time transform over the same record and can be measured on the 25 ordering questions already captured.
4. **If summarization alone is the target**, a summarization-only route (the `summarize` rule, 10 of 10 and 16 of 16 here) with a confirmation on a larger held-out set: the direction held in both runs, the size did not.
5. **If a later design clears a held-out confirmation**, the wiring is what the brief described: a derived sidecar store of entries keyed by event ID (rebuildable, excluded from backups like the exchange index), a background extraction job through the configured model endpoint at about $0.0024 per stored message, and the router plus record path in `AnswerAttemptCoordinator` as an opt-in versioned policy, with the quote verification as a check.

## Reproduce

```bash
P=/Users/johnshahbazian/.venv-vllm-metal/bin/python3
$P scripts/beam_record.py extract-declare --output .build/beam-record-20261013 --tag rest --conversations 100K-2,500K-1,500K-2,500K-3 --cap-usd 12
$P scripts/beam_record.py extract-run --output .build/beam-record-20261013 --tag rest
$P scripts/beam_record.py coverage --output .build/beam-record-20261013
$P scripts/beam_record.py declare --output .build/beam-record-20261013 --reuse-answers <the multi-source run> --cap-usd 15
$P scripts/beam_record.py run --output .build/beam-record-20261013 --stages baseline,select
$P scripts/beam_record.py recall --output .build/beam-record-20261013
$P scripts/beam_record.py run --output .build/beam-record-20261013 --stages candidate
$P scripts/beam_record.py grade-declare --output .build/beam-record-20261013 --reuse-grades <its grader directory> --cap-usd 10
$P scripts/beam_record.py grade-run --output .build/beam-record-20261013
$P scripts/beam_record.py score --output .build/beam-record-20261013
```

The held-out run is the same sequence on `.build/beam-record-heldout-20261013` after `beam_cohort.py build` and `capture` with the conversation and category selection above, without the reuse flags. Tests: `scripts/test_beam_record.py` (8 synthetic contracts: the extraction request, quote location, entry parsing, lexical selection and expansion, the listing chunks and selection parsing, the candidate composition, the answer-body transform, citations and the decision rule), run by `check.py`.

## Privacy and artifacts

Entries, listings, selections, request bodies, answers, grades and the declarations are in `.build/beam-record-20261013/` and `.build/beam-record-heldout-20261013/` of worktree `agent-a58874337b3759528` (0700 directories, 0600 files). This record contains no question, answer, entry, quote, reference or conversation text.
