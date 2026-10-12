# Reader choice on the exchange_packed default

Record date: October 12, 2026. The user asked "ok run sonnet vs gemini on the new default". This record compares two hosted readers, Vertex Sonnet 5.5 and Vertex Gemini 3.8 Flash. Both read the exact `exchange_packed` requests that ordinary Send now assembles ([previous record](EXCHANGE-PACKED-ANSWERS.md)). This is a measurement for the reader decision (P5). No default changed, and the application still answers with the selected local model. A hosted default reader needs the egress and disclosure contracts AGENTS.md requires.

## Summary

- **Step 3 retrieval questions, 72 (measured).** Mean per-question accept rate:
  - Under the default judge: Sonnet 78.7 percent against Gemini 69.0. D = +9.7 points, 95 percent paired bootstrap interval +2.8 to +17.1. Sonnet was better on 14 questions and worse on 2 (sign test p = 0.004).
  - Under Sonnet as second judge: 76.4 against 66.2, D = +10.2, interval +2.8 to +18.1, 15 better and 4 worse (p = 0.019).
  - The rule declared before generation gives **Sonnet preferred**.
- **The advantage comes from preference questions (measured).**
  - preference-27: +28.4 points under the default judge (12 better, 0 worse) and +32.1 under the second judge.
  - retrieval-on-21: -5.0, one question worse.
  - temporal-25: +1.3 and -1.3 under the two judges.
  - On factual and temporal questions the two readers are level.
- **BEAM, 20 questions (measured).**
  - Gemini answered 10, 10 and 9 correctly per replicate. Sonnet answered 8, 9 and 9 under the Gemini grader, and 8, 8 and 8 under the Sonnet grader.
  - Sonnet was worse on two questions (one temporal, one instruction following) and better on none.
  - D = -5.0 points (interval -13.3 to 0.0) under the Gemini grader and -8.3 (interval -21.7 to 0.0) under the Sonnet grader.
  - The Sonnet grader passed OptChat's calibration rule: 14 of 14 positives and 20 of 20 negatives. The Gemini grader again missed it by one positive.
- **Cost and latency (measured, step 3 answers).**
  - Sonnet: $0.039 per answer at its list price, 3.0 s median, 246 output tokens median.
  - Gemini: $0.025 per answer at the standard rate ($0.012 billed at the introductory price through 2026), 3.2 s median, 113 output tokens median.
  - At current billing, Sonnet costs about three times as much per answer.
- **Run cost.** $16.71 at the declared rates:
  - $11.07 for 279 Sonnet answers;
  - $1.44 for the default judge;
  - $1.85 for the Sonnet judge;
  - $2.35 for both BEAM graders.

## Method

`scripts/reader_choice.py`, declaration `.build/reader-choice-20261012/declaration.json` (SHA-256 `d31b5c0c…2258`), frozen before any Sonnet call.

### Inputs (reused, verified)

- The 73 step 3 `exchange_packed` request bodies captured for the previous record.
- The 20 BEAM `exchange_packed` bodies.
- Gemini's three replicates for each. These were generated earlier the same day and are verified against their ledger digests.

### Sonnet answers

- **Generation.** 279 answers: 73 inputs and 20 BEAM questions, three replicates each.
- **Settings.**
  - The reader comparison's Sonnet settings: thinking `between_tools` (off), no sampling field.
  - Output limit: the step 3 limit per input, and 2,048 for BEAM.
- **Outcome.**
  - No failures and no retries stopped.
  - Two step 3 answers reached the output limit and keep their text as incomplete results.
  - Sonnet counts the median step 3 prompt at 18,077 tokens, where Gemini counts 15,618 for the same bytes.

### Judging (step 3)

- **Blinded set.** One blinded set, `jrx-c6101521a20da209`, holds all 438 answers of both readers in a seeded order. It has 0 identifier substitutions and 0 items naming a model.
- **Default judge.** Gemini through `gemini_judge.py`, prompt set v4, three replicates and a majority vote. 1,314 requests completed with 0 parse failures and 0 unknown votes.
- **Second judge.** Gemini is also a contestant, so the same v4 verdict request (`gemini_judge.messages_for`) was also sent to Sonnet: thinking `between_tools`, 512 output tokens, three replicates. 1,314 requests completed with 0 off-format replies.
- **Limits of the second judge.** It was sent through this driver rather than `judge_calibration_run.py`, with no count before generation and six workers. Its v4 calibration on 79 items (October 9, error 8/79) is that of the same request.

### Grading (BEAM)

- **Request and controls.** OptChat's `beam-native-grader-1` request and its 34 calibration controls, as ported in [the previous record](EXCHANGE-PACKED-ANSWERS.md), on both graders.
- **Graders.**
  - Gemini: thinking low, 2,432 output tokens.
  - Sonnet: thinking `between_tools`, 384 output tokens.
