# Durable episode accounting projections

October 5, 2026. Schema 8 adds four projections for indexed episode setup and settlement. Original episode, work, snapshot and settlement bytes remain authoritative. These projections supply accounting facts and confer no processing, disclosure or publication permission.

## Transaction contract

| Projection | Meaning | Lookup |
|---|---|---|
| `episode_accounting` | Work count, distinct referenced snapshot bytes and unknown-input operation count per episode | Exact episode ID |
| `episode_snapshot_references` | Exact snapshot digest membership per episode | Episode ID and digest |
| `episode_settlement_receipts` | Every retained settlement ID, owning work, ordinal and canonical receipt hash | Episode ID and receipt ID |
| `episode_adapter_quarantine` | Normalized recognized adapter family, or an unsupported adapter's exact identity, with a deterministic violating-work witness | Kind and binary identity |

Reservation, arming, handoff, settlement and terminal recovery update primary rows and their projections in the same SQLite transaction. Exact retries return existing evidence before adding a projection. Conflicting retries cannot donate capacity or replace a receipt. Receipt identifiers and adapter keys preserve exact UTF-8 bytes, including canonically equivalent Unicode spellings. Family keys and unsupported exact keys occupy distinct namespaces. A family's witness is the lexicographically smallest violating work ID in SQLite binary order; the complete family inventory is reconstructed during validation.

Unknown-input counts preserve the original predicate: work is neither prepared nor cancelled before dispatch, input tokens are unknown and reserved model calls are positive. Failed/completed historical work remains included when that predicate applies. Cancellation of prepared work releases only proven unused capacity; armed/submitted work becomes uncertain and retains its original charged units and output holds. Accounting projections add no synthetic settlement receipts during recovery.

## Validation and confidence

A schema-8 or current schema-9 owner validates the complete expected SQLite schema and the original episode journal, then reconstructs every projection before changing lifecycle or authority state. Missing rows, extra rows, altered aggregates, omitted receipts and incorrect quarantine keys fail even when mutable hashes are refreshed. Current projections are never silently repaired on reopen. Historical schemas 1–7 gain empty tables and one complete transactional backfill before recovery; genuine schema 7 uses its independently frozen 53-object schema contract.

Full projection reconstruction streams authoritative metadata into private disposable SQLite storage, with a bounded page cache and complete ordered inventory hashes. That reconstruction excludes snapshot/source bodies; the separate original journal validation still verifies those bodies and lifecycle/accounting relationships. Startup/archive validation is administrative work. It is not charged to a new foreground episode and is not a measured physical-memory or latency bound. Normal completion removes validation scratch storage; exhaustive filesystem crash cleanup remains unverified.

After full startup validation, the owner retains a private accounting-confidence witness. Every permission-bearing accounting lookup runs inside a write transaction and checks SQLite's external `data_version` and the same-connection accounting-write generation. Narrow audited ledger writes preserve confidence only while maintaining both primary rows and projections. Unknown writes to accounting data or schema invalidate it, including rolled-back writes. External commits conservatively invalidate it even if bytes are later restored. A new paid cache attempt cannot repair confidence; explicit owner reopening and complete validation are required.

If confidence is lost after work is armed, further settlement is refused. Original charges and holds remain durable for conservative recovery. Observational test queries can inspect these facts; they do not restore runtime eligibility.

## Bounded setup and remaining work

Ordinary receipt, reservation and cross-work settlement-ID checks use indexed points instead of per-episode work scans. Snapshot capacity reads use the stored byte total and indexed membership. Quarantine checks use one normalized point instead of enumerating malformed candidates or the global work inventory. Inspected descriptor/snapshot bytes remain subject to existing per-record caps. The paid authority recipe retains its conservative fixed bootstrap metadata allowance.

At the schema-8 checkpoint, terminalization on Stop, deadline, interruption or exhaustion enumerated prepared/armed/submitted work and updated each affected record. Removing repeated aggregate scans does not make that administrative cleanup constant work. The schema-9 cleanup contract below closes the separately bounded funding prerequisite before claiming that every failure path fits a fixed bootstrap charge or enabling shared live authority consumers. Outside-owner cold validation, complete input/dependency proof, policy rendering, runtime gates, service interfaces and representative evaluation remain separate prerequisites.

## Evidence

The isolated runner is `python3 scripts/test_episode_accounting.py`. It uses private synthetic stores and reports fixed Boolean keys, source hashes and SQLite VM/full-scan counters. Process schedules kill the writer between primary and projection changes, then validate originals and projections before recovery and after two reopens. Lookup scaling checks use a valid migrated inventory with unrelated historical work; raw fixture construction never grants confidence to an active owner.

Current verified counts and capture paths are recorded in [STATUS.md](STATUS.md). Contract checks establish atomicity and logical lookup behavior for the tested schedules. They do not establish representative performance, SSD power-loss durability or production readiness. See [episode budgets](EPISODE-BUDGET.md), [authority cache](AUTHORITY-VALIDATION-CACHE.md) and [backup/restore](BACKUP-RESTORE.md).

Schema 9 adds [bounded prepaid terminal cleanup](EPISODE-CLEANUP.md), using the same accounting confidence fence and original rows. This closes the terminal enumeration gap described at the schema-8 checkpoint.
