# exchange_packed answer quality

Record date: October 12, 2026. This is R1 of the [context diagnostic response](reviews/CONTEXT-DIAGNOSTIC-RESPONSE-20261012.md). It gives the P2 `exchange_packed` selection policy the answer-quality evidence that the [P2 records](P2-EXCHANGE-INDEX.md) named as the remaining gate for a default change. It uses the same inputs, reader and judge on both arms. Each section states whether it reports measured results, inferences or decisions.

## Summary

- **Authorization.** The user said "ok do it" to the proposed evaluation, which included an exception to the repair plan's principle 3 for a configuration below the offline R2 gate. The user then said "just use vertex for evals, don't worry about the local llm anymore" and "gemini 3.8 flash whatever is pretty cheap for the next few months". Both runs therefore use Vertex Gemini 3.8 Flash as the reader, and no local model.
- **Step 3 cohorts (measured).** The 72 retrieval questions, three replicates per arm, default Gemini judge.
  - Mean per-question accept rate: 57.9 percent under ordinary Send, 69.0 percent under `exchange_packed`.
  - Difference: +11.1 points, 95 percent paired bootstrap interval +2.3 to +20.4. On 16 questions `exchange_packed` was better and on 7 it was worse (sign test p = 0.093).
  - Outcome under the rule declared before generation: **promote**, and retrieval is confirmed as a practical lever for this reader.
- **Where the gain comes from (measured).**
  - On the 13 questions where `exchange_packed` newly delivers every gold turn, the accept rate rises from 17.9 to 76.9 percent.
  - On the 54 questions whose gold delivery is unchanged, it moves from 69.1 to 68.5 percent (interval -4.9 to +3.7). The longer prompt (about 1,300 more tokens at the median) did not cost accuracy.
- **BEAM (measured).** On the 20 questions of the OptChat comparison, the same reader and OptChat's BEAM grader request on Gemini were used.
  - Ordinary Send answered 8 of 20 correctly on every replicate. `exchange_packed` answered 9, 10 and 9.
  - Two questions were better and none worse. The difference is +6.7 points, interval 0.0 to +18.3.
  - The grader's calibration missed OptChat's strict rule by one control, so these are paired results, not calibrated scores.
- **Cost (measured).** $14.79 at the declared standard rate, which is twice what is billed through 2026:
  - $10.28 for the 438 answers;
  - $1.45 for the 1,314 judge requests;
  - $2.83 for the 120 BEAM answers;
  - $0.78 for the 462 BEAM grade requests.
  Every request completed. There were two BEAM grade replicates with an off-contract field (described below).

## Declared before generation

The declaration (`.build/exchange-packed-answers-20261012/declaration.json`, SHA-256 `142030a5…fee2`) froze the following:

- the captures and token counts;
- the 438 jobs: 73 inputs, two arms, three replicates, with the arm order alternating by question and replicate;
- the reader settings and the $30 cap at the standard rate;
- the decision rule.

The rule:

- **Unit.** The question. That means the 72 retrieval questions without `54026fce`. Each question's accept rate is its accepted answers over three replicates: the judge's majority of three, with unknown counted as not accepted.
- **Difference.** D is the mean accept rate of `exchange_packed` minus ordinary Send, in points. It is reported with a 95 percent paired bootstrap percentile interval over questions (10,000 resamples, seeded by the declaration digest) and a two-sided sign test.
- **Promote.** Promote when D is at least 0, the interval's lower bound is at least -2 points, and no cohort's D is below -5 points.
- **Retrieval lever.** Retrieval counts as a lever for this reader when D is at least +5 points and the interval's lower bound is above 0.

The -2 and -5 point margins were declared by the coordinator for this run. The repair plan does not define them. The context diagnostic response called the -2 margin "the plan's regression envelope", which was incorrect; that sentence is corrected.

## Step 3 retrieval cohorts

### Inputs (measured, offline)

