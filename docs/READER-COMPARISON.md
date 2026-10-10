# Reader comparison: Sonnet 5.5, Haiku 5.5 and Gemini 3.8 Flash against local Qwen

Status, October 10, 2026:

- **Measured:** the 94 V4 answer prompts of the step 3 cohorts ([FRAMING-V4-VARIANTS.md](FRAMING-V4-VARIANTS.md)), sent unchanged to three Vertex-hosted readers, three replicates each: 846 generations, no failure, no truncated answer, $14.72. Every answer was graded by the default judge, blinded and interleaved with the 163 local Qwen V4 answers to the same inputs from the step 3 replay and the V5 test: 1,009 items, three replicates, $3.58. Lexical measures as in the step 3 replay. A second judge, Gemini 3.8 Flash, then re-graded everything to check for self-preference ($3.10).
- **Result:** Sonnet 5.5 is the best reader here and the most repeatable at the verdict level. On the 72 questions with retrieval, its mean per-question accept rate is 67.1 percent against Qwen's 56.9 percent; it does better than Qwen on 11 questions and worse on 2 (two-sided sign test p = 0.022). Gemini 3.8 Flash matches Qwen overall (57.4 percent; 7 better, 8 worse). Haiku 5.5 is worse than Qwen (48.1 percent; 5 better, 14 worse, p = 0.064), mostly through false declines.
- **Self-preference check (second judge):** Gemini 3.8 Flash re-graded all 1,009 items with the default judge's prompts, after grading the 79 calibration items. On those 79 items it made 6 errors, against the default judge's 9. On Sonnet's own answers the two judges agree on 275 of 276, so Sonnet's grades show no self-preference. Gemini shows a small lean toward its own answers: it accepted 7 Gemini answers that Sonnet rejected, and Sonnet accepted none that Gemini rejected. Under Gemini the ranking is unchanged:
  - Sonnet 66.7 percent;
  - Gemini 60.6 percent;
  - Qwen 59.0 percent;
  - Haiku 48.6 percent.

  Sonnet's paired edge over Qwen is 10 better and 5 worse under Gemini (p = 0.30), so its lead of about 8 points is the same size under either judge but significant only under the default judge ([Second judge](#second-judge-self-preference-check)).
- **Not decided:** no default changes. A hosted default reader in the application needs the plan's egress and disclosure contracts first ([DESIGN-REPAIR-PLAN.md](DESIGN-REPAIR-PLAN.md#p5-reader-decision)). This is P5's upper-reference measurement on delivered packs, not A1 on sufficient packs.

This document contains no question, answer, reference, evidence or history text. It reports identifiers, counts and classes only.

## Why

The step 3 replay found that the local Qwen reader does not reproduce its own answers across runs: 17 of 69 V4 answers on identical inputs were byte-identical, and the decline status changed on 4 questions. The user asked, on October 10, 2026, to try `gemini-3.8-flash`, `claude-haiku-5-5` and `claude-sonnet-5-5` in the GCP project `llm-train-482420` and see how they do for what Boros needs.

## Method

### Inputs: the exact V4 prompts

The inputs are the answer request bodies the ordinary path assembles for the 94 V4 runs of the step 3 replay: retrieval-on-21, preference-27 and temporal-25 with `--retrieval-arm ordinary_send`, and recent-only-21. They were rebuilt offline, so no answer was generated locally and nothing in the application changed.

- **Capture.** `Tests/Evaluation/DeliveryHarness.swift` gains an optional `capture_directory` (select mode only). The coordinator still stops at the answering boundary, the GUI Stop path. The harness then reads the prepared answer work's request body from the attempt's store, which is the body the runner would dispatch unchanged, checks its SHA-256 against the preparation's request digest, and writes it privately (0600). The harness output records only the digest and size, plus the content-free label map and framing version. The control mode refuses a capture directory.
- **Checks against the step 3 run, all 94 passed** (`.build/reader-comparison-20261010/captures.json`, SHA-256 `dc3250e1…7013`):
  - the same runner input (recorded runner-input SHA-256);
  - the same delivered ranges as the step 3 declaration;
  - framing `context-source-snapshot-v4`;
  - the same citation-label map as the step 3 V4 report;
  - one distinct System message across all 94.
- **Prompt tokens.** Counted by the pinned Qwen tokenizer, they differ from the step 3 reports by -57 to +42 tokens, and by 0 on every recent-only input. As documented for the earlier replays, the spread comes from per-ingestion conversation IDs in excerpt headers, not from delivery.

### Readers and settings

