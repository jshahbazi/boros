# Durable authority state foundation

October 5, 2026. Main-store schema 6 adds an internal task and standing-policy state kernel. It is not exposed through the GUI, CLI, imported documents or model output. Existing answering, source browsing and background indexing do not yet consult this state. Runtime enforcement and user-facing lifecycle operations remain unfinished.

## State and human operations

The owner persists a store identity, local owner identity, control epoch, authority revision, clock high-water mark, tasks, conversation bindings, policies and an append-only operation journal. These are independent of episode budget revisions. Startup advances the control epoch before existing recovery paths expose the store. Ordinary accepted chat and index work do not advance it.

The internal operation contract supports explicit task new, select, suspend, resume, complete, cancel and reopen operations. Task selection binds an existing conversation in the same project. Policies have global, project or task scope, explicit rule/value fields, optional exact source spans, effective time, expiry, until-task-complete lifetime and explicit supersession. Proposed policies require human activation. Imported human-role text, quoted text, documents, model output and subagent output cannot create or activate authority through this contract.

The host supplies a nonserializable `AuthorityContext`; request JSON cannot supply human origin or owner capability. The initial owner identity is `local-owner:<effective UID>`. This represents the exclusive local owner, with no external-client authentication or portable owner reassignment contract. A future service must authenticate the caller before constructing this context.

Mutations require the expected global revision and relevant task/policy revision. An exact request-ID retry returns its original receipt; reuse with different request bytes fails. Receipts bind the request, prior and resulting state digests, revision, epoch, journal sequence and expired policy IDs. Limits fail transactionally. Sources are checked against original scope, complete UTF-8 payload, full digest and exact bounded excerpt digest. Policy text and source content remain private store data.

## Resolution and lifecycle

Resolution selects task scope before project scope before global scope. Different active values for the same rule at the same scope create an explicit conflict. Any applicable conflict blocks resolution, including a conflicting lower scope shadowed by a higher one. Suspended and terminal tasks block task resolution. Conflict is computed from active records; it is not a separate persisted policy state.

Completing or cancelling a task expires its until-task-complete policies in the same transaction. Suspend makes task policies dormant; resume restores eligibility of still-active policies. Reopen does not revive expired, revoked or superseded records. An explicitly permanent task preference can become eligible again on reopen. Renewal of a terminal policy requires a new policy ID and a new explicit human operation. No operation grants external-action authority.

Validated clock advances use a monotonic durable high-water mark. Moving the wall clock backward cannot revive expired policies. Due expiry or scheduled activation commits before a subsequent authorized mutation is attempted, so a rejected mutation cannot roll back expiry. Temporal changes advance the authority revision and control epoch. Clock-only advances retain those values and append a time receipt. Unauthorized callers are rejected before this clock work.

## Integrity, migration and backup

Schema 6 requires the exact authority table and implicit-index definitions, canonical bounded state/request/receipt bytes and digests, sequential replay and agreement with every materialized record. Extra authority objects, triggers or custom indexes attached to authority tables, changed constraints, missing records and contradictory receipts fail validation before current-store installation. Digests establish consistency; they do not authenticate an archive against an actor able to replace all of its contents.

Prototype schemas 1–5 migrate to an empty authority foundation. Historical chat roles create no task or policy. Historical schema-5 recognition uses a separately frozen complete DDL contract from the verified pre-upgrade application. Existing foreground and background accounting survives migration.

Schema-6 archives include authority inventory and validate the complete journal. Restore preserves its records and requires exactly one startup epoch/revision/journal advance in private staging before publication. Opening the restored store later adds another startup advance. The archived clock remains the durable high-water mark until the caller supplies a new time. External deletion-ledger application and antirollback authority remain separate unfinished contracts; restoring this state does not establish deletion safety.

## Bounds and remaining integration

The kernel allows 4,096 records per state collection, 8,192 journal operations, a 64 MiB journal, a 4 MiB canonical snapshot, 64 KiB canonical requests and 16 source spans per policy. Each increasing clock observation consumes a journal entry. Continuous gates therefore require a durable clock checkpoint/compaction contract before using this journal operationally. The next proposed amendment introduces a new versioned, mutable final pure-clock checkpoint: repeated observations with no temporal transition can replace it atomically, while a later human operation, startup or actual temporal transition freezes it. Existing v1 receipts stay immutable. This proposal is unimplemented and requires replay, retry, quota, corruption and crash tests; intermediate no-effect clock samples would no longer be retained. Full replay also rereads source proofs; its CPU and source-work cost is not metered by an episode allowance yet.

Required next work includes task binding on human acceptance, operation/event/invocation provenance, a bounded policy renderer, route/source dependency grants, and one serialized gate for dispatch, page delivery, visible output and derived publication. Work must capture the epoch and dependency revisions; invalidated late payload must be discarded while authoritative usage can still settle. Cancellation and episode accounting already have narrower fences and cannot substitute for these authority gates. Policy mutation stays unexposed until their race, restart, expiry, conflict and adversarial tests pass.

The self-test entry point is `--authority-state-self-test`. It creates isolated synthetic stores and reports fixed check names and booleans. Verification results are recorded in [STATUS.md](STATUS.md).