The inputs are the 73 retrieval runs of the [step 3 replay](FRAMING-V4-VARIANTS.md): retrieval-on-21, preference-27 and temporal-25. These are the reader comparison's inputs without recent-only-21, whose recent-only strategy has no selection policy.

`scripts/exchange_packed_answers.py capture` rebuilt both arms' exact answer request bodies. It used the delivery harness built from this checkout's 105 Swift sources (build SHA-256 `f9a36bbd…f7db`, the same for both runs and unchanged since `5494e40`), one harness process per input with both arms, and the pinned offline tokenizer. No answer was generated.

- **Ordinary Send matches step 3.** Ordinary Send delivered exactly the step 3 declaration's delivered ranges and gold class on 73 of 73 inputs.
- **Bodies differ only in identifiers.** Its bodies are not byte-identical to the reader comparison's October 10 captures. They differ only in ingestion timestamps and generated identifiers inside host headings. Message roles and every message's length are identical on 73 of 73. Both arms here were generated fresh from the new captures, so the comparison does not depend on that equality.
- **Framing.** Both arms use framing V4 on 73 of 73.

Gold delivery on the 72 counted questions (`retrieval_harness.coverage`; "whole" means every annotated gold turn delivered whole):

| Cohort | Ordinary Send whole / partial / none / no gold | `exchange_packed` whole / partial / none / no gold |
|---|---|---|
| retrieval-on-21 (20 counted) | 12 / 1 / 4 / 3 | 14 / 2 / 1 / 3 |
| preference-27 | 14 / 5 / 8 / 0 | 20 / 3 / 4 / 0 |
| temporal-25 | 14 / 5 / 6 / 0 | 18 / 4 / 3 / 0 |
| All 72 | 40 / 11 / 18 / 3 | 52 / 9 / 8 / 3 |

Prompt size, median Gemini count: 14,312 tokens for ordinary Send and 15,618 for `exchange_packed`. The harness's Qwen counts were 14,176 and 15,395.

### Generation (measured)

- **Reader.** `gemini-3.8-flash` through `scripts/vertex_gemini.py`, with the reader comparison's settings:
  - thinking level "low", which is its lowest;
  - the step 3 output limit plus a 2,048-token thinking allowance;
  - no sampling field;
  - only the captured messages are sent.
- **Completion.** 438 of 438 answers finished, with no failure, no incomplete result and no retry stop.
- **Latency.** The median was 2.9 s for ordinary Send and 3.2 s for `exchange_packed`, with six concurrent workers.
- **Cost.** $4.87 and $5.41 at the declared standard rate ($1.50 / $7.50 per million tokens). The introductory price billed through December 31, 2026 is half.
- **Repeatability.**
  - Answers were byte-identical across all three replicates on 2 of 72 questions in each arm.
  - Verdicts were unanimous across replicates on 65 of 72 questions for ordinary Send and on 61 for `exchange_packed`.

### Judging (measured)

- **Judge.** The default verdict judge, `scripts/gemini_judge.py`:
  - prompt set v4;
  - the default declaration's prompt hashes, matched against `vertex-sonnet-v4-r3.json`;
  - three replicates and a majority vote.
- **Blinding.** All 438 answers of both arms went into one blinded set, `jep-992880da336f623f` (items SHA-256 `7222eb12…9c74`), in a seeded interleaved order with no arm, cohort or run visible. It had 0 identifier substitutions and 0 items naming a model.
- **Run.** 1,314 requests completed, with 0 parse failures and 0 invalid responses. Every answer received a majority verdict (0 unknown). Cost was $1.45 at the declared standard rate.
- **Earlier error rates.** The judge's calibration error rates from October 11 apply: error 6/79, false reject 4/35, false accept 2/44.

### Result (measured)

Mean per-question accept rate, D in points, paired 95 percent bootstrap interval, questions better / worse / tied:

