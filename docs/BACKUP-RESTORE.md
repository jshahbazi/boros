# Verified backups and restores

Boros can create and verify a private archive of its SQLite evidence store, then restore it into a new data directory. Current archives preserve the schema 4 source, invocation and episode journals, including chat and standalone-read origins. Genuine historical schema 1, 2 and 3 sources and archives remain supported. Deletion-ledger application, retention, encryption, remote synchronization, and automatic scheduled backups remain unimplemented.

## Archive contents

An archive is a directory with `memory.sqlite3`, `manifest.json`, and optional `settings.json`. The database is a consistent snapshot created with SQLite's online backup API inside a pinned source read transaction. A running owner can continue committing WAL transactions while that older snapshot is copied. New transactions after the snapshot cutoff are outside the archive.

The snapshot preserves conversation IDs, complete typed source bytes, capture status, source digest, drafts, database settings, exact credential-free invocation request bodies, committed stream chunks, admission receipts, usage receipts, and terminal/recovery metadata. The episode journal retains accepted-request linkage, frozen allowances and clock domains, charged/held resource totals, prepared/armed/submitted work, request snapshots and receipt chains. Schema 4 also preserves the exact canonical origin JSON and its project-bound digest. A standalone read has no conversation, turn or human-event linkage. Unknown usage remains unknown in the archive.

The manifest records format and database versions, file lengths and SHA-256 checksums, project-scoped source counts and bytes, invocation/chunk counts, unfinished attempts, observed provider identities and served model IDs. Schema 3 and 4 inventory also records episode/work/snapshot counts and bytes, prepared and uncertain work, and charged/held resource vectors. Schema 4 requires separate `chatEpisodes` and `localReadEpisodes` counts that match the stored origin types. Schema 1 and 2 have no episode journal; episode inventory fields remain optional when decoding historical manifests. Historical schema 3 manifests can omit origin subtype counts. Missing legacy fields remain unavailable rather than becoming inferred zeroes.

The optional nonsensitive `settings.json` is an independent file point capture taken after the database snapshot. It may describe a newer GUI selection or model configuration than the snapshot's database contents. Its manifest label makes this boundary explicit. Malformed JSON or forbidden credential/header fields cause archive creation or verification to fail.

Keychain credentials, model files, runtime executables, owner locks, WAL/SHM sidecars, and the derived semantic sidecar are excluded. The restored semantic index starts absent and requires a rebuild from restored source events. Source text and request bodies can contain private information supplied in chat; their accepted bytes are preserved completely. Archives require the same privacy precautions as the live store.

Directories created by the workflow use `0700`; files use `0600`. SHA-256 verifies integrity. Archives are neither encrypted nor cryptographically authenticated. A party able to replace an entire archive and recompute its manifest is outside the checksum integrity guarantee.

## Publication and failure behavior

The caller supplies an absolute destination whose parent exists and whose final path does not exist. Existing files, directories and symbolic links are refused. Destination paths containing dot components are refused. Parent directories are opened component by component with `O_NOFOLLOW`; a held parent descriptor and inode checks detect replacement before staging or publication. The final rename uses `RENAME_EXCL`, which refuses a destination created concurrently. These checks do not claim isolation against malicious code running with the same user's filesystem authority.

Creation writes into a new private sibling staging directory. It verifies the database and manifest, syncs files and the staging directory, then atomically publishes the archive and syncs the parent directory. Conversion out of WAL occurs only in the new, closed snapshot; leftover snapshot sidecars are removed after the standalone rollback-mode database header is verified. The live source's WAL and sidecars are untouched.

Normal pre-publication failures and cancellation remove unpublished staging. SIGKILL can leave a private `.boros-staging-*` directory. It is never treated as a completed archive or promoted automatically. There is no live orphan collector. The operator may remove a known abandoned staging directory after confirming its operation stopped; never remove staging solely because of age.

If the exclusive rename succeeds and the subsequent parent sync fails, the API reports that publication durability is unknown. The already published verified destination is retained. Verify it and inspect the operation result before retrying with a new destination.

## Verification and restore

Verification rejects unknown archive/schema versions, missing or unlisted files, duplicate inventory entries, symbolic or hard-linked database files, nonprivate files, and nonstandalone database snapshots. It checks file hashes and lengths, SQLite integrity and foreign keys, the expected table/column inventory, event scope and status, complete source UTF-8 and digests, journal body/receipt digests, contiguous chunk sequences, chunk totals, matching human evidence and assistant publication, and compatible terminal/recovery states.

