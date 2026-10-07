# Native investigation local trial

Recorded October 7, 2026. **The trial stopped during Qwen calibration before retrieval or answering. It produced no answer-quality comparison.** The supplied JevK5-4B MCP connector passed all six public judging controls. It received no Boros answers to judge.

The user explicitly authorized a small local trial after the native investigation implementation. This authorization covered this fixed trial; the preceding paid orientation experiment and its continuation remain held. No OpenAI API call or other remote-provider request occurred.

## Frozen scope

The trial selected the first three histories by the existing answer-blind hash rank from the frozen fourteen-history development cohort. Selection did not use reference answers, evidence annotations, previous scores or judge feedback. The selected histories are `1b9b7252`, `4baee567`, and `gpt4_70e84552`: two single-session-assistant cases and one temporal-reasoning case. All are answerable; their IDs contain no abstention cue. This reused development subset is a diagnostic, not a held-out quality gate.

There were six declared attempts: recent-only and native investigation for each history, in that order. Exact version-7 original-source projections and the 1,024-token final output configuration stayed pinned. The explicit `--investigate-memory` CLI amendment applies investigation only to the input's hybrid arm, records its distinct preparation identity, skips semantic maintenance for that arm, and retains private runtime evidence. Ordinary application settings still default to investigation off.

The answering model was the local `ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit`. The judge was `JevK5-4B-v0.3-Q8_0`, SHA-256 `aea433883bc7ed399f2fbd539e53d2eac7caf71a946fe6650995a413979d4a30`, reached through the user-supplied mcpme slot. The connector exposes status and choice judging; it does not provide a free-form answer-generation tool.

The declaration limited execution to six answer attempts and twelve judge decisions, including six public controls. Execution was one-shot, with no retries and a stop on the first operational failure. The driver retained all six denominator rows. Private inputs, separate scorer annotations, the upstream QA protocol, controller code, native code, binary and connector executable were hash-bound before dispatch.

## Observed result

| Outcome | Count |
|---|---:|
| Public JevK5 controls passed | 6 / 6 |
| Accepted Boros answer attempts | 1 / 6 |
| Operationally completed answers | 0 / 6 |
| Failed accepted attempts | 1 |
| Undispatched attempts | 5 |
| Native investigation / planner dispatches | 0 |
| Retrieval / source-read work | 0 |
| JevK5 answer judgments | 0 |
| Remote-provider calls | 0 |

The first recent-only attempt completed three provider discovery requests and one tokenizer request. Its one-token calibration request failed after approximately 15.2 seconds. The episode charged five HTTP attempts, one model call and 74 input tokens. It charged zero output tokens and retained the original one-token unknown-output hold. The native arm and both remaining pairs were not dispatched. The CLI deliberately exited with failure after this operational stop.

An independent audit verified all 466 original payloads, roles, statuses, digests, byte counts and source chronology against the frozen input. Request/snapshot hashes and summed charged/held resources matched the episode. The store contains zero answer invocations, answer work, source-read work and visible chunks. Four preparatory work rows completed; calibration remained `outcomeUnknown`. A completed server inference cannot be substituted for the absent client usage receipt.

The ordinary score helper reports empty delivery fractions for the failed preparation. Those zeros are not observed retrieval failures: no original evidence was selected or dispatched. There is no QA score, winner or evidence of improved investigation quality.

## Failure attribution and repair

The measured implementation applied a 15-second per-request transport limit to calibration as well as metadata and tokenization. The matching local server log tail contains the calibration signature of four messages, 74 prompt tokens and a one-token output cap. It records client cancellation and an approximately 68.8-second prefill/decode interval. This strongly implicates inference outlasting the client timeout. The log lacks request IDs and request timestamps; cold loading, queuing and memory pressure remain unproven.

A separate repair permits calibration requests up to 90 seconds. Metadata/tokenizer requests retain 15 seconds. Admission sessions have a fixed 120-second ceiling with an episode lease and retain 45 seconds without one. Each request takes the minimum of its stage limit, original session remainder and original episode remainder; no original turn deadline or resource allowance is extended. Unknown dispatched usage remains held; no calibration retry is introduced. Fixed numeric transport causes, timeout and HTTP status are recorded without request or response text. Task-bound absolute timers prevent a queued old timeout from affecting a later request. The component proof's 30-second freshness interval still starts after verification.

This repair is separate from the frozen implementation measured above. A fresh debug build passes 150 admission checks, 281 endpoint integration checks, 682 component pipeline checks, 53 navigation checks, 248 investigation pipeline checks, 25 answering tests and seven controller tests. The endpoint tests include a 16-second calibration response, Stop/deadline holds and HTTP 503 evidence. All 166 captured source/test files match; strict deep signature verification passes. The first repair compilation failed on a throwing test expression and remains retained; the corrected source was freshly compiled and verified. These synthetic checks establish transport mechanics. They do not prove the actual local model completes within 90 seconds or improve retrieval. No second live trial has been run.

The next authorized model trial must first establish operational calibration and then measure actual search/zoom behavior, selected original evidence and final answer quality. This three-case comparison would still have only a recent-context control, larger investigation preparation allowances, two categories and one replicate. It cannot isolate the value of orientation from full-snapshot lexical retrieval. JevK5 reference-based acceptance requires independent source inspection before being treated as semantic correctness.

## Receipts

Private runtime captures live in the isolated worktree, under `.build/evaluation/native-local-trial-v1-20261007`. They are ignored by Git. No source-bearing input, answer or provider response belongs in this document.

| Receipt | SHA-256 |
|---|---|
| Frozen declaration | `473d7647715debb94c0b57dd4f170f6005be505777a76f794ccae4fc7e53ace3` |
| Terminal trial report | `8ab2b913f4ed515c08cb76c8235a6d1d75d83533cab0ac101f5b5d61a82a577e` |
| Native first-pair report | `cf88fe14dff090b6c816992d076eb1f9ddb6e6fee49777132e4adcceb0619c1a` |
| Measured native binary | `bab773254e14c6beea5f77a5cc819370cac513ac85ec71977dd5307646a46867` |
| Focused build verification | `909e1fc96fbd7fbcb963b2888290bcaf24f27b160cb3399e33d81073205494a2` |

The optimized measured binary was compiled from copied native sources and passed strict deep signature verification. Focused checks passed: 53 pure navigation checks, 248 actual-coordinator pipeline checks, 119 GUI checks, 25 answering tests and seven controller tests. The controller's two post-audit fixes were captured after native compilation and before trial freezing; all native sources remained identical. After the trial, the frozen inputs, controller, native sources, binary and connector executable remained unchanged. This focused receipt does not replace the preceding complete 4,024-check application verification.

The subsequent repair debug bundle is `.build/calibration-timeout-repair-debug-v2/Boros.app`. Its binary SHA-256 is `02c60c8daa6975d267ba1755a4a047001ac2b5225e84cf52b611dcf8d50bd59e`; verification SHA-256 is `094f1366a757dade6baf80a86510ebbc07eba8c767204b0aa3bb1ca8c4911a09`; source/test manifest SHA-256 is `eea4ea729a12647b28bb80b487090ad2c42153cb564a8122a716b55b46ac2750`. This debug build is a synthetic verification artifact, not a measured performance or release build. The running GUI was not refreshed.