| Reader | Route | Thinking | Output limit | Declared price (USD per million tokens, input / output) |
|---|---|---|---|---|
| `claude-sonnet-5-5` | `scripts/vertex_anthropic.py` | `between_tools` (off) | the step 3 cap: 512 for runner document 5, 1,024 otherwise | 2.00 / 10.00 (as declared for the default judge) |
| `claude-haiku-5-5` | `scripts/vertex_anthropic.py` (Haiku added, thinking `disabled` only) | `disabled` (off) | same | 0.10 / 0.50 (prompts of 100K tokens or fewer) |
| `gemini-3.8-flash` | `scripts/vertex_gemini.py` (new) | `thinkingLevel` "low", its lowest; thinking cannot be turned off | the cap plus a 2,048-token thinking allowance | 1.50 / 7.50 (list rate from third-party pages; a promotional 0.75 / 3.75 is also reported) |
| Qwen (baseline) | local mlx-serve, earlier runs | off | same | local |

- **What was sent.** Only the captured body's messages: the System message as the system instruction, then the remaining turns in order. No temperature, seed or Qwen template field was sent, because none of these models accepts a pinned temperature through these adapters. Repeatability is therefore measured with replicates.
- **Gemini thinking cannot be turned off.** On October 10, 2026, `thinkingLevel` "minimal" returned HTTP 400, and `thinkingBudget` 0 still produced thought tokens. Gemini used 1,773 thought tokens over 282 answers.
- **Counts.** The Claude count endpoint gave identical counts for Haiku and Sonnet: 1,366,239 input tokens per pass, against 1,103,404 for Gemini and about 1.09 million for Qwen.

### Declaration and run

- **Declaration.** Frozen before the first generation at `.build/reader-comparison-20261010/declaration.json` (private), SHA-256 `c01de851…225c`, from implementation commit `b7ac813`. It pins:
  - the captures and counts;
  - the readers, settings, prices and three replicates;
  - the dispatch order: replicate, then question, then the readers rotated per question;
  - six workers and the retry rule;
  - a $30 generation cap, against a worst case of $22.72;
  - the measures, and the absence of a decision rule.
- **Run.** 846 generations, all complete: 0 failures, 0 retries, 0 stopped at the output limit. Each request's worst case was reserved against the cap before dispatch.
- **Judging.** The default judge: Vertex `claude-sonnet-5-5`, declaration version 3, prompt set v3, verdict task only, three replicates, majority vote, ties unknown. It graded every hosted answer and the 163 Qwen V4 answers to the same inputs: 94 from the step 3 replay and 69 from the V5 test.
- **Split.** The 1,009 blinded items were split into two interleaved halves by seeded order, because calibration item IDs have three digits: set `jrc-9dc333e2b9fba209` with 505 items and set `jrc-c946307030c78f31` with 504.
- **Grading run.** 3,027 verdict requests, $1.78 and $1.80 (cap $4 each). One reply in the second half stopped at the output limit, and its item kept a two-replicate majority. No item ended unknown. The judge-set split was changed after generation and does not affect any answer.

## Results

54026fce is reported separately and excluded from every count, as in the step 3 replay. Qwen has two samples per question on retrieval-on-21, preference-27 and recent-only-21, and one on temporal-25. Each hosted reader has three samples everywhere.

### Judged accepts, mean per-question accept rate

Each question contributes the fraction of its samples the judge accepted, so readers with different sample counts are compared on the same questions.

| Questions | Sonnet 5.5 | Gemini 3.8 Flash | Qwen (local) | Haiku 5.5 |
|---|---:|---:|---:|---:|
| With retrieval (72) | **67.1%** | 57.4% | 56.9% | 48.1% |
| retrieval-on-21 (20) | **76.7%** | 75.0% | 70.0% | 63.3% |
| preference-27 (27) | **72.8%** | 45.7% | 55.6% | 39.5% |
| temporal-25 (25) | 53.3% | **56.0%** | 48.0% | 45.3% |
| recent-only-21 (20) | 15.0% | 15.0% | 15.0% | 15.0% |

Recent-only has no delivered gold. Every reader's accepts there are its declines on the 3 abstention questions. A decline on an answerable question is a reject under the verdict rule.

**Paired per question, against Qwen, on the 72 questions with retrieval:**

| Reader | Better | Worse | Tie | Two-sided sign test |
|---|---:|---:|---:|---|
| Sonnet 5.5 | 11 | 2 | 59 | p = 0.022 |
| Gemini 3.8 Flash | 7 | 8 | 57 | p = 1.0 |
| Haiku 5.5 | 5 | 14 | 53 | p = 0.064 |

