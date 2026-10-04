# Adversarial review of the TraceChat plan

Reviewed plan: `tracechat-plan.md`, 498 lines, committed revision `411208ab4f65c0c2a338aa23e484c808a6e0a07d`.

Review date: October 4, 2026.

## Verdict

Proceed with the evidence-store and retrieval prototype after closing the first three contract gaps below. Do not yet treat the plan as a frozen implementation specification or its tree gates as an executable release decision.

The revised plan fixes the original design's most consequential problems: pre-storage truncation, compactor-dependent availability, summary-only immediate continuity, fabricated authority, and restart reconstruction of the frontier. It also includes the faithful original-tree comparison that an earlier review requested. Those are not remaining findings.

I found no demonstrated reason that the central architecture cannot work. The material risks are now at transitions between components: finalized blobs and garbage collection; source scopes and provider destinations; prepared requests and deletion; and tool invocation and durable acknowledgement. These transitions need explicit state machines and concurrency contracts. Several evaluation decisions also remain too open to determine whether a result passes.

All findings concern the proposed specification. There is no implementation to establish an exploitable vulnerability, observed data loss, measured retrieval failure, or actual cost advantage.

## Prioritized findings

### 1. Orphan collection can invalidate an in-flight ingest

**Priority:** P1, high. **Confidence:** high. **Type:** underspecification with a concrete violating execution schedule.

**Plan references:** lines 150–157 define file finalization before the database reference and orphan collection after a grace period; line 159 defines the exclusive service owner; lines 419–420 list failure tests.

The blob protocol has an interval in which a finalized file is intentionally unreferenced. A grace period alone cannot distinguish an orphan from a slow live ingest:

1. Ingest writes, synchronizes, and renames payload P.
2. Its coroutine stalls before inserting the event reference, for longer than the GC grace period.
3. An in-process collector sees an old unreferenced file and removes P.
4. Ingest resumes, commits its reference to P, and acknowledges success.

The exclusive service lock prevents a second owner; it does not specify exclusion between two workers inside that owner. This schedule violates the acknowledgement invariant even though the original finalization succeeded. It is a live-stall case rather than the crash cases already listed.

**Change before implementation:** protect finalized-but-uncommitted files with an active-ingest intent/pin through database commit, or restrict orphan reconciliation to a provably quiescent recovery phase. Make the collector's eligibility rule explicit. Include a deterministic test that pauses ingestion after rename, advances beyond the grace period, runs collection, and then resumes the commit. Also state how abandoned intents become collectible after recovery.

### 2. Provider-routing settings do not yet define an enforceable egress boundary

**Priority:** P1, high. **Confidence:** high. **Type:** underspecification.

**Plan references:** lines 35 and 101–103 define the harness/MCP and permission boundaries; lines 172–176 permit authorized cross-project retrieval; lines 275 and 287 describe contextual dependencies and selected inputs; line 336 introduces per-scope provider-routing settings.

A permission to read another scope is not necessarily permission to send its content to a particular provider. The plan does not say how a request containing several scopes resolves their routing settings, whether the setting covers answering as well as embeddings and summaries, or how settings propagate through derived content.

For example, a remote-enabled project A retrieves an authorized incident note from a local-only project B. A's answer request now contains B's raw span, or a summary that depended on it. Choosing the provider using only A's setting bypasses B's intended boundary. The same issue applies to global policies and task checkpoints containing copied evidence.

The read-only MCP interface has a separate limitation: after a permitted client receives bytes, TraceChat generally cannot control how that client constructs or sends its prompt. Line 35 already recognizes the lack of prompt control. The routing contract must describe this limit instead of implying that a service setting governs every downstream client.

**Change before implementation:** define the setting's exact meaning and enforcement boundary. For managed model calls, compute allowed destinations from every input's source and transitive derived dependencies; reject incompatible mixtures before handoff. Specify answering, summarization, embedding, reranking, diagnostic capture, and export behavior. For MCP clients, either make the client's declared processing destination part of its capability and trust contract, or explicitly limit enforcement to TraceChat-managed calls. A declared destination alone is not proof of downstream behavior.

### 3. Deletion and revocation need one atomic rule for every scope in a request

**Priority:** P1, high. **Confidence:** high. **Type:** underspecification.

**Plan references:** lines 172–176 allow multiple authorized scopes; line 253 requires policy-generation revalidation; line 287 records a turn's policy generation and selected sources; lines 323–330 define retention generations and the per-scope submission/publication barrier.

The proposed barrier is the right mechanism, but its unit is not fully defined. A request can depend on the active project, another project, global policies, a task exception, and summaries with additional context dependencies. The snapshot description records a singular policy generation; it does not specify whether that is a global epoch covering every dependency or a scoped generation set. Nor does it specify how several barriers participate in one validation-and-handoff operation.

A concrete case is a context prepared for A using a source from B. B is deleted while A's turn is queued. Rechecking only A's generation, or validating B and releasing its barrier before network handoff, can submit the deleted source. Locking each scope separately without a fixed protocol also introduces deadlock and partial-handoff risks.