| Questions | Ordinary Send | `exchange_packed` | D | Interval | Better / worse / tie | Sign test p |
|---|---:|---:|---:|---|---|---:|
| All 72 | 57.9% | 69.0% | +11.1 | +2.3 to +20.4 | 16 / 7 / 49 | 0.093 |
| retrieval-on-21 (20) | 73.3% | 90.0% | +16.7 | -5.0 to +38.3 | 5 / 1 / 14 | 0.22 |
| preference-27 | 49.4% | 56.8% | +7.4 | -6.2 to +21.0 | 7 / 4 / 16 | 0.55 |
| temporal-25 | 54.7% | 65.3% | +10.7 | -1.3 to +25.3 | 4 / 2 / 19 | 0.69 |

The pre-declared outcome is **promote**:

- D is +11.1;
- the lower bound is +2.3;
- the lowest cohort D is +7.4.

**Retrieval lever: yes.** D is at least +5 and the lower bound is above 0. The sign test alone does not reach 0.05. The declared rule uses the interval.

By change in gold delivery between the arms:

| Delivery change | Questions | Ordinary Send | `exchange_packed` | D | Better / worse |
|---|---:|---:|---:|---:|---|
| `exchange_packed` newly whole | 13 | 17.9% | 76.9% | +59.0 (+28.2 to +84.6) | 10 / 1 |
| Changed, neither whole | 4 | 25.0% | 66.7% | +41.7 | 2 / 0 |
| Unchanged | 54 | 69.1% | 68.5% | -0.6 (-4.9 to +3.7) | 4 / 5 |
| Ordinary Send whole, `exchange_packed` not | 1 | 100% | 0% | -100 | 0 / 1 |

The single loss is `retrieval-on-21--00ca467f`. `exchange_packed` delivered its gold only partly, and all three answers were rejected. Under ordinary Send it was delivered whole and accepted three times.

Declines (the step 3 lexical decline measure, all 219 answers per arm):

- Ordinary Send declined 81 times and `exchange_packed` 47 times.
- Declines with every gold turn delivered were 19 and 21.

The excluded `54026fce` was accepted three of three times under both arms.

As a consistency check, this run's ordinary Send baseline (57.9 percent) is close to the Gemini reader's earlier result on the same 72 prompts in the [reader comparison](READER-COMPARISON.md): 60.6 percent under the Gemini judge with prompt set v3. That was a different judge prompt set and a different day.

## BEAM long-history questions

### Inputs and capture (measured, offline)

`scripts/beam_exchange_packed.py capture` read, read-only, the inputs from the OptChat repository's private evaluation storage:

- the accepted Boros input of each of the 20 questions: the 796-message BEAM conversation, the question and the comparison's answer configuration;
- the normalized case;
- the author reference supplement.

It rebuilt both arms with Boros's delivery harness at this checkout. No OptChat code ran.

- **Ordinary Send matches the comparison.** Ordinary Send delivered the same recent sources as the frozen comparison request on 20 of 20 questions.
- **Bodies differ only in identifiers.** Its bodies differ from the frozen bodies only in ingestion timestamps and generated identifiers (same message count and character lengths). Each counts 32 fewer Qwen tokens.
- **Revision.** The comparison's Boros revision `f28584b` already ran ordinary Send lexically (`88303e3`, October 8).

Delivery of the 83 author-resolved source messages:

- Ordinary Send delivered 16 whole. That matches the comparison's 16 complete.
- `exchange_packed` delivered 27 whole.
- Of the 17 questions with resolvable sources, every source was whole on 7 under ordinary Send and on 10 under `exchange_packed`.
- `exchange_packed` reached part of the event-ordering question `dd324d29` (4 of 9 whole, against 0) and of multi-session `c396433f` (4 of 7, against 2).
- It lost the one whole source ordinary Send had for summarization `feefc644` (0 of 15, against 1).

### Reader and grader (measured)

- **Reader.** Gemini 3.8 Flash as above, with the comparison's 2,048 output tokens plus the thinking allowance, both arms, three replicates. 120 of 120 answers completed with no failure, at $2.83.
- **Grader.** OptChat's `beam-native-grader-1` request, ported to `scripts/beam_exchange_packed.py` and sent to the same Gemini model:
  - the blind-judge instruction, verbatim;
  - one JSON user message with question, category, reference answer, native rubric, author reference and candidate;
  - no delivered evidence;
  - the reply parser ported from `parseBeamVerdict`;
  - output limit 384 plus the 2,048-token thinking allowance;
  - three replicates and a majority vote on `correct`.
