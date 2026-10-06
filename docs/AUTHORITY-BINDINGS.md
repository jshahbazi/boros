# Dormant authority bindings and funded validation

October 5, 2026. Main-store schema 7 adds internal immutable episode, work and invocation bindings. Ordinary GUI answering, source browsing and maintenance still use their existing legacy contracts. Task/policy commands remain unexposed. A validation receipt grants no dispatch, delivery or publication permission. The remaining integration contract is in [authority gates](AUTHORITY-GATES.md).

## Acceptance and provenance

`acceptManagedHumanRequest` requires a host-created human-owner capability. It atomically commits complete accepted human text, the original episode allowance, task creation/selection and a versioned binding. The first managed turn creates/selects a task when its conversation has none. Later turns retain the active selection; suspended or terminal selections require an explicit operation. New/select intents retain exact request identity and CAS requirements. Conflict or a rejected task operation rolls back the complete acceptance. Authorized due expiry commits separately before acceptance and survives a later rejection.

An exact acceptance retry returns the original binding and allowance, including after startup or another control mutation makes that binding stale. It cannot refresh authorization or replenish resources. Imported human-role text cannot construct the capability. `acceptManagedLocalRead` creates no conversation, human event or task, and can bind an explicitly selected active task in its project.

Episode bindings retain store/owner and immutable startup/control receipt identities, epoch/revision, project/conversation/task, applicable policy revisions, policy-resolution digest, authenticated request origin, task-intent digest and accepted source identity. The managed host converts wall time to nonnegative UTC milliseconds; the authority kernel's stored numeric times must use that unit in this path.

Prepared-work bindings separately bind the original request/snapshot digests, episode-binding digest, local route, declared source ranges and optional renderer-proof digest. Source dependencies require exact project, identity, UTF-8 range and excerpt digest. HTTP routes require the declared loopback adapter; memory/native routes require the matching adapter identity. Nonempty artifact lineage is refused. Invocation bindings derive from the actual linked work, exact body and admission evidence.

These records do not establish a complete input dependency set, transitive artifact permission, policy rendering, tokenizer proof or immutable runtime identity. A declared route does not attest the running processor. Those contracts must precede managed consumer enablement.

## Schema, migration and archives

Three canonical BLOB/digest tables provide one binding classification for each episode, work item and invocation. Historical prototype schemas 1–6 migrate original records to explicit `legacyUnbound` classifications. Original request, snapshot, source, accounting and authority-receipt bytes are retained. Migration creates no historical authorization. Managed children require managed parents and matching digests; inconsistent classification, missing records, unexpected schema objects and rehashed semantic contradictions are refused.

Schema-6 recognition uses its independently frozen complete 47-object DDL contract. Schema-7 archives require a binding inventory containing subtype counts and deterministic streaming digests. Restore preserves the binding bytes and inventory; startup advances authority state and makes previously accepted managed bindings stale. Individual canonical binding records are bounded to 512 KiB, with at most 512 declared source dependencies. Historical record counts are streamed rather than restricted by a new global binding count cap.

Digests establish consistency, not authenticity against someone able to replace the whole store. Legacy classification grants no managed authority. Existing consumers remain legacy because human mutation is still unavailable through their interfaces.

## Conservative validation recipe

`validateManagedAuthority` uses four private owner-funded `authorityValidation` work items under the original episode allowance:

| Phase | Charged inspection |
|---|---|
| Metadata | Bounded control/journal/projection cardinality, BLOB types and byte lengths |
| Journal descriptors | Canonical operation requests and source-proof occurrence discovery |
| Source metadata | Original payload lengths and accepted-source metadata |
| Replay and clock | Conservative two-pass byte ceiling; one complete journal/projection/source replay reused by the trusted clock writer, extra control/tail reads, historical anchor validation and current eligibility |

Each phase reserves and arms its durable charge before inspection; failure retains incurred charges and settles confirmed failure. Exhaustion stops before unfunded original payload access. This private funding path avoids recursive public lease dispatch. Accounting-ledger and canonical-binding inspection needed to reserve/arm/settle is a bootstrap exception. Per-episode aggregates can scan the existing 100,000-work cap, and unsupported-adapter quarantine can scan the global work inventory without an inspected-row bound. Complete setup metering remains unfinished; fixed session metadata prepayment covers warm checks, not these inherited bootstrap scans. Counters do not measure every SQLite byte, physical I/O or CPU instruction.

SQLite `data_version` witnesses and immediate transactions fence externally changed sizing before descriptor or original-source reads. The final receipt hashes the exact binding validated in the fenced transaction. Complete historical binding validation includes its immutable receipt, startup, origin, accepted source, policy resolution and host contract. Expiry remains committed when current eligibility fails afterward. Late accounting settlement does not revive an invalidated or cancelled episode.

This is a bounded conservative full-replay diagnostic. It can exhaust an interactive allowance quickly. The internal [funded cache/session recipe](AUTHORITY-VALIDATION-CACHE.md) now reuses paid current-state evidence with progress/cancellation and owner/write fences. Complete consumer proofs and serialized runtime boundaries remain unfinished. No validator callback itself grants permission to launch inference or publish content.

## Verification

`--authority-binding-self-test` and `python3 scripts/test_authority_bindings.py` report fixed booleans from isolated synthetic stores. The 157 checks cover acceptance atomicity/retry, local reads, task lifecycle, provenance, parent classification, stale epochs, route/dependency checks, archive inventory, retained charges, exhaustion and rehashed corruption. Two external SQLite schedules replace or grow a request after sizing; both reject before descriptor decoding or source replay. A Unicode TEXT payload in a BLOB-affinity column is rejected during funded metadata inspection. Results and the full application source capture are recorded in [STATUS.md](STATUS.md).
