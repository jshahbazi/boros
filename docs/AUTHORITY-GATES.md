# Shared authority gate implementation contract

October 5, 2026. This is the next N6 implementation contract derived from [plan section 3](../tracechat-plan.md#3-architecture-and-boundaries). The [schema-7 bindings and conservative funded validator](AUTHORITY-BINDINGS.md) and [internal cache/session recipe](AUTHORITY-VALIDATION-CACHE.md) are implemented. Bootstrap scan metering, complete consumer proofs, the shared consumer boundary and policy renderer remain unfinished. The [authority state kernel](AUTHORITY-STATE.md) remains unexposed. Existing episode cancellation, scope checks and background publication gates enforce narrower contracts.

## Durable binding

Use an immutable accepted-episode binding and a separately immutable prepared-work binding. Dependencies discovered during retrieval belong to the prepared binding; do not rewrite the accepted episode baseline. Each managed episode, work request and generated invocation must carry a canonical, versioned control binding. The binding includes the store and startup receipt identity (a Mach boot clock domain cannot identify one owner process), control epoch, accepted request identity, project/conversation/task and task revision, applicable policy identities/revisions, complete input source and artifact identities/versions/scopes, selected processing route and authorization receipt. Private input bytes remain in their existing evidence/snapshot records; binding digests do not require a new public prompt copy.

Source dependencies include mandatory accepted input, policy-source evidence, retained recent messages and every delivered historical span. Derived inputs include their transitive original dependencies. A renderer/count proof binds the actual request to this complete dependency set. A source ID, role label or cursor supplies no permission by itself. Historical source epochs describe provenance; new authorized operations can read eligible older sources.

Human acceptance and initial task creation/selection must commit atomically with the complete human event, episode resource totals and resulting control binding. The [task default](../tracechat-plan.md#task-identity-and-lifecycle) creates and selects an active task on the first authenticated human turn when none is selected; subsequent turns keep that selection. A suspended or closed selected task requires an explicit lifecycle/selection operation. Check exact acceptance retries before creating another task; return the original binding and allowance without refreshing authorization. Overdue expiry commits separately under the same owner lock and survives a rejected acceptance. Imported human-role text creates no authority. Explicit administrative task/policy commands require the authenticated human-owner capability and retain complete accepted content. Task completion, suspension, cancellation and policy conflict/expiry affect eligibility before any new managed boundary.

Schema 7 now uses a separately frozen complete schema-6 DDL recognition contract and explicit legacy binding classifications. Migration must preserve existing capture/accounting evidence and identify historical records without inventing past authorization. Classify historical episodes, work and invocations explicitly as `legacyUnbound`, retain their request/snapshot/admission bytes, recover existing uncertain work conservatively and grant no fresh dispatch. New managed records require bindings. Restore retains those bindings as historical provenance; startup makes them stale instead of rewriting them.

## Prerequisites for repeated boundaries

The implemented diagnostic consumes four memory operations and about 20,000 initial metadata rows before replay costs. With current development caps of 24 memory operations and 100,000 metadata rows, it cannot fund every streamed chunk. Do not increase those caps to conceal repeated validation cost.

The implemented internal cache retains paid owner-private current-state evidence, its immutable authority anchor, state/tail, policy-source descriptors and earliest temporal boundary. It binds owner/startup, external SQLite `data_version` and audited connection write generation. Arbitrary historical anchors remain the offline resolver's responsibility. External commits, unknown writes, failed transactions, control transitions and source/binding/schema changes invalidate reuse. Narrow accounting/chunk manifests preserve only domains they do not change.

Repeated checks use separately prepaid sessions under the original allowance: at most 256 attempts per session, four live sessions, 4,096 proof descriptors and 16 MiB retained canonical evidence, with existing independent record limits. Lower-only internal limits are enforced. Denied attempts consume counters and retain charges; same-ID retries cannot reset permission. Warm checks use indexed lifecycle and fixed-point clock probes. These are canonical evidence limits, not physical heap measurements. Offline archive/reopen validation remains unchanged. The inherited reserve/arm bootstrap still includes a global quarantine scan and per-episode aggregates outside fixed metadata prepayment; closing that metering gap is required before live consumers.

Initialization now checks cancellation/progress during SQLite replay and CPU source hashing; busy-lock waits consult the same independent original fence. Cold replay still holds the owner mutex. A future outside-lock reader must establish its consistent snapshot under the owner's write fence and recheck owner generations and the owner's `data_version` before publishing the proof. Never compare witnesses from different connections. Actual bounded acceptance/delivery must remain inside the final owner/write fence; a cached receipt used afterward grants no permission.

If overdue maintenance cannot be funded by the attempted episode, deny content. Commit and acknowledge a temporal transition only when it has an explicit funded sponsor. The eventual human/control-maintenance allowance contract remains to be implemented; exhaustion cannot justify an unfunded source replay or a claim that expiry committed.

Background work currently lacks an authority anchor. Freeze schema-7 recognition before adding background bindings or durable invalidated-capture reasons. Maintenance needs an explicit project/global policy scope, original background allowance and migration with historical classifications; it must not invent an authenticated human task. Global epoch changes conservatively invalidate old maintenance bindings.

## Boundary protocol

One `MemoryStore` owner gate coordinates every managed dispatch, page/result delivery, visible chunk and derived publication:

1. Refresh validated time and commit overdue expiry under the gate, preserving monotonic high-water behavior.
2. Validate the binding's epoch, task/policy revisions, complete dependency permissions/liveness and selected route. Charge bounded validation work before source inspection; full unmetered journal replay is unsuitable for a repeated interactive boundary.
3. Arm durable resource accounting where required, then accept one bounded tracked operation before releasing the gate.
4. Perform inference, source materialization, hashing and transport waits outside the gate.
5. Revalidate at actual content delivery/publication. Retain authoritative usage settlement even when payload acceptance is denied.

Validation cannot fund itself through public `lease.prepare/dispatch` inside a handoff gate: that recurses into the gate. Schema 7 supplies private owner reserve/charge/settle primitives and a conservative four-phase `authorityValidation` recipe; its diagnostic receipt grants no boundary permission. Charge metadata inspection before control/source metadata access, then reserve checked raw-byte costs before original payload inspection. The current proof avoids repeated pure-clock replay, and sessions prepay bounded warm checks. Accounting bootstrap scans remain an explicit metering gap. Exhaustion prevents acceptance while preserving charges already incurred.

A control mutation closes admission, resolves currently accepted bounded boundaries, commits its state and epoch, invalidates queued bindings/cancellation signals, then acknowledges and reopens admission. After acknowledgement, no new dispatch, local content delivery or publication from an older epoch can begin. Requests already accepted by a processor and bytes already delivered retain that recorded boundary.

The owner uses an `NSRecursiveLock`. A transport-start or delivery callback must not synchronously acknowledge a reentrant authority mutation halfway through its boundary. Reject it with a fixed retryable code or queue it as a separately owned human operation. Stop's immediate cancellation signal remains separate. Test the ordering explicitly.

Callbacks under the gate must perform bounded acceptance or delivery only. An empty callback followed by an untracked encoder call or queued sender leaves a race. Queue-based adapters must own cancellation and stale-job rejection through actual acceptance; adapters without this contract cannot participate in the managed path. Gate operations must not acquire a sidecar mutex while holding the main owner gate.

## Required consumer changes

| Consumer | Current boundary | Required change |
|---|---|---|
| `MemoryStore.performEpisodeHandoff` | Durable arm and bounded `start` under owner mutex | Validate control binding before arming and immediately before tracked acceptance; preserve quarantine, charges, holds and original deadline |
| Qwen discovery/count/calibration/answer transport | Tracked `URLSessionTask.resume()` through lease dispatch | Bind exact body, route and complete dependencies to each accepted operation |
| Foreground semantic encoder | `MeteredRetrieval.charge` arms an empty handoff before running its body | Owned encoder adapter with bounded acceptance and cancellation of queued stale work |
| Background semantic encoder/probes | `SemanticIndex.beginBackground` arms before later `encode` | Same owned acceptance contract under background allowance, including empty-source completion and probes |
| Native model transport | `Process.run()` is gated; full stdin write follows outside the gate | Bind the rendered payload before launch; owned bounded nonblocking stdin delivery and cancellation, with delivered-byte boundary recorded |
| Visible answering | Coordinator checks, commits chunk, then invokes `onText` | Durable commit and actual bounded visible delivery inside one control boundary; apply to native GUI capture too |
| Assistant-event finalization/recovery | Publishes committed chunks as an event | Explicit invalidated capture termination; preserve accepted prefixes, discard late bytes and prevent fresh stale event publication |
| Local read/search/page completion | Checks generation and deadline on delivery queue | Validate control binding and exact delivered sources at callback acceptance, including budget-limited results; epoch-bound cursors |
| Semantic sidecar publication | Sidecar mutex held before main-owner publication gate | Retain sidecar-to-owner lock order, revalidate before commit, use invalidation signals and later cleanup |

Invalidated prepared work releases only unused holds where no handoff is established. Armed/submitted work retains conservative charges and unknown output bounds. Late authoritative usage and provider-violation evidence can settle without reopening the episode, stream, task or authority. Context rebuilding retains the original episode allowance and recounts changed mandatory task/policy content.

Previously delivered prefixes remain accepted evidence. The mutation/finalization contract must identify when those prefixes are sealed before acknowledgement and how an interrupted invalidated capture remains inspectable without fresh stale publication after acknowledgement. Imported and already terminal historical captures retain their stated provenance and compatibility boundary.

## Verification and enablement

Contract/schema work precedes concurrent consumer edits. Root owns the owner/lease/binding integration; independent agents can then own answering/native transport, local-read delivery and semantic/background acceptance. Resolve shared APIs, accounting recipes and lock order before concurrent edits. An independent reviewer checks race schedules and archive/restart behavior before explicit human commands or UI expose mutation.

Required controlled schedules include mutation after preparation but before dispatch; between encoder arming and actual acceptance; between native launch and stdin delivery; between chunk commit and UI delivery; inside a reentrant callback; while a page or budget-limited search waits on its queue; before sidecar commit and after commit before settlement; overdue expiry with delayed scheduling; startup/restore followed by stale callbacks; task completion/reopen with old prepared bindings; and rebuilding that exhausts the original allowance. Each test must establish both payload fencing and retained accounting.

Remote processing/disclosure, suppression/purge, deletion-aware restore and external actions retain their separate contracts. Optional trees still require accepted baseline evidence. Passing this gate suite establishes the scoped task/policy boundary only; the full architecture and release gates remain outstanding.