Sonnet against Gemini is 12 better and 2 worse (p = 0.013). Sonnet against Haiku is 21 better and 1 worse (p < 0.001).

**By delivered gold, per answer, on the three retrieval cohorts:**

| Subset | Sonnet 5.5 | Gemini 3.8 Flash | Qwen (local) | Haiku 5.5 |
|---|---|---|---|---|
| Answerable, gold whole | **108 / 120 (90%)** | 98 / 120 (82%) | 53 / 66 (80%) | 88 / 120 (73%) |
| Answerable, gold partial | **18 / 33 (55%)** | 8 / 33 (24%) | 7 / 17 (41%) | 7 / 33 (21%) |
| Answerable, gold none | 10 / 54 (19%) | 9 / 54 (17%) | 4 / 30 (13%) | 3 / 54 (6%) |
| Abstention | 9 / 9 | 9 / 9 | 6 / 6 | 6 / 9 |

"Gold whole" is the closest this run comes to the reader's own quality: every annotated gold turn was delivered. Accepts with no gold delivered come from the recent context or from preference rubrics that general advice can satisfy. They are not evidence of retrieval.

### Repeatability

| Measure | Sonnet 5.5 | Gemini 3.8 Flash | Haiku 5.5 | Qwen (local) |
|---|---:|---:|---:|---:|
| Byte-identical across samples | 0 of 92 | 0 of 92 | 0 of 92 | 17 of 67 |
| Verdict unanimous over three samples | **89 of 92** | 85 of 92 | 82 of 92 | (two samples only) |
| Verdict agrees, first two samples, Qwen's 67 questions | **67 of 67** | 61 of 67 | 59 of 67 | 63 of 67 |
| Decline status agrees, first two samples, same 67 | 65 of 67 | 65 of 67 | 59 of 67 | 63 of 67 |
| Questions always accepted / sometimes / never (72 with retrieval) | 47 / 3 / 22 | 38 / 7 / 27 | 29 / 10 / 33 | |

No hosted reader repeats its wording, which is expected without a pinned temperature. The outcome is what matters for Boros. Sonnet's verdicts are the most stable: the same verdict on both of the first two samples for all 67 questions where Qwen has two runs, and unanimous over three samples on 89 of 92.

### Lexical measures (per answer, without 54026fce)

Declines use the step 3 decline measure: the phrase list plus the anchored source-decline extension, with partial declines counted. A "false decline" is a decline with every gold turn delivered.

| Cohort | Measure | Sonnet 5.5 | Gemini 3.8 Flash | Haiku 5.5 | Qwen (local) |
|---|---|---:|---:|---:|---:|
| retrieval-on-21 | false declines (gold whole) | 5 / 36 | 3 / 36 | 20 / 36 | 1 / 24 |
| preference-27 | false declines (gold whole) | 7 / 42 | 14 / 42 | 32 / 42 | 10 / 28 |
| temporal-25 | false declines (gold whole) | 12 / 42 | 3 / 42 | 16 / 42 | 0 / 14 |
| all four | AI or memory disclaimers | 0 | 0 | 1 | 2 |
| all four | self-contradiction (detector v1) | 4 | 5 | 2 | 10 |
| all four | copied headers, raw event IDs, unresolved labels, LaTeX | 0 | 0 | 0 | 0 |
| retrieval cohorts | answers citing a gold turn | 139 of 216 | 130 of 216 | 111 of 216 | 52 of 119 |
| all four | median words, preference-27 / temporal-25 | 219 / 92 | 216 / 47 | 155 / 85 | 187 / 74 |

- **Haiku's false declines explain its low score.** It declined most preference questions even when the gold was delivered.
- **Sonnet's temporal false declines (12) are lexical.** Its judged temporal rate (53.3%) is still above Qwen's (48.0%). Some of these answers give a result and also note a missing date, which the lexical measure counts as a partial decline.
- **Gemini declines least where gold is whole** on retrieval-on and temporal, and is shortest overall.

### Faithfulness without evidence

On recent-only-21 (no delivered gold), every reader declined all 3 abstention questions in every sample. Qwen declined all 17 answerable questions too. The hosted readers declined 16 of the 17 in every sample; all three answered 1a1907b4 in all three samples without delivered gold, and the judge rejected every one of those answers. Qwen declined it in both runs. For 54026fce (excluded above), Sonnet and Haiku answered with retrieval and were accepted in all three samples. Gemini answered and was rejected three times. Qwen V4 declined it in both runs, as in every earlier replay.

### Latency and cost

