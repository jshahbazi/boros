# Evidence allowance: the exchange_wide policy

Record date: October 12, 2026. This is R5 of the [context diagnostic response](reviews/CONTEXT-DIAGNOSTIC-RESPONSE-20261012.md): a larger evidence allowance for the `exchange_packed` selection, measured offline first and then on answer quality with the same inputs, reader and judge as the [exchange_packed record](EXCHANGE-PACKED-ANSWERS.md). Each section states whether it reports implemented behavior, measured results, inferences or decisions.

## Why this lever (inferred from the October 12 records)

Under the `exchange_packed` default with the Gemini 3.8 Flash reader, the 72 step 3 retrieval questions lose about 22 question-equivalents of accept rate (69.0 percent). From the per-question outputs of that run:

- 17 questions whose gold turns were delivered partly or not at all account for about 12 of them (preference-27: 4 none and 3 partial, 5 lost; temporal-25: 3 none and 4 partial, 6 lost; retrieval-on-21: 2 partial, 1 lost).
- 52 questions with every gold turn delivered account for about 10, of which 6.7 are preference questions (14 of their 60 answers are lexical declines, the rest are answers the judge rejected).

The retrieval misses are the larger bucket, and the P1 harness measures them at no model cost. The development receipts of the October 12 index run (`p2-index-development.json`) show why they happen under `exchange_packed`: the estimated evidence tokens sit at 11,600 to 12,000 of the 12,000 cap in every attempt, and the delivery audit at 15,000 to 21,600 bytes of its roughly 22,000-byte budget. Of the 28 missed development turns, 12 are candidates skipped by the token budget (`T`, block ranks 4 to 31) and 16 are outside the 32-block window, often with 50 to 150 matched blocks below it. Thirty of the 73 step 3 inputs are in that cohort; their misses have the same shape (`6e984302`, `gpt4_ec93e27f`, `9a707b82` and `gpt4_f420262c` are `T` at ranks 4 to 26; `gpt4_4929293b`, `gpt4_d6585ce8`, `gpt4_7f6b06db` and `95228167` are below the window).

Both constraints are declared parameters, and prompts sit at a median of 15,600 tokens against the 29,696-token allowance.

## Implemented

One new, explicitly versioned component policy, `ContextComponentPolicy.selectedQwenExchangeWide` (`Sources/Boros/EpisodeBudget.swift`), harness arm `exchange_wide`, retrieval audit mode `exchange_wide`. It is the `exchange_packed` query, ranking, neighbor definition, value-density packer, single-span reduction and `context-exchange-v1` selection audit, with four parameters changed:

| Parameter | `exchange_packed` | `exchange_wide` | Where |
|---|---:|---:|---|
| Evidence token cap (`evidenceTokens`) | 12,000 | 16,000 | policy |
| Evidence span cap (`evidenceSpans`) | 48 | 64 | policy |
| Candidate window (`candidateBlockDepth`) | 32 | 48 | derived from the policy; `ExchangeValuePacking` reads it |
| Delivery audit limit (`deliveryAuditBytes`) | 32,768 | 40,960 | derived from the policy; carried on the snapshot |

Why each:

- **Token cap.** The binding constraint in every development attempt. 16,000 keeps the whole prompt under the 29,696-token allowance (prompt minus evidence was at most about 6,500 tokens on the step 3 inputs).
- **Audit limit.** Each delivered span costs about 800 bytes of the content-free delivery audit, so the 32 KiB audit binds at about 27 spans and would have taken the gain back. The limit now follows the policy: `ContextSnapshot.deliveryAuditLimit` (default 32,768) is set by `ContextAssembler.addEvidence` from the frozen policy and carried through every reduction. The audit travels base64-encoded inside the admission receipt, which the store caps at 64 KiB (`MemoryStore.beginInvocation`), so 40 KiB is the largest round value that fits with the receipt's own fields; the episode checks measure that overhead on the real path and assert the fit.
- **Window.** With more budget the packer reaches blocks ranked beyond 32. Packing is by value per cost, so deeper blocks are admitted last.
- **Spans.** 64 so the span cap does not bind before the token cap.

Two contracts changed to let the policy's caps apply end to end:

- `ProviderComponentProof.accepts` and `ProviderAdmission.admit` bounded the component receipts by the v1 constants 8,000 and 12,000 regardless of the frozen policy. They now bound them by the policy's `recentTokens` and `evidenceTokens`, which the proof already records and the journal validator already checks. The constants remain as the v1 values their own checks use. Before this change, a wide episode packed 16,000 tokens and then lost spans to `envelope` reductions at admission (94 envelope removals across the 14 regression histories, and one lost regression case).
- `ExchangeBlockQuery.retrievalMode` and the packer's audit name the policy (`exchange_wide`); the harness reads the declared `candidate_block_depth` from each audit instead of assuming 32.

Two lead-priority variants were added after the first offline result (below) showed that the larger budget was spent on replies and neighbors of higher-ranked blocks rather than on the leads the annotations name: `selectedQwenExchangeLeads` (`exchange_leads`, the `exchange_packed` caps and window) and `selectedQwenExchangeWideLeads` (`exchange_wide_leads`, the wide caps and window). Under either, a lead phase precedes the density pass: candidate leads are admitted in value-per-cost order while their total stays within a declared share of the token budget (`leadShare`, 0.5). A lead outside that share keeps its receipt open and competes in the density pass like every other unit. The audit records `lead_priority` and `lead_share`. Pass 1 (quoted-anchor members) and the dependency rule (a reply or neighbor needs its lead) are unchanged.

A strict form (every lead before any reply or neighbor, no share) was measured first on the regression cohort and discarded: it lost both assistant-recall cases, whose gold is the top block's reply, because 40 leads filled the token budget (`1b9b7252`) or the audit budget (`4baee567`) before that reply was considered (`evidence-allowance-regression-3.json`, R2 9 of 12 at either budget).

Nothing else changed. v1/16, the step 1 and 2 policies and `exchange_packed` keep their declared parameters, which the packer checks pin (`exchange_packed_parameters_are_declared`). The evaluation command's `--component-policy` option is unchanged.

### Contracts

- `--retrieval-strategy-self-test` (`ExchangeBlockQueryChecks.swift`): the wide policy is versioned, distinct, round-trips, refuses a forged cap, declares its window and audit limit, fits the 64 KiB receipt after base64 with 8 KiB of headroom; the entry point records mode `exchange_wide`, depth 48, budget 16,000, 64 spans and a 40,960-byte limit on the snapshot and on its counted reduction, while `exchange_packed` snapshots keep 32,768.
- `--retrieval-strategy-integration-test` (`ExchangeEpisodeChecks.swift`): the wide policy joins the per-policy journal suite. Under the synthetic tokenizer (5,000 tokens per source) its counted reductions end at 3 spans (16,000 / 5,000) with a receipt per removal; the snapshot carries the policy's audit limit; the admission receipt's measured overhead plus the base64 audit at the policy's limit fits the store's 64 KiB; the journal and archive validators accept the episode.
- `scripts/test_retrieval_harness.py`: the packed R1 scorer reads the declared depth (32 or 48) and refuses an undeclared one; `exchange_wide` follows `exchange_packed` in the arm list.
- `scripts/test_exchange_packed_answers.py`: the driver's `--baseline-arm`, `--candidate-arm` and `--promote-minimum-points` options drive the declared rule and are restored.

## Measured, offline (P1 harness)

Conditions: this checkout's sources compiled into the delivery harness, pinned offline tokenizer, three workers, one replicate, stores built cold by this harness. Reports are under `.build/evaluation/` of this worktree (`evidence-allowance-regression-2.json`, `evidence-allowance-development.json`).

### Regression cohort (12 answerable of 14)

| Arm | R1 | R2 | Turns whole | Prompt tokens p50 / max | Spans p50 / max | Envelope removals | Audit bytes max |
|---|---:|---:|---:|---:|---:|---:|---:|
| `exchange_packed` | 12 | 11 | 17 / 18 | 15,170 / 16,939 | 24 / 27 | 0 | 30,602 |
| `exchange_wide` | 12 | 11 | 17 / 18 | 18,558 / 20,631 | 31.5 / 37 | 0 | 37,846 |

No case changed in either direction. The one known miss, `1a1907b4` (the next neighbor of the rank-17 block, a long assistant turn), is still skipped by the token budget (`T`) under both arms. The `ordinary_send` arm still equals `exchange_packed` on 14 of 14 histories.

