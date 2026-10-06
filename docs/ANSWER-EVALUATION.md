# Production-path answering evaluation

Status: shared GUI lifecycle, public development diagnostic and separate JSON-object control implemented and verified, October 6, 2026. The original October 5 paired pilot retains all 18 attempts and failures. Subsequent developer-history and complete-pack amendments remain separate unregistered development diagnostics; no new registered quality protocol is frozen. The full architecture and release gates remain unfinished in [STATUS.md](STATUS.md).

## Implementation contract

Run paired `recent_only` and `hybrid` attempts through the shared selected-Qwen preparation and answer lifecycle. Each attempt has an isolated public synthetic store, one original episode lease, exact provider counts and durable capture. The GUI retains hybrid as its default. Native profiles retain their existing path during this extraction.

| Surface | Owner | Contract |
|---|---|---|
| Retrieval strategy | `ContextRetrievalStrategy` | Immutable `ContextRetrievalStrategy`; recent-only skips historical search/read/query encoding while retaining mandatory input, recent preparation, reductions and proofs |
| Answer attempt coordinator | `AnswerAttemptCoordinator` | Atomic acceptance, original lease, shared preparation, proof-bound invocation, commit-before-delivery streaming, cancellation and operational finalization |
| GUI and diagnostic integration | Ordinary Send and `AnswerEvaluationCommand` | Use the same selected-Qwen coordinator; preserve visible behavior and private capture; drive isolated public fixtures |
| Orchestration and scoring | `scripts/evaluate_answers.py` | Exclude oracle data from runner input; retain every attempt; produce content-free reports and explicit unknowns |

`semanticIndex:nil` still retrieves lexical evidence. Recent-only must therefore be an explicit preparation strategy. Its checks must establish the absence of historical source work and query encoding, including when a usable semantic index exists. Empty returned evidence alone is insufficient evidence of that behavior.

The coordinator accepts synchronously before preparation starts. The host can finish draft/preference persistence and establish transcript callbacks, then call `start()`. Its original lease and identifiers remain available for Stop/deadline fencing. Cancelling or failing host persistence before start terminalizes the accepted attempt without dispatching inference. Stale prepared bodies, receipts and answer work cannot carry into a new attempt.

Every visible delta commits to the invocation journal before the host receives it. Cancellation and failures preserve armed unknown charges and output holds. Operational completion depends on transport, accounting and durable capture. A complete incorrect answer remains a completed captured answer with a separate task score of zero. Scoring cannot change episode or invocation state.

## Execution

```sh
python3 scripts/test_answer_evaluation.py --binary "$PWD/.build/boros/Boros.app/Contents/MacOS/Boros"
python3 scripts/evaluate_answers.py --output .build/evaluation/public-answer-pilot.json
```

The first command uses controlled transport. The second compiles an immutable copied source inventory, then uses the configured local Qwen endpoint. The output must be new. An exact configuration JSON may change the supported generation settings and loopback endpoint; credentials are not accepted. The system instruction defaults to the production GUI instruction. All source/compiler/binary, generator, corpus, instruction and configuration hashes are retained.

The original pilot accepts the pinned oracle-free projection of one public development history: 31 events, 123,572 source bytes, nine probes and both strategies, totaling 18 attempts. The projection digest is `6ca035c6bb87f23b75c59c8529a0181667e8ece0cc838056139d009f0c501bb4`. The native allowlist additionally accepts the three separately frozen projections in the [N3 public developer-history amendment](DEVELOPER-ANSWER-EVALUATION.md). Direct CLI invocation cannot substitute arbitrary chat text, remove probes or introduce oracle fields. Runtime histories and answer IPC stay in private temporary directories and are discarded after scoring; the final report contains no prompts, answers or expected values.

## Diagnostic scope

Begin with one public development history and all its probes, paired across both strategies. Execution must refuse validation/held-out splits, arbitrary user-store paths, existing output destinations and unknown input/configuration fields. Historical preregistration, v1–v4 source pins and held-out artifacts remain unchanged.

Use one common frozen system instruction and generation configuration for both arms. The first diagnostic uses the production free-text instruction and a deterministic scorer only for factual probes with explicit expected values. Keep abstention, quoted-policy attribution, whole-record completion and citation correctness unscored until their rubrics are frozen. Preserve those attempts and their operational outcomes. Missing task dimensions leave the complete five-category quality gate inconclusive; available categories are not renormalized into a product-quality score.

This diagnostic establishes that the production measurement path works. Representative workloads, provider-budget feasibility, independent histories, repeated answering, cache schedules, economics, power and held-out confirmation remain required for the plan's quality decision.

## Runner and oracle separation

The version-1 paired answer runner receives history events, question, public probe ID, scope/conversation mapping, strategy and generation settings. It receives no gold spans, expected answers, targeted search queries, sufficient-evidence witnesses or grading rubric.

The separately pinned version-2 [sufficient-evidence control](EVIDENCE-CONTROL.md) intentionally supplies curated complete original exchanges. It retains oracle separation and the shared production lifecycle. Its packs and scores remain separate from paired retrieval inputs and denominators.