Episode journal validation also verifies allowance/resource arithmetic, snapshot digests, episode/work scope, parent linkage, lifecycle clocks and revisions, receipt/state agreement, unknown output bounds and adapter-violation flags. An invocation's exact request digest must match its linked answering-work snapshot. A linked complete capture requires a completed episode. Recovered cancellation requires a matching cancelled episode and the exact partial or empty-cancelled capture state. The validator accepts the legitimate late-receipt chain of unknown outcome, independent identity-violation proof and later authoritative usage while preserving the episode's terminal state. Corruption cannot bypass these checks merely by regenerating file hashes or truthful aggregate inventory.

Schema 4 verification requires the exact versioned origin keys and types, canonical JSON bytes, a valid project-bound origin digest and exact UTF-8 identifier equality. Duplicate keys, unknown versions or kinds, malformed descriptor bindings, duplicate initiator/request-ID pairs, and chat/read linkage mismatches fail. Read episodes cannot link an invocation or contain answering, calibration, provider-discovery or tokenizer work; only retrieval, source reads and query encoding with zero output reservation are valid. A truthful total episode count cannot replace the required subtype counts.

Restore verifies the archive, copies only declared files into private staging, and verifies the copied database again. It opens an exclusive `MemoryStore` owner there before exposing the restored directory, migrating genuine schema 1, 2 or 3 stores to main-store schema 4. Schema 3 migration preserves exact chat identity bytes, source payloads, work, snapshots and accounting while adding canonical chat origins; older stores acquire no invented episodes. Startup recovery terminalizes archived active chat and read episodes as interrupted, or deadline-exceeded when the continuous clock remains comparable and the deadline has passed. It releases only unarmed prepared reservations. Armed/submitted work becomes unknown and retains its charged input/call/work units and output headroom. It performs no automatic resend or query-encoder replay.

Invocation recovery publishes unfinished attempts with committed visible chunks as partial and preserves their exact prefix; empty attempts become failed, or cancelled when their linked episode was cancelled. Existing terminal attempts retain their state. A late usage settlement changes accounting without reopening an episode. The workflow verifies every published source through the real paginated exact-read API, closes the owner, rebuilds the contentless lexical index from complete restored source payloads and checks its FTS integrity, validates recovered journal invariants, syncs the restored files and directory, then publishes to the new destination atomically. Derived semantic schema 2 data is excluded and must rebuild separately.

`restored-from.json` records the archive ID, original archived database checksum, restoration time and number of recovered attempts. It is a receipt; the recovered database can differ from the archived database because startup recovery publishes missing assistant events. The archive remains unchanged. Restoring never switches the GUI's active store automatically and never overwrites a live or closed data directory.

## Control authority boundary

Every manifest includes `authorityID`, `epoch`, `deletionControlsEnabled`, and an optional ledger digest. Restore requires a separately supplied current authority. The current implementation accepts only `BackupControlState.unmanagedNoDeletion`, which describes prototype stores without deletion controls. Its existing `boros-unmanaged-schema-2` authority ID remains stable across supported schemas; the ID does not select a database schema. A missing or changed authority, a nonzero epoch, an enabled deletion state, or any ledger requirement fails closed. Even an old unmanaged archive is refused when the supplied current authority has enabled deletion controls.

This is a compatibility hook, not a deletion guarantee. No external deletion ledger or suppression state is implemented. Before deletion becomes available, restore must apply the current external ledger to all source, journal, chunk, setting and derived-content copies and verify suppression before publication. Code enabling deletion must stop selecting `unmanagedNoDeletion`; an operator-supplied claim that controls never existed cannot substitute for the required ledger.

## Swift API and checks

```swift
let manifest = try BackupArchive.create(from: owner, at: archiveDirectory)
let verified = try BackupArchive.verify(at: archiveDirectory)
try BackupArchive.restore(from: archiveDirectory, to: newStoreDirectory,
                          authority: .unmanagedNoDeletion)
```

The archive and restore directory parents must already exist. On macOS, use a real parent path; `/var` is a system symbolic link to `/private/var` and is refused by the destination parent walk. No credentials, request bodies or response payloads are printed by these APIs.

## Command-line workflow

The built executable exposes three commands:

```sh
.build/boros/Boros.app/Contents/MacOS/Boros --backup-create --data-directory /absolute/existing/store --archive /absolute/existing/parent/new-archive
.build/boros/Boros.app/Contents/MacOS/Boros --backup-verify --archive /absolute/existing/parent/new-archive
.build/boros/Boros.app/Contents/MacOS/Boros --backup-restore --archive /absolute/existing/parent/new-archive --destination /absolute/existing/parent/new-store
```

