# Durable background indexing budget

Status: implemented and pushed at `b006b6a`, October 5, 2026. The contract was first recorded October 4. Targeted current-tree verification is described below; integrated application verification is tracked in [STATUS.md](STATUS.md).

Since October 8, 2026, the application schedules no semantic maintenance; `SemanticRetrievalPolicy.ordinarySend` disables it ([decision](P2-SEMANTIC-DECISION.md#decision)). The ledger and its contracts are unchanged and still govern explicit on-demand builds. Optional semantic maintenance has its own durable allowance in the authoritative main store. Foreground answering, source browsing and query encoding retain their episode allowances. Rebuilding the derived semantic index preserves the background ledger; restoring a schema-5 archive preserves its archived accounting.

## Allowance and window

`background-index-day-v1` supplies one global allowance shared by all projects, encoder/index fingerprints, retries and rebuilds in one owner store. It does not aggregate work across separate stores or the machine. Each window is a nonoverlapping 24-hour period anchored by its first successful reservation. Local timezone and foreground request boundaries do not affect it.

| Resource | Development allowance per window |
|---|---|
| Conservative logical raw source work | 512 MiB |
| Encoder calls | 4,096 |
| Encoder input bytes | 16 MiB |
| Vector publication bytes | 32 MiB |
| Inspected metadata rows | 100,000 |
| Newly scheduled source jobs | 4,096 |

These are development defaults; their suitability for representative archives is unmeasured. Internal synthetic fixtures can establish lower caps. An existing window freezes its limits, and a conflicting limit request fails. There is no manual quota override. A project, fingerprint, trigger or sidecar change cannot obtain another allowance.

The owner samples its clock after acquiring the main-store mutex. Within the originating boot, the continuous clock controls rollover and includes sleep; moving UTC cannot shorten the 24-hour period. After reboot, a valid UTC observation can establish the remaining age or permit rollover after at least 24 hours relative to the durable UTC baseline, provided it has not regressed behind the stored high-water mark. The new boot's continuous anchor prevents later UTC movement from shortening the established remaining period. Regressed or unavailable observations retain the existing allowance or fail explicitly. Clock anchors, observations, original limits and charged/held totals remain durable; a rollover closes the old window without rewriting its work.

A fully armed attempt may finish against its original charged window while the owner still accepts its boot domain and live work identity. Rollover supplies no new allowance to that attempt. Reopen recovers interrupted attempts before a newly triggered worker can reserve work.

## Durable requests and source binding

Main-store schema 6 retains the schema-5 background windows and canonical work records with their request snapshots. It also preserves accepted bytes, foreground episodes, their deduplicated request snapshots and invocation evidence. The derived semantic sidecar remains schema 2.

Each work request binds its operation, adapter identity, index fingerprint and project using exact UTF-8 identity. Source operations include the canonical complete `MemorySourceReference`: sequence, event/conversation/project IDs, role, capture status, original timestamp, SHA-256 and accepted byte count. Its digest and exact range bound are immutable. Metadata scheduling retains the canonical ordered source-reference list. Work-ID retries are idempotent; changed bindings, snapshots or resource requests conflict.

Reservation and window selection commit atomically under the exclusive owner. A prepared reservation holds capacity. Arming converts every declared resource to a conservative charge before an operation can inspect payload, perform a full source seal, invoke the encoder or publish a vector. An armed maximum remains charged after unsupported, failed or unknown work; settlement cannot refund it to a lower observation. Encoder input tokens remain explicitly unknown. The Apple API exposes no verified tokenizer or input-token usage; input bytes and vector dimensions cannot supply that count. This local encoder ledger introduces no generative output-token or provider HTTP allowance.

## Bounded work recipe

`background-bounded-pages-v1` derives resource requests before bytes are read. Let `B` be accepted source bytes, `o` the committed cursor, `K` the configured chunk bound, `D` the encoder dimension, `L = min(K, B-o)` and `P = B / 4093 + 1`. Valid bounds are `B <= 4 MiB`, `64 <= K <= 4096` and `1 <= D <= 8192`. Arithmetic is checked for overflow.

| Operation | Raw source work | Encoder calls / input bytes | Vector bytes | Metadata rows | New jobs |
|---|---:|---:|---:|---:|---:|
| Two fixed public adapter probes | 0 | 2 / 65 | 0 | 0 | 0 |
| Pending-job peek | 0 | 0 / 0 | 0 | 1 | 0 |
| Initial complete-source seal, `B > 0` | `2*(B+4P)` | 0 / 0 | 0 | `P+2` | 0 |
| Ordinary chunk attempt | `4*(L+1)` | 1 / `L` | `4D` | 5 | 0 |
| Final chunk and fresh seal | `4*(L+1)+2*(B+4P)` | 1 / `L` | `4D` | `5+P+2` | 0 |
| Empty-source completion | 0 | 0 / 0 | 0 | 5 | 0 |

The four chunk passes describe bounded page materialization/UTF-8 validation, selection, excerpt materialization/validation and excerpt digest. Seal work describes bounded page materialization/UTF-8 validation and full SHA-256 reconstruction. `P` bounds the traversal rows when a page advances by at least 4,093 bytes; the extra four bytes per page conservatively cover alignment and SQL's extra byte. These declarations describe logical work. Physical I/O, internal Foundation/encoder work and billed cost are unmeasured.

The final page and its fresh full seal use one composite request, reserved and armed before claim, payload access or encoding. Completion requires the actual final range to reach `B` and the current attempt's complete SHA-256 to match the original. A shorter whitespace range remains pending and is charged for its immutable maximum page request.

Metadata capture of the source frontier and scope cursor each charges one row. Source-manifest inspection charges its declared row limit. Scheduling `n` selected references charges `2*n+1` metadata rows and `n` source jobs before inserts/checks and cursor advancement. If the ordered scheduling snapshot would exceed 64 KiB, the worker selects the largest fitting ordered prefix and advances only through that prefix. Remaining sources stay behind the cursor for a later trigger. Ledger bookkeeping does not recursively count itself as source/sidecar inspection.

Production Apple initialization performs the two public probes only after reserve/arm, then freezes the observed vector digest in its encoder fingerprint. Probe quota denial keeps semantic initialization unavailable and exposes the maintenance status through the main owner. Original-source retrieval remains available, and a later explicit trigger can retry initialization when its allowance permits.

## Source reader and publication gate

Each armed source attempt can claim one private read-only SQLite connection that strongly retains the original store owner and process lock. Its payload query binds every canonical source field in the SQL `WHERE` clause before returning bytes. A chunk projection is bounded to `L+1`; complete seals traverse pages of at most 4,096 bytes. The reader permits one bound chunk read and only the seal authorized by that descriptor. Duplicate reader claims or reuse after terminalization fail.

Payload reads, full hashing and encoder execution hold neither the main owner mutex nor the semantic sidecar mutex. An initial full seal can create one metadata-only hint for the current worker/source/fingerprint. Its successful work ID and source digest survive only in that live worker. Source/index changes, integrity failures, budget pause and reopen clear it. A historical completed record cannot reconstruct the hint after reopen. Every final attempt performs a fresh seal.

Publication acquires locks in **sidecar -> main** order. With the sidecar already held, `withBackgroundPublication` samples the clock and validates the live work, adapter quarantine, exact source metadata and private reader completion under the main owner. It commits the submitted-state journal before running bounded SQL/commit on that already-held sidecar, and retains the owner mutex through that callback. The callback acquires no new sidecar lock and performs no source reading, hashing, inference or blocking observer work. A concurrent authority mutation cannot pass between the final gate and sidecar commit. Main-owner code must not acquire a fresh sidecar lock.

A chunk and its continuation commit atomically in the sidecar. Full readiness publishes only after the final seal; incomplete and failed prefixes stay unavailable to vector ranking. Settlement follows after both locks release. The two databases have no shared transaction: a crash after sidecar commit and before settlement preserves the submitted attempt's maximum charge as unknown, while retaining the committed cursor. Resume uses a new request and does not duplicate the committed range.

## Pause, recovery and archives

Budget exhaustion stops the current slice with the cursor and failure attempts unchanged. It preserves pending coverage, performs no payload/encoder work for the denied attempt, and does not skip to a cheaper source or spin. Clock/work refusal and adapter quarantine also fence publication; a claimed but unpublished job returns to pending. Ordinary source/encoder failures retain their charged work and bounded failure state. Existing per-trigger bounds and exact-UTF-8 project coalescing still apply.

The main owner exposes a snapshot of the window, remaining resources and clock/exhaustion status. The worker exposes a synchronized public pause code, including denial when the remaining allowance is positive but insufficient for the next request. The native maintenance status can report these without source content, prompts, responses or credentials.

Startup releases unused prepared reservations and converts interrupted armed/submitted attempts to unknown with all charges retained. It executes no source-job replay. Public startup probes are separately metered. The sidecar recovers processing jobs to pending at their committed offset; a later capture/open/search trigger can create a new charged attempt. Reopen, fingerprint changes and sidecar rebuild retain that store's allowance.

Backup verification checks background bindings, canonical snapshots, clock anchors, work-window linkage, settlements and aggregate totals alongside foreground journals. Schema-5/6 restore preserves the archived windows and charges before any derived rebuild. An archive is a point-in-time snapshot: restore does not merge later charges from the current or another store, and no external budget authority prevents rollback to older archived accounting. Historical schema 1–4 recognition is frozen; a recognized schema-4 archive establishes its absence of background accounting. Migration creates its new ledger without inventing charges for historical unmetered work. Schema-5/6 archives require the background inventory. The sidecar remains derived and excluded from archives.

## Integrity and measurement limits

Initial and final complete-source seals detect persistent corruption at those reads. They do not prove every earlier vector used the original bytes if an external actor temporarily corrupts a range, lets it be encoded and restores it before the final seal. The deterministic fixture records that limitation. Delivered excerpts still require their stored range digest to match the original bytes. Stronger validation of every historical chunk/range needs its own bounded, resumable protocol before this limitation can be closed.

Daily accounting does not establish retrieval quality, paraphrase recall, answer quality, multilingual/code support, physical I/O cost or token accounting for Apple. The installed adapter smoke verifies observed mechanics. The full-source budget fixture uses a deterministic injected encoder and supplies no evidence about Apple's retrieval quality. The frozen evaluation protocol and source pins remain unchanged.

## Verification

Targeted current-tree verification passed **455 checks** through `python3 scripts/test_background_index.py --full-source`. It includes 167 pure contract checks, 108 main-owner checks, 80 worker checks, seven full-source checks, and actual SIGKILL/reopen controls. Archive, episode and integrated application verification, along with implementation commit/push, remain tracked in [STATUS.md](STATUS.md).

The wrapper kills real producers after arm, during encoding, after the final seal before publication and after sidecar commit before settlement. Each case is observed on two reopens, then resumed explicitly. Checks cover no uncharged publication, retained unknown charges, pending cursors/failure attempts, fresh sealing and no duplicate ranges. Owner tests additionally cover concurrent admission and a same-adapter violation blocked until gated sidecar SQL commits; prior quarantine or terminalization runs zero publication callbacks.

The full synthetic 4 MiB source publishes all 4,096 exact 1 KiB ranges across two windows. Two actual public probes plus 4,094 chunks exhaust the first window's 4,096-call cap. After rollover, a fresh initial seal and two remaining chunks complete the source. Three complete-source seals plus chunk work charge exactly **41,984,024 logical raw bytes**. The closed first window retains its original charges. This is protocol evidence from the deterministic fixture.

Archive and migration checks cover legitimate schema 1–4 inputs, schema-5 inventory and refreshed-file-hash corruption of ledger requests, digests, resources, clocks and linkage. Historical semantic checkpoint totals and immutable evaluation pins are retained in [SEMANTIC-RETRIEVAL.md](SEMANTIC-RETRIEVAL.md) and [EVALUATION.md](EVALUATION.md).
