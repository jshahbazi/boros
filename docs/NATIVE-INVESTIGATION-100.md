# Native investigation: 100-question local evaluation

Authorized October 7, 2026. The user requested 100 questions after the three-question local comparison. This run evaluates **100 investigation answers**, using local Qwen for answering and the supplied JevK5 MCP connector for reference-based grading. Native verification is complete; execution is ready. The preceding three-question captures and paid experiment remain intact.

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

## Current checkpoint

The selector/controller passes eleven synthetic checks covering answer-blind selection, opaque identifiers, the 100-question denominator, version-8 provenance, failure handling and recovery without duplicate answer/judge dispatch. The fixed Swift projection set independently matches all 100 frozen inputs. The optimized build passes 4,087 application checks, all seven preceding pilot-controller tests and strict deep signature verification. All 167 captured source/test hashes remain stable. Its binary SHA-256 is `5790b8ab6ba6016f297e984973d110725843faeb1e36f08f1a2e776ea51a917f`. The first full verification caught the coordinator's filtering of new fixed failure labels; the corrected build passes all 282 native investigation checks, including actual malformed/empty/output-limited transport cases with zero unknown work and no final dispatch. No evaluation model calls have occurred at this checkpoint.

Private selection files live in the isolated worktree's `.build/evaluation/native-hundred-selection-v1-20261007`. Inputs, scorer data, model bodies, answers, runtime stores and generated bundles remain outside Git.