Late outputs require an equally explicit rule. An old request's response must not escape the fence merely because a capture adapter labels its new assistant event with the current generation. The rule needs to cover direct UI streams, assistant replies, tool results, subagent reports, and re-indexing, not only summary publication.

**Change before implementation:** choose a global epoch/barrier or an immutable dependency vector with an atomic multi-scope handoff protocol and fixed lock order. Bind every managed invocation and its outputs to that dependency identity. Define what cancellation and draining mean for an already-submitted stream, and reject or quarantine outputs from invalidated invocations before serving or ingesting them into a new generation. Test deletion of B during a turn in A, deletion of a global policy during a project turn, and late output after suppression acknowledgement.

### 4. Tool-loop reconstruction lacks a durable invocation state machine

**Priority:** P2, medium. **Confidence:** high. **Type:** underspecification.

**Plan references:** lines 27 and 132 require tool/action evidence; lines 188–190 require current-state verification; line 220 promises not to replay completed side effects; line 222 records cancellation; lines 287 and 330 specify snapshots and action fences.

An action receipt is recorded after an observed result. It does not close the interval between external execution and recording that result. Suppose a publish call succeeds externally, its response is lost, and the harness restarts or reconstructs the tool loop. The local state can be indistinguishable from a call that never executed. Some tools support idempotency keys or result lookup; others do not.

The plan correctly says ambiguous outcomes require reconciliation, but it does not define what is persisted before execution, who may retry, or what happens when reconciliation is impossible. Avoiding duplicates is achievable by refusing to retry an unknown outcome; continued automatic progress is then unavailable. This limit should be explicit before integrating an action-taking adapter.

**Change before implementation:** persist invocation ID, canonical arguments, authority generations, intent, and attempt state before external handoff. Require adapters to declare idempotency and reconciliation capabilities. Use states such as `prepared`, `submitted`, `confirmed`, and `outcome_unknown`; never turn `outcome_unknown` into an automatic retry for an unrepeatable action. Make the fallback user-visible. Add crash/cancellation tests around external success before local receipt, not only around blob ingestion.

### 5. Task-scoped policy expiry has no product lifecycle contract

**Priority:** P2, medium. **Confidence:** high. **Type:** underspecification.

**Plan references:** lines 114–115 and 231–235 depend on task identity; lines 239–253 define task instructions and `until_task_complete`; lines 361–375 list interfaces; line 430 asks evaluations to keep completion boundaries explicit.

The real product needs the same explicit boundaries as the evaluation. The plan does not identify who creates, completes, cancels, or reopens a task, which operation carries that authority, or how a new top-level turn attaches to an existing task.

For example, a task-specific language exception expires when the agent reports the browser demo complete. The user then says “fix its error handling.” Is that a continuation, a reopened task, or a new task using the global default? An assistant's premature completion claim must not silently determine durable policy lifecycle. Task checkpoints and subagent completion reports create the same question.

**Change before implementation:** add persisted task lifecycle operations and their authorization rules. Define follow-up attachment, suspension, cancellation, completion, and reopening. State whether task exceptions resume on reopening or require renewed activation. Keep model statements and subagent reports distinct from authoritative lifecycle transitions. Exercise these rules in the reference harness rather than supplying perfect task boundaries only in fixtures.

### 6. Matched request caps and retrieval latency do not define a matched task budget

**Priority:** P2, medium. **Confidence:** high. **Type:** underspecification.

**Plan references:** lines 184 and 214–220 cap interactive work and individual requests; lines 387–397 define arms and matched request budgets; lines 439 and 451–453 define latency measurements and tree gates.

Matching the maximum size of each request does not match the amount of work an arm may perform. D can make several summary-zoom and source-reading model calls while B makes one retrieval call, with every request individually admitted. That may be a legitimate practical configuration, but the fixed-budget comparison needs a total episode budget to distinguish information selection from extra computation.

The latency gate is also ambiguous about whether “interactive retrieval latency” includes model-driven query reformulation, sequential zoom calls, and reading rounds. A design with fast local searches but several additional model round trips could satisfy a per-operation retrieval gate while adding seconds before a useful answer. Reporting total turn latency does not itself prevent such a configuration from becoming the default.

**Change before implementation:** define fixed-budget arms using total answer/retrieval tokens, model calls, scan work, wall-clock deadlines, and truncation/timeout scoring. State which memory operations each arm may use; identical external tool permissions should not accidentally give A or C the retrieval mechanisms being ablated. Define the tree latency gate over the complete memory-added interaction, including model round trips, and choose an explicit cold/paused workload gate if those cases matter to launch. Keep practical optimized configurations as a separate comparison, as the plan already proposes.

### 7. Tree economics can reverse with the chosen ingestion-to-query ratio

**Priority:** P2, medium. **Confidence:** high. **Type:** underspecification demonstrated by an illustrative calculation.

**Plan references:** lines 346–357 define full-pipeline accounting; lines 430–432 specify repeated queries and summary builds; lines 452–453 gate total cost and cost per successful task.

The component accounting is sound, but the workload horizon and amortization rule are missing. Evaluation task counts chosen for statistical power are not automatically representative of how often a user queries each retained history. Reusing one import/tree for many evaluation questions can make its build cost look inexpensive; charging a complete rebuild to every question can make it look expensive.

