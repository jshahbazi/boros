# Four-arm paired run: roles+feedback retrieval, the combined presentation and the conflicts sentence

Record date: October 13, 2026. The coordinator's follow-up to the [accuracy batch](STATUS.md#1-current-position): one paired, judged run on the 73 step 3 inputs with a fresh budget of $25 at declared standard rates, three candidates against the current default, the same reader, judge and promotion rule as the [presentation probes](PRESENTATION-PROBES.md). Each section states whether it reports implemented behavior, measured results, inferences or decisions.

## Arms (implemented)

| Arm | What it is | Where it comes from |
|---|---|---|
| `exchange_packed` (baseline) | The ordinary Send default: `exchange_packed` retrieval under the V4-advice framing | Fresh harness capture of the 73 inputs at this checkout (`.build/retrieval-roles-20261013`); delivery and gold class reproduce the October 12 capture on 73 of 73 |
| `exchange_roles_prf` | The combined retrieval variant of [RETRIEVAL-VARIANTS.md](RETRIEVAL-VARIANTS.md): role-weighted scoring with feedback expansion, V4-advice framing | The same capture; carried into the run unchanged |
| `exchange_packed_combined` | The `chronology` presentation applied to the baseline bodies, then the `one-block` fold: one delimited evidence message whose historical excerpts are oldest first, relabelled, with the relative-time header lines, and both System changes | `exchange_packed_answers.py transform --presentation combined` |
| `exchange_packed_conflicts` | The baseline bodies plus one System sentence: report conflicting quoted sources, state each version with its label, ask which is correct, and do not describe a change no source states | `transform --presentation conflicts` |

Retrieval is identical for the baseline and the two presentation arms (52 whole, 9 partial, 8 none, 3 no gold turns of the 72); `exchange_roles_prf` delivers every gold turn whole on 58 of 73 against 53. The unchanged-request rule found no request to reuse (every candidate differs from the baseline on every input), so all 876 jobs were generated.

## Declared before generation (measured)

`.build/four-arm-20261013/declaration.json` (SHA-256 `aa774746…3438`): captures SHA-256 recorded; 876 jobs (73 inputs, four arms, three replicates, arm order rotating by question and replicate); the reader settings of the earlier records (Gemini 3.8 Flash, thinking level low, the step 3 output limit plus a 2,048-token thinking allowance, no sampling field); the worst-case bound of $41 as the driver's cap with an operational stop before judging at $22.5 of generation spend; the default verdict judge (prompt set v4, three replicates, majority vote, one blinded set holding every answer of the four arms); and the rule: the question is the unit (72 without `54026fce`); for each candidate D is its mean per-question accept rate minus the baseline's with a 10,000-resample paired bootstrap interval and a sign test; **promote** a candidate when D is at least +5 points, the interval's lower bound is at least -2 and no cohort's D is below -5; otherwise no change.

Token counts (free): median Gemini count 15,658 (baseline), 15,662 (`exchange_roles_prf`), 16,200 (`combined`), 15,708 (`conflicts`).

## Result (measured)

- **Generation.** 876 of 876 answers completed, no failure, no incomplete result, no retry stop; $21.94 at the declared standard rate (the introductory price billed through 2026 is half).
- **Judging.** Blinded set `jep-11c7df373c88ef75` (876 items, items SHA-256 `80ba0275…20ea`), 0 identifier substitutions, 2 items naming a model (the blinding check passed). 2,628 judge requests completed with 0 failures and 0 unknown votes; $2.92. Judge declaration SHA-256 `73b0b6ed…4569`.
- **Run total.** $24.86 at the declared standard rate, within the $25 the coordinator allowed for this run.
- **Baseline consistency.** The same V4-advice requests (fresh capture, identical delivery) measured 78.7 percent here, 76.4 in the morning's presentation-probe run and 79.2 on October 12. That spread is the reader's and judge's run-to-run variation, which is why every candidate is compared paired within this run.

Mean per-question accept rate, D in points, paired 95 percent bootstrap interval, questions better / worse / tied:

| Questions | Baseline | `exchange_roles_prf` | D | Interval | B / W / T | `combined` | D | Interval | B / W / T | `conflicts` | D | Interval | B / W / T |
|---|---:|---:|---:|---|---|---:|---:|---|---|---:|---:|---|---|
| All 72 | 78.7% | 77.8% | -0.9 | -8.3 to +6.0 | 5 / 6 / 61 | 76.9% | -1.9 | -6.5 to +2.8 | 2 / 4 / 66 | 75.5% | -3.2 | -7.9 to +0.9 | 2 / 6 / 64 |
| retrieval-on-21 (20) | 90.0% | 85.0% | -5.0 | -25.0 to +10.0 | 1 / 2 / 17 | 90.0% | 0.0 | 0.0 to 0.0 | 0 / 0 / 20 | 86.7% | -3.3 | -10.0 to 0.0 | 0 / 1 / 19 |
| preference-27 | 80.2% | 81.5% | +1.2 | -8.6 to +12.3 | 3 / 3 / 21 | 76.5% | -3.7 | -12.3 to +4.9 | 1 / 3 / 23 | 76.5% | -3.7 | -12.3 to +4.9 | 2 / 4 / 21 |
| temporal-25 | 68.0% | 68.0% | 0.0 | -12.0 to +12.0 | 1 / 1 / 23 | 66.7% | -1.3 | -12.0 to +8.0 | 1 / 1 / 23 | 65.3% | -2.7 | -8.0 to 0.0 | 0 / 1 / 24 |

Sign tests: 1.0, 0.69 and 0.29. The excluded `54026fce` was accepted three of three times under every arm.

`exchange_roles_prf` by change in gold delivery against the baseline:

| Delivery change | Questions | Baseline | `exchange_roles_prf` | D |
|---|---:|---:|---:|---:|
| Newly whole | 5 | 26.7% | 66.7% | +40.0 |
| Unchanged class, different context | 66 | 81.8% | 79.3% | -2.5 |
| Partial to none | 1 | 100% | 0% | -100 |

Declines (the step 3 lexical measure, 219 answers per arm; "false" means every gold turn delivered on an answerable question): baseline 45 declines, 17 false; `exchange_roles_prf` 39 and 15; `combined` 39 and 12; `conflicts` 43 and 17. Verdicts accepted: 173, 171, 169 and 166 of 219.

### What each candidate did (measured, then inferred)

- **`exchange_roles_prf`: the recovered gold converts, the re-ranked context costs about as much.** The five questions whose gold became whole rose from 26.7 to 66.7 percent accepted (three of them from 0 to 3 of 3: `0edc2aef`, `00ca467f`, `9a707b82`), the same mechanism the October 12 record measured. But the 66 questions whose gold class did not change lost 2.5 points, and the one question whose partial delivery became none lost all three replicates. Net, the arm is level with the default (-0.9 points, six worse against five better). On the development cohort the same arm gains net five cases of R2; on these 72 questions the delivery gain is five questions, and its conversion is offset by the different surrounding evidence on the rest.
- **`combined`: the two separately positive probes are not positive together.** The morning's separate runs measured chronology at +3.7 and one block at +3.2 (each against its own fresh baseline); combined, -1.9 with two better and four worse, all with gold delivered whole. The three preference losses and the temporal loss (`0bc8ad93`, which the morning's chronology arm also lost) are the kind of question where ordering the user's statements oldest first puts the latest statement last. False declines with gold whole fell again (17 to 12), as one block did in the morning, but that did not become accepted answers here.
- **`conflicts`: the guard fires.** The sentence costs 3.2 points on the 72 questions, none of which has a genuine contradiction: six questions lose replicates (four preference, one factual, one temporal, five of them with gold whole), consistent with the reader hedging between two sources that do not conflict or declining to choose. Whether it helps on real contradictions is the BEAM probe's question, which was not run.

Inference across the three runs of the day: the step 3 cohorts are at a level where single changes move the mean by a few points at most, inside the run-to-run spread of the baseline itself (76.4 to 79.2). The declared rule's +5 threshold is doing its job; the per-question flips are small sets of the same questions moving in both directions.

## Decision

Under the rule declared before generation, **no candidate is promoted**: every D is below zero. `currentSelectedQwen` remains `exchange_packed`, the default framing remains V4-advice, and the application is unchanged. The three candidates stay selectable: the retrieval arm as an explicit policy and harness arm, the two presentations as transforms in the evaluation driver.

What this run establishes (inferred): the roles+feedback ranking recovers gold on five more step 3 questions and that recovery converts to accepted answers, but it changes the packed context on every other question and those move by about as much the other way; a version that keeps the baseline's packing where the gold delivery does not change would isolate the gain, which the harness can measure offline before any further spend. Neither presentation change is worth promoting on this evidence, and the conflicts sentence should not be applied to ordinary questions without a conflict detector in front of it.