- **Calibration.** OptChat's controls were graded first: one authored positive per question where one exists (14) and one fabricated negative per question (20).
  - All 20 negatives were rejected and 13 of 14 positives accepted, with no invalid control.
  - OptChat's rule requires every positive to pass, so **the calibration is not accepted**.
  - The failed positive is the authored reference answer of temporal question `fb212bbc`, rejected three times with high confidence. Both arms' answers to that question were accepted three of three times.
  - The grades are therefore reported as a paired comparison under one grader, not as calibrated scores.
- **Off-contract replies.** Two of the 462 grade replicates returned a grounding score although no evidence was supplied. They are recorded as `UNEXPECTED_GROUNDING_SCORE` and the answer takes the majority of its remaining replicates. No vote was unknown. Grading cost $0.78.

### Result (measured)

| | Ordinary Send | `exchange_packed` |
|---|---|---|
| Correct per replicate, of 20 | 8, 8, 8 | 9, 10, 9 |
| Mean per-question accept rate | 40.0% | 46.7% |

- **Difference.** D is +6.7 points, interval 0.0 to +18.3. Two questions improved and none got worse.
- **Information extraction `b5dc14dd`.** Its source went from not delivered to whole, and the answers went from 0 of 3 to 3 of 3 correct.
- **Instruction following `9cd27fcb`.** It went from 0 of 3 to 1 of 3 with the same delivery. That is inside replicate noise.

By category, mean accept rate in percent for ordinary Send and `exchange_packed`, two questions each:

| Category | Ordinary Send | `exchange_packed` |
|---|---:|---:|
| Abstention | 50 | 50 |
| Contradiction resolution | 0 | 0 |
| Event ordering | 0 | 0 |
| Information extraction | 0 | 50 |
| Instruction following | 50 | 67 |
| Knowledge update | 100 | 100 |
| Multi-session reasoning | 0 | 0 |
| Preference following | 100 | 100 |
| Summarization | 0 | 0 |
| Temporal reasoning | 100 | 100 |

These numbers are not comparable with the comparison's 10, 6 and 3 of 20, which used local Qwen as reader and grader.

Two reader effects from the diagnostic are visible:

- **Knowledge update.** `cf558e11`, which local Qwen failed five of five times with its updated fact delivered, was accepted three of three times under both arms with Gemini.
- **Contradiction.** Both contradiction questions stayed wrong under both arms.

## Interpretation (inferred)

- **Better delivery becomes better answers for this reader.** The gain sits almost entirely on the questions whose gold delivery became whole. Questions with unchanged delivery did not lose accuracy to the longer prompt. That is the mechanism the diagnostic response predicted, and it answers the question this run was declared to answer.
- **The reader is Gemini, not local Qwen.** Ordinary Send in the application still answers with the selected local model, and a hosted reader would need its own egress and disclosure contracts (AGENTS.md). The reader comparison's delivery gradient for Qwen suggests the selection effect transfers, but that was not measured here: 80 percent accepted with every gold turn delivered, 41 with some and 13 with none.
- **What retrieval does not fix.** Contradiction resolution, multi-source aggregation (summarization with 15 to 26 sources, event ordering with 6 to 9) and multi-session reasoning stayed at zero on BEAM under both arms. Those belong to the reader decision (P5) and to an explicit multi-step mode (P3), as the response proposed.
- **Size.** 72 questions and three replicates per arm. The interval is wide (+2.3 to +20.4), and the sign test is not significant. The direction is supported by both cohort families and by every step 3 cohort. The size is not established.

## Decision