Version 3 supplies the separately allowlisted provider JSON-object amendment for those same nine packs. Only its exact `response_format: json_object` configuration and separately pinned version-3 projections are accepted. Version-1 and version-2 inputs continue to reject that field. Original questions, strict rubrics, System text, source bytes and caps remain fixed. The shared path counts the provider's added mandatory instruction and preserves actual body/source/count evidence through capture, reopen and archives; output format and task accuracy are scored separately after terminalization.

The model receives only the production request body. No filesystem, SQL, source-dump, shell, MCP or additional HTTP tool is enabled. Host ingestion supplies the synthetic corpus; shared production preparation is the source-selection path. Focused access/accounting tests must catch accidental historical reads in recent-only and unmetered helper use.

The scorer receives its oracle after operational terminalization. Answer text is transient private IPC or memory, absent from logs and reports, and discarded after scoring. Report answer length/digest, rubric version, scores or unavailable reasons, source-range coverage and authoritative accounting. A wrong-answer score must not make the invocation look like a transport failure.

## Isolation and index construction

Create an immutable ingested corpus checkpoint with exact source bytes, timestamps and order. Each `(history, probe, arm, replicate)` receives a disposable restored store. Question/answer overlays remain isolated so later probes cannot see earlier answers. Report overlay event/byte counts separately.

Main-store archives exclude the derived semantic sidecar. The first executable diagnostic builds the real Apple index inside each hybrid attempt before answering. Stop construction at the real budget, pause or quarantine; record partial coverage. A fresh store or simulated clock must not be used to manufacture complete coverage after a cap is reached within an attempt.

Repeated construction is experimental spend and must be reported explicitly. A later experiment reusing one build needs a consistent main-plus-derived snapshot contract. Schema-5 restore preserves archived accounting only; it does not merge later charges or provide external budget rollback authority.

Keep maintenance quiescent during the answer measurement. Do not index the disposable question/answer overlay into the baseline corpus. Hybrid uses the actual scoped semantic-plus-lexical selector with the question. Fallback and incomplete coverage remain observed outcomes.

## Configuration and reports

Capture copied-source, driver, scorer, generator and corpus hashes; strategy and order; requested endpoint/model and observed provider/template identities; common instruction digest; temperature, seed, thinking and output cap; context/safety bounds; selected-Qwen component policy; episode/background caps; and construction schedule. Credentials remain outside this manifest. Git revision supplements exact source hashes.

For each attempt, record:

- Preparation and admission proof identities, mandatory/recent/evidence/whole-request counts, reductions and failure stage.
- Authoritative episode state, charged/held/unknown resources, provider usage and capture result.
- Background construction inventory, fingerprint, frontier, work outcome and coverage.
- Continuous-clock preparation, first durable delta, provider completion, finalization and full-host timings; separate oracle time.
- Task score or unavailable reason, delivered-range coverage, answer digest/length and overlay counts.

All failures remain in the declared denominators. Partial/noncompleted answers score zero for otherwise scorable factual tasks. Missing usage remains unknown. Apple query/background input tokens remain opaque even when the Qwen prompt count is exact. Local billed cost is unknown. First visible delta does not establish first useful answer.

Actual delivered gold coverage can be scored after completion. It does not establish that sufficient evidence fits the frozen provider budget. The separate complete-exchange control counts and validates its entire witness through ordinary recent-only preparation; that witness remains unavailable to paired retrieval. General feasibility beyond component allocations still needs a funded whole-render measurement contract without an admission grant.

## Verification and publication gates

Before model calls, verify shared preparation parity, actual source access, one original lease, proof/body linkage, durable streaming order, cancellation/late callbacks, failed capture, incomplete provider results, wrong-answer operational completion and content-free output with public fixtures and controlled transport.

Integrate the coordinator into the GUI and diagnostic before claiming a production-path comparison. Rebuild and run the applicable app/archive checks. Then run the one-history paired diagnostic against the configured Qwen endpoint, preserving the exact report and all failures. Review the diagnostic before expanding or registering a quality comparison.

The optional summary tree remains gated by the complete measured baseline and the original decision criteria in [EVALUATION.md](EVALUATION.md).

## Recorded pilot

The matching-source application passed 2,162 checks and strict deep development signature verification. The controlled native driver passed all 18 isolated attempts with deliberately wrong answers remaining operationally complete; GUI success and Stop after a durable chunk also passed.

The live report `.build/evaluation/public-answer-pilot-20261005.json` retains all 18 attempts: recent-only completed 7/9 operationally and hybrid completed 8/9. Literal factual successes and delivered gold coverage were 1/6 for recent-only and 6/6 for hybrid. Each arm also retains three unscored probes. The first recent-only calibration/admission failed with `provider_admission_unavailable` and an unknown one-token output hold. Hybrid whole-record and recent-only absence attempts reached the generation cap and preserved partial output as `incomplete_result`.

This one-history, one-replicate diagnostic uses fixed strategy order and uncontrolled caches. Literal expected-marker presence is narrower than semantic answer correctness. The full quality gate remains inconclusive. The next packages are independent developer-history cases, frozen missing rubrics, admission failure attribution and representative scaling; [STATUS.md](STATUS.md) records details and exact report identity.
