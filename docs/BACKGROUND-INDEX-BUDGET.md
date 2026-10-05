# Durable background indexing budget

Status: implementation contract recorded October 4, 2026. Foreground answering and local reads already use episode allowances. This contract governs optional semantic maintenance independently. Its ledger belongs in the authoritative main store and must survive rebuilding the derived index and backup/restore.

## Allowance and window

Use `background-index-day-v1`: one global allowance shared by all projects, encoder fingerprints, retries and rebuilds in a store. The operational day is a rolling 24-hour window beginning with the first reserved maintenance work. It is independent of local timezone and foreground requests.

| Resource | Development allowance per window |
|---|---|
| Conservative logical raw source work | 512 MiB |
| Encoder calls | 4,096 |
| Encoder input bytes | 16 MiB |
| Vector publication bytes | 32 MiB |
| Inspected metadata rows | 100,000 |
| Newly scheduled source jobs | 4,096 |

These are bounded development settings, not measured optimal values. Internal synthetic fixtures may use lower limits. A caller cannot increase an existing window's limits or obtain another allowance by changing project, fingerprint, trigger or index directory. There is no manual quota override in this wave. Foreground query inference keeps its foreground episode charge.

Within a boot, the continuous clock controls rollover. Wall-clock movement cannot open a new window before 24 continuous hours have elapsed. After reboot, a new window requires a valid UTC observation showing at least 24 hours since its stored start and no regression behind the durable UTC high-water mark. A clock that cannot establish those conditions retains the previous allowance or fails explicitly. Persist the window identity, original limits, start clocks, clock observations and charged/held totals. Resample the real clock after acquiring the owner mutex.

## Durable work and recovery

Schema 5 adds the background ledger without changing accepted source bytes, chat/read episodes, invocation evidence or sidecar job cursors. Each bounded work reservation has an exact UTF-8 binding to its project, index fingerprint, source identity/digest/sequence and operation descriptor. Work IDs are idempotent; a changed binding or resource request is a conflict. Window selection and reservation happen atomically under the exclusive store owner.

Reserve and arm before source payload reads, conservative full-source hashing, encoder inference and vector publication. Bound and charge metadata inspection and new job scheduling too. Armed work consumes its declared conservative resource bounds; unknown encoder input-token usage is recorded explicitly. Do not infer tokens from bytes or vector dimensions. No generative output or provider HTTP budget is introduced by this local encoder.

Slow source reads and encoder execution occur outside the main-store transaction and owner mutex. Check the current budget/work state before publication. A failed or unsupported attempt retains performed charges. Release only unused prepared work. Startup recovery releases prepared reservations and preserves armed/submitted work as unknown, including its resource charges; it performs no automatic encoder replay. Resuming a pending sidecar job uses a new charged attempt, leaving the interrupted attempt intact.

A derived sidecar commit and main-ledger settlement cannot share a transaction. Make the boundary conservative: an armed operation with uncertain settlement retains its maximum charge, and source/chunk publication remains idempotent. A crash must never publish uncharged work or reset a daily allowance. Backup verification validates the background ledger alongside foreground journals; restore preserves windows, charges and unknown work before any derived rebuild.

## Worker behavior

Existing per-trigger bounds still apply. Budget exhaustion leaves source jobs and their committed cursor pending, preserves explicit coverage holes and stops the current worker slice. It must not consume a job failure attempt, mark a source successfully complete, skip to a cheaper source and imply exhaustive coverage, or loop on denied work. Schedule coalescing remains bounded.

Expose a content-free budget snapshot and reason for paused maintenance so a missing semantic result is not mistaken for complete indexing. No source content, prompt, response or key is logged. Daily resource counters measure declared logical work; physical I/O, encoder token count, billed cost and general retrieval quality remain unknown.

## Verification

Required evidence covers exact cap boundaries; reservation conflicts and concurrent admission; project/fingerprint/rebuild sharing; no source or encoder access before preflight; failed and unsupported work charges; prepared versus armed SIGKILL/reopen; repeated reopen and restored-store stability; UTC regression/forward movement and boot-domain changes; rollover without rewriting history; exhausted jobs retaining cursor and retry attempts; corrupted ledger/digests/totals rejected after archive hash refresh; and legitimate schema 1–4 migration with preserved source and foreground accounting.

Keep historical schema recognition frozen. A schema-4 archive has no background ledger; absence is established by its recognized schema, not inferred from missing schema-5 fields. Current archives require the background inventory. The semantic sidecar remains derived schema 2 and is excluded from archives.