## The BEAM conflicts probe (measured)

The coordinator asked, if practical, for the conflicts sentence on the 10 contradiction questions of the other agent's 100-question BEAM cohort (`beam-cohort-20261013` in worktree `agent-ab324e6f37c8d1b84`, read-only). `scripts/beam_conflicts_probe.py` is that adapter: it derives the conflicts bodies from the cohort's captured V4-advice requests, counts tokens, freezes 30 answer jobs and 90 grades (the cohort's ported `beam-native-grader-1` request on Gemini, majority of three) and scores before/after against the cohort run's recorded `ordinary_send` rate, which is 0 of 10 on every replicate under that grader. Its declaration (`.build/beam-conflicts-20261013/declaration.json`, SHA-256 `259acfcd…5779`) froze a $4 worst-case cap (answers $1.69, grades $2.18; about $1.3 expected). The coordinator then funded it separately (up to $4). Measured: 30 of 30 answers and 90 of 90 grades completed with no failure; $0.79 for the answers and $0.14 for the grades at the declared standard rate ($0.93 in all). Per question, correct replicates of three under the conflicts sentence, beside the cohort run's `ordinary_send` rate (0 of 3 on every question):

| Gold delivery under `exchange_packed` | Questions | Conflicts sentence: 3 of 3 / 1 of 3 / 0 of 3 |
|---|---:|---|
| Whole (both conflicting statements delivered) | 6 | 3 / 2 / 1 |
| Partial | 3 | 2 / 0 / 1 |
| None | 1 | 0 / 0 / 1 |

Mean per-question correct rate 56.7 percent against 0.0 (7 questions better, none worse; 17 of 30 replicates correct). Of the six questions with both statements delivered, three are now correct on every replicate, two on one replicate and one on none (the question whose morning answers chose a single state). The question with no gold delivered stays at zero, as it must. These are before/after figures on one grader whose calibration the cohort run reported as not accepted (78 of 80 positives), with the baseline answers taken from that run rather than regenerated here.

Inference: the sentence does what it was written for when a real contradiction is in the quoted sources, and it costs 3.2 points on ordinary questions where none is. **Nothing is promoted from this probe** (the coordinator's instruction): applying it by default would need a conflict detector in front of it, so that the sentence is present only when two quoted sources state incompatible facts about the asked-for item. That detector is the proposed next step; the lexical shape of the contradiction questions (two user statements, one negated) suggests a cheap test on the delivered evidence, measured offline on these 10 questions and the 72 before any further spend.

## Privacy and artifacts

Requests, answers, raw responses, judge items, labels and the score are under `.build/four-arm-20261013/` of this worktree (0700 directories, 0600 files); the BEAM probe's declaration and derived bodies under `.build/beam-conflicts-20261013/`. This record contains no question, answer, reference or conversation text.

## Reproduce

```bash
python3 scripts/exchange_packed_answers.py capture --output CAP --dataset DATASET --reference STEP3_OUTPUT --baseline-captures EXCHANGE_PACKED_RECORD/captures.json --baseline-arm exchange_packed --candidate-arm exchange_roles exchange_roles_prf --promote-minimum-points 5
python3 scripts/exchange_packed_answers.py transform --output OUT --source-output CAP --source-arm exchange_packed --presentation combined conflicts --baseline-arm exchange_packed --candidate-arm exchange_roles_prf exchange_packed_combined exchange_packed_conflicts --promote-minimum-points 5
python3 scripts/exchange_packed_answers.py count|declare|run|judge-set|score --output OUT --baseline-arm exchange_packed --candidate-arm exchange_roles_prf exchange_packed_combined exchange_packed_conflicts --promote-minimum-points 5 ...
python3 scripts/gemini_judge.py declare|run ...   # as in PRESENTATION-PROBES.md
python3 scripts/beam_conflicts_probe.py declare --output BEAM_OUT --cohort BEAM_COHORT --baseline-score BEAM_COHORT/grades-gemini-3.8-flash/score.json --cap-usd 4 --authorization "..."
```

DATASET, STEP3_OUTPUT and EXCHANGE_PACKED_RECORD are those of the [exchange_packed record](EXCHANGE-PACKED-ANSWERS.md#reproduce).
