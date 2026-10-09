# Framing V4 variants: V4-advice and V4-ordered

Status, October 9, 2026:

- **Implemented:** `context-source-snapshot-v4-advice` (V4-advice) and `context-source-snapshot-v4-ordered` (V4-ordered). Both are selectable only with `--answer-evaluation --context-framing`. **V4 stays the default.** Runner document version 10 (the development cohort's 25 answerable temporal-reasoning questions for the ordinary path), the replay driver `scripts/framing_v4_variants_replay.py` and the self-contradiction detector `boros-self-contradiction-detector-v1` are implemented with synthetic contracts.
- **Measured:** one pre-declared, paired, local-only replay of V4 (default), V4-advice and V4-ordered on four cohorts: 282 local generations, no retry, no remote call. Lexical measures only.
- **Not measured:** judged accepts. Grading by the remote judge was not authorized for this run, because the user is still choosing the default judge. The 282 blinded verdict items are prepared for later grading. The judged-accept criteria of both rules are **pending**.
- **Outcome on the pre-declared lexical criteria: neither variant qualifies as a candidate replacement for V4.** Each variant met every lexical criterion but the zero-disclaimer one. V4-advice had one AI or memory disclaimer (preference question 35a27287), and so did V4-ordered (32260d93). V4 itself also had one (32260d93).
- **Main caveat (measured):** the V4 arm does not reproduce across runs. Only 17 of its 69 answers on the cohorts shared with the V5 test are byte-identical to that test's V4 answers on the same inputs, and its decline status changed on 4 questions. The variant effects below are of the same size as this run-to-run variation. V4-advice also reduced flagged self-contradictions on temporal questions by exactly as much as V4-ordered, so that reduction cannot be attributed to the ordering instruction.

This document contains no question, answer, reference, evidence or history text. It reports identifiers, counts and classes only.

## Implementation

### What changed

Each variant is the V4 System framing with one sentence inserted after the second fix G sentence, just before "A missing excerpt is not proof that the archive lacks a fact." Both fix G sentences are unchanged.

- **V4-advice** adds only V5's advice clause: "If the request asks for advice or suggestions, tailor the reply to relevant details about the user found in any quoted source and cite their labels." Nothing else from V5 is taken. The decline wording still names "the conversation history provided here". The "check every quoted source" and "specific fact from the user's past" sentences of V5 are absent.
- **V4-ordered** adds: "Work from the quoted evidence first: state the supporting facts and complete any date or count arithmetic before you state the conclusion, and never revise a conclusion once you have stated it." It targets the wrong-headline-then-correct pattern found on gpt4_70e84552 ([Why gpt4_70e84552 was rejected](ANSWER-PRESENTATION-DEFECTS.md#why-gpt4_70e84552-was-rejected-read-locally-at-the-users-request-october-9-2026)).

Both sentences go in the same place, so that the G sentences stay contiguous and the added instruction is the last one before the closing sentence. For V4-ordered, a position before G would have put "answer directly" after the ordering instruction.

### Contracts (V5's pattern)

- **Only the System text differs.** `ContextSourceFraming.quotedSelectionVersions` now holds V4, V5, the V4 no-G ablation and the two variants. All five share V4's recent prefixes, historical headers and footers, citation labels, label map, reductions and journal validation. `ContextAssembler.historyFraming(selectionVersion:)` returns a separate literal for each. `RecentSourceFramingChecks.v4VariantChecks` (14 new checks) derives both variants from the V4 literal, whose SHA-256 is pinned (`d3a316dd…d1b4`), by that one insertion, and checks the byte count. On a live selection, with and without a historical excerpt, it checks that every non-System message, the recent IDs, the excerpt IDs, the label map and the assignments equal V4's. `scripts/test_framing_v4_variants_replay.py` repeats the derivation from the Swift source text.
- **The version binds the System bytes.** Snapshot and journal validation already require, for the V4 family, that the System message carries exactly the journaled version's framing. The new checks confirm this for both variants. Each variant has its own mandatory-message binding and selection digest. A V4 binding paired with a variant body is refused, and so is the reverse. The two variants cannot be relabelled as each other.
- **Selectable only through `--context-framing`.** Both are in `AnswerEvaluationCommand.pinnableFramings`. Neither is evaluation-only in the ablation's sense: like V5, `ContextSourceFraming.permits` accepts them, and no runtime permission is granted for them. The default (`ContextSourceFraming.defaultSelectionVersion`, `GenerationSettings().contextFraming`) stays V4. A source scan checks that `BonsaiPlayground.swift` sets no `contextFraming` and names neither variant, and that only the framing, assembler and answer-evaluation sources (plus synthetic checks) reference them. CLI checks cover pinning with and without `--retrieval-arm ordinary_send` and refuse four near-miss spellings.
- **End to end.** `ComponentPreparationChecks` runs its quoted pipeline fixture under both variants: admission, the original-input proof, journal validation, archive, restore and the full journal corruption suite (132 new checks).
- **Runner document version 10.** The temporal cohort uses runner document version 10. Each document is the question's version-8 development runner document, built by `native_investigation_hundred_cases._history` (the pinned QA projector, then the version-8 opaque identity projection in its own domain), with only the version number changed. The 25 version-8 projections were checked against the production version-8 pins before the change. The ordinary path answers version 10, never the native investigation. It accepts only 25 separately pinned projections (`AnswerEvaluationCommand.temporalLongMemoryCorpusProjectionSHA256`, configuration pin equal to the development cohort's). Decode checks cover acceptance, refusal by the investigation mode, separation from the version-8 and version-9 pins in both directions, and refusal of paired, recent-only or reconfigured documents.

`scripts/check.py` passed before the first generation. It ran once under the default interpreter (4,925 checks, recall floor skipped because that interpreter lacks `tokenizers`) and once with an interpreter that has it (4,980 checks, floor ran with 55 comparisons). That run included 109 recent-source framing checks, 1,097 component-preparation checks and 8 driver contracts. It passed again after the run; see [Run](#run).

### Self-contradiction detector

`boros-self-contradiction-detector-v1` is a deterministic, lexical detector over the answer and the dataset reference. It is `judge_calibration.self_correction_signals` (the extension's candidate heuristic) with three declared changes:

- **Explicit revision:** a revision marker anywhere in the answer ("Correction", "Wait,", "Actually,", "let me re-check", an apology for an error, and so on).
- **Late reference:** the question is answerable and has a short reference target: the whole reference, or its first sentence, at most 6 normalized tokens. The answer has at least two paragraphs. The first paragraph has an answer-like bold headline of the target's kind (numeric or not) and contains no target. The last paragraph contains a target in a sentence without a conditional marker.
- **The three changes:**
  - the headline is the first bold span that is not a label (not ending in, or followed by, a colon);
  - a multi-sentence reference contributes its first sentence as a target;
  - a target that appears only in conditional sentences ("if", "unless", "assuming", "depending", "otherwise", "alternatively", "whether") is a hedge, not a correction.
- `self_contradiction` is explicit revision or late reference.

**Validation against the user's adjudication (in-sample).** Truth is the user's self-correction decision. In the extension, the self-correction rejects are items 004, 008, 009 and 017; items 010, 012 and 022 were accepted and are not self-corrections. In the base set they are items 010 and 011. Every other item is not a self-correction. The three changes were chosen with the documented descriptions of these items in view and were not tuned after the first validation, so the counts are in-sample.

| Item set | True positive | False positive | False negative | True negative |
|---|---:|---:|---:|---:|
| Extension, stratum `self_correction` (7) | 4 (004, 008, 009, 017) | 2 (012, 022) | 0 | 1 (010) |
| Extension, other strata (22) | 0 | 0 | 0 | 22 |
| Base set (50) | 1 (010) | 1 (001) | 1 (011) | 47 |
| All 79 | 5 | 3 | 1 | 70 |

On the 7, precision is 4 of 6 and recall 4 of 4. The hedge exclusion cleared 1 of the 3 accepted 00ca467f answers. The other two are numeric count references, where the reference number also appears in a later, unhedged sentence. The base false negative, item-011, states the correct value in a form that never matches the reference string. The base false positive, item-001, is a temporal answer. On the 79 items, the detector flags 5 of the 6 self-corrections and 3 of the 73 other answers.

## Declaration

Frozen at 21:54:40 UTC, before the first generation, at `.build/framing-v4-variants-replay-20261009/declaration.json` (private, 0600), SHA-256 `3405c60dbac9f4c2584637abe401bc3a502141c895ea1ce06fb44a3168852287`. One declaration covers the arms, cohorts, question lists, gold-delivery table, settings, cap, detector definition and validation counts, and the pre-declared rule for each variant.

- **Authorization.** The user authorized this in chat on October 9, 2026: implement both variants and run local generations, up to 290, with no remote calls. Judge grading is not part of the authorization.
- **Binary.** All arms ran the same binary, SHA-256 `c6a8626fec684817eab78ee57fa48aab145aaeccd285d80a1bf23e5e63dacc24`, built from the implementation commit `a9ecafa` (by `check.py`, then copied to a separate directory). The declaration records `build_commit` `a9ecafa` with a clean `Sources/` and `scripts/` tree. The work started from `main` at `c7d0265`.
- **Arms.** `v4-default` passes no `--context-framing`. `v4-advice` and `v4-ordered` pass `--context-framing` with their version. Run order: cohorts as listed below; within each cohort, questions in order and the arms V4, V4-advice, V4-ordered for each question.
- **Cohorts.**
  - **`retrieval-on-21`**: the 21 questions of the earlier replays, recorded hybrid attempt, run with `--retrieval-arm ordinary_send`. The inputs are the same runner documents as in the V5 test (documents 5 and 7, rebuilt and matched to their recorded runner-input SHA-256).
  - **`preference-27`**: the V5 test's 27 preference questions, unchanged (runner document version 9), with `--retrieval-arm ordinary_send`.
  - **`temporal-25`**: every answerable `temporal-reasoning` question of the development cohort (`native-investigation-100-v1`), in its rank order: gpt4_5438fa52, gpt4_2d58bcd6, 9a707b82, gpt4_4929293b, 0bc8ad93, gpt4_e072b769, gpt4_d6585ce8, 8c18457d, gpt4_1e4a8aeb, gpt4_7f6b06db, 4dfccbf8, gpt4_5dcc0aab, gpt4_213fd887, 6e984302, gpt4_d9af6064, gpt4_0a05b494, gpt4_7a0daae1, gpt4_e414231f, gpt4_fe651585, gpt4_7ddcf75f, gpt4_ec93e27f, gpt4_cd90e484, gpt4_468eb064, gpt4_f420262c and eac54adc. Runner document version 10, 1,024 output tokens, with `--retrieval-arm ordinary_send`. **None is in `retrieval-on-21`, so none was excluded:** the development selection already excludes the pilot and independent questions. The cohort's three temporal abstention questions (982b5123_abs, c8090214_abs and gpt4_93159ced_abs) are not answerable and were left out.
  - **`recent-only-21`**: the recent-only attempt of the 21 questions.
- **Gold delivery, computed offline before any generation** (`framing_v4_variants_replay.py gold`, table SHA-256 `c0edd12fa584908b47ed2dc5d5647f76fc3b9d779a07cb3d3f5ab6e4b8623569`). As in the V5 test, the retrieval harness's delivery binary was compiled from this checkout and given a loopback tokenizer stand-in, so no answer was generated. It ran the declared arm on each runner input, and the annotated gold turns were scored with `gold_delivery`. For the three cohorts shared with the V5 test, every class and every delivered range set equals the V5 test's gold table.

  | Cohort | Whole | Partial | None | No gold turns (abstention) |
  |---|---:|---:|---:|---:|
  | retrieval-on-21 | 13 (12 without 54026fce) | 1 (08f4fc43) | 4 (06878be2, 1a1907b4, 1b9b7252, 4baee567) | 3 |
  | preference-27 | 14 | 5 (35a27287, 0a34ad58, 1c0ddc50, afdc33df, 07b6f563) | 8 (32260d93, d6233ab6, 6b7dfb22, d24813b1, 06f04340, 09d032c9, 95228167, 0edc2aef) | 0 |
  | temporal-25 | 14 | 5 (gpt4_d6585ce8, 8c18457d, gpt4_d9af6064, gpt4_f420262c, eac54adc) | 6 (9a707b82, gpt4_4929293b, gpt4_7f6b06db, gpt4_5dcc0aab, 6e984302, gpt4_ec93e27f) | 0 |
  | recent-only-21 | 0 | 0 | 18 | 3 |

  The temporal cohort's 14 of 25 whole matches the harness's lexical R2 for the temporal category (14 of 25, [RETRIEVAL-HARNESS.md](RETRIEVAL-HARNESS.md)).
- **Model and settings.** These match the earlier replays: model `ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit` (listed by the live server), temperature 0, thinking off, seed 104202601, the frozen 32,768 context limit with 256 safety tokens, and the frozen output caps (512 for document 5, 1,024 for documents 7, 9 and 10).
- **Limit and retry rule.** Cap 290 authorized, 282 runs declared, generation limit 282. A run that never started an answer invocation could be retried twice without counting.
- **Measures.** Declines use the V5 test's declared measure: the detector's phrase list plus the anchored source-decline pattern, `decline` within the first 200 characters and `partial_decline` later, both counted as declines. Gold classes are the declared offline ones. Self-contradiction is the detector above. Header, raw IDs, disclaimers, labels and "has reference" come from `answer_presentation_defects.py` (`answer-presentation-defects-v2`) through the replay driver.
- **Decision rules (verbatim in the declaration).** Each variant is compared with V4. 54026fce is reported separately and excluded from every count. A criterion whose subset lacks a measured answer in either arm counts as not holding. **The judged-accept criteria are recorded as pending:** they will be added before any grading, when grading is authorized. Until then the lexical criteria are necessary, not sufficient, and neither variant can be recommended.
  - **V4-advice** is a candidate on the lexical criteria only if all of these hold:
    - **A1:** on the preference questions of retrieval-on-21 and preference-27 with gold whole, it declines fewer than V4. A tie fails, and so does V4 having 0 declines.
    - **A2:** on the 3 retrieval-on abstention questions, it declines at least as often as V4.
    - **A3:** on recent-only-21 without 54026fce (20 answers, all without delivered gold), it declines at least as often as V4.
    - **A4:** it has 0 AI or memory disclaimers over all four cohorts.
  - **V4-ordered** is a candidate on the lexical criteria only if all of these hold:
    - **O1:** on the answerable temporal-reasoning questions of retrieval-on-21 and temporal-25, it has fewer detector-flagged self-contradictions than V4. A tie fails, and so does V4 having 0.
    - **O2:** on the answerable gold-whole questions of the three retrieval cohorts, it declines no more often than V4.
    - **O3:** it has 0 AI or memory disclaimers over all four cohorts.

  **Correction to the declaration text:** O1's text gives the subset size as "2 + 25 = 27 per arm". The operative definition (answerable temporal-reasoning questions of those two cohorts) covers 28, because 08f4fc43 in retrieval-on-21 is also temporal-reasoning. The detector does not flag 08f4fc43 in any arm, so the O1 counts and outcome are the same with 27 or 28.

## Run

- **Generations.** 282 answer generations, 21:55 to 22:48 UTC, local server only. No retry was needed: 0 runs failed before an answer invocation and 0 failed after it. No answer stopped at its output cap.
- **Arms and delivery.** All 282 runs reported the declared framing. The 219 retrieval-cohort runs recorded `ordinary_send` with semantic retrieval `disabled_by_policy` and a validated lexical receipt, and the 63 recent-only runs carried no arm fields. Every run delivered exactly the declared ranges (identical range digest). Prompt sizes relative to V4 were -16 to +64 tokens for V4-advice and -11 to +69 for V4-ordered. As in the V5 test, the spread comes from per-ingestion conversation IDs in excerpt headers, not from delivery. 15 V4-advice answers and 4 V4-ordered answers are byte-identical to V4's.
- **No remote call.** Measurement and the judge-item builder are local. No judge was called.
- **Checks.** `scripts/check.py` passed before the first generation (see [Contracts](#contracts-v5s-pattern)) and again after the run, with the same interpreter: 4,980 checks, recall floor ran (55 comparisons).

## Results

Lexical measures are string checks on the answer, not a judge. Declines are split by the declared gold class:

- **false:** answerable, gold whole;
- **justified:** answerable, no gold delivered;
- **partial gold:** answerable, some gold delivered;
- **abstention:** an abstention question declined.

"Header" counts a copied V3 or V4 host header at the start of the answer. "Raw IDs" counts answers with benchmark event IDs. "Self-contr." counts answers flagged by the detector. "Labels" counts cited `[E n]` labels, with unresolved ones in parentheses. "Cites gold" counts answers citing a label that maps to an annotated gold turn. "Has ref." counts answers containing the reference string; it is meaningless for preference questions, whose references are rubrics. All counts leave out 54026fce.

### retrieval-on-21 (ordinary Send, 20 questions without 54026fce)

| Arm | Declines | False | Justified | Partial gold | Abstention | Disclaimers | Header | Raw IDs | Self-contr. | Labels (unresolved) | Cites gold | Has ref. | Median words |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|
| V4 | 8 | 1 (51c32626) | 3 | 1 (08f4fc43) | 3 of 3 | 0 | 0 | 0 | 1 (gpt4_70e84552) | 35 (0) | 12 | 9 | 65 |
| V4-advice | 7 | 0 | 3 | 1 (08f4fc43) | 3 of 3 | 0 | 0 | 0 | 2 (00ca467f, gpt4_70e84552) | 39 (0) | 12 | 9 | 50 |
| V4-ordered | 8 | 1 (51c32626) | 3 | 1 (08f4fc43) | 3 of 3 | 0 | 0 | 0 | 1 (gpt4_70e84552) | 38 (0) | 13 | 9 | 66 |

The justified declines are 06878be2, 1b9b7252 and 4baee567 in all three arms. All three arms declined the three abstention questions (031748ae_abs, 0862e8bf_abs, f685340e_abs). The 00ca467f flag under V4-advice is on the question whose earlier answers were the detector's numeric false positives.

### preference-27 (ordinary Send)

| Arm | Declines (partial) | False (of 14 gold whole) | Justified (of 8) | Partial gold (of 5) | Disclaimers | Header | Raw IDs | Self-contr. | Labels (unresolved) | Cites gold | Median words |
|---|---:|---|---:|---:|---|---:|---:|---:|---|---:|---:|
| V4 | 12 (1) | 6 (1da05512, 38146c39, 57f827a0, 75832dbd, 75f70248, b6025781) | 5 | 1 (35a27287) | 1 (32260d93) | 0 | 0 | 1 (1da05512) | 57 (0) | 5 | 187 |
| V4-advice | 8 (0) | 2 (57f827a0, 75832dbd) | 6 | 0 | 1 (35a27287) | 0 | 0 | 1 (1da05512) | 173 (0) | 11 | 235 |
| V4-ordered | 12 (1) | 5 (1da05512, 38146c39, 57f827a0, 75832dbd, 75f70248) | 6 | 1 (35a27287) | 1 (32260d93) | 0 | 0 | 1 (1da05512) | 136 (0) | 6 | 193 |

Against V4, V4-advice removed the declines on 1da05512, 35a27287, 38146c39, 75f70248 and b6025781, and added one on 95228167 (gold none, so justified). V4-ordered removed b6025781 and added 95228167. V4's justified declines are 06f04340, 09d032c9, 0edc2aef, d24813b1 and d6233ab6; both variants add 95228167. No arm had a copied header, a raw ID, an unresolved label or LaTeX in any cohort.

### temporal-25 (ordinary Send, development cohort)

| Arm | Declines (partial) | False (of 14) | Justified (of 6) | Partial gold (of 5) | Disclaimers | Header | Raw IDs | Self-contr. | Labels (unresolved) | Cites gold | Has ref. | Median words |
|---|---:|---:|---:|---|---:|---:|---:|---|---|---:|---:|---:|
| V4 | 7 (1) | 0 | 5 | 2 (8c18457d, gpt4_f420262c) | 0 | 0 | 0 | 6 | 67 (0) | 17 | 9 | 74 |
| V4-advice | 6 (0) | 0 | 5 | 1 (8c18457d) | 0 | 0 | 0 | 4 | 66 (0) | 17 | 9 | 74 |
| V4-ordered | 6 (0) | 0 | 5 | 1 (8c18457d) | 0 | 0 | 0 | 4 | 81 (0) | 17 | 10 | 110 |

The justified declines are 6e984302, 9a707b82, gpt4_4929293b, gpt4_5dcc0aab and gpt4_7f6b06db in all three arms. Flagged self-contradictions:

| Arm | Flagged questions |
|---|---|
| V4 | gpt4_0a05b494, gpt4_2d58bcd6, gpt4_7a0daae1, gpt4_7ddcf75f, gpt4_cd90e484, gpt4_d9af6064 |
| V4-advice | gpt4_1e4a8aeb, gpt4_2d58bcd6, gpt4_7a0daae1, gpt4_d9af6064 |
| V4-ordered | gpt4_0a05b494, gpt4_2d58bcd6, gpt4_7ddcf75f, gpt4_e072b769 |

Against V4, V4-ordered removed gpt4_7a0daae1, gpt4_cd90e484 and gpt4_d9af6064 and added gpt4_e072b769. V4-advice removed gpt4_0a05b494, gpt4_7ddcf75f and gpt4_cd90e484 and added gpt4_1e4a8aeb. Only gpt4_2d58bcd6 is flagged in all three arms. V4-ordered answers are longer (median 110 words against 74), consistent with stating facts and arithmetic first. "Has ref." moved from 9 to 10 under V4-ordered (gained gpt4_0a05b494 and gpt4_e072b769, lost gpt4_7a0daae1); it is a string check, not a verdict.

### recent-only-21 (20 questions without 54026fce; no gold delivered)

| Arm | Declines | Answerable (17) | Abstention (3) | Disclaimers | Self-contr. | Labels |
|---|---:|---:|---:|---:|---:|---:|
| V4 | 20 | 17 | 3 | 0 | 0 | 0 |
| V4-advice | 20 | 17 | 3 | 0 | 0 | 6 |
| V4-ordered | 20 | 17 | 3 | 0 | 0 | 2 |

Every arm declined all 20. No copied header or raw ID in any arm.

### 54026fce (reported separately, excluded from every count)

| Cohort | V4 | V4-advice | V4-ordered |
|---|---|---|---|
| retrieval-on-21 (gold whole) | decline (false), 0 labels | answer, 8 labels | answer, 2 labels |
| recent-only-21 (no gold) | decline | decline | decline |

V4 declined 54026fce again, as in every earlier replay with this evidence. Both variants answered it. Whether those answers are tailored and correct needs a verdict, which is pending.

## Pre-declared rules: lexical outcome

| Criterion | V4 | Variant | Holds |
|---|---:|---:|---|
| A1: declines on preference questions with gold whole (14) | 6 | 2 | yes |
| A2: declines on retrieval-on abstention questions (3) | 3 | 3 | yes |
| A3: declines on recent-only, without 54026fce (20) | 20 | 20 | yes |
| A4: V4-advice AI or memory disclaimers (92 answers) | | 1 (35a27287) | **no** |
| O1: self-contradictions on answerable temporal questions (28) | 7 | 5 | yes |
| O2: declines on answerable gold-whole questions (40) | 7 | 6 | yes |
| O3: V4-ordered AI or memory disclaimers (92 answers) | | 1 (32260d93) | **no** |
| Judged-accept criteria, both variants | | | **pending** |

**Outcome: neither V4-advice nor V4-ordered qualifies as a candidate replacement for V4 under its pre-declared lexical criteria.** Each fails the zero-disclaimer criterion by one answer in the preference cohort. V4 had one disclaimer there as well, on 32260d93, the same question as in the V5 test. The rules were fixed before the first generation, and the judged-accept criteria, which would also be required, have not been defined or measured. V4 stays the default; this replay changes no default.

## Measured and inferred

Measured:

- The counts above, from one generation per question and arm at temperature 0 with fixed inputs and identical delivery.
- **The V4 arm is not reproducible across runs.** The V5 test ran V4 on the same 69 inputs of retrieval-on-21, preference-27 and recent-only-21, with a different binary but identical V4 bytes and identical delivered ranges. Only 17 of 69 V4 answers are byte-identical between the two runs. V4's decline status changed on 4 questions: 51c32626, b6025781, 1da05512 and afdc33df. V4's false declines on preference questions with gold whole were 4 of 14 in the V5 test and 6 of 14 here.
- **The declared decline extension mattered here.** Unlike the V5 test, the anchored source-decline pattern changed 4 outcomes, all from answer to decline: 08f4fc43 (V4 and V4-advice, partial gold), 51c32626 (V4, gold whole) and 1da05512 (V4, gold whole, a partial decline). With the phrase list alone, A1 would still hold (5 against 2). O2 would fail (V4 5, V4-ordered 6), because two of V4's seven gold-whole declines are found only by the extension. The declared measure includes the extension, so O2 holds as declared, but the result depends on it.
- **V4-advice reduced flagged temporal self-contradictions exactly as much as V4-ordered** (7 to 5 on the 28 temporal questions). The two variants removed and added different questions.

Inferred, not measured:

- **The O1 reduction is not evidence for the ordering instruction.** A sentence about advice, which does not apply to temporal questions, produced the same change. Changes of two flagged answers are within what an unrelated one-sentence System change, or the run-to-run variation above, produces.
- **The A1 reduction (6 to 2) is larger, but not cleanly separated from noise.** V4's own count moved by 2 between runs. The direction agrees with the V5 test, where V5's advice clause and wider rewording removed all four V4 false declines, and with the ablation finding that the false declines come from G. V4-advice's answers in the preference cohort cited three times as many labels as V4 (173 against 57) and cited a gold turn more often (11 against 5), which is consistent with the clause being followed. Whether the extra answers are accepted needs the judge.
- **The disclaimer failures are single answers.** Each variant's one disclaimer is in the preference cohort, as is V4's. A single disclaimer decides the pre-declared rule, as the rule intended.
- **The detector is weak evidence on its own.** Its in-sample precision on the 7 validation items is 4 of 6; its false positives were numeric count references. 6 of the 28 temporal questions have no reference target of at most 6 tokens (0bc8ad93, gpt4_d6585ce8, gpt4_7f6b06db, 4dfccbf8, 6e984302 and gpt4_0a05b494), so only an explicit revision marker can flag their answers; gpt4_0a05b494 was flagged that way under V4 and V4-ordered. The detector does not decide correctness either: a judged verdict under the user's self-correction rule is the measure that matters.
- **Judged accepts are pending.** Nothing here says whether either variant gives more correct answers.

## Judge-ready items (not graded)

`judge-set` built 282 blinded verdict items with the calibration item builder: dataset question, date, type, reference and abstention flag, no evidence, the calibration identifier scrub and a seeded interleaved order, with no arm, cohort, run or question ID visible. Set `jr-279000e99e02f5e2`, items SHA-256 `479cd699b992d0e463cc1004fed97f1ab379eba949deb5a11a9f1f76211a21bd`, key SHA-256 `0a858df0fc58412fcdaae8bcf76c78b9fc9f1bea47ab3afe43750900ca15becf`, 0 identifier substitutions, 0 items naming a model. They are at `.build/framing-v4-variants-replay-20261009/judge-set/` (`items.json`, `key.json`, `manifest.json`; 0600 in a 0700 directory) in worktree `agent-a80d0b180c643f811`. The private `measure.json` beside it (SHA-256 `591f746d07fc5d9122973b0a719c74e7bfd77856a62007e73194df638cd57936`) holds the rows that a judge summary would join by run index.

When grading is authorized: first add the judged-accept criteria for both variants to this record, then fill a judge declaration for the chosen default judge, run `scripts/judge_calibration_run.py --set <run dir>/judge-set ...`, and join the labels to `measure.json` by run index.

## Reproduction

```sh
python3 scripts/framing_v4_variants_replay.py validate-detector
python3 scripts/build.py --output <new .build directory for the binary>
<python with tokenizers> scripts/framing_v4_variants_replay.py gold --output <new .build directory> --dataset <pinned longmemeval_s_cleaned.json>
python3 scripts/framing_v4_variants_replay.py declare --output <new .build directory> --dataset <dataset> --binary <Boros binary> --gold <gold dir>/gold-delivery.json
python3 scripts/framing_v4_variants_replay.py run --output <run dir> --binary <same binary>
python3 scripts/framing_v4_variants_replay.py measure --output <run dir> --dataset <dataset>
python3 scripts/framing_v4_variants_replay.py judge-set --output <run dir> --dataset <dataset>
```

Private outputs: `.build/framing-v4-variants-gold/` and `.build/framing-v4-variants-replay-20261009/` in worktree `agent-a80d0b180c643f811`. They hold the gold table, declaration, inputs, ledger, native reports and answers, `measure.json` and the judge set. `validate-detector`, `measure` and `judge-set` print identifiers, classes and counts only.
