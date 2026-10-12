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

Nothing else changed. v1/16, the step 1 and 2 policies and `exchange_packed` keep their declared parameters, which the packer checks pin (`exchange_packed_parameters_are_declared`). The evaluation command's `--component-policy` option is unchanged.

### Contracts

- `--retrieval-strategy-self-test` (`ExchangeBlockQueryChecks.swift`): the wide policy is versioned, distinct, round-trips, refuses a forged cap, declares its window and audit limit, fits the 64 KiB receipt after base64 with 8 KiB of headroom; the entry point records mode `exchange_wide`, depth 48, budget 16,000, 64 spans and a 40,960-byte limit on the snapshot and on its counted reduction, while `exchange_packed` snapshots keep 32,768.
- `--retrieval-strategy-integration-test` (`ExchangeEpisodeChecks.swift`): the wide policy joins the per-policy journal suite. Under the synthetic tokenizer (5,000 tokens per source) its counted reductions end at 3 spans (16,000 / 5,000) with a receipt per removal; the snapshot carries the policy's audit limit; the admission receipt's measured overhead plus the base64 audit at the policy's limit fits the store's 64 KiB; the journal and archive validators accept the episode.
- `scripts/test_retrieval_harness.py`: the packed R1 scorer reads the declared depth (32 or 48) and refuses an undeclared one; `exchange_wide` follows `exchange_packed` in the arm list.
- `scripts/test_exchange_packed_answers.py`: the driver's `--baseline-arm`, `--candidate-arm` and `--promote-minimum-points` options drive the declared rule and are restored.

## Measured, offline (P1 harness)

To be recorded from the regression and development runs.

## Measured, answer quality (step 3 cohorts)

To be recorded.

## Decision

To be recorded.
