# Native investigation: 100-question local evaluation

Authorized October 7, 2026. The user requested 100 questions after the three-question local comparison. This run evaluates **100 investigation answers**, using local Qwen for answering and the supplied JevK5 MCP connector for reference-based grading. Native verification is complete. The user stopped the model run on October 7, 2026; it is paused. All six JevK5 controls passed before the first question. The preceding three-question captures and paid experiment remain intact.

## Frozen selection

The source is the same pinned 500-record LongMemEval S cleaned file, revision `98d7416c24c778c2fee6e6f3006e7a073259d48f`, SHA-256 `d6f21ea9d60a0d56f34a05b609c79c88a451d2ae03597821ea3d5a9678c3a442`.

Selection excludes all 51 question identities used in the seven-question, fourteen-question and thirty-question experiments. A new SHA-256 domain ranks the remaining 449 identities. Hamilton proportional allocation selects by question category, with category names resolving allocation ties. Selection does not inspect question text, history text, answers, positive annotations or abstention labels. Ten abstention questions occur in the selected set.

| Category | Questions |
|---|---:|
| Knowledge update | 15 |
| Multi-session | 27 |
| Assistant recall | 11 |
| Preference | 5 |
| User recall | 14 |
| Temporal reasoning | 28 |
| Total | 100 |

The selected histories retain 49,229 original turns and 48,884,452 UTF-8 source bytes across 4,754 sessions. There are 4,543 distinct original session identities; 203 identities recur across selected histories, and one history repeats an original session identity. Question identity exclusions therefore do not establish independent histories or users.

Every model-visible history, event, project, conversation and probe identity is replaced by a deterministic opaque hash. Category and `_abs` identifiers stay in the private scorer. Original source text, source dates and exact question text remain unchanged. Separate version-8 native projection pins authorize exactly the 100 single-hybrid inputs; version-7 inputs retain their prior contract. The frozen selection manifest SHA-256 is `2e310e440a7aca2fa24b8474b6afe1f2115a654851b37f8948acef995649f8ae`.

## Execution and scoring

The repaired selected-Qwen native investigation path retains its original 300-second episode, finite resource limits, deliberate navigation, private stages and final original-evidence request. Each question has one visible answer attempt, thinking disabled, with a 1,024-token final output cap. Questions execute serially; no recent-only or ordinary-hybrid comparison arm is included.

Six public JevK5 controls precede grading. The run permits at most 100 visible answer attempts and 106 judge decisions. Paid remote providers and automatic retries are unavailable. Durable dispatch intents and validated receipts permit recovery of completed operations while refusing an ambiguous redispatch. Checkpoints retain all 100 questions after each operation.

Case-specific format, output-cap, context-cap, budget and deadline failures remain in the denominator. Continuation requires healthy terminal capture/accounting, zero held resources, zero unknown input/output operations and no unresolved work. Infrastructure failures or invalid provenance stop further dispatch. Numeric diagnostics distinguish model output limits from transport/count failures; they do not change successful investigation behavior.

The primary result will be JevK5-accepted answers divided by all 100 declared questions. Accepted answers among completed/scored answers will be reported separately. Category results, abstention results, complete annotated evidence delivery, operational failures, latency and resource charges will accompany the headline. Grading reuses the pinned upstream QA prompt, SHA-256 `ecce9c4c79dc89d99534ac17b383a5cbb5b9f0c69ee98adaf0684742e3d95251`. This local judge result is not the official benchmark score; JevK5 semantic accuracy and source-support calibration remain unvalidated.

## Continuation amendment

The initial controller stopped after five graded answers when question 6 failed in preparation. A read-only runtime audit located a planner request to pin ten blocks when nine were selected; one requested pin was a previously returned search candidate outside the current selection. All eight private model calls and all 1,729 work records completed, with healthy capture/accounting, no held resources, no unknown usage, no unresolved work and a healthy SQLite store. The application rejected the action before the final answer and used the broad `context_preparation_failed` label.

The frozen binary, source hashes, selection, settings and judge remain unchanged. A private continuation amendment permits only this exact audited native-report hash, `9014bcc0620d11bef8fa1dee06fe6f4f855c7381312317340b171697dd40968c`, to count as a zero-credit case failure. The original controller halt report is retained. Saved dispatches and judge receipts are recovered without repeat model calls, then question 7 onward continues. Other infrastructure or accounting failures still stop dispatch. Amendment SHA-256: `a185142364c17398db3efdbc4b252c4239a62120c19d66b830f2d7d95a89fb84`. This is a disclosed failure-classification amendment after observation; it changes neither answers nor their denominator.

## User-requested stop

The runner and active native evaluation process were terminated on October 7, 2026. Seven answers were graded: six accepted and one rejected. Two preceding preparation failures count as zero credit. The tenth attempted question was interrupted, leaving ninety questions unattempted. These partial results do not establish accuracy for the declared 100-question evaluation. The goal is paused; no resume or retry is authorized. The private `user-requested-stop.json` preserves the checkpoint hash and stop state.

## Verification checkpoint

The selector/controller passes eleven synthetic checks covering answer-blind selection, opaque identifiers, the 100-question denominator, version-8 provenance, failure handling and recovery without duplicate answer/judge dispatch. The fixed Swift projection set independently matches all 100 frozen inputs. The optimized build passes 4,087 application checks, all seven preceding pilot-controller tests and strict deep signature verification. All 167 captured source/test hashes remain stable. Its binary SHA-256 is `5790b8ab6ba6016f297e984973d110725843faeb1e36f08f1a2e776ea51a917f`. The first full verification caught the coordinator's filtering of new fixed failure labels; the corrected build passes all 282 native investigation checks, including actual malformed/empty/output-limited transport cases with zero unknown work and no final dispatch. The pre-execution verification made no evaluation model calls. The subsequently frozen declaration SHA-256 is `b07e71cf589f834607e026ba78c3c9e341955895737aa6ad0df09cdf84d89d9b`; the live run was subsequently stopped by the user. JevK5's preflight counters were 68 decisions, three cache hits and zero errors, with generation 32. Current progress is checkpointed privately after each question and judgment.

Private selection files live in the isolated worktree's `.build/evaluation/native-hundred-selection-v1-20261007`. Inputs, scorer data, model bodies, answers, runtime stores and generated bundles remain outside Git.