| Reader | Median seconds | p90 seconds | Cost per answer | This run |
|---|---:|---:|---:|---:|
| Haiku 5.5 | 1.53 | 2.72 | $0.0016 | $0.44 |
| Sonnet 5.5 | 2.38 | 5.20 | $0.032 | $8.98 |
| Gemini 3.8 Flash | 2.45 | 5.42 | $0.019 (at the declared list rate) | $5.30 |
| Qwen (local) | 10.98 | 17.39 | local | local |

- **Wall time** is per request with six concurrent workers, and includes the network round trip. Qwen's time is the recorded provider time of the earlier local runs.
- **Prompts** average about 14,500 tokens across all 94 inputs (Claude count), so input dominates cost.
- **Gemini's cost** would be about half at the reported promotional rate.

## Second judge: self-preference check

Requested by the user on October 10, 2026, after the first results.

- **Judge.** Vertex `gemini-3.8-flash` through `scripts/gemini_judge.py`. The request is the default judge's: prompt set v3, verdict task only, rendered by `judge_calibration.judge_messages` with the reply-format line, and parsed by `judge_calibration.parse_instructed_reply`. Three replicates, majority vote.
- **Settings.** Thinking level "low"; no sampling field; output limit 2,048 tokens, because thought tokens count against it.
- **Declaration.** Frozen before dispatch (`gemini-judge/declaration.json`, SHA-256 `805287b7…1465`), under a $12 cap. It records the sets with their item hashes, a digest of every rendered request, and the default judge's prompt hashes.
- **Run.** 3,264 requests (the 79 calibration items, then both halves). All parsed, with no failure. 160,237 thought tokens (about 49 per request). $3.10.
- **Registry.** `judge_calibration.CANDIDATE_JUDGES` gains `vertex-gemini`, so the existing `score` and `pool-scores` read its labels.

### Calibration on the 79 items (against the reference adjudication)

| Judge | Error | False reject | False accept |
|---|---|---|---|
| Gemini 3.8 Flash (prompt set v3) | 6/79 (7.6%, 3.5-15.6%) | 0/35 | 6/44 (13.6%, 6.4-26.7%) |
| Sonnet 5.5 (default judge, prompt set v3) | 9/79 (11.4%, 6.1-20.3%) | 3/35 | 6/44 |

- **Shared false accepts.** Five of Gemini's six are also Sonnet's: extension items 004, 008 and 009 (self-corrections) and 024 and 029 (judgment-call rejects). The sixth is base item-006; Sonnet's own sixth is base item-011.
- **No false rejects.** Gemini rejected nothing the reference accepts.
- **Intervals.** They overlap. Neither calibration set contains a Claude- or Gemini-authored answer.

### The reader comparison under both judges

**Mean per-question accept rate:**

| Questions | Judge | Sonnet 5.5 | Gemini 3.8 Flash | Qwen (local) | Haiku 5.5 |
|---|---|---:|---:|---:|---:|
| With retrieval (72) | Sonnet | 67.1% | 57.4% | 56.9% | 48.1% |
| With retrieval (72) | Gemini | 66.7% | 60.6% | 59.0% | 48.6% |
| preference-27 | Sonnet | 72.8% | 45.7% | 55.6% | 39.5% |
| preference-27 | Gemini | 71.6% | 54.3% | 55.6% | 42.0% |
| temporal-25 | Sonnet | 53.3% | 56.0% | 48.0% | 45.3% |
| temporal-25 | Gemini | 53.3% | 56.0% | 52.0% | 44.0% |
| retrieval-on-21 (20) | Sonnet | 76.7% | 75.0% | 70.0% | 63.3% |
| retrieval-on-21 (20) | Gemini | 76.7% | 75.0% | 72.5% | 63.3% |

**Answer-level agreement between the judges** (every sample, without 54026fce):

| Reader | Answers | Same verdict | Only Sonnet accepts | Only Gemini accepts |
|---|---:|---:|---:|---:|
| Sonnet 5.5 | 276 | 275 | 1 | 0 |
| Haiku 5.5 | 276 | 259 | 8 | 9 |
| Gemini 3.8 Flash | 276 | 269 | 0 | 7 |
| Qwen (local) | 159 | 155 | 1 | 3 |

**Paired against Qwen per question, 72 questions with retrieval:**

| Reader | Sonnet judge | Gemini judge |
|---|---|---|
| Sonnet 5.5 | 11 better, 2 worse (p = 0.022) | 10 better, 5 worse (p = 0.30) |
| Gemini 3.8 Flash | 7 better, 8 worse | 6 better, 6 worse |
| Haiku 5.5 | 5 better, 14 worse (p = 0.064) | 7 better, 17 worse (p = 0.064) |

