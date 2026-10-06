# Bounded episode terminal cleanup

The schema-9 cleanup contract separates the durable terminal fence from cleanup of previously admitted work. New reservations, arming, content publication and transport handoffs still require an active episode. Stop, exhaustion, deadline expiry and interruption commit a terminal state and increment the existing revision before cleanup begins. A cleanup failure cannot roll back that committed fence.

## Original allowance and prepayment

New episodes freeze `terminalCleanup` in their original, digested limit record. `terminal-work-cleanup-v1` permits at most 100,000 original work slots; callers may lower that cap. A slot prepays two automatic attempt units. Each unit covers a conservative 64 metadata-row units, a 128-unit bound on fixed transaction/fence overhead and 512 KiB of encoded metadata passes. A batch charges its declared row bound before inspecting pending work; that per-row overhead allocation also covers a partially filled batch. The version fixes these constants and a maximum batch size of 32. These are declared bookkeeping ceilings, not measured heap, elapsed time or SQL VM instructions.

This allowance is separate from the nine content resource counters. Their limits and charged/held meanings stay intact. Cleanup receipts report its own prepaid, consumed and pending slots. Reserving a slot and inserting the original work commit atomically. A naturally settled operation retains its original slot allocation; retries and cancellation do not replenish admission capacity. If a new work would exceed the original slot cap, it is refused and the existing episode becomes budget-exceeded. Its already prepaid cleanup remains available.

Cleanup may spend its frozen allowance after the content deadline or content-resource exhaustion. It grants no permission to read accepted source bodies, run models, contact a provider, continue an answer or admit replacement work. Ordinary indexed ledger setup retains its existing fixed bookkeeping exception. Full input-dependency metering and the future human/control maintenance sponsor remain separate unfinished contracts.

## Fence, batches and uncertainty

`episode_cleanup_budget` retains the classification, frozen slot limit, allocated slot count, consumed count, literal pending-state count, durable automatic/admin attempt counts and first terminal tick. `episode_cleanup_receipts` retains one unique receipt per cleaned work, with its episode, prior state and original terminal tick. Neither table replaces the original request, snapshot, settlement or resource vectors.

The pending partial index covers only `prepared`, `dispatchArmed` and `submitted` work, ordered by exact SQLite episode/work identity. A transaction selects at most 32 IDs. Each operation reads bounded request/resource metadata and indexed accounting points. Cleanup never loads a request snapshot or source payload.

Prepared work releases its hold only in the transaction that proves it was never armed, changes it to cancelled-before-dispatch and consumes its original cleanup slot. Armed or submitted work becomes outcome-unknown and retains its charged vector and uncertain output hold. All original rows remain inspectable. A terminal episode may therefore temporarily have pending original rows and retained holds; its cleanup receipt explicitly reports that state. Full validation requires the pending count and terminal fence to match those originals.

The first ordinary terminal operation drains one bounded batch after the fence commits. Attempt funding commits in a separate transaction before the batch executes. A failed transaction or SIGKILL retains that debit; two attempts per original slot bound automatic retries. Exhausting cleanup attempts preserves the terminal fence and remaining holds. Idempotent Stop and receipt inspection remain available. A private serial owner queue processes remaining batches, releasing the owner mutex between them. Failure or lost accounting confidence leaves the durable pending record intact. It does not invent a successful cleanup receipt or release uncertain capacity. A point lookup or late authoritative usage settlement can separately fund and clean its original target from the same allowance. Receipt replay cannot consume another slot. Late usage can settle accounting without reopening content publication.

## Recovery and compatibility

Schemas 1–8 retain separately frozen recognition. Schema 8 is captured from verified commit `ea6ae1ea`: all 62 SQLite objects match the retained optimized application, including shadow tables and automatic indexes. Older episodes migrate as `legacy-administrative`; migration does not claim they prepaid slots. Their structural record counts remain explicit, and aggregate prepaid totals exclude them.

Owner startup validates the original journal and cleanup ledger before recovery. It closes active episodes and completes pending cleanup in bounded transactions under exclusive administrative startup ownership before accepting another episode. Administrative attempt units are recorded separately and never replenish the original automatic allowance. Repeated startup retains existing cleanup receipts and does not replay requests. Archive verification accepts correctly fenced pending snapshots without mutating them; restore validates the permitted cleanup delta while preserving original request/snapshot identity and all prior receipts.

## Verification boundary

The focused suite exercises bounded Stop, exhaustion, late usage, retries, rollback after original work mutation, confidence loss, repeated recovery and indexed selection with unrelated inventory. Process fixtures kill the actual process after the terminal-fence commit and inside an uncommitted cleanup batch. Final counts and the exact tested bundle/source evidence are recorded in [STATUS.md](STATUS.md).

The shared managed consumer gate, counted policy integration, managed standing-policy input proofs, background authority bindings and terminal invalidated-capture reasons remain unfinished. This contract enables no remote processing, external action, deletion, optional tree or managed live consumer.

The later [funded policy renderer](AUTHORITY-POLICY-RENDERING.md) uses this accounting/cleanup foundation to prepare mandatory policy bytes; it enables no live consumer.