Before the admission fix, the same run measured `exchange_wide` at R2 10 of 12: the proof bounded evidence receipts at 12,000 regardless of the policy, admission refused the 16,000-token component, and 94 `envelope` removals across the 14 histories took the lowest-ranked spans back out, losing `1192316e` (first report, `evidence-allowance-regression.json`).

### Development cohort (90 answerable of 100), budget alone

| Arm | R1 | R2 | Turns whole / 165 | Prompt tokens p50 / max | Spans p50 / max | Audit bytes max |
|---|---:|---:|---:|---:|---:|---:|
| `exchange_packed` | 78 (86.7%) | 69 (76.7%) | 137 | 15,535 / 18,289 | 24 / 27 | 31,806 |
| `exchange_wide` | 82 (91.1%) | 70 (77.8%) | 139 | 18,992 / 22,027 | 30.5 / 35 | 39,732 |

One case changed, `73d42213` (multi-session; its rank-18 lead, `T` under `exchange_packed`, is delivered), and none was lost. By category R2 is identical except multi-session 11 to 12. No envelope or counted token removal occurred under either arm; the delivery audit never exceeded its limit.

The budget is not the lever. Where the 26 turns `exchange_wide` still misses sit:

| Where | Turns |
|---|---:|
| Not a candidate (outside the 48-block window, or in no matched block) | 12 |
| Candidate lead, token budget (`T`), block ranks 19 to 33 | 10 |
| Candidate lead, audit byte budget (`A`), rank 38 | 1 |
| Candidate neighbor whose lead was not delivered (`L`), ranks 35 and 38 | 2 |
| Candidate next neighbor, token budget (`T`), rank 4 | 1 |

With 4,000 more tokens the packer delivered about seven more spans per history, but they were replies and neighbors of higher-ranked blocks, which value per cost prefers over the leads of lower-ranked blocks. The annotated turns are leads in 11 of the 14 candidate misses. That is why the lead-priority variants were added.

### Development and regression cohorts, lead share

Second development run (`evidence-allowance-development-2.json`, warm stores, same binary sources plus the lead-share packer) and the fourth regression run (`evidence-allowance-regression-4.json`):

| Arm | Development R1 / R2 / turns | Regression R1 / R2 / turns |
|---|---|---|
| `exchange_packed` | 78 / 69 / 137 | 12 / 11 / 17 |
| `exchange_leads` | 78 / 69 / 137 | 12 / 11 / 17 |
| `exchange_wide` | 82 / 70 / 139 | 12 / 11 / 17 |
| `exchange_wide_leads` | 82 / 70 / 139 | 12 / 11 / 17 |

The lead share changed no delivery on either cohort: each lead arm reproduces its density counterpart case for case, and the same ten gold leads at ranks 19 to 33 keep their `T` receipts. The half-budget lead phase is filled by the leads of the blocks ranked above them, which in these histories are long user turns of one to three pages. Delivering the ten missed leads would cost roughly their own size each, more than the whole evidence cap, in addition to the top blocks. On these cohorts the remaining misses are therefore ranking misses, not packing misses: the gold block scores too low among 50 to 180 matched blocks for any affordable budget to reach it.

### Step 3 inputs (73), budget alone

The offline capture for the answer-quality run (`scripts/exchange_packed_answers.py capture`, both arms, no generation) delivered every gold turn whole on 53 of the 73 inputs under `exchange_packed` (reproducing the October 12 captures on 73 of 73) and on 54 under `exchange_wide`: only `00ca467f` changed. Median prompt 15,358 tokens against 18,921 (maximum 22,034). One recovered question of 17 non-whole is not worth a paid answer run, so none was dispatched for this arm.

## Decision on the retrieval variants

No answer run was dispatched for `exchange_wide`, `exchange_leads` or `exchange_wide_leads`. The offline gate the repair plan puts before answer spending was the right one here: a policy that changes delivery on one input of 73 cannot move a 72-question accept rate by more than about a point, and the earlier record already measured that unchanged delivery under a longer prompt does not change accuracy (-0.6 points on 54 questions). All three stay explicit, selectable policies; `currentSelectedQwen` remains `exchange_packed`.