Replace the illustrative absolute paths with the intended local directories. Creation requires an existing private schema 1, 2, 3 or 4 memory database; a missing directory, foreign schema or corrupt source is refused before opening an original store owner. A SQLite version number alone is insufficient: recognition checks the expected core/FTS table, column, index and constraint definitions, then complete source/journal integrity. Schemas 1–3 use separately frozen historical DDL contracts; recognition does not derive them by removing current columns or constraints. Schema 4 uses the current contract, including the unique read-request index. Recognition probes an existing owner lock without creating one, copies the main file and any WAL into private temporary storage, and opens only that copy for SQLite validation. Source SHM is never opened or copied. Migration and interrupted episode/invocation recovery during recognition affect only the private copy. These main/WAL copies are fail-closed recognition input and never archive evidence; partial or inconsistent copies are refused. The actual archive still uses the pinned SQLite online snapshot.

The command takes exclusive store ownership, so close the GUI's owner first. After recognition releases its probe, `MemoryStore` obtains the normal exclusive owner lock, then performs any needed migration and interrupted-invocation recovery on the recognized original before creating the archive. Another cooperating owner makes acquisition fail. A process that edits the files without respecting the owner lock, or changes them between recognition and original ownership, is outside this handoff guarantee. The Swift owner API can snapshot a running owner directly; the separate command-line process cannot acquire another process's ownership.

Restore publishes a new directory and leaves the GUI's configured store unchanged. All three commands use the explicit `unmanaged-no-deletion` compatibility state. They do not accept credential fields or enable deletion-ledger application. Future deletion controls must replace this CLI authority selection with the implemented current ledger; these commands cannot remain an unrestricted way to bypass it.

Success prints one JSON metadata object containing the operation, verified status, archive UUID, format/schema versions, control label and aggregate conversation/source/invocation counts. When present, it also reports aggregate episode, unfinished-episode, work and uncertain-work counts. Schema 4 additionally reports `chat_episodes` and `local_read_episodes`; older archives omit unavailable origin subtype counts. Restore reports recovered unfinished invocation and episode counts. Paths, project/event IDs, provider or model configuration, drafts, request bodies and chat text are excluded from output. Errors use fixed content-free messages on stderr. Exit statuses are `0` for success, `1` for an operation failure, and `2` for invalid arguments. Duplicate/unknown/mixed options, missing values, relative paths and dot components are rejected. An existing restore destination is always refused.

## Synthetic verification

Run the isolated suite:

```sh
python3 scripts/test_backup.py
```

Final verification and suite totals are recorded in [STATUS.md](STATUS.md). The standalone backup suite and combined application suite overlap. The earlier schema 2 checkpoint passed 60 standalone checks.

Current checks cover a WAL owner writing after the pinned snapshot is established, independent settings-file capture, complete source/request/receipt/chunk/episode restoration, interrupted partial and empty-failed recovery, preserved unknown output holds, release of only unarmed reservations, exact completed usage, close/reopen without duplicate publication or recharge, reconstruction of a missing lexical index and embedded-NUL source suffix, scoped inventory, corrupted data with regenerated file hashes, receipt/state/body/episode-capture linkage corruption, foreign keys, unknown schema/object/file inventories, symlinks, an existing active owner, no-clobber publication races, cancellation cleanup, command-line arguments and metadata output, a complete CLI restore roundtrip, and a real SIGKILL after private staging creation. Empty and partial invocations recovered after durable Stop also pass close/reopen, archive verification, CLI source recognition and restore while retaining unknown output bounds. Foreign SQLite databases marked version 1, 2, 3 and 4 retain their original bytes, schema and directory inventory after CLI refusal, including the absence of a newly created owner lock. Corrupt recognized sources are refused before original-owner mutation. Genuine historical schemas 1–3 and their manifests are accepted through the supported compatibility path.

Read-specific checks preserve completed origins and receipts, recover active reads without source/chat mutation or inference replay, retain unknown encoder input usage, and verify schema 4 CLI subtype counts. Corruption checks refresh file and origin digests before testing malformed or duplicate origin keys, linkage mismatches, prohibited read work and false subtype inventories. Invalid read archives are refused before restore publication. Separate-process checks kill active read work before archive restoration and verify stable charged/held recovery.

Independent review separately compiled and validated a real-store three-receipt chain, preserving cancellation and adapter quarantine while settling the late output hold. The SIGKILL check establishes that an interrupted unpublished operation has no completed archive; it does not exhaustively simulate every filesystem crash or power-loss boundary. None of these checks establishes deletion-aware restore, physical purge or encryption.

A negative recovered-cancellation fixture changes the linked episode to failed and refreshes the archive's file hash. Verification rejects that inconsistent terminal relationship; the positive empty/partial Stop-recovery fixtures remain accepted.

The tests use synthetic temporary stores and do not read or modify the user's chat history, existing archives, local models, or Keychain.