- **Off-contract replies.** Three replicates across both graders returned a grounding score although no evidence was supplied (`UNEXPECTED_GROUNDING_SCORE`). One Sonnet-graded answer had no majority, and it is counted as not correct.

### Declared rule

- **Sonnet preferred.** D is at least +5 with a lower bound above 0 under the default judge, and D is above 0 under the second judge.
- **Gemini preferred.** The mirror image of the Sonnet rule.
- **Otherwise.** No measured difference, so cost, latency and egress terms decide.
- **BEAM.** BEAM is reported beside the decision and does not decide it.

## Results

### Step 3, by cohort and judge

Mean per-question accept rate (Gemini / Sonnet), D in points, better / worse for Sonnet:

| Questions | Default judge (Gemini) | D | Second judge (Sonnet) | D |
|---|---|---:|---|---:|
| All 72 | 69.0 / 78.7 | +9.7 (14 / 2) | 66.2 / 76.4 | +10.2 (15 / 4) |
| retrieval-on-21 (20) | 90.0 / 85.0 | -5.0 (0 / 1) | 90.0 / 85.0 | -5.0 (0 / 1) |
| preference-27 | 56.8 / 85.2 | +28.4 (12 / 0) | 49.4 / 81.5 | +32.1 (14 / 1) |
| temporal-25 | 65.3 / 66.7 | +1.3 (2 / 1) | 65.3 / 64.0 | -1.3 (1 / 2) |

By `exchange_packed` gold delivery, default judge:

| Delivery | Questions | Gemini | Sonnet | D |
|---|---:|---:|---:|---:|
| Every gold turn whole | 52 | 80.8% | 91.0% | +10.3 (+0.6 to +19.9) |
| Some gold | 9 | 40.7% | 59.3% | +18.5 |
| No gold | 8 | 12.5% | 12.5% | 0 |
| No gold turns (abstention) | 3 | 100% | 100% | 0 |

- **Excluded question.** `54026fce` was accepted three of three times for both readers under the default judge. Under the second judge, Sonnet was accepted two of three times and Gemini none.
- **Declines.** The step 3 lexical measure counts 50 for Sonnet and 47 for Gemini, of 219 answers each.

### BEAM

| Grader | Calibration | Gemini correct per replicate | Sonnet correct per replicate | D (Sonnet - Gemini) |
|---|---|---|---|---:|
| Gemini | 13/14 positives, 20/20 negatives (not accepted) | 10, 10, 9 | 8, 9, 9 | -5.0 |
| Sonnet | 14/14, 20/20 (accepted) | 10, 10, 9 | 8, 8, 8 | -8.3 |

- **Where they differ.** The two readers differ on two questions only: temporal `470fe812` and instruction following `9cd27fcb`. Gemini was ahead on both.
- **Grader variation.** Gemini's own BEAM answers scored 10, 10 and 9 here, against 9, 10 and 9 in the previous record. Same answers, a fresh run of the same grader. That is grader variation of one answer.

## Interpretation (inferred)

- **What the step 3 preference means.** The preference questions ask for advice that should draw on what the user said earlier. The gold is the user's stated preference, and the rubric rewards using it. Sonnet's large gain there, with level results on factual and temporal recall, says Sonnet is the better reader at applying remembered context to an open request, not at finding facts. Both judges agree, and neither reader's own family judge reverses it.
- **BEAM leans the other way on two questions.** With 20 questions and intervals ending at zero, this is not a contradiction of the step 3 result. It is a reminder that the step 3 advantage is concentrated in one question type. BEAM has two preference questions, and both readers got both right.
- **Cost.** Sonnet costs about three times as much per answer at current billing and writes longer answers. Its latency is the same.
- **What this does not measure.**
  - Local Qwen on the new default.
  - A framing tuned for either hosted reader; V4 was written against Qwen.
  - Anything about remote processing of private history, which the application does not do.

## Decision

The declared rule's outcome is **Sonnet preferred** as the reader for the `exchange_packed` default. Using any hosted reader in the application is a separate decision for the user. It needs its own egress and disclosure contracts before it can be enabled. Nothing in the application changed.

## Privacy and reproduce

- **Private outputs.** Requests, answers, items, labels, grades and replies are in `.build/reader-choice-20261012/` (0700 directories, 0600 files) in worktree `exciting-agnesi-172906`. This record has no question, answer or reference text.
- **Commands.** `scripts/reader_choice.py` runs `count`, `declare` and `run`, then `judge-set`. Next come `gemini_judge.py declare --prompt-set v4` and `gemini_judge.py run`, then `second-judge`. After that, `beam-grade-declare` and `beam-grade-run --grader` for each grader, and finally `score --labels`.
- **Inputs.** The source directories are those of [the previous record](EXCHANGE-PACKED-ANSWERS.md#reproduce).
- **Tests.** `scripts/test_reader_choice.py` (4 synthetic contracts) runs in `check.py`.