What this rules out (inferred): on the LongMemEval cohorts, the remaining retrieval misses are not fixed by budget, window or packing order. They sit in ranking (the gold block among the 50 to 180 blocks that share a question term, scored too low to be packed) or beyond the 48-block window (12 of 26 development misses, below the window or in no matched block; the receipts do not say which). The repair plan's P2 step 4 already found that fusing the shipped semantic index into the v1 selector recovered none of these; a re-ranker over the exchange blocks is the untested path.

## Measured, answer quality: V4 against V4-advice on the same requests

With the retrieval lever closed, the budget went to the next-largest bucket from the October 12 per-question outputs: preference questions answered wrongly with every gold turn delivered (20 questions, 40 of 60 answers accepted, 14 of the 60 lexical declines). The [V4-advice framing](FRAMING-V4-VARIANTS.md) adds one sentence to V4's System framing that tells the model to tailor advice to the user's details in the quoted sources and cite them. It had been measured only lexically, with the local model, and never judged.

### Method (measured)

- **Inputs.** The 73 `exchange_packed` request bodies captured above (V4 framing). `scripts/exchange_packed_answers.py transform` derived the candidate arm `exchange_packed_v4_advice` by replacing the V4 System framing (pinned literal, SHA-256 `d3a316dd…d1b4`) with the V4-advice literal (`2944b44c…f74c`), both read from `ContextAssembler.swift` as the variants' own test reads them. Every other message, the delivery and the gold class are the source arm's; the candidate's bodies are re-serialized by the driver (messages identical). Median Gemini count: 15,598 tokens against 15,626.
- **Declared before generation** (`.build/v4-advice-answers-20261012/declaration.json`, SHA-256 `aced892b…65b05`): 438 jobs (73 inputs, two arms, three replicates, arm order alternating), Gemini 3.8 Flash with the earlier record's settings, a $30 cap at the standard rate (worst case $20.08), and the rule: the question is the unit (72 without `54026fce`), D is the candidate's mean per-question accept rate minus the baseline's with a 10,000-resample paired bootstrap interval; **recommend V4-advice over V4 for this reader when D is at least +5 points, the interval's lower bound is at least -2 and no cohort's D is below -5**; otherwise no change.
- **Judge.** The default verdict judge (`gemini_judge.py`, prompt set v4, three replicates, majority vote) on one blinded set holding both arms.

### Result (measured)

- **Generation.** 438 of 438 answers completed, no failure, no incomplete result, no retry stop; $10.83 at the declared standard rate (`ledger.jsonl`).
- **Judging.** Blinded set `jep-f6e3bd65162d2122` (items SHA-256 `b2b099d8…e990`), 0 identifier substitutions, 1 item naming a model (the blinding check passed). 1,314 judge requests completed with 0 parse failures, 0 invalid responses and 0 unknown votes; $1.42.

Mean per-question accept rate, D in points, paired 95 percent bootstrap interval, questions better / worse / tied:

| Questions | V4 (`exchange_packed`) | V4-advice | D | Interval | Better / worse / tie | Sign test p |
|---|---:|---:|---:|---|---|---:|
| All 72 | 72.7% | 79.2% | +6.5 | +2.3 to +11.6 | 8 / 0 / 64 | 0.0078 |
| retrieval-on-21 (20) | 90.0% | 90.0% | 0.0 | 0.0 to 0.0 | 0 / 0 / 20 | 1.0 |
| preference-27 | 65.4% | 82.7% | +17.3 | +6.2 to +29.6 | 8 / 0 / 19 | 0.0078 |
| temporal-25 | 66.7% | 66.7% | 0.0 | 0.0 to 0.0 | 0 / 0 / 25 | 1.0 |

- The eight questions that improved are all preference questions; seven had every gold turn delivered (`0edc2aef`, `195a1a1b`, `35a27287`, `38146c39`, `6b7dfb22`, `75832dbd`, `a89d7624`) and one had none (`09d032c9`). No question got worse under either cohort or by gold class.
- Declines (the step 3 lexical measure, 219 answers per arm): 54 under V4, 41 under V4-advice; declines with every gold turn delivered 20 and 15. On preference questions with every gold turn delivered, 13 of 60 answers declined under V4 and 6 of 60 under V4-advice; the three abstention questions kept all 9 declines under both; temporal questions gained two declines (4 to 6 of 54) without a verdict change.
- The excluded `54026fce` was accepted three of three times under both arms.
- **Consistency.** This run's V4 arm measured 72.7 percent where the October 12 record measured the same requests at 69.0 with the same reader and judge, fresh generations both times. That 3.7-point gap is the reader's and judge's run-to-run variation, which is why the comparison is paired within one run.
- **Cost.** $12.25 at the declared standard rate for this comparison; the whole evidence-allowance work spent nothing else on model calls.