**Reading:**

- **No sign that Sonnet favours Sonnet's answers.** The other family's judge accepts the same Sonnet answers in 275 of 276 cases. Haiku's disagreements split evenly (8 and 9).
- **Gemini is the more lenient judge, most of all on Gemini's own answers.** Its accepts that Sonnet withholds are 7 of 276 Gemini answers, against 3 of 159 Qwen answers, 9 of 276 Haiku answers and 0 of 276 Sonnet answers. Its calibration also shows no false rejects. The 7 are concentrated in preference questions: Gemini's preference score rises from 45.7 to 54.3 percent under its own judge. That is consistent with a small self-preference, or with leniency on the preference rubric's partial matches. At this size it cannot be separated from either.
- **Sonnet's advantage over Qwen is about 8 to 10 points under either judge.** Its statistical support depends on the judge, because Gemini accepts a few more Qwen answers. Treat the lead as likely, not established. The Qwen arm also has fewer samples (one on temporal-25), which adds noise.
- **Both judges could share a bias** toward fluent hosted answers, which this check cannot detect. The user's adjudication of a small blinded sample of hosted answers would.

## Measured and inferred

Measured:

- **Sonnet 5.5:** the highest judged accept rate on these prompts, with a paired advantage over Qwen (11 better, 2 worse), and the most stable verdicts.
- **Gemini 3.8 Flash:** equal to Qwen overall. It is better on temporal questions and worse on preference questions, where it declines more.
- **Haiku 5.5:** worse than Qwen, because it declines far more often with the evidence delivered.
- **Wording:** no hosted reader repeats it byte for byte.
- **Hosted versus local:** all three hosted readers answered faster than local Qwen and produced no presentation defect beyond one Haiku disclaimer.

Inferred, not measured:

- **Self-preference does not explain Sonnet's grades.** Before the second judge, this was the main open question. The Gemini judge agrees on 275 of 276 Sonnet answers, and Sonnet's lower lexical false-decline rate on preference questions needs no judge (7 of 42 against Qwen's 10 of 28). Gemini's small lean toward its own answers is described under [Second judge](#second-judge-self-preference-check).
- **Retrieval, not the reader, limits the end-to-end score.** With gold whole, Sonnet is accepted 90 percent of the time. With gold none, every reader is mostly, and correctly, declining. Raising A2 still depends on P2.
- **The comparison uses V4, which was tuned against Qwen.** Fix G's decline wording was written for Qwen. Hosted readers may do better with a framing tuned for them, Haiku especially, but that was not tested.

## Reproduce

Commands, from this checkout (private outputs under `.build/reader-comparison-20261010/`):

```bash
/Users/johnshahbazian/.venv-vllm-metal/bin/python3 scripts/reader_comparison.py capture --output .build/reader-comparison-20261010 --dataset DATASET --reference STEP3_OUTPUT
python3 scripts/reader_comparison.py count --output .build/reader-comparison-20261010
python3 scripts/reader_comparison.py declare --output .build/reader-comparison-20261010
python3 scripts/reader_comparison.py run --output .build/reader-comparison-20261010
python3 scripts/reader_comparison.py measure --output .build/reader-comparison-20261010 --dataset DATASET --qwen-run STEP3_OUTPUT --qwen-run V5_OUTPUT
python3 scripts/reader_comparison.py judge-set --output .build/reader-comparison-20261010 --dataset DATASET --qwen-run STEP3_OUTPUT --qwen-run V5_OUTPUT
```

The two judge halves run with `scripts/judge_calibration_run.py` and their declarations under `judge-declarations/`, and then `reader_comparison.py score` with `--labels` for half a, then half b.

- **Capture interpreter.** `capture` needs an interpreter with `tokenizers`, for the stand-in.
- **Locations.** The step 3 and V5 outputs are in the agent worktrees `agent-a80d0b180c643f811` and `agent-aa05a0dd01171d721`.
- **Tests.** `scripts/test_reader_comparison.py` (11 synthetic contracts, including the Gemini judge) and the extended `scripts/test_vertex_anthropic.py` (16) run in `check.py`.

## Possible next steps

- **Check shared judge bias.** The user adjudicates a small blinded sample of hosted answers, especially those the two judges split on: 17 Haiku answers, 7 Gemini answers and 1 Sonnet answer.
- **Measure A1 on sufficient packs.** P5's actual gate: Sonnet, Gemini and Qwen on the sufficient packs, three replicates.
- **Design hosted-reader contracts.** If a hosted reader is wanted in the application, the egress and disclosure contracts come first. Routing private history to Vertex is a product decision, not an evaluation setting.