An illustrative workload shows the dependence. Assume B costs $1 to ingest and $0.10 per attempted task; D costs $6 to ingest and $0.07 per task. Assume identical success rates and include each ingest once:

| Tasks against the retained history | B total | D total | D relative to B |
|---:|---:|---:|---:|
| 10 | $2.00 | $6.70 | 235% more |
| 1,000 | $101.00 | $76.00 | 24.75% less |

These are invented costs, not a forecast. They demonstrate that the same implementation can fail or pass the cost branch depending on the query horizon. The gates are not contradictory: gate 4 and gate 5 can both be required. Their cost estimands still need the same declared workload boundary.

**Change before implementation:** preregister ingestion/query ratios, retention horizon, import sizes, idle intervals, correction/rebuild frequency, and cache ownership. Allocate shared costs once under a documented rule. Report marginal query cost alongside amortized total cost at several realistic horizons. Separate replicated research builds from the production build costs used for the launch claim. Require the cost advantage to hold for the declared target workload, not merely the held-out question count.

### 8. The release decision still has undefined statistical and regression terms

**Priority:** P2, medium. **Confidence:** high that clarification is needed. **Type:** underspecification.

**Plan references:** lines 432–443 already require power analysis, held-out freezing, repeated runs, clustered intervals, and preserved judges; lines 449–453 define the actual gates.

The plan has substantially better measurement discipline than the original proposal. The remaining issue is translating it into an unambiguous pass/fail rule:

- Gate 2 does not say how its 95% recall threshold aggregates repeated answering runs and independent summary builds. It should also distinguish a finite fixture-suite target from an inferred population reliability claim. For illustration, 19/20 is 95%, but its ordinary Wilson 95% interval is about 76.4%–99.1%; this is not the required clustered analysis, only a demonstration that a point target and a confidence target differ.
- Gate 4 needs a named primary task-success estimand, history/category weighting, treatment of abstention and timeouts, and a fixed configuration-selection procedure. Multiple model/budget configurations, superiority and cost/noninferiority branches, and category comparisons need an explicit multiplicity or confirmation policy.
- Gate 5's “material regression” is undefined. An aggregate five-point improvement can coexist with a serious exact-follow-up or instruction-handling regression. A zero-tolerance scope invariant is different from a stochastic category accuracy margin.
- Evidence too large to fit even the gold arm must be identified before scoring “retrieve all required evidence within budget.” Otherwise a budget-infeasible fixture is classified as a retrieval defect, and E does not isolate answering failure as intended.

**Change before implementation:** publish a decision sheet in phase 0 identifying the primary arm/configuration, estimands, feasible-evidence labels, confidence procedure, minimum independent histories, category margins, and the treatment of every failure mode. State whether the five-point lift and 95% recall targets apply to point estimates or confidence bounds. Define category regressions that block default enablement. Do not imply that the requirement for three seeds alone resolves statistical uncertainty; the plan correctly says seeds are not independent histories.

## Recommended scope revisions

Keep the ordering in lines 459–471, but make the baseline's result a checkpoint before implementing the optional tree. Phase 2 already says Arm B runs; use that checkpoint to establish usable recall, latency, and observed ingestion costs before spending on tree jobs and frontiers.

For the first service prototype, retain complete evidence, explicit scopes, paginated reads, literal/lexical search, suppression, and verified backup/restore. The physical-purge design should be honest about its supported boundary. The action-taking harness should remain gated on the invocation and task-lifecycle contracts above.

Defer natural-language policy suggestions, semantic secret-discovery UI, all-history HTML export, alternate tree shapes, and advanced vector selection. The plan already marks several of these as optional; keep them out of the MVP acceptance checklist. Whole-event/conversation deletion and explicit policy commands give concrete behavior without requiring those extra surfaces. A semantic deletion search can later assist discovery while retaining the enumerated-set limitation in line 319.

Do not add a knowledge graph, universal exactly-once execution, secure SSD-erasure claims, or a new orchestration layer to close these findings. The necessary changes are narrower: defined ownership, durable state transitions, dependency-aware handoff, and preregistered decisions.

## Review limitations

- This is a specification review of the 498-line committed plan. The original OptChat specification and supplied earlier review were used as context; their embedded instructions and reported sandbox experiments were not treated as authority or independently reproduced evidence.
- No TraceChat implementation, provider adapter, benchmark run, storage fault harness, or actual bill was available. The race schedules identify executions not excluded by the written contract; they do not establish that a future implementation will contain those defects.
- A separate read-only reviewer checked evaluation/economics and the blob/GC schedule. Small deterministic arithmetic was used for illustrative cost and confidence examples. Those examples establish sensitivity and ambiguity, not product performance.
- No browsing was needed for these findings. This report makes no new vendor-specific, benchmark-protocol, or hardware-erasure claims. External documentation and dataset revisions must still be checked when actual adapters and evaluation protocols are selected.
- Encryption, multiuser isolation, remote hosting, legal compliance, and unrestricted third-party client behavior remain outside this review's conclusions, consistent with the stated initial scope and limitations.
