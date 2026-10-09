# Framing V5: scoped insufficient-evidence wording

Status, October 9, 2026:

- **Implemented:** `context-source-snapshot-v5` (V5) and the evaluation-only ablation `context-source-snapshot-v4-no-g`. Both are selectable with `--answer-evaluation --context-framing`. **V4 stays the default.**
- **Measured:** one pre-declared, paired replay of V4 (default), V5 and the ablation, run on three cohorts: the 21-question retrieval-on cohort (ordinary Send's lexical retrieval), a fresh 27-question preference cohort, and the 21-question recent-only cohort. It used 207 local generations, and the default judge gave verdicts on all 207 answers (621 Vertex requests, $0.851556).
- **Decision (pre-declared rule): do not adopt V5. V4 stays the default.** V5 removed every decline on the preference questions with gold delivered whole (V4 4 of 14, V5 0 of 14), and the judge accepted all 14. But V5 failed three of the five criteria. It declined one fewer abstention question (2 of 3 against 3 of 3) and one fewer recent-only question (19 of 20 against 20 of 20). It also had two fewer judge accepts on the gold-whole regression set (9 of 12 against 11 of 12).
- **G against A (ablation):** removing G removed V4's preference false declines too (0 of 14). It also removed most recent-only declines (5 of 20) and brought back AI or memory disclaimers (2 in recent-only, 1 in the preference cohort). The preference false declines come from G, not from the quoted presentation (fix A).

This document contains no question, answer, reference, evidence or history text. It reports identifiers, counts and classes only.

## Implementation

### What changed

V5 is V4 with the second fix G sentence replaced. That sentence is the scoped rewording proposed in [the 54026fce diagnosis](ANSWER-PRESENTATION-DEFECTS.md#proposed-mitigation-not-implemented). The first G sentence ("If the quoted sources contain the answer, answer directly.") is kept. The replacement says:

- check every quoted source, including the historical excerpts, before saying that something is not shown;
- for advice or suggestions, tailor the reply to user details found in any quoted source and cite their labels;
- say that the quoted sources do not show something only when the request needs a specific fact from the user's past that no quoted source states;
- in that case, mention partially relevant information, do not guess, and do not say that you are an AI or that you lack memory or access.

The decline wording names "the quoted sources", not "the conversation history provided here". The diagnosis also offered an excerpt-block scope header as an alternative presentation change. It is **not** added: the System text is the only difference from V4, so the replay measures the rewording alone.

The ablation `context-source-snapshot-v4-no-g` is V4 without both G sentences, including the no-disclaimer clause. Comparing it with V4 separates fix G from fix A (the quoted presentation of the recent conversation).

### Contracts

- **Only the System text differs.** `ContextSourceFraming.quotedSelectionVersions` holds V4, V5 and the ablation. All three use V4's recent prefixes, historical headers and footers, citation labels, label map, reductions and journal validation. `ContextAssembler.historyFraming(selectionVersion:)` returns a separate literal for each. `RecentSourceFramingChecks` derives V5 and the ablation from the V4 literal by exact string replacement. The V4 literal's SHA-256 is pinned (`d3a316dd…d1b4`, the bytes measured since `85c5117`). The checks also verify, on a live selection, that every non-System message is byte-identical to V4's, with and without a historical excerpt. Recent IDs, excerpt IDs, the citation label map and assignments are equal too. `scripts/test_framing_v5_replay.py` repeats the derivation from the Swift source text.
- **The version binds the System bytes.** Because the three versions differ only in the System framing, `ContextSnapshot.componentAssignments` and `ContextComponentJournal` validation now require, for the V4 family, that the System message carries exactly the journaled version's framing. Without this, a V4 binding relabelled as V5 would have validated at the snapshot level. Each version has its own mandatory-message binding and selection digest, and a V4 binding paired with a V5 or ablation body is refused in both directions.
- **The ablation is evaluation-only.** `ContextSourceFraming.permits` refuses an evaluation-only framing unless `GenerationSettings.evaluationOnlyFramingPermitted` is set. `AnswerAttemptCoordinator.accept` checks this before any request is stored. Only the answer-evaluation command sets the flag, and only for an explicitly pinned evaluation-only `--context-framing`. Synthetic checks cover the cases:
  - a coordinator with the ablation and default settings is refused at acceptance, and nothing is stored;
  - the CLI accepts V5 and the ablation and grants the permission only for the pinned ablation;
  - invalid framing values are refused, and so is the ablation with `--investigate-memory`.
  A source scan in `test_framing_v5_replay.py` checks two more things. Only `AnswerEvaluationCommand.swift` (and synthetic fixtures) grants the permission. `BonsaiPlayground.swift` neither sets `contextFraming` nor references the permission or the ablation.
- **The default is unchanged.** `ContextSourceFraming.defaultSelectionVersion` and `GenerationSettings().contextFraming` remain V4, and checks assert both.
- **End to end.** `ComponentPreparationChecks` runs its quoted pipeline fixture under V5 and under the ablation as well. Each goes through admission, the original-input proof, journal validation, archive and restore. The journal corruption suite also runs for V5.
- **Runner document version 9.** The fresh preference cohort uses runner document version 9, with the version-8 opaque-identity shape: opaque project, conversation, event and probe IDs, one `hybrid` attempt, original session dates and the question date. The ordinary path answers it (never the native investigation), and it accepts only 27 separately pinned projections (`AnswerEvaluationCommand.preferenceLongMemoryCorpusProjectionSHA256`). Decode checks cover acceptance, refusal by the investigation mode, cross-version pin separation and refusal of paired, recent-only or reconfigured documents.

`scripts/check.py` passed 4,815 checks before the replay, including 95 framing checks (13 new), 965 component-preparation checks and 9 new synthetic driver contracts.

## Declaration

Frozen at 16:43 UTC, before the first generation, at `.build/framing-v5-replay-20261009/declaration.json` (private, 0600), SHA-256 `677ccfcc…2092`. One declaration covers all three cohorts, arms, question lists, the gold-delivery table, settings, caps, the judge plan and the decision rule.

- **Authorization.** The user authorized this in chat on October 9, 2026: implement V5 and run the test plan, with up to 207 local generations ((21 + 27 + 21) x 3 arms) and default-judge verdicts under a $2.00 cap.
- **Binary.** All arms ran the same binary, SHA-256 `357a5d26…dfad`, built from the implementation commit `3e56ca2`. The declaration records the checkout `19a4243`, which is the merge of `main` at `b2fa534` and changes no `Sources/` file.
- **Arms.**
  - `v4-default`: no `--context-framing` flag, so the binary's default.
  - `v5`: `--context-framing context-source-snapshot-v5`.
  - `v4-no-g`: `--context-framing context-source-snapshot-v4-no-g`.

  Run order: cohorts as listed below; within each cohort, questions in order and the arms V4, V5, ablation for each question. Measurement verified that every report and selection records the declared framing (207 of 207).
- **Cohorts.**
  - **`retrieval-on-21`**: the 21 questions of the earlier replays, with the recorded hybrid attempt run with `--retrieval-arm ordinary_send`. This is lexical selection, what ordinary Send ships. The 7 pilot questions use the natural-v5 runner input (document 5, 512 output tokens). The 14 independent questions use independent-v1 (document 7, 1,024 output tokens). All 21 inputs were rebuilt and matched their recorded runner-input SHA-256.
  - **`preference-27`**: every other `single-session-preference` question of the pinned dataset. That is 30 in all, minus 54026fce, 06878be2 and 1a1907b4. Selection reads question identity and type only, and the order is a SHA-256 rank. The questions are 1d4e3b97, 35a27287, 505af2f5, 0a34ad58, 32260d93, 57f827a0, 1c0ddc50, a89d7624, b6025781, d6233ab6, 6b7dfb22, 75832dbd, b0479f84, 1da05512, 75f70248, 8a2466db, afdc33df, d24813b1, caf03d32, 06f04340, 09d032c9, 95228167, 07b6f563, 0edc2aef, 38146c39, 195a1a1b and fca70973. They are built like the existing development-cohort documents: the pinned QA projector, then the version-8 opaque identity projection (plan P4 step 4) under its own domain. Runner document version 9 has one hybrid attempt, run with `--retrieval-arm ordinary_send`, and 1,024 output tokens. All 27 have annotated gold turns; none is an abstention question. Four (0edc2aef, 1c0ddc50, 6b7dfb22, 75832dbd) were used in early runs, which does not matter for this test.
  - **`recent-only-21`**: the recent-only attempt of the same 21 questions.
- **Gold delivery, computed offline before any generation** (`framing_v5_replay.py gold`, table SHA-256 `36fe9846…cbc9`). The retrieval harness's delivery binary was compiled from this checkout and given a loopback tokenizer stand-in, so no answer was generated. It ran the declared arm on each runner input: `ordinary_send` for the two retrieval cohorts and `recent_only` for the third. The annotated gold turns were scored with `gold_delivery` (`retrieval_harness.coverage`).

  | Cohort | Whole | Partial | None | No gold turns (abstention) |
  |---|---:|---:|---:|---:|
  | retrieval-on-21 | 13 (12 without 54026fce) | 1 (08f4fc43) | 4 (06878be2, 1a1907b4, 1b9b7252, 4baee567) | 3 |
  | preference-27 | 14 | 5 (35a27287, 0a34ad58, 1c0ddc50, afdc33df, 07b6f563) | 8 (32260d93, d6233ab6, 6b7dfb22, d24813b1, 06f04340, 09d032c9, 95228167, 0edc2aef) | 0 |
  | recent-only-21 | 0 | 0 | 18 | 3 |

  Under ordinary Send, 51c32626 is whole (it was partial on the hybrid arm). 06878be2 is none (partial on hybrid). The preference questions with gold whole are the other 14 of preference-27; retrieval-on-21 contributes none besides the excluded 54026fce. **Every one of the 207 runs delivered exactly the declared ranges** (identical range digest), so the declared and measured gold classes agree throughout.
- **Model and settings.** These match the earlier replays: model `ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit` (listed by the live server), temperature 0, thinking off, seed 104202601, the frozen 32,768 context limit with 256 safety tokens, and the frozen output caps (512 for document 5, 1,024 for documents 7 and 9).
- **Limit and retry rule.** Generation limit 207. A run that never started an answer invocation could be retried twice without counting.
- **Decline measure.** The detector `answer_presentation_defects.py` (`answer-presentation-defects-v2`) is used with its plain-decline phrase list, extended by one anchored pattern. The pattern matches a source noun followed by "do not show / contain / mention / state ...", or "no / none of the quoted sources ...". It was added so that V5's "the quoted sources do not ..." wording could not escape the list. A phrase within the first 200 characters is a `decline`; one only later is a `partial_decline`. Both count as declines. The extension changed no outcome: the measure with and without it agrees on all 207 answers.
- **Judge plan.** Default judge: Vertex `claude-sonnet-5-5`, `llm-train-482420`, `global`, declaration version 3, prompts `boros-judge-calibration-prompts-v3`, verdict task only, three replicates, majority vote, ties `unknown`. The spending cap is $2.00, with at most 640 generation and 414 count requests, which leaves room for one resume. The output cap is **64 tokens per request** instead of the template's 512. The runner reserves counted input plus the output cap for every request against the cap. At 512, 621 requests would reserve about $3.7 and the run would be refused under $2.00. Prompt, reply format, model and replicate count are unchanged; these are what define the judge. All 621 replies ended with `end_turn` at a mean of 11.5 output tokens, so the lower cap truncated nothing.
- **Decision rule (verbatim in the declaration).** It compares V5 with V4. 54026fce is reported separately and excluded from every count. A decline is a lexical `decline` or `partial_decline`. Gold classes are the declared offline ones.
  - **R1:** on preference questions (both retrieval cohorts) with gold delivered whole, V5 declines fewer than V4. A tie fails, and so does V4 having 0 declines.
  - **R2:** on the 3 abstention questions of retrieval-on-21, V5 declines at least as often as V4.
  - **R3:** on recent-only-21 without 54026fce (20 answers), V5 declines at least as often as V4.
  - **R4:** V5 has 0 AI or memory disclaimers.
  - **R5:** on the answerable gold-whole questions of retrieval-on-21, V5 gets at least as many default-judge accepts as V4. `unknown` is not an accept.

  Adopt V5 only if all five hold. A subset with a missing answer counts as not holding. The ablation is reported, not decided.

## Run

- **Generations.** 207 answer generations, 16:43 to 17:27 UTC, local server only. No retry was needed: 0 runs failed before an answer invocation and 0 failed after it. One answer stopped at its output cap (ablation, recent-only 06878be2, `incomplete_result`).
- **Delivery and arms.** 207 of 207 runs had the declared framing and retrieval arm. Every runner report for the two retrieval cohorts recorded `ordinary_send` with semantic retrieval `disabled_by_policy` and a validated lexical receipt. All runs delivered the declared ranges. Prompt sizes relative to V4 were +11 to +95 tokens for V5 and -15 to -115 tokens for the ablation. The spread comes from the per-ingestion conversation IDs in excerpt headers, not from delivery.
- **Judge.** One standalone empty-body access probe returned HTTP 400 (reachable), and the runner's own probe was also `reachable`. Then 202 count requests and 621 verdict generations ran in one session: all parsed, all bare JSON, 0 thinking tokens. Set `jr-6d3b1c7ae4df92e6` (items SHA-256 `bdd4a045…3749`, 0 identifier substitutions). Judge declaration SHA-256 `e709d109…9723`, labels SHA-256 `aaf783c5…358e`. **Cost: $0.851556 observed** (390,078 input and 7,140 output tokens) and $1.178838 reserved, under the $2.00 cap. 206 of 207 items were unanimous; 1 split 2 to 1, and none was `unknown`.
- **Checks.** `scripts/check.py` passed 4,815 checks before the first generation and again after the run.

## Results

Lexical measures are string checks on the answer, not a judge. Declines are split by the declared gold class:

- **false:** answerable, gold whole;
- **justified:** answerable, no gold delivered;
- **partial gold:** answerable, some gold delivered;
- **abstention:** an abstention question.

Header is a copied V3 or V4 host header at the start of the answer. Raw IDs are answers with benchmark event IDs. Labels are cited `[E n]` labels, with unresolved ones in parentheses. "Cites gold" counts answers citing a label that maps to an annotated gold turn. All counts leave out 54026fce.

### retrieval-on-21 (ordinary Send, 20 questions without 54026fce)

| Arm | Declines | False | Justified | Partial gold | Abstention | Disclaimers | Header | Raw IDs | Labels (unresolved) | Cites gold | Median words |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|
| V4 | 7 | 0 | 3 | 1 | 3 of 3 | 0 | 0 | 0 | 36 (0) | 12 | 65 |
| V5 | 5 | 0 | 2 | 1 | 2 of 3 | 0 | 0 | 0 | 38 (0) | 13 | 55 |
| V4 no G | 4 | 1 (51c32626) | 2 | 1 | 0 of 3 | 0 | 0 | 0 | 32 (0) | 13 | 59 |

Default-judge accepts:

| Arm | Gold whole (12) | Gold not whole (5) | Abstention (3) | All (20) |
|---|---:|---:|---:|---:|
| V4 | 11 | 0 | 3 | 14 |
| V5 | 9 | 1 | 2 | 12 |
| V4 no G | 11 | 1 | 1 | 13 |

The verdict changes against V4:

- **V5 lost three:** 00ca467f and 51c32626 (gold whole, answered under both arms, rejected under V5), and f685340e_abs (an abstention question V5 answered instead of declining).
- **V5 gained one:** 1a1907b4 (preference, no gold).
- **The ablation:** it gained gpt4_70e84552 and 1a1907b4. It lost 51c32626 (declined although gold was whole), 031748ae_abs and f685340e_abs (abstentions answered).

### preference-27 (ordinary Send, fresh cohort)

| Arm | Declines | False (of 14 gold whole) | Justified (of 8) | Partial gold (of 5) | Disclaimers | Labels (unresolved) | Cites gold | Median words |
|---|---:|---:|---:|---:|---:|---|---:|---:|
| V4 | 11 | 4 (57f827a0, 75832dbd, 75f70248, 38146c39) | 5 | 2 | 1 (32260d93) | 112 (0) | 6 | 187 |
| V5 | 1 | 0 | 1 (0edc2aef) | 0 | 0 | 185 (0) | 14 | 270 |
| V4 no G | 0 | 0 | 0 | 0 | 1 (35a27287) | 90 (0) | 6 | 309 |

Default-judge accepts:

| Arm | Gold whole (14) | Gold not whole (13) | All (27) |
|---|---:|---:|---:|
| V4 | 12 | 4 | 16 |
| V5 | **14** | 7 | **21** |
| V4 no G | 11 | 5 | 16 |

No arm had a copied header, raw event IDs or LaTeX in this cohort. Against V4, V5 gained five accepts (57f827a0, 1c0ddc50, afdc33df, d24813b1 and 38146c39) and lost none. Two of V4's false declines were still accepted by the judge (75832dbd and 75f70248): a decline sentence followed by an answer, the shape the 54026fce diagnosis described. The only split vote of the run was V5 on d24813b1 (accept 2 to 1).

### recent-only-21 (20 questions without 54026fce; no gold delivered)

| Arm | Declines | Answerable (17) | Abstention (3) | Disclaimers | Labels | Judge accepts |
|---|---:|---:|---:|---:|---:|---:|
| V4 | 20 | 17 | 3 | 0 | 0 | 3 (the 3 abstentions) |
| V5 | 19 (18 + 1 partial) | 16 | 3 | 0 | 15 | 3 (the 3 abstentions) |
| V4 no G | 5 | 4 | 1 | 2 (0e5e2d1a, 1192316e) | 2 | 4 (the 3 abstentions and 1b9b7252) |

V5's one recent-only answer without a decline phrase was 1a1907b4, a preference question with nothing delivered; the judge rejected it. Its partial decline was 06878be2, also a preference question. Under V5, 4 recent-only declines cited labels, all of them recent sources from the unrelated current conversation (14 labels). The answered 1a1907b4 cited 1 more.

### 54026fce (reported separately, excluded from the decision)

| Cohort | V4 | V5 | V4 no G |
|---|---|---|---|
| retrieval-on-21 (gold whole) | decline, 0 labels, reject | answer, 8 labels, **accept** | answer, 0 labels, reject (2 to 1) |
| recent-only-21 (no gold) | decline, reject | decline, reject | decline, reject |

Under ordinary Send, V4 reproduced the false decline seen on the hybrid arm. V5 answered it with labels and was accepted. None of V5's labels points to the annotated gold turn, though it does not need to: the diagnosis found that same-session excerpts carry the rubric's context too.

## Decision rule outcome

| Criterion | V4 | V5 | Holds |
|---|---:|---:|---|
| R1: declines on preference questions with gold whole (14) | 4 | 0 | yes |
| R2: declines on retrieval-on abstention questions (3) | 3 | 2 | **no** |
| R3: declines on recent-only, without 54026fce (20) | 20 | 19 | **no** |
| R4: V5 AI or memory disclaimers (67 answers) | | 0 | yes |
| R5: judge accepts on retrieval-on answerable gold whole (12) | 11 | 9 | **no** |

**Outcome: V5 is not adopted. V4 stays the default.** The rule was fixed before the first generation, and three of its criteria fail. Each failure is a difference of one or two questions at temperature 0 with a single sample. The rule required no loss, so these small differences decide.

## G against A (the ablation)

Measured, V4 against V4 without G on the same delivery:

- **G causes the preference false declines.** Without G, preference questions with gold whole had 0 declines of 14 (V4: 4). The whole preference cohort had 0 declines of 27 (V4: 11). Fix A, the quoted presentation, is present in both arms, so it does not produce these declines.
- **Removing G does not by itself fix the preference answers.** The ablation's judge accepts on the preference cohort equal V4's (16 of 27). They are lower on gold whole (11 against 12). Its answers cited no more labels than V4's (90 against 112). V5 got 21 of 27 with more cited labels (185) and more answers citing a gold turn (14 against 6). On this cohort the scoped wording adds something beyond dropping the decline instruction.
- **G produces the recent-only declines and suppresses disclaimers.** Without G, recent-only declines fell from 20 to 5 and abstention declines from 3 to 1. Two AI or memory disclaimers came back: 1192316e, one of the three original disclaimer questions, and 0e5e2d1a. A third appeared in the preference cohort. Judge accepts barely moved (4 against 3), because the recent-only cohort has no gold evidence to answer from.
- **Without G, abstention handling degrades with retrieval on.** The ablation declined 0 of 3 retrieval-on abstention questions, and the judge accepted 1 of 3 (V4: 3 of 3).

## Measured and inferred

Measured: the counts above, from one generation per question and arm at temperature 0 with fixed inputs, and verdicts from the default judge. Its calibrated rates on the 50-item adjudication are error 2/50, 4% (1-13%); false reject 1/30, 3% (1-17%); and false accept 1/20, 5% (1-24%).

Inferred, not measured:

- **The V5 regressions are small and may not be systematic.** The three failing criteria rest on four questions: f685340e_abs, 1a1907b4 (recent-only), 00ca467f and 51c32626. At temperature 0 a one-word System change can flip an answer on any question. This replay cannot separate a systematic V5 effect on factual questions from that kind of perturbation. The preference gain (5 more accepts, 0 lost) is larger, but it also comes from single samples.
- **The preference result supports the diagnosis's mechanism.** The diagnosis said G's sufficiency test is ill-posed for advice requests and that the decline names the wrong scope. Removing or rescoping G removed those declines, and V5's answers used the historical excerpts more often. The judge's reference-only verdict on preference rubrics is the weakest part of its calibration: the one borderline preference item was rejected by Sonnet and accepted by the adjudication.
- **A follow-up could be scoped further.** The data suggest a narrower change: keep V4's G for factual requests and add only V5's advice clause. That would be a new framing version with a new pre-declared test, not a reading of this one.
- **Lexical only.** Declines are measured lexically. V5 changed how declines are phrased, but the extended pattern found no decline that the original phrase list missed.

## Reproduction

```sh
python3 scripts/framing_v5_replay.py gold --output <new .build directory> --dataset <pinned longmemeval_s_cleaned.json>
python3 scripts/framing_v5_replay.py declare --output <new .build directory> --dataset <dataset> --binary <Boros binary> --gold <gold dir>/gold-delivery.json
python3 scripts/framing_v5_replay.py run --output <run dir> --binary <same binary>
python3 scripts/framing_v5_replay.py measure --output <run dir> --dataset <dataset>
python3 scripts/framing_v5_replay.py judge-set --output <run dir> --dataset <dataset>
# fill vertex-sonnet.v3.template.json from the declaration's judge plan, check-declaration, dry run, then:
python3 scripts/judge_calibration_run.py --set <run dir>/judge-set --declaration <filled> --output <run dir>/judge-run-vertex-sonnet-v3 --protocol <evaluate_qa.py> --execute
python3 scripts/framing_v5_replay.py judge-summary --output <run dir> --dataset <dataset> --labels <labels path>
```

Private outputs: `.build/framing-v5-gold/` and `.build/framing-v5-replay-20261009/` in worktree `agent-aa05a0dd01171d721`. They hold the declaration, inputs, ledger, native reports and answers, `measure.json`, the judge set, declaration, run and labels, and `judge-summary.json`. `measure` and `judge-summary` print identifiers, classes and counts only.