### Interpretation (inferred)

The sentence does what it names. It removes most of Gemini's declines on advice requests whose supporting preference is quoted, and the judge accepts the resulting tailored answers; it does not touch factual or temporal questions, where V4 and V4-advice are tied question for question. The two added temporal declines did not change a verdict and are inside the decline measure's run-to-run noise (4 questions in the V4 replays). This is a reader-presentation effect measured with Gemini; the local Qwen reader was measured on V4-advice only lexically (October 9, neutral), not judged.

## Decision

The declared rule's outcome is **promote**: D is +6.5 with a lower bound of +2.3 and no cohort below 0. By the coordinator's mandate (measure a fix before and after on the same inputs and keep it if it helps), **V4-advice is the default framing** from this commit: `ContextSourceFraming.defaultSelectionVersion` is `adviceSelectionVersion`, `GenerationSettings().contextFraming` follows it, and V4, V5 and V4-ordered stay selectable with `--context-framing`. The retrieval policies measured above stay explicit and are not defaults.

What this does not establish: the effect under the local Qwen reader (lexically neutral on October 9, unjudged), the effect on BEAM, and whether the two added temporal declines recur.

## Privacy and artifacts

Requests, answers, raw responses, judge items, labels and reports are private, under `.build/` of this worktree with 0700 directories and 0600 files: `.build/evidence-allowance-answers-20261012/` (the two retrieval arms' captures and request bodies, no answers), `.build/v4-advice-answers-20261012/` (captures, declaration, ledger, answers, judge set, judge declaration, replies and labels, score) and `.build/evaluation/evidence-allowance-*.json` (the metadata-only harness reports). This record contains no question, answer, reference or conversation text.

## Reproduce

```bash
/Users/johnshahbazian/.venv-vllm-metal/bin/python3 scripts/retrieval_harness.py --cohort regression --workers 3 --output .build/evaluation/evidence-allowance-regression.json
/Users/johnshahbazian/.venv-vllm-metal/bin/python3 scripts/retrieval_harness.py --cohort development --workers 3 --output .build/evaluation/evidence-allowance-development.json
python3 scripts/exchange_packed_answers.py capture --output OUT --dataset DATASET --reference STEP3_OUTPUT --baseline-captures EXCHANGE_PACKED_RECORD/captures.json --baseline-arm exchange_packed --candidate-arm exchange_wide --promote-minimum-points 5
python3 scripts/exchange_packed_answers.py transform --output OUT2 --source-output OUT --source-arm exchange_packed --framing v4-advice --baseline-arm exchange_packed --candidate-arm exchange_packed_v4_advice --promote-minimum-points 5
python3 scripts/exchange_packed_answers.py count|declare|run|judge-set|score --output OUT2 --baseline-arm exchange_packed --candidate-arm exchange_packed_v4_advice --promote-minimum-points 5 ...
python3 scripts/gemini_judge.py declare --output OUT2/gemini-judge --protocol PROTOCOL --set OUT2/judge-set --default-declaration SONNET_V4_DECLARATION --prompt-set v4 --cap 5 --authorization "..."
python3 scripts/gemini_judge.py run --output OUT2/gemini-judge --protocol PROTOCOL
```

The locations of DATASET, STEP3_OUTPUT, PROTOCOL and SONNET_V4_DECLARATION are those of the [exchange_packed record](EXCHANGE-PACKED-ANSWERS.md#reproduce); EXCHANGE_PACKED_RECORD is that record's output directory. A `capture` run from this commit produces V4-advice bodies, since the default framing changed; the V4 bodies this record used were captured before the switch. Tests: `scripts/test_exchange_packed_answers.py` (8 contracts) and `scripts/test_retrieval_harness.py` (15) run in `check.py`.

## Decision

To be recorded.