The declared rule's outcome is **promote**. Before the run, the user had approved "if it beats the current default by at least about 5 points: make it the default and move on". The default was switched the same day: ordinary Send now freezes `exchange_packed`, with a labelled v1 lexical fallback for projects that neither the index nor the per-turn rebuild can serve. See [IMPLEMENTATION.md](IMPLEMENTATION.md) and [the P2 index record](P2-EXCHANGE-INDEX.md).

After the switch, the harness `ordinary_send` arm follows the new default. A rerun of this record's capture must use the `lexical` arm for the earlier baseline; rerunning it unchanged fails its own reference check (`baseline_does_not_match_reference`) instead of silently comparing `exchange_packed` with itself.

## Privacy and artifacts

Requests, answers, raw responses, judge items, labels and BEAM grades are in the private output directories, with 0700 directories and 0600 files:

- `.build/exchange-packed-answers-20261012/` holds:
  - `captures.json` (SHA-256 `b10149d9…a6e`);
  - `counts.json`;
  - `declaration.json`;
  - `ledger.jsonl`;
  - `answers/`;
  - `judge-set/`;
  - `gemini-judge/`;
  - `score.json`.
- `.build/beam-exchange-packed-20261012/` holds the captures, the declarations (answer declaration SHA-256 `45205a96…815d`, grade declaration `8d8a3e12…a72e`), the ledgers, answers, grades and `score.json`.

Both directories are in the worktree `exciting-agnesi-172906`. This record contains no question, answer, reference or conversation text. The BEAM inputs are the public benchmark conversation and its authored references, kept in OptChat's private storage, which this run did not modify.

## Reproduce

```bash
/Users/johnshahbazian/.venv-vllm-metal/bin/python3 scripts/exchange_packed_answers.py capture --output .build/exchange-packed-answers-20261012 --dataset DATASET --reference STEP3_OUTPUT --baseline-captures READER_COMPARISON/captures.json
python3 scripts/exchange_packed_answers.py count --output .build/exchange-packed-answers-20261012
python3 scripts/exchange_packed_answers.py declare --output .build/exchange-packed-answers-20261012
python3 scripts/exchange_packed_answers.py run --output .build/exchange-packed-answers-20261012
python3 scripts/exchange_packed_answers.py judge-set --output .build/exchange-packed-answers-20261012 --dataset DATASET
python3 scripts/gemini_judge.py declare --output .build/exchange-packed-answers-20261012/gemini-judge --protocol PROTOCOL --set .build/exchange-packed-answers-20261012/judge-set --default-declaration SONNET_V4_DECLARATION --prompt-set v4 --cap 5 --authorization "..."
python3 scripts/gemini_judge.py run --output .build/exchange-packed-answers-20261012/gemini-judge --protocol PROTOCOL
python3 scripts/exchange_packed_answers.py score --output .build/exchange-packed-answers-20261012 --labels .build/exchange-packed-answers-20261012/gemini-judge/labels-jep-992880da336f623f.json
```

The BEAM run uses `scripts/beam_exchange_packed.py` with the commands `capture`, `count`, `declare`, `run`, `grade-declare`, `grade-run` and `score`. `capture`, `grade-declare` and `grade-run` take `--case` and `--supplement`, the OptChat normalized case and author reference files. `capture` also takes `--contexts`, OptChat's `beam-500K-05/boros-contexts`.

Locations:

- DATASET is the pinned `longmemeval_s_cleaned.json` under `.build/datasets/` of the main checkout.
- STEP3_OUTPUT is `framing-v4-variants-replay-20261009` in worktree `agent-a80d0b180c643f811`.
- READER_COMPARISON is `reader-comparison-20261010` in worktree `nervous-kapitsa-65f1d9`.
- PROTOCOL is the pinned upstream `evaluate_qa.py` under `.build/longmemeval-protocol-20261006/` of the main checkout.
- SONNET_V4_DECLARATION is `.build/judge-calibration/declarations/vertex-sonnet-v4-r3.json` in `nervous-kapitsa-65f1d9`.

Tests: `scripts/test_exchange_packed_answers.py` (6 synthetic contracts) and `scripts/test_beam_exchange_packed.py` (6) run in `check.py`.
