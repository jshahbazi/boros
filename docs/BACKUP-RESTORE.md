# Verified backups and restores

Boros can create and verify a private archive of its SQLite evidence store, then restore it into a new data directory. This implements backup and restore for the current schema 2 text and invocation journal. Deletion-ledger application, retention, encryption, remote synchronization, and automatic scheduled backups remain unimplemented.

## Archive contents

An archive is a directory with `memory.sqlite3`, `manifest.json`, and optional `settings.json`. The database is a consistent snapshot created with SQLite's online backup API inside a pinned source read transaction. A running owner can continue committing WAL transactions while that older snapshot is copied. New transactions after the snapshot cutoff are outside the archive.

The snapshot preserves conversation IDs, complete typed source bytes, capture status, source digest, drafts, database settings, exact credential-free invocation request bodies, committed stream chunks, admission receipts, usage receipts, and terminal/recovery metadata. The manifest records format and database versions, file lengths and SHA-256 checksums, project-scoped source counts and bytes, invocation/chunk counts, unfinished attempts, observed provider identities and served model IDs.

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

Restore verifies the archive, copies only declared files into private staging, and verifies the copied database again. It opens an exclusive `MemoryStore` owner there before exposing the restored directory. Startup recovery publishes archived unfinished attempts as interrupted: attempts with committed visible chunks become partial; empty attempts become failed. Completed/cancelled/failed attempts retain their previous terminal state. The workflow verifies every published source through the real paginated exact-read API, closes the owner, rebuilds the contentless lexical index from complete restored source payloads and checks its FTS integrity, validates recovered journal invariants, syncs the restored files and directory, then publishes to the new destination atomically.

`restored-from.json` records the archive ID, original archived database checksum, restoration time and number of recovered attempts. It is a receipt; the recovered database can differ from the archived database because startup recovery publishes missing assistant events. The archive remains unchanged. Restoring never switches the GUI's active store automatically and never overwrites a live or closed data directory.

## Control authority boundary

Every manifest includes `authorityID`, `epoch`, `deletionControlsEnabled`, and an optional ledger digest. Restore requires a separately supplied current authority. The current implementation accepts only `BackupControlState.unmanagedNoDeletion`, which describes schema 2 stores that have no deletion control implementation. A missing or changed authority, a nonzero epoch, an enabled deletion state, or any ledger requirement fails closed. Even an old unmanaged archive is refused when the supplied current authority has enabled deletion controls.

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

Replace the illustrative absolute paths with the intended local directories. Creation requires an existing private schema 1 or 2 memory database; a missing directory, foreign schema or corrupt source is refused before opening an original store owner. A SQLite version number alone is insufficient: recognition checks the expected core/FTS table, column, index and constraint definitions, then complete source/journal integrity. It probes an existing owner lock without creating one, copies the main file and any WAL into private temporary recognition storage, and opens only that copy for SQLite validation. Source SHM is never opened or copied. Schema 1 migration and interrupted-invocation recovery during recognition affect only the private copy. These main/WAL copies are fail-closed recognition input and never archive evidence; partial or inconsistent copies are refused. The actual archive still uses the pinned SQLite online snapshot.

The command takes exclusive store ownership, so close the GUI's owner first. After recognition releases its probe, `MemoryStore` obtains the normal exclusive owner lock, then performs any needed migration and interrupted-invocation recovery on the recognized original before creating the archive. Another cooperating owner makes acquisition fail. A process that edits the files without respecting the owner lock, or changes them between recognition and original ownership, is outside this handoff guarantee. The Swift owner API can snapshot a running owner directly; the separate command-line process cannot acquire another process's ownership.

Restore publishes a new directory and leaves the GUI's configured store unchanged. All three commands use the explicit `unmanaged-no-deletion` compatibility state. They do not accept credential fields or enable deletion-ledger application. Future deletion controls must replace this CLI authority selection with the implemented current ledger; these commands cannot remain an unrestricted way to bypass it.

Success prints one JSON metadata object containing the operation, verified status, archive UUID, format/schema versions, control label and aggregate conversation/source/invocation counts. Restore also reports how many archived interrupted attempts were recovered. Paths, project/event IDs, provider or model configuration, drafts, request bodies and chat text are excluded from output. Errors use fixed content-free messages on stderr. Exit statuses are `0` for success, `1` for an operation failure, and `2` for invalid arguments. Duplicate/unknown/mixed options, missing values, relative paths and dot components are rejected. An existing restore destination is always refused.

## Synthetic verification

Run the isolated suite:

```sh
python3 scripts/test_backup.py
```

Sixty synthetic checks passed on October 4, 2026. They cover a WAL owner writing after the pinned snapshot is established, independent settings-file capture, complete source/request/receipt/chunk restoration, interrupted partial and empty-failed recovery, close/reopen without duplicate publication, reconstruction of a missing lexical index and embedded-NUL source suffix, scoped inventory, corrupted data with regenerated file hashes, foreign-key and terminal-state corruption, unknown schema/object/file inventories, symlinks, an existing active owner, no-clobber publication races, cancellation cleanup, command-line arguments and metadata output, a complete CLI restore roundtrip, and a real SIGKILL after private staging creation. Foreign SQLite databases marked version 1 and 2 retain exactly their original file bytes, schema and directory inventory after CLI refusal, including the absence of a newly created owner lock. A corrupt recognized store is also refused without mutation; a genuine schema 1 store is accepted and upgraded. The SIGKILL check establishes that an interrupted unpublished operation has no completed archive; it does not exhaustively simulate every filesystem crash or power-loss boundary.

The tests use synthetic temporary stores and do not read or modify the user's chat history, existing archives, local models, or Keychain.
