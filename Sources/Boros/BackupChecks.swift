import Foundation
import CryptoKit
import CSQLite
import Darwin

/// Isolated synthetic backups. No user store, model, or credential is opened.
enum BackupChecks {
    static func run() throws -> [String: Bool] {
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw BackupError.io("cannot resolve synthetic temporary directory") }
        let temporaryRoot = String(cString: resolved); free(resolved)
        let scratch = URL(fileURLWithPath: temporaryRoot, isDirectory: true)
            .appendingPathComponent("boros-backup-check-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let directory = scratch.appendingPathComponent("source", isDirectory: true)
        var owner: MemoryStore? = try MemoryStore(directory: directory)
        var checks: [String: Bool] = [:]
        let first = try owner!.createConversation(projectID: "synthetic-backup-alpha", title: "Synthetic backup")
        let second = try owner!.createConversation(projectID: "synthetic-backup-beta", title: "Other scope")
        let payload = String(repeating: "full archived synthetic text\n", count: 4000) + "EXACT_BACKUP_SENTINEL café \u{1F680}\0suffix"
        let human = try owner!.append(conversationID: first.id, role: .human, text: payload, status: .complete, turnID: "backup-turn", eventID: "backup-human")
        _ = try owner!.append(conversationID: second.id, role: .human, text: "Other source", status: .complete, turnID: "other-turn", eventID: "other-human")
        let body = Data("{\"model\":\"synthetic-backup-model\",\"messages\":[{\"role\":\"user\",\"content\":\"Synthetic private request snapshot\"}],\"stream\":true}".utf8)
        let admission = Data("{\"input_tokens\":37,\"output_reserve\":64}".utf8)
        let usage = Data("{\"prompt_tokens\":37,\"completion_tokens\":9}".utf8)
        _ = try owner!.beginInvocation(invocationID: "complete-attempt", conversationID: first.id, turnID: human.turnID,
            humanEventID: human.id, assistantEventID: "complete-assistant", providerIdentity: "http://localhost:11234/v1/chat/completions", requestBody: body, admissionJSON: admission)
        _ = try owner!.appendInvocationChunk(invocationID: "complete-attempt", sequence: 0, text: "COMPLETED_BACKUP_SENTINEL exact café")
        _ = try owner!.finalizeInvocation(invocationID: "complete-attempt", status: .complete, usageJSON: usage)
        let interrupted = try owner!.append(conversationID: first.id, role: .human, text: "Synthetic interrupted question", status: .complete, turnID: "interrupted-turn", eventID: "interrupted-human")
        _ = try owner!.beginInvocation(invocationID: "interrupted-attempt", conversationID: first.id, turnID: interrupted.turnID,
            humanEventID: interrupted.id, assistantEventID: "interrupted-assistant", providerIdentity: "native:synthetic", requestBody: body)
        let fragment = "INTERRUPTED_BACKUP_SENTINEL exact café \u{1F680}"
        _ = try owner!.appendInvocationChunk(invocationID: "interrupted-attempt", sequence: 0, text: fragment)
        let empty = try owner!.append(conversationID: first.id, role: .human, text: "Synthetic empty interrupted question", status: .complete, turnID: "empty-turn", eventID: "empty-human")
        _ = try owner!.beginInvocation(invocationID: "empty-attempt", conversationID: first.id, turnID: empty.turnID,
            humanEventID: empty.id, assistantEventID: "empty-assistant", providerIdentity: "native:synthetic", requestBody: body)
        try owner!.saveDraft(conversationID: first.id, text: "synthetic unsent draft café")
        try owner!.saveSetting(key: "synthetic-config", value: "synthetic preserved setting")
        let fileSettings = Data("{\"endpointURL\":\"http://localhost:11234/v1/\",\"endpointModel\":\"synthetic-backup-model\",\"profile\":\"custom-local\"}".utf8)
        try privateWrite(fileSettings, at: directory.appendingPathComponent("settings.json"))
        try privateWrite(Data("derived synthetic vectors".utf8), at: directory.appendingPathComponent("semantic.sqlite3"))
        try privateWrite(Data("fake synthetic model data".utf8), at: directory.appendingPathComponent("model.gguf"))

        let archive = scratch.appendingPathComponent("archive", isDirectory: true)
        let independentlyUpdatedSettings = Data("{\"endpointURL\":\"http://localhost:11234/v1/\",\"endpointModel\":\"synthetic-backup-model\",\"profile\":\"custom-local\",\"endpointTokenBudget\":64}".utf8)
        var snapshotCallbacks = 0
        let manifest = try BackupArchive.create(from: owner!, at: archive, cancellation: {
            snapshotCallbacks += 1
            if snapshotCallbacks == 2 {
                // The source read snapshot was pinned before this callback.
                // WAL accepts new committed writes while the backup copies its
                // older internally consistent snapshot.
                do {
                    _ = try owner!.append(conversationID: first.id, role: .human, text: "Synthetic transaction during backup", status: .complete, turnID: "during-turn", eventID: "during-backup-human")
                    try owner!.saveDraft(conversationID: first.id, text: "synthetic newer draft")
                    try privateWrite(independentlyUpdatedSettings, at: directory.appendingPathComponent("settings.json"))
                } catch { return true }
            }
            return false
        })
        checks["backup_active_owner_consistent_online_snapshot"] = manifest.inventory.events == 5 && manifest.inventory.invocations == 3 && manifest.inventory.unfinishedInvocations == 2 && manifest.inventory.chunks == 2
        checks["backup_manifest_roundtrip_verification"] = try BackupArchive.verify(at: archive) == manifest
        checks["backup_scope_model_configuration_inventory"] = manifest.inventory.scopes.map(\.projectID) == ["synthetic-backup-alpha", "synthetic-backup-beta"] && manifest.inventory.scopes[0].events == 4 && manifest.inventory.scopes[1].events == 1 && manifest.inventory.servedModels == ["synthetic-backup-model"] && manifest.inventory.providerIdentities.count == 2
        checks["backup_private_directory_and_files"] = try permissions(archive) == 0o700 && FileManager.default.contentsOfDirectory(atPath: archive.path).allSatisfy { permissions(archive.appendingPathComponent($0)) == 0o600 }
        checks["backup_semantic_models_runtime_sidecars_excluded"] = try FileManager.default.contentsOfDirectory(atPath: archive.path).sorted() == ["manifest.json", "memory.sqlite3", "settings.json"] && manifest.excluded.contains("derived-semantic-index-rebuild-required")
        checks["backup_settings_independent_point_capture_declared"] = manifest.settingsCapture == "independent-atomic-file-point-capture" && manifest.databaseCapture == "sqlite-online-backup-pinned-read-transaction"
        checks["backup_pinned_snapshot_excludes_concurrent_transactions"] = try manifest.inventory.events == 5 && owner!.events(conversationID: first.id).contains { $0.id == "during-backup-human" }
        _ = try owner!.append(conversationID: first.id, role: .human, text: "Synthetic after archive publication", status: .complete, turnID: "later-turn", eventID: "later-human")
        let restored = scratch.appendingPathComponent("restored", isDirectory: true)
        _ = try BackupArchive.restore(from: archive, to: restored, authority: .unmanagedNoDeletion)
        var restoredOwner: MemoryStore? = try MemoryStore(directory: restored)
        let sources = try restoredOwner!.events(conversationID: first.id)
        checks["restore_snapshot_excludes_post_backup_publication"] = !sources.contains { ["later-human", "during-backup-human"].contains($0.id) } && sources.count == 6
        checks["restore_complete_exact_history_and_utf8_pages"] = try sources.first { $0.id == human.id }?.text == payload && paged(restoredOwner!, human.id) == Data(payload.utf8)
        checks["restore_draft_database_settings_and_file_settings"] = try restoredOwner!.loadDraft(conversationID: first.id) == "synthetic unsent draft café" && restoredOwner!.loadSetting(key: "synthetic-config") == "synthetic preserved setting" && Data(contentsOf: restored.appendingPathComponent("settings.json")) == independentlyUpdatedSettings
        checks["backup_independent_settings_point_capture_boundary"] = try restoredOwner!.loadDraft(conversationID: first.id) != owner!.loadDraft(conversationID: first.id) && Data(contentsOf: restored.appendingPathComponent("settings.json")) == independentlyUpdatedSettings
        let complete = try restoredOwner!.invocation(id: "complete-attempt")!
        checks["restore_exact_request_admission_usage_journal"] = complete.requestBody == body && complete.admissionJSON == admission && complete.usageJSON == usage && complete.finalStatus == .complete && complete.chunkCount == 1
        let partial = try restoredOwner!.invocation(id: "interrupted-attempt")!
        let emptyRecovered = try restoredOwner!.invocation(id: "empty-attempt")!
        checks["restore_interrupted_chunks_recovered_partial"] = partial.finalStatus == .partial && partial.terminalReason == .interrupted && partial.recovered && sources.first { $0.id == "interrupted-assistant" }?.text == fragment
        checks["restore_interrupted_empty_attempt_recovered_failed"] = emptyRecovered.finalStatus == .failed && emptyRecovered.terminalReason == .interrupted && emptyRecovered.recovered && sources.first { $0.id == "empty-assistant" }?.text == ""
        checks["restore_recovered_source_searchable"] = try restoredOwner!.search(query: "INTERRUPTED_BACKUP_SENTINEL", projectID: "synthetic-backup-alpha").first?.eventID == "interrupted-assistant"
        checks["restore_rebuilt_lexical_index_preserves_embedded_nul_suffix"] = try restoredOwner!.search(query: "suffix", projectID: "synthetic-backup-alpha").first?.eventID == human.id
        checks["restore_existing_active_owner_refused"] = rejects { _ = try BackupArchive.restore(from: archive, to: restored, authority: .unmanagedNoDeletion) }
        restoredOwner = nil
        restoredOwner = try MemoryStore(directory: restored)
        checks["restore_real_close_reopen_exact_sources_no_duplication"] = try restoredOwner!.events(conversationID: first.id).count == sources.count && paged(restoredOwner!, human.id) == Data(payload.utf8) && restoredOwner!.invocation(id: "interrupted-attempt")?.finalizedAt == partial.finalizedAt
        restoredOwner = nil
        checks["restore_existing_closed_directory_refused"] = rejects { _ = try BackupArchive.restore(from: archive, to: restored, authority: .unmanagedNoDeletion) }
        checks["backup_existing_archive_refused_unchanged"] = try rejects { _ = try BackupArchive.create(from: owner!, at: archive) } && BackupArchive.verify(at: archive) == manifest

        let changedAuthority = BackupControlState(authorityID: "synthetic-enabled-authority", epoch: 1, deletionControlsEnabled: true, ledgerDigest: String(repeating: "a", count: 64))
        let authorityDestination = scratch.appendingPathComponent("incompatible-restore")
        checks["restore_enabled_current_authority_rejects_unmanaged_archive"] = rejects { _ = try BackupArchive.restore(from: archive, to: authorityDestination, authority: changedAuthority) } && !FileManager.default.fileExists(atPath: authorityDestination.path)
        checks["restore_missing_or_changed_control_epoch_refused"] = rejects { _ = try BackupArchive.restore(from: archive, to: authorityDestination, authority: BackupControlState(authorityID: "", epoch: 0, deletionControlsEnabled: false, ledgerDigest: nil)) } && rejects { _ = try BackupArchive.restore(from: archive, to: authorityDestination, authority: BackupControlState(authorityID: BackupControlState.unmanagedNoDeletion.authorityID, epoch: 1, deletionControlsEnabled: false, ledgerDigest: nil)) }
        checks["backup_unimplemented_deletion_authority_refused"] = rejects { _ = try BackupArchive.create(from: owner!, at: scratch.appendingPathComponent("controlled-archive"), control: changedAuthority) }

        let symlink = scratch.appendingPathComponent("symbolic-destination")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: restored)
        checks["restore_symlink_destination_refused_without_clobber"] = try rejects { _ = try BackupArchive.restore(from: archive, to: symlink, authority: .unmanagedNoDeletion) } && FileManager.default.destinationOfSymbolicLink(atPath: symlink.path) == restored.path
        let parentLink = scratch.appendingPathComponent("symbolic-parent")
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: scratch)
        checks["backup_restore_symbolic_parent_refused"] = rejects { _ = try BackupArchive.create(from: owner!, at: parentLink.appendingPathComponent("archive-through-link")) } && rejects { _ = try BackupArchive.restore(from: archive, to: parentLink.appendingPathComponent("restore-through-link"), authority: .unmanagedNoDeletion) }
        let cancelled = scratch.appendingPathComponent("cancelled-archive")
        var cancellationChecks = 0
        checks["backup_cancellation_removes_unpublished_staging"] = try rejects { _ = try BackupArchive.create(from: owner!, at: cancelled, cancellation: { cancellationChecks += 1; return cancellationChecks == 3 }) } && !FileManager.default.fileExists(atPath: cancelled.path) && !FileManager.default.contentsOfDirectory(atPath: scratch.path).contains { $0.hasPrefix(".boros-staging-") }
        let raced = scratch.appendingPathComponent("raced-archive")
        var callbacks = 0
        checks["backup_final_publication_no_clobber_competing_destination"] = try rejects {
            _ = try BackupArchive.create(from: owner!, at: raced, cancellation: {
                callbacks += 1
                if callbacks == 1 { try? privateWrite(Data("synthetic competing file".utf8), at: raced) }
                return false
            })
        } && Data(contentsOf: raced) == Data("synthetic competing file".utf8)

        func corrupted(_ name: String, _ mutation: (URL) throws -> Void) throws -> URL {
            let copy = scratch.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.copyItem(at: archive, to: copy)
            try mutation(copy)
            return copy
        }
        let truncated = try corrupted("truncated") { folder in
            let database = folder.appendingPathComponent("memory.sqlite3")
            let data = try Data(contentsOf: database); try privateWrite(Data(data.prefix(100)), at: database)
        }
        checks["backup_truncated_database_refused"] = rejects { _ = try BackupArchive.verify(at: truncated) }
        let sourceCorrupt = try corrupted("source-corrupt") { folder in
            try sql(folder.appendingPathComponent("memory.sqlite3"), "UPDATE events SET digest='altered' WHERE id='backup-human'")
            try refreshDatabaseHash(folder)
        }
        checks["backup_source_digest_corruption_refused_with_matching_file_hash"] = rejects { _ = try BackupArchive.verify(at: sourceCorrupt) }
        let staleLexical = try corrupted("stale-lexical-index") { folder in
            try sql(folder.appendingPathComponent("memory.sqlite3"), "INSERT INTO event_fts(event_fts) VALUES('delete-all')")
            try refreshDatabaseHash(folder)
        }
        checks["backup_stale_derived_lexical_state_keeps_exact_evidence_verifiable"] = try BackupArchive.verify(at: staleLexical).inventory == manifest.inventory
        let repairedDirectory = scratch.appendingPathComponent("repaired-lexical-store", isDirectory: true)
        _ = try BackupArchive.restore(from: staleLexical, to: repairedDirectory, authority: .unmanagedNoDeletion)
        do {
            let repairedOwner = try MemoryStore(directory: repairedDirectory)
            checks["restore_rebuild_repairs_missing_derived_lexical_state"] = try repairedOwner.search(query: "EXACT_BACKUP_SENTINEL", projectID: "synthetic-backup-alpha").contains { $0.eventID == human.id } && repairedOwner.search(query: "COMPLETED_BACKUP_SENTINEL", projectID: "synthetic-backup-alpha").first?.eventID == "complete-assistant"
        }
        let chunkCorrupt = try corrupted("chunk-corrupt") { folder in
            try sql(folder.appendingPathComponent("memory.sqlite3"), "UPDATE invocation_chunks SET digest='altered' WHERE invocation_id='interrupted-attempt'")
            try refreshDatabaseHash(folder)
        }
        checks["backup_chunk_digest_corruption_refused"] = rejects { _ = try BackupArchive.verify(at: chunkCorrupt) }
        let receiptCorrupt = try corrupted("receipt-corrupt") { folder in
            try sql(folder.appendingPathComponent("memory.sqlite3"), "UPDATE invocations SET usage_digest='altered' WHERE id='complete-attempt'")
            try refreshDatabaseHash(folder)
        }
        checks["backup_usage_metadata_corruption_refused"] = rejects { _ = try BackupArchive.verify(at: receiptCorrupt) }
        let schemaCorrupt = try corrupted("unknown-schema") { folder in
            try sql(folder.appendingPathComponent("memory.sqlite3"), "PRAGMA user_version=999")
            try refreshDatabaseHash(folder)
        }
        checks["backup_unknown_database_schema_refused"] = rejects { _ = try BackupArchive.verify(at: schemaCorrupt) }
        let inventoryCorrupt = try corrupted("unknown-inventory") { folder in
            try privateWrite(Data("unlisted".utf8), at: folder.appendingPathComponent("extra.txt"))
        }
        checks["backup_unknown_file_inventory_refused"] = rejects { _ = try BackupArchive.verify(at: inventoryCorrupt) }
        let objectCorrupt = try corrupted("unknown-table") { folder in
            try sql(folder.appendingPathComponent("memory.sqlite3"), "CREATE TABLE unexpected(payload BLOB)")
            try refreshDatabaseHash(folder)
        }
        checks["backup_unknown_database_object_refused"] = rejects { _ = try BackupArchive.verify(at: objectCorrupt) }
        let foreignCorrupt = try corrupted("foreign-corrupt") { folder in
            try sql(folder.appendingPathComponent("memory.sqlite3"), "PRAGMA foreign_keys=OFF; UPDATE drafts SET conversation_id='missing-conversation'")
            try refreshDatabaseHash(folder)
        }
        checks["backup_foreign_key_corruption_refused"] = rejects { _ = try BackupArchive.verify(at: foreignCorrupt) }
        let terminalCorrupt = try corrupted("terminal-corrupt") { folder in
            try sql(folder.appendingPathComponent("memory.sqlite3"), "UPDATE invocations SET terminal_reason='transportFailure' WHERE id='complete-attempt'")
            try refreshDatabaseHash(folder)
        }
        checks["backup_terminal_semantics_corruption_refused"] = rejects { _ = try BackupArchive.verify(at: terminalCorrupt) }
        let archiveLink = scratch.appendingPathComponent("symbolic-archive")
        try FileManager.default.createSymbolicLink(at: archiveLink, withDestinationURL: archive)
        checks["backup_symbolic_archive_refused"] = rejects { _ = try BackupArchive.verify(at: archiveLink) }
        let fileLink = try corrupted("symbolic-file") { folder in
            let database = folder.appendingPathComponent("memory.sqlite3")
            try FileManager.default.removeItem(at: database)
            try FileManager.default.createSymbolicLink(at: database, withDestinationURL: archive.appendingPathComponent("memory.sqlite3"))
        }
        checks["backup_symbolic_database_refused"] = rejects { _ = try BackupArchive.verify(at: fileLink) }
        let credentialSettings = try corrupted("credential-settings") { folder in
            let file = folder.appendingPathComponent("settings.json")
            try privateWrite(Data("{\"api_key\":\"synthetic-placeholder\"}".utf8), at: file)
            try refreshFileHash(folder, name: "settings.json")
        }
        checks["backup_credential_configuration_refused"] = rejects { _ = try BackupArchive.verify(at: credentialSettings) }
        let failedRestore = scratch.appendingPathComponent("invalid-restore")
        checks["restore_corrupt_archive_never_published"] = rejects { _ = try BackupArchive.restore(from: sourceCorrupt, to: failedRestore, authority: .unmanagedNoDeletion) } && !FileManager.default.fileExists(atPath: failedRestore.path)
        owner = nil
        checks.merge(try commandChecks(in: scratch)) { _, new in new }
        checks.merge(try episodeChecks(in: scratch)) { _, new in new }
        checks.merge(try cancelledRecoveryChecks(in: scratch)) { _, new in new }
        checks.merge(try schemaTwoArchiveChecks(in: scratch, archive: archive)) { _, new in new }
        checks.merge(try schemaOneArchiveChecks(in: scratch, archive: archive)) { _, new in new }
        checks.merge(try localReadArchiveChecks(in: scratch)) { _, new in new }
        checks.merge(try ReadIdentityChecks.run()) { _, new in new }
        checks.merge(try closedWALRecognitionChecks(in: scratch)) { _, new in new }
        return checks
    }

    private static func closedWALRecognitionChecks(in scratch: URL) throws -> [String: Bool] {
        let directory = scratch.appendingPathComponent("closed-wal-source", isDirectory: true)
        var owner: MemoryStore? = try MemoryStore(directory: directory)
        withExtendedLifetime(owner) {}
        owner = nil
        let database = directory.appendingPathComponent("memory.sqlite3")
        try sql(database, "PRAGMA journal_mode=WAL; PRAGMA wal_checkpoint(TRUNCATE)")
        // The synthetic checkpoint has no live owners. Some SQLite builds
        // retain empty WAL/SHM files on close; remove only the proven empty WAL
        // and its derived SHM to construct the sidecar-free header fixture.
        let wal = URL(fileURLWithPath: database.path + "-wal")
        if FileManager.default.fileExists(atPath: wal.path) {
            guard try Data(contentsOf: wal).isEmpty else { throw BackupError.invalid("synthetic WAL checkpoint was incomplete") }
            try FileManager.default.removeItem(at: wal)
        }
        let shm = URL(fileURLWithPath: database.path + "-shm")
        if FileManager.default.fileExists(atPath: shm.path) { try FileManager.default.removeItem(at: shm) }
        let before = try Data(contentsOf: database)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let fixtureValid = before.count >= 100 && before[18] == 2 && before[19] == 2
            && !names.contains("memory.sqlite3-wal") && !names.contains("memory.sqlite3-shm")
        try BackupArchive.recognizeExistingSource(at: directory)
        return [
            "backup_recognizes_closed_wal_without_sidecars": fixtureValid,
            "backup_recognition_leaves_original_closed_wal_untouched": try Data(contentsOf: database) == before
                && FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == names
        ]
    }

    private static func commandChecks(in scratch: URL) throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let directory = scratch.appendingPathComponent("command-source", isDirectory: true)
        var owner: MemoryStore? = try MemoryStore(directory: directory)
        let conversation = try owner!.createConversation(projectID: "PRIVATE_SCOPE_SENTINEL", title: "Synthetic command source")
        let prompt = "PRIVATE_PROMPT_SENTINEL synthetic café \u{1F680}"
        _ = try owner!.append(conversationID: conversation.id, role: .human, text: prompt, status: .complete, turnID: "command-turn", eventID: "PRIVATE_EVENT_SENTINEL")
        try owner!.saveDraft(conversationID: conversation.id, text: "PRIVATE_DRAFT_SENTINEL")
        owner = nil
        let archive = scratch.appendingPathComponent("command-archive", isDirectory: true)
        let created = try captureCommand(["/synthetic/Boros", "--backup-create", "--data-directory", directory.path, "--archive", archive.path])
        let createdMetadata = (try? JSONSerialization.jsonObject(with: created.output)) as? [String: Any]
        checks["backup_cli_create_existing_store_json_summary"] = created.status == 0 && created.errors.isEmpty && createdMetadata?["operation"] as? String == "backup-create" && createdMetadata?["archived_events"] as? Int == 1 && createdMetadata?["control_state"] as? String == "unmanaged-no-deletion"
        let verified = try captureCommand(["--backup-verify", "--archive", archive.path])
        let verifiedMetadata = (try? JSONSerialization.jsonObject(with: verified.output)) as? [String: Any]
        checks["backup_cli_verify_matches_archive_identity"] = verified.status == 0 && verified.errors.isEmpty && verifiedMetadata?["archive_id"] as? String == createdMetadata?["archive_id"] as? String && verifiedMetadata?["operation"] as? String == "backup-verify"
        let restoredDirectory = scratch.appendingPathComponent("command-restored", isDirectory: true)
        let restored = try captureCommand(["--backup-restore", "--archive", archive.path, "--destination", restoredDirectory.path])
        let restoredMetadata = (try? JSONSerialization.jsonObject(with: restored.output)) as? [String: Any]
        checks["backup_cli_restore_new_directory_json_summary"] = restored.status == 0 && restored.errors.isEmpty && restoredMetadata?["operation"] as? String == "backup-restore" && restoredMetadata?["restored_interrupted_attempts"] as? Int == 0
        do {
            let reopened = try MemoryStore(directory: restoredDirectory)
            checks["backup_cli_roundtrip_complete_sources_draft_reopen"] = try reopened.events(conversationID: conversation.id).first?.text == prompt && reopened.loadDraft(conversationID: conversation.id) == "PRIVATE_DRAFT_SENTINEL"
        }
        let allOutput = String(decoding: created.output + verified.output + restored.output + created.errors + verified.errors + restored.errors, as: UTF8.self)
        checks["backup_cli_success_output_excludes_private_content_scope_paths"] = ["PRIVATE_SCOPE_SENTINEL", "PRIVATE_PROMPT_SENTINEL", "PRIVATE_DRAFT_SENTINEL", "PRIVATE_EVENT_SENTINEL", scratch.path].allSatisfy { !allOutput.contains($0) }
        let allowedMetadata = Set(["operation", "status", "archive_id", "archive_version", "database_schema", "control_state", "conversations", "scope_count", "archived_events", "archived_source_bytes", "invocations", "chunks", "unfinished_archived_invocations", "episodes", "chat_episodes", "local_read_episodes", "episode_work", "unfinished_archived_episodes", "uncertain_archived_work"])
        checks["backup_cli_metadata_keys_have_no_request_or_configuration_fields"] = createdMetadata.map { Set($0.keys) == allowedMetadata } ?? false
        let activeOwner = try MemoryStore(directory: directory)
        let blocked = try captureCommand(["--backup-create", "--data-directory", directory.path, "--archive", scratch.appendingPathComponent("blocked-command-archive").path])
        checks["backup_cli_create_active_owner_refused_content_free"] = blocked.status == 1 && blocked.output.isEmpty && String(decoding: blocked.errors, as: UTF8.self).contains("Another Boros process") && !String(decoding: blocked.errors, as: UTF8.self).contains(scratch.path)
        withExtendedLifetime(activeOwner) {}
        let duplicateRestore = try captureCommand(["--backup-restore", "--archive", archive.path, "--destination", restoredDirectory.path])
        checks["backup_cli_restore_existing_destination_refused"] = duplicateRestore.status == 1 && duplicateRestore.output.isEmpty
        let absentSource = scratch.appendingPathComponent("missing-command-source", isDirectory: true)
        let missingSource = try captureCommand(["--backup-create", "--data-directory", absentSource.path, "--archive", scratch.appendingPathComponent("missing-source-archive").path])
        checks["backup_cli_missing_source_never_creates_empty_store"] = missingSource.status == 1 && missingSource.output.isEmpty && !FileManager.default.fileExists(atPath: absentSource.path)
        let unrelatedDirectory = scratch.appendingPathComponent("non-boros-command-source", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelatedDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let unrelatedDatabase = unrelatedDirectory.appendingPathComponent("memory.sqlite3")
        try privateWrite(Data(), at: unrelatedDatabase)
        try sql(unrelatedDatabase, "CREATE TABLE unrelated(payload BLOB); PRAGMA user_version=0")
        let beforeUnrelated = try Data(contentsOf: unrelatedDatabase)
        let unrelatedArchive = scratch.appendingPathComponent("non-boros-command-archive")
        let unrelatedSource = try captureCommand(["--backup-create", "--data-directory", unrelatedDirectory.path, "--archive", unrelatedArchive.path])
        checks["backup_cli_unrecognized_source_schema_refused_without_mutation"] = try unrelatedSource.status == 1 && unrelatedSource.output.isEmpty && Data(contentsOf: unrelatedDatabase) == beforeUnrelated && !FileManager.default.fileExists(atPath: unrelatedArchive.path) && !FileManager.default.fileExists(atPath: unrelatedDirectory.appendingPathComponent("owner.lock").path)
        for version in [1, 2, 3, 4] {
            let foreignDirectory = scratch.appendingPathComponent("foreign-command-source-\(version)", isDirectory: true)
            try FileManager.default.createDirectory(at: foreignDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let database = foreignDirectory.appendingPathComponent("memory.sqlite3")
            try privateWrite(Data(), at: database)
            try sql(database, "CREATE TABLE unrelated(payload BLOB); INSERT INTO unrelated VALUES(X'010203'); PRAGMA user_version=\(version)")
            let before = try Data(contentsOf: database)
            let schemaBefore = try schemaSnapshot(database)
            let inventoryBefore = try FileManager.default.contentsOfDirectory(atPath: foreignDirectory.path).sorted()
            let foreignArchive = scratch.appendingPathComponent("foreign-command-archive-\(version)")
            let result = try captureCommand(["--backup-create", "--data-directory", foreignDirectory.path, "--archive", foreignArchive.path])
            checks["backup_cli_foreign_version_\(version)_bytes_schema_inventory_unchanged"] = try result.status == 1 && result.output.isEmpty && Data(contentsOf: database) == before && schemaSnapshot(database) == schemaBefore && FileManager.default.contentsOfDirectory(atPath: foreignDirectory.path).sorted() == inventoryBefore && !FileManager.default.fileExists(atPath: foreignArchive.path) && !FileManager.default.fileExists(atPath: foreignDirectory.appendingPathComponent("owner.lock").path)
        }
        let corruptDirectory = scratch.appendingPathComponent("corrupt-command-source", isDirectory: true)
        do {
            let corruptOwner = try MemoryStore(directory: corruptDirectory)
            let item = try corruptOwner.createConversation(projectID: "corrupt-synthetic", title: "Synthetic corrupt source")
            _ = try corruptOwner.append(conversationID: item.id, role: .human, text: "Synthetic source before corruption", status: .complete, turnID: "corrupt-turn", eventID: "corrupt-event")
        }
        let corruptDatabase = corruptDirectory.appendingPathComponent("memory.sqlite3")
        try sql(corruptDatabase, "UPDATE events SET digest='broken' WHERE id='corrupt-event'")
        let corruptBytesBefore = try Data(contentsOf: corruptDatabase)
        let corruptInventoryBefore = try FileManager.default.contentsOfDirectory(atPath: corruptDirectory.path).sorted()
        let corruptCommand = try captureCommand(["--backup-create", "--data-directory", corruptDirectory.path, "--archive", scratch.appendingPathComponent("corrupt-command-archive").path])
        checks["backup_cli_corrupt_known_source_refused_without_mutation"] = try corruptCommand.status == 1 && corruptCommand.output.isEmpty && Data(contentsOf: corruptDatabase) == corruptBytesBefore && FileManager.default.contentsOfDirectory(atPath: corruptDirectory.path).sorted() == corruptInventoryBefore
        let legacyDirectory = scratch.appendingPathComponent("legacy-command-source", isDirectory: true)
        var legacyConversationID = ""
        do {
            let legacyOwner = try MemoryStore(directory: legacyDirectory)
            let item = try legacyOwner.createConversation(projectID: "legacy-synthetic", title: "Synthetic legacy source")
            legacyConversationID = item.id
            _ = try legacyOwner.append(conversationID: item.id, role: .human, text: "Synthetic recognized legacy history", status: .complete, turnID: "legacy-turn", eventID: "legacy-event")
        }
        try downgrade(legacyDirectory.appendingPathComponent("memory.sqlite3"), to: 1)
        let legacyArchive = scratch.appendingPathComponent("legacy-command-archive", isDirectory: true)
        let legacyCommand = try captureCommand(["--backup-create", "--data-directory", legacyDirectory.path, "--archive", legacyArchive.path])
        var legacyReadback = false
        if legacyCommand.status == 0 {
            let legacyOwner = try MemoryStore(directory: legacyDirectory)
            legacyReadback = try legacyOwner.events(conversationID: legacyConversationID).first?.text == "Synthetic recognized legacy history" && BackupArchive.verify(at: legacyArchive).databaseSchema == 4
        }
        checks["backup_cli_strict_recognition_accepts_genuine_schema_one_upgrade"] = legacyCommand.status == 0 && legacyCommand.errors.isEmpty && legacyReadback
        let versionTwoDirectory = scratch.appendingPathComponent("schema-two-command-source", isDirectory: true)
        do {
            let itemOwner = try MemoryStore(directory: versionTwoDirectory)
            let item = try itemOwner.createConversation(projectID: "legacy-two-synthetic", title: "Synthetic schema two source")
            _ = try itemOwner.append(conversationID: item.id, role: .human, text: "Synthetic schema two accepted history", status: .complete, turnID: "legacy-two-turn", eventID: "legacy-two-event")
        }
        try downgrade(versionTwoDirectory.appendingPathComponent("memory.sqlite3"), to: 2)
        let versionTwoArchive = scratch.appendingPathComponent("schema-two-command-archive", isDirectory: true)
        let versionTwoCommand = try captureCommand(["--backup-create", "--data-directory", versionTwoDirectory.path, "--archive", versionTwoArchive.path])
        checks["backup_cli_strict_recognition_accepts_genuine_schema_two_upgrade"] = try versionTwoCommand.status == 0 && versionTwoCommand.errors.isEmpty && BackupArchive.verify(at: versionTwoArchive).databaseSchema == 4
        let missingArchive = try captureCommand(["--backup-verify", "--archive", scratch.appendingPathComponent("missing-command-archive").path])
        checks["backup_cli_verify_missing_archive_refused"] = missingArchive.status == 1 && missingArchive.output.isEmpty
        let invalid: [[String]] = [
            ["--backup-create", "--data-directory", directory.path],
            ["--backup-verify", "--archive"],
            ["--backup-verify", "--archive", "relative/path"],
            ["--backup-verify", "--archive", archive.path, "--archive", archive.path],
            ["--backup-verify", "--archive", archive.path, "--unknown", "PRIVATE_ARGUMENT_SENTINEL"],
            ["--backup-verify", "--backup-restore", "--archive", archive.path],
            ["--backup-create", "--destination", directory.path, "--archive", archive.path],
            ["--backup-verify", "--archive", scratch.path + "/../PRIVATE_ARGUMENT_SENTINEL"],
            ["--archive", archive.path, "--backup-verify"]]
        var invalidPassed = true
        for args in invalid {
            let result = try captureCommand(args)
            invalidPassed = invalidPassed && result.status == 2 && result.output.isEmpty && !String(decoding: result.errors, as: UTF8.self).contains("PRIVATE_ARGUMENT_SENTINEL") && !String(decoding: result.errors, as: UTF8.self).contains(scratch.path)
        }
        checks["backup_cli_missing_duplicate_unknown_mixed_relative_dot_args_refused"] = invalidPassed
        let unrelated = try captureCommand(["/synthetic/Boros", "--memory-self-test"])
        let empty = try captureCommand([])
        checks["backup_cli_unrelated_and_empty_dispatch_return_nil"] = unrelated.status == nil && unrelated.output.isEmpty && unrelated.errors.isEmpty && empty.status == nil && empty.output.isEmpty && empty.errors.isEmpty
        return checks
    }

    /// One live schema-4 snapshot includes completed receipts, interrupted
    /// answering, preflight-only inference and never-armed reservations.
    private static func episodeChecks(in scratch: URL) throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let directory = scratch.appendingPathComponent("episode-source", isDirectory: true)
        var owner: MemoryStore? = try MemoryStore(directory: directory)
        let conversation = try owner!.createConversation(projectID: "synthetic-episode-backup", title: "Synthetic episode backup")
        let clock = EpisodeClockSnapshot(domain: "synthetic-backup-clock-v1", continuousNanoseconds: 1_000_000_000, utc: Date(timeIntervalSince1970: 1_700_000_000))
        let body = Data("{\"model\":\"synthetic-episode-model\",\"messages\":[{\"role\":\"user\",\"content\":\"SYNTHETIC_EPISODE_PRIVATE_REQUEST\"}],\"max_tokens\":128}".utf8)
        let calibrationBody = Data("{\"model\":\"synthetic-episode-model\",\"messages\":[{\"role\":\"user\",\"content\":\"SYNTHETIC_CALIBRATION\"}],\"max_tokens\":1}".utf8)
        let adapter = "http://localhost:11234/v1/chat/completions"
        func begin(_ episode: String, _ turn: String, _ human: String) throws {
            _ = try owner!.acceptRequestAndBeginEpisode(conversationID: conversation.id, turnID: turn, humanEventID: human,
                episodeID: episode, text: "SYNTHETIC_EPISODE_BACKUP_ACCEPTED_SOURCE " + human, limits: EpisodeLimits(), clock: clock)
        }
        func reserve(_ episode: String, _ operation: String, _ kind: EpisodeWorkKind, _ resources: EpisodeResources, _ snapshot: Data) throws -> EpisodeWorkRecord {
            try owner!.reserveEpisodeWork(episodeID: episode,
                request: EpisodeWorkRequest(id: operation, parentID: nil, kind: kind, resources: resources,
                    adapterIdentity: adapter, snapshot: snapshot, inputTokensKnown: true), clock: clock)
        }
        func arm(_ work: EpisodeWorkRecord) throws -> EpisodeWorkRecord {
            try owner!.armEpisodeWork(episodeID: work.episodeID, operationID: work.id, expectedRevision: work.revision, clock: clock)
        }
        func settle(_ work: EpisodeWorkRecord, _ observed: EpisodeResources) throws -> EpisodeWorkRecord {
            try owner!.settleEpisodeWork(episodeID: work.episodeID, operationID: work.id,
                settlement: EpisodeWorkSettlement(receiptID: work.id + "-receipt", outcome: .completed, observed: observed,
                    evidence: Data("{\"synthetic_verified\":true}".utf8)), clock: clock)
        }
        try begin("episode-completed", "episode-complete-turn", "episode-complete-human")
        let calibration = try arm(reserve("episode-completed", "episode-complete-calibration", .calibration,
            EpisodeResources(inputTokens: 13, outputTokens: 1, modelCalls: 1, httpAttempts: 1), calibrationBody))
        let calibrationReceipt = try settle(calibration, EpisodeResources(inputTokens: 13, outputTokens: 1, modelCalls: 1, httpAttempts: 1))
        let answer = try reserve("episode-completed", "episode-complete-answer", .answer,
            EpisodeResources(inputTokens: 37, outputTokens: 64, modelCalls: 1, httpAttempts: 1), body)
        _ = try owner!.beginInvocation(invocationID: "episode-complete-invocation", conversationID: conversation.id,
            turnID: "episode-complete-turn", humanEventID: "episode-complete-human", assistantEventID: "episode-complete-assistant",
            providerIdentity: adapter, requestBody: body, episodeID: answer.episodeID, episodeWorkID: answer.id)
        _ = try arm(answer)
        _ = try owner!.appendInvocationChunk(invocationID: "episode-complete-invocation", sequence: 0, text: "SYNTHETIC_EPISODE_COMPLETED_ANSWER café")
        let answerReceipt = try settle(answer, EpisodeResources(inputTokens: 37, outputTokens: 5, modelCalls: 1, httpAttempts: 1))
        let complete = try owner!.finishEpisode(episodeID: "episode-completed", reason: .completed, clock: clock)
        _ = try owner!.finalizeInvocation(invocationID: "episode-complete-invocation", status: .complete,
            usageJSON: Data("{\"prompt_tokens\":37,\"completion_tokens\":5}".utf8))

        try begin("episode-preflight", "episode-preflight-turn", "episode-preflight-human")
        let pendingTokenizer = try reserve("episode-preflight", "episode-pending-tokenizer", .tokenizer,
            EpisodeResources(httpAttempts: 1), body)
        let uncertainCalibration = try arm(reserve("episode-preflight", "episode-uncertain-calibration", .calibration,
            EpisodeResources(inputTokens: 17, outputTokens: 1, modelCalls: 1, httpAttempts: 1), calibrationBody))
        let pendingAnswer = try reserve("episode-preflight", "episode-pending-answer", .answer,
            EpisodeResources(inputTokens: 23, outputTokens: 32, modelCalls: 1, httpAttempts: 1), body)
        try begin("episode-answering", "episode-answering-turn", "episode-answering-human")
        let uncertainAnswer = try reserve("episode-answering", "episode-uncertain-answer", .answer,
            EpisodeResources(inputTokens: 31, outputTokens: 128, modelCalls: 1, httpAttempts: 1), body)
        _ = try owner!.beginInvocation(invocationID: "episode-uncertain-invocation", conversationID: conversation.id,
            turnID: "episode-answering-turn", humanEventID: "episode-answering-human", assistantEventID: "episode-uncertain-assistant",
            providerIdentity: adapter, requestBody: body, episodeID: uncertainAnswer.episodeID, episodeWorkID: uncertainAnswer.id)
        _ = try arm(uncertainAnswer)
        let fragment = "SYNTHETIC_EPISODE_RESTORED_PARTIAL café \u{1F680}"
        _ = try owner!.appendInvocationChunk(invocationID: "episode-uncertain-invocation", sequence: 0, text: fragment)
        let beforePreflight = try owner!.episodeReceipt(id: "episode-preflight", clock: clock)
        let beforeAnswering = try owner!.episodeReceipt(id: "episode-answering", clock: clock)
        let archive = scratch.appendingPathComponent("episode-archive", isDirectory: true)
        let manifest = try BackupArchive.create(from: owner!, at: archive)
        let expectedCharged = try complete.charged.adding(beforePreflight.charged).adding(beforeAnswering.charged)
        let expectedHeld = try complete.held.adding(beforePreflight.held).adding(beforeAnswering.held)
        checks["backup_schema_four_episode_inventory_captures_active_and_settled_work"] = manifest.databaseSchema == 4 && manifest.inventory.episodes == 3 && manifest.inventory.unfinishedEpisodes == 2 && manifest.inventory.episodeWork == 6 && manifest.inventory.episodePreparedWork == 2 && manifest.inventory.episodeUncertainWork == 2 && manifest.inventory.episodeCharged == expectedCharged && manifest.inventory.episodeHeld == expectedHeld
        checks["backup_episode_request_snapshots_deduplicate_exact_bodies"] = manifest.inventory.episodeSnapshots == 2 && manifest.inventory.episodeSnapshotBytes == Int64(body.count + calibrationBody.count)
        checks["backup_episode_manifest_roundtrip_verified"] = try BackupArchive.verify(at: archive) == manifest
        checks.merge(try schemaThreeArchiveChecks(in: scratch, archive: archive)) { _, new in new }
        let restored = scratch.appendingPathComponent("episode-restored", isDirectory: true)
        _ = try BackupArchive.restore(from: archive, to: restored, authority: .unmanagedNoDeletion)
        var restoredOwner: MemoryStore? = try MemoryStore(directory: restored)
        let restoredComplete = try restoredOwner!.episodeReceipt(id: "episode-completed", clock: clock)
        let restoredPreflight = try restoredOwner!.episodeReceipt(id: "episode-preflight", clock: clock)
        let restoredAnswering = try restoredOwner!.episodeReceipt(id: "episode-answering", clock: clock)
        let restoredCalibration = try restoredOwner!.episodeWork(episodeID: uncertainCalibration.episodeID, operationID: uncertainCalibration.id)!
        let restoredAnswer = try restoredOwner!.episodeWork(episodeID: uncertainAnswer.episodeID, operationID: uncertainAnswer.id)!
        checks["restore_episode_completed_receipts_and_usage_exact"] = try restoredComplete == complete && restoredOwner!.episodeWork(episodeID: calibration.episodeID, operationID: calibration.id) == calibrationReceipt && restoredOwner!.episodeWork(episodeID: answer.episodeID, operationID: answer.id) == answerReceipt
        checks["restore_preflight_only_episode_interrupts_without_resend"] = restoredPreflight.state == .interrupted && restoredPreflight.charged == beforePreflight.charged && restoredPreflight.held == EpisodeResources(outputTokens: 1) && restoredCalibration.state == .outcomeUnknown && restoredCalibration.observed == nil && restoredCalibration.recovered
        let restoredTokenizer = try restoredOwner!.episodeWork(episodeID: pendingTokenizer.episodeID, operationID: pendingTokenizer.id)!
        let restoredPendingAnswer = try restoredOwner!.episodeWork(episodeID: pendingAnswer.episodeID, operationID: pendingAnswer.id)!
        checks["restore_only_unarmed_reservations_release_capacity"] = restoredTokenizer.state == .cancelledBeforeDispatch && restoredTokenizer.charged == .zero && restoredTokenizer.held == .zero && restoredPendingAnswer.state == .cancelledBeforeDispatch && restoredPendingAnswer.charged == .zero && restoredPendingAnswer.held == .zero
        let invocation = try restoredOwner!.invocation(id: "episode-uncertain-invocation")!
        checks["restore_armed_answer_keeps_unknown_output_and_invocation_linkage"] = restoredAnswering.state == .interrupted && restoredAnswering.charged == beforeAnswering.charged && restoredAnswering.held == EpisodeResources(outputTokens: 128) && restoredAnswer.state == .outcomeUnknown && restoredAnswer.observed == nil && restoredAnswer.request.snapshot == body && invocation.episodeID == uncertainAnswer.episodeID && invocation.episodeWorkID == uncertainAnswer.id && invocation.finalStatus == .partial && invocation.terminalReason == .interrupted && invocation.recovered
        checks["restore_episode_fragment_exact_and_semantic_sidecar_absent"] = try restoredOwner!.events(conversationID: conversation.id).first { $0.id == "episode-uncertain-assistant" }?.text == fragment && !FileManager.default.fileExists(atPath: restored.appendingPathComponent("semantic.sqlite3").path)
        let recoveredArchive = scratch.appendingPathComponent("episode-recovered-archive", isDirectory: true)
        let recoveredManifest = try BackupArchive.create(from: restoredOwner!, at: recoveredArchive)
        checks["restore_episode_recovered_archive_reverifies_held_unknown_bounds"] = try recoveredManifest.inventory.unfinishedEpisodes == 0 && recoveredManifest.inventory.episodeCharged == expectedCharged && recoveredManifest.inventory.episodeHeld == EpisodeResources(outputTokens: 129) && BackupArchive.verify(at: recoveredArchive) == recoveredManifest
        restoredOwner = nil
        restoredOwner = try MemoryStore(directory: restored)
        checks["restore_repeated_episode_reopen_does_not_recharge_or_release_unknown"] = try restoredOwner!.episodeReceipt(id: "episode-preflight", clock: clock) == restoredPreflight && restoredOwner!.episodeReceipt(id: "episode-answering", clock: clock) == restoredAnswering && restoredOwner!.invocation(id: "episode-uncertain-invocation")?.finalizedAt == invocation.finalizedAt
        restoredOwner = nil
        owner = nil

        func corrupt(_ name: String, _ statement: String) throws -> URL {
            let copy = scratch.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.copyItem(at: archive, to: copy)
            try sql(copy.appendingPathComponent("memory.sqlite3"), statement)
            try refreshDatabaseHash(copy)
            return copy
        }
        let corruptions: [(String, String)] = [
            ("limits_digest", "UPDATE episodes SET limits_digest='corrupt' WHERE id='episode-preflight'"),
            ("request_digest", "UPDATE episode_work SET request_digest='corrupt' WHERE id='episode-uncertain-calibration'"),
            ("snapshot_digest", "UPDATE episode_request_snapshots SET payload=zeroblob(byte_count)"),
            ("receipt_digest", "UPDATE episode_work SET receipt_digest='corrupt' WHERE id='episode-complete-answer'"),
            ("resource_totals", "UPDATE episode_resource_totals SET charged=0 WHERE episode_id='episode-preflight' AND resource='inputTokens'"),
            ("scope_linkage", "UPDATE episodes SET project_id='wrong-scope' WHERE id='episode-preflight'"),
            ("invocation_linkage", "UPDATE invocations SET episode_work_id='episode-complete-calibration' WHERE id='episode-complete-invocation'")]
        for (name, statement) in corruptions {
            let copy = try corrupt("episode-corrupt-" + name, statement)
            checks["backup_episode_" + name + "_corruption_refused_after_file_hash_refresh"] = rejects { _ = try BackupArchive.verify(at: copy) }
        }
        let inconsistentReceipt = try corrupt("episode-state-receipt-disagreement", "UPDATE episode_work SET state='failedConfirmed' WHERE id='episode-complete-answer'")
        checks["backup_episode_terminal_state_must_agree_with_receipt_outcome"] = rejects { _ = try BackupArchive.verify(at: inconsistentReceipt) }
        let inconsistentCapture = try corrupt("episode-complete-capture-after-cancellation", "UPDATE episodes SET state='cancelled',terminal_reason='cancelled' WHERE id='episode-completed'")
        checks["backup_episode_complete_capture_requires_completed_episode"] = rejects { _ = try BackupArchive.verify(at: inconsistentCapture) }
        let missingReceipt = try corrupt("episode-completed-without-receipt", "UPDATE episode_work SET state='completed' WHERE id='episode-uncertain-calibration'")
        let missingReceiptManifest = missingReceipt.appendingPathComponent("manifest.json")
        var missingReceiptObject = try JSONSerialization.jsonObject(with: Data(contentsOf: missingReceiptManifest)) as! [String: Any]
        var missingReceiptInventory = missingReceiptObject["inventory"] as! [String: Any]
        // Preserve a truthful row-state inventory, so this fixture exercises
        // journal semantics rather than failing merely on aggregate counts.
        missingReceiptInventory["episodeUncertainWork"] = 1
        missingReceiptObject["inventory"] = missingReceiptInventory
        try privateWrite(try JSONSerialization.data(withJSONObject: missingReceiptObject, options: [.sortedKeys]), at: missingReceiptManifest)
        checks["backup_episode_completed_work_requires_terminal_receipt"] = rejects { _ = try BackupArchive.verify(at: missingReceipt) }
        let changedBody = Data(String(decoding: body, as: UTF8.self).replacingOccurrences(of: "SYNTHETIC_EPISODE_PRIVATE_REQUEST", with: "ALTERED_SYNTHETIC_EPISODE_PRIVATE_REQUEST").utf8)
        let changedBodyHex = changedBody.map { String(format: "%02x", $0) }.joined()
        let changedBodyDigest = SHA256.hash(data: changedBody).map { String(format: "%02x", $0) }.joined()
        let unboundInvocation = try corrupt("episode-unbound-invocation-body", "UPDATE invocations SET request_body=X'\(changedBodyHex)',request_digest='\(changedBodyDigest)' WHERE id='episode-complete-invocation'")
        checks["backup_episode_invocation_body_must_equal_admitted_work_snapshot"] = rejects { _ = try BackupArchive.verify(at: unboundInvocation) }
        let zero = try JSONEncoder().encode(EpisodeResources.zero).map { String(format: "%02x", $0) }.joined()
        let lostBound = try corrupt("episode-lost-unknown-bound", "UPDATE episode_work SET held_json=X'\(zero)' WHERE id='episode-uncertain-answer'; UPDATE episode_resource_totals SET held=0 WHERE episode_id='episode-answering' AND resource='outputTokens'")
        checks["backup_episode_unknown_output_bound_cannot_be_erased"] = rejects { _ = try BackupArchive.verify(at: lostBound) }
        let refusedDestination = scratch.appendingPathComponent("episode-corrupt-not-published", isDirectory: true)
        checks["restore_corrupt_episode_journal_never_published"] = rejects { _ = try BackupArchive.restore(from: lostBound, to: refusedDestination, authority: .unmanagedNoDeletion) } && !FileManager.default.fileExists(atPath: refusedDestination.path)
        let sourceDatabase = directory.appendingPathComponent("memory.sqlite3")
        try sql(sourceDatabase, "UPDATE episodes SET limits_digest='corrupt' WHERE id='episode-preflight'")
        let sourceBytesBefore = try Data(contentsOf: sourceDatabase)
        let sourceSchemaBefore = try schemaSnapshot(sourceDatabase)
        let sourceFilesBefore = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let commandArchive = scratch.appendingPathComponent("corrupt-episode-command-archive", isDirectory: true)
        let refusedCommand = try captureCommand(["--backup-create", "--data-directory", directory.path, "--archive", commandArchive.path])
        checks["backup_cli_corrupt_schema_four_journal_refused_before_source_mutation"] = try refusedCommand.status == 1 && refusedCommand.output.isEmpty && Data(contentsOf: sourceDatabase) == sourceBytesBefore && schemaSnapshot(sourceDatabase) == sourceSchemaBefore && FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == sourceFilesBefore && !FileManager.default.fileExists(atPath: commandArchive.path)
        return checks
    }

    private static func cancelledRecoveryChecks(in scratch: URL) throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        for hasPrefix in [false, true] {
            let label = hasPrefix ? "partial" : "empty"
            let directory = scratch.appendingPathComponent("cancelled-recovery-" + label)
            var owner: MemoryStore? = try MemoryStore(directory: directory)
            let chat = try owner!.createConversation(projectID: "synthetic-cancelled-recovery", title: "Synthetic Stop recovery")
            let clock = try SystemEpisodeClock().now()
            _ = try owner!.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "turn", humanEventID: "human",
                episodeID: "episode", text: "Synthetic Stop before publication", limits: .init(), clock: clock)
            let body = Data("{\"messages\":[],\"max_tokens\":8}".utf8)
            let work = try owner!.reserveEpisodeWork(episodeID: "episode",
                request: EpisodeWorkRequest(id: "answer", parentID: nil, kind: .answer,
                    resources: EpisodeResources(inputTokens: 4, outputTokens: 8, modelCalls: 1),
                    adapterIdentity: "synthetic-cancelled-recovery", snapshot: body, inputTokensKnown: true), clock: clock)
            _ = try owner!.beginInvocation(invocationID: "invocation", conversationID: chat.id, turnID: "turn",
                humanEventID: "human", assistantEventID: "assistant", providerIdentity: "native:synthetic",
                requestBody: body, episodeID: "episode", episodeWorkID: work.id)
            _ = try owner!.armEpisodeWork(episodeID: "episode", operationID: work.id, expectedRevision: work.revision, clock: clock)
            if hasPrefix { _ = try owner!.appendInvocationChunk(invocationID: "invocation", sequence: 0, text: "Synthetic committed Stop prefix") }
            _ = try owner!.finishEpisode(episodeID: "episode", reason: .cancelled, clock: clock)
            // Model the crash boundary after durable Stop and before capture
            // publication by reopening with the invocation still unfinished.
            owner = nil
            owner = try MemoryStore(directory: directory)
            let invocation = try owner!.invocation(id: "invocation")!
            checks["backup_cancelled_recovery_" + label + "_has_expected_terminal_capture"] = invocation.recovered
                && invocation.terminalReason == .cancelled && invocation.finalStatus == (hasPrefix ? .partial : .cancelled)
            let archive = scratch.appendingPathComponent("cancelled-recovery-archive-" + label)
            let manifest = try BackupArchive.create(from: owner!, at: archive)
            checks["backup_cancelled_recovery_" + label + "_archive_verifies"] = try BackupArchive.verify(at: archive) == manifest
            if !hasPrefix {
                let inconsistent = scratch.appendingPathComponent("cancelled-recovery-inconsistent")
                try FileManager.default.copyItem(at: archive, to: inconsistent)
                try sql(inconsistent.appendingPathComponent("memory.sqlite3"), "UPDATE episodes SET state='failed',terminal_reason='failed' WHERE id='episode'")
                try refreshDatabaseHash(inconsistent)
                checks["backup_cancelled_recovery_requires_matching_cancelled_episode"] = rejects { _ = try BackupArchive.verify(at: inconsistent) }
            }
            owner = nil
            let commandArchive = scratch.appendingPathComponent("cancelled-recovery-cli-" + label)
            let command = try captureCommand(["--backup-create", "--data-directory", directory.path, "--archive", commandArchive.path])
            checks["backup_cancelled_recovery_" + label + "_cli_recognition_accepts_source"] = command.status == 0
            let restored = scratch.appendingPathComponent("cancelled-recovery-restored-" + label)
            _ = try BackupArchive.restore(from: archive, to: restored, authority: .unmanagedNoDeletion)
            owner = try MemoryStore(directory: restored)
            let receipt = try owner!.episodeReceipt(id: "episode", clock: SystemEpisodeClock().now())
            checks["restore_cancelled_recovery_" + label + "_preserves_terminal_and_unknown_bounds"] = try
                owner!.invocation(id: "invocation")?.finalizedAt == invocation.finalizedAt
                && owner!.events(conversationID: chat.id).count == 2 && receipt.state == .cancelled
                && receipt.charged.inputTokens == 4 && receipt.charged.modelCalls == 1 && receipt.held.outputTokens == 8
            owner = nil
        }
        return checks
    }

    /// Older manifests have no episode fields. Their exact invocation evidence
    /// remains historical/unmetered when privately upgraded during restore.
    private static func schemaTwoArchiveChecks(in scratch: URL, archive: URL) throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let legacy = scratch.appendingPathComponent("schema-two-archive", isDirectory: true)
        try FileManager.default.copyItem(at: archive, to: legacy)
        try downgrade(legacy.appendingPathComponent("memory.sqlite3"), to: 2)
        try relabelLegacyManifest(legacy, version: 2)
        let verified = try BackupArchive.verify(at: legacy)
        checks["backup_schema_two_manifest_decodes_without_episode_inventory"] = verified.databaseSchema == 2 && verified.inventory.episodes == nil && verified.inventory.episodeCharged == nil && verified.inventory.episodeHeld == nil
        let legacyCommand = try captureCommand(["--backup-verify", "--archive", legacy.path])
        let legacyCommandObject = (try? JSONSerialization.jsonObject(with: legacyCommand.output)) as? [String: Any]
        checks["backup_schema_two_cli_omits_unavailable_episode_origin_counts"] = legacyCommand.status == 0 && legacyCommandObject?["episodes"] == nil && legacyCommandObject?["chat_episodes"] == nil && legacyCommandObject?["local_read_episodes"] == nil
        let destination = scratch.appendingPathComponent("schema-two-restored", isDirectory: true)
        _ = try BackupArchive.restore(from: legacy, to: destination, authority: .unmanagedNoDeletion)
        do {
            let owner = try MemoryStore(directory: destination)
            let invocation = try owner.invocation(id: "complete-attempt")!
            checks["restore_schema_two_invocations_remain_unmetered_historical"] = invocation.episodeID == nil && invocation.episodeWorkID == nil && invocation.finalStatus == .complete && invocation.usageJSON == Data("{\"prompt_tokens\":37,\"completion_tokens\":9}".utf8)
            checks["restore_schema_two_private_upgrade_preserves_recovery_and_counts"] = try owner.invocation(id: "interrupted-attempt")?.finalStatus == .partial && owner.invocation(id: "empty-attempt")?.finalStatus == .failed && owner.sourceManifest(projectID: "synthetic-backup-alpha", afterSequence: 0, limit: 1000).count == 6
            let upgradedArchive = scratch.appendingPathComponent("schema-two-upgraded-archive", isDirectory: true)
            let upgraded = try BackupArchive.create(from: owner, at: upgradedArchive)
            checks["restore_schema_two_upgrades_private_staging_to_schema_four"] = upgraded.databaseSchema == 4 && upgraded.inventory.episodes == 0 && upgraded.inventory.episodeWork == 0 && upgraded.inventory.invocations == verified.inventory.invocations && upgraded.inventory.events == verified.inventory.events + verified.inventory.unfinishedInvocations
        }
        checks["restore_schema_two_preserves_original_verified_archive"] = try BackupArchive.verify(at: legacy) == verified
        return checks
    }

    private static func schemaOneArchiveChecks(in scratch: URL, archive: URL) throws -> [String: Bool] {
        let legacy = scratch.appendingPathComponent("schema-one-archive", isDirectory: true)
        try FileManager.default.copyItem(at: archive, to: legacy)
        try downgrade(legacy.appendingPathComponent("memory.sqlite3"), to: 1)
        try relabelLegacyManifest(legacy, version: 1)
        let verified = try BackupArchive.verify(at: legacy)
        let destination = scratch.appendingPathComponent("schema-one-restored", isDirectory: true)
        _ = try BackupArchive.restore(from: legacy, to: destination, authority: .unmanagedNoDeletion)
        let owner = try MemoryStore(directory: destination)
        let upgraded = try BackupArchive.create(from: owner, at: scratch.appendingPathComponent("schema-one-upgraded-archive", isDirectory: true))
        return [
            "backup_schema_one_explicit_contract_has_no_journal": verified.databaseSchema == 1 && verified.inventory.invocations == 0 && verified.inventory.chunks == 0 && verified.inventory.episodes == nil && verified.inventory.chatEpisodes == nil && verified.inventory.localReadEpisodes == nil,
            "restore_schema_one_exact_sources_without_invented_attempts": upgraded.databaseSchema == 4 && upgraded.inventory.events == verified.inventory.events && upgraded.inventory.sourceBytes == verified.inventory.sourceBytes && upgraded.inventory.invocations == 0 && upgraded.inventory.episodes == 0 && upgraded.inventory.chatEpisodes == 0 && upgraded.inventory.localReadEpisodes == 0,
            "backup_schema_one_archive_bytes_unchanged_after_restore": try BackupArchive.verify(at: legacy) == verified
        ]
    }

    private static func schemaThreeArchiveChecks(in scratch: URL, archive: URL) throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let legacy = scratch.appendingPathComponent("schema-three-archive", isDirectory: true)
        try FileManager.default.copyItem(at: archive, to: legacy)
        try downgrade(legacy.appendingPathComponent("memory.sqlite3"), to: 3)
        try relabelLegacyManifest(legacy, version: 3)
        let verified = try BackupArchive.verify(at: legacy)
        checks["backup_schema_three_frozen_contract_decodes_without_origin_counts"] = verified.databaseSchema == 3 && verified.inventory.episodes == 3 && verified.inventory.chatEpisodes == nil && verified.inventory.localReadEpisodes == nil
        let legacyCommand = try captureCommand(["--backup-verify", "--archive", legacy.path])
        let legacyCommandObject = (try? JSONSerialization.jsonObject(with: legacyCommand.output)) as? [String: Any]
        checks["backup_schema_three_cli_omits_unavailable_origin_subtypes"] = legacyCommand.status == 0 && legacyCommandObject?["episodes"] as? Int == 3 && legacyCommandObject?["chat_episodes"] == nil && legacyCommandObject?["local_read_episodes"] == nil
        let database = legacy.appendingPathComponent("memory.sqlite3")
        let bytesBefore = try Data(contentsOf: database), schemaBefore = try schemaSnapshot(database)
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: legacy.path).sorted()
        try BackupArchive.recognizeExistingSource(at: legacy)
        checks["backup_schema_three_recognition_leaves_database_and_inventory_unchanged"] = try Data(contentsOf: database) == bytesBefore && schemaSnapshot(database) == schemaBefore && FileManager.default.contentsOfDirectory(atPath: legacy.path).sorted() == filesBefore
        let destination = scratch.appendingPathComponent("schema-three-restored", isDirectory: true)
        _ = try BackupArchive.restore(from: legacy, to: destination, authority: .unmanagedNoDeletion)
        do {
            let owner = try MemoryStore(directory: destination)
            let clock = EpisodeClockSnapshot(domain: "synthetic-backup-clock-v1", continuousNanoseconds: 1_000_000_000, utc: Date(timeIntervalSince1970: 1_700_000_000))
            let complete = try owner.episodeReceipt(id: "episode-completed", clock: clock)
            let interrupted = try owner.episodeReceipt(id: "episode-answering", clock: clock)
            let upgraded = try BackupArchive.create(from: owner, at: scratch.appendingPathComponent("schema-three-upgraded-archive", isDirectory: true))
            checks["restore_schema_three_migrates_exact_chat_origins_and_unknown_hold"] = complete.origin == .chat(conversationID: complete.conversationID!, turnID: complete.turnID!, humanEventID: complete.humanEventID!) && complete.state == .completed && interrupted.state == .interrupted && interrupted.held == EpisodeResources(outputTokens: 128) && upgraded.inventory.chatEpisodes == 3 && upgraded.inventory.localReadEpisodes == 0 && upgraded.inventory.episodeCharged == verified.inventory.episodeCharged
        }
        checks["restore_schema_three_preserves_original_verified_archive"] = try BackupArchive.verify(at: legacy) == verified
        let altered = scratch.appendingPathComponent("schema-three-altered-constraint", isDirectory: true)
        try FileManager.default.copyItem(at: legacy, to: altered)
        try downgrade(altered.appendingPathComponent("memory.sqlite3"), to: 3, alterLimitsConstraint: true)
        try refreshDatabaseHash(altered)
        checks["backup_schema_three_same_columns_changed_constraint_refused"] = rejects { _ = try BackupArchive.verify(at: altered) }
        return checks
    }

    private static func relabelLegacyManifest(_ archive: URL, version: Int) throws {
        let path = archive.appendingPathComponent("manifest.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        object["databaseSchema"] = version
        var inventory = object["inventory"] as! [String: Any]
        inventory.removeValue(forKey: "chatEpisodes"); inventory.removeValue(forKey: "localReadEpisodes")
        if version < 3 {
            for key in Array(inventory.keys) where key.hasPrefix("episode") || key == "unfinishedEpisodes" { inventory.removeValue(forKey: key) }
        }
        if version == 1 {
            for key in ["invocations", "unfinishedInvocations", "chunks", "chunkBytes"] { inventory[key] = 0 }
            inventory["providerIdentities"] = [String](); inventory["servedModels"] = [String]()
            var scopes = inventory["scopes"] as! [[String: Any]]
            for index in scopes.indices { scopes[index]["invocations"] = 0 }
            inventory["scopes"] = scopes
        }
        object["inventory"] = inventory
        try privateWrite(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), at: path)
        try refreshDatabaseHash(archive)
    }

    private static func localReadArchiveChecks(in scratch: URL) throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let directory = scratch.appendingPathComponent("read-source", isDirectory: true)
        var owner: MemoryStore? = try MemoryStore(directory: directory)
        let conversation = try owner!.createConversation(projectID: "synthetic-read-backup", title: "Synthetic read source")
        _ = try owner!.append(conversationID: conversation.id, role: .human, text: "Synthetic source remains unchanged", status: .complete, turnID: "seed-turn", eventID: "seed-human")
        let body = Data("{\"model\":\"synthetic-read-model\",\"messages\":[{\"role\":\"user\",\"content\":\"Synthetic read-only probe\"}]}".utf8)
        _ = try owner!.beginInvocation(invocationID: "seed-invocation", conversationID: conversation.id, turnID: "seed-turn", humanEventID: "seed-human", assistantEventID: "seed-assistant", providerIdentity: "native:synthetic", requestBody: body)
        _ = try owner!.appendInvocationChunk(invocationID: "seed-invocation", sequence: 0, text: "Synthetic baseline answer")
        _ = try owner!.finalizeInvocation(invocationID: "seed-invocation", status: .complete)
        let sourceEncoder = JSONEncoder(); sourceEncoder.outputFormatting = [.sortedKeys]
        let before = try sourceEncoder.encode(owner!.events(conversationID: conversation.id))
        let clock = EpisodeClockSnapshot(domain: "synthetic-read-backup-clock", continuousNanoseconds: 1_000_000_000, utc: Date(timeIntervalSince1970: 1_700_000_000))
        let descriptor = Data("{\"project\":\"synthetic-read-backup\",\"query\":\"synthetic\"}".utf8)
        let digest = SHA256.hash(data: descriptor).map { String(format: "%02x", $0) }.joined()
        let completedBinding = EpisodeLocalReadBinding(initiator: .humanBrowser, purpose: .searchInitialPage, requestID: "read-request-complete", descriptorVersion: "backup-read-fixture-v1", descriptorSHA256: digest)
        _ = try owner!.beginLocalReadEpisode(episodeID: "read-complete", projectID: "synthetic-read-backup", binding: completedBinding, limits: .init(), clock: clock)
        let read = try owner!.reserveEpisodeWork(episodeID: "read-complete", request: EpisodeWorkRequest(id: "read-source-work", parentID: nil, kind: .sourceRead, resources: EpisodeResources(memoryOperations: 1, rawSourceBytes: 20), adapterIdentity: "synthetic-read-fixture-v1", snapshot: body, inputTokensKnown: true), clock: clock)
        _ = try owner!.armEpisodeWork(episodeID: read.episodeID, operationID: read.id, expectedRevision: read.revision, clock: clock)
        let settled = try owner!.settleEpisodeWork(episodeID: read.episodeID, operationID: read.id, settlement: EpisodeWorkSettlement(receiptID: "read-source-receipt", outcome: .completed, observed: read.request.resources, evidence: nil), clock: clock)
        let completed = try owner!.finishEpisode(episodeID: "read-complete", reason: .completed, clock: clock)
        let activeDescriptor = Data("{\"project\":\"synthetic-read-only-project\",\"query\":\"synthetic\"}".utf8)
        let activeDigest = SHA256.hash(data: activeDescriptor).map { String(format: "%02x", $0) }.joined()
        let activeBinding = EpisodeLocalReadBinding(initiator: .syntheticEvaluation, purpose: .retrievalProbe, requestID: "read-request-active", descriptorVersion: "backup-read-fixture-v1", descriptorSHA256: activeDigest)
        _ = try owner!.beginLocalReadEpisode(episodeID: "read-active", projectID: "synthetic-read-only-project", binding: activeBinding, limits: .init(), clock: clock)
        let uncertain = try owner!.reserveEpisodeWork(episodeID: "read-active", request: EpisodeWorkRequest(id: "read-uncertain-encoder", parentID: nil, kind: .queryEmbedding, resources: EpisodeResources(modelCalls: 1, encoderInputBytes: 23), adapterIdentity: "synthetic-query-encoder-v1", snapshot: nil, inputTokensKnown: false), clock: clock)
        _ = try owner!.armEpisodeWork(episodeID: uncertain.episodeID, operationID: uncertain.id, expectedRevision: uncertain.revision, clock: clock)
        let prepared = try owner!.reserveEpisodeWork(episodeID: "read-active", request: EpisodeWorkRequest(id: "read-prepared-source", parentID: nil, kind: .sourceRead, resources: EpisodeResources(memoryOperations: 1, rawSourceBytes: 200), adapterIdentity: "synthetic-read-fixture-v1", snapshot: nil, inputTokensKnown: true), clock: clock)
        let activeBefore = try owner!.episodeReceipt(id: "read-active", clock: clock)
        let archive = scratch.appendingPathComponent("read-archive", isDirectory: true)
        let manifest = try BackupArchive.create(from: owner!, at: archive)
        checks["backup_read_origins_separate_counts_and_no_source_or_chat_mutation"] = try sourceEncoder.encode(owner!.events(conversationID: conversation.id)) == before && manifest.inventory.conversations == 1 && manifest.inventory.events == 2 && manifest.inventory.invocations == 1 && manifest.inventory.episodes == 2 && manifest.inventory.chatEpisodes == 0 && manifest.inventory.localReadEpisodes == 2 && manifest.inventory.unfinishedEpisodes == 1
        checks["backup_read_only_project_appears_in_scope_inventory"] = manifest.inventory.scopes.first { $0.projectID == "synthetic-read-only-project" }.map { $0.conversations == 0 && $0.events == 0 && $0.invocations == 0 } ?? false
        let readCommand = try captureCommand(["--backup-verify", "--archive", archive.path])
        let readCommandObject = (try? JSONSerialization.jsonObject(with: readCommand.output)) as? [String: Any]
        checks["backup_read_cli_reports_only_content_free_origin_counts"] = readCommand.status == 0 && readCommandObject?["episodes"] as? Int == 2 && readCommandObject?["chat_episodes"] as? Int == 0 && readCommandObject?["local_read_episodes"] as? Int == 2 && !String(decoding: readCommand.output + readCommand.errors, as: UTF8.self).contains("synthetic-read") && !String(decoding: readCommand.output + readCommand.errors, as: UTF8.self).contains(scratch.path)
        let destination = scratch.appendingPathComponent("read-restored", isDirectory: true)
        _ = try BackupArchive.restore(from: archive, to: destination, authority: .unmanagedNoDeletion)
        var restoredOwner: MemoryStore? = try MemoryStore(directory: destination)
        let restoredComplete = try restoredOwner!.episodeReceipt(id: "read-complete", clock: clock)
        let restoredActive = try restoredOwner!.episodeReceipt(id: "read-active", clock: clock)
        let restoredUncertain = try restoredOwner!.episodeWork(episodeID: uncertain.episodeID, operationID: uncertain.id)!
        let restoredPrepared = try restoredOwner!.episodeWork(episodeID: prepared.episodeID, operationID: prepared.id)!
        checks["restore_read_completed_origin_receipts_exact"] = try restoredComplete == completed && restoredComplete.origin == .localRead(completedBinding) && restoredOwner!.episodeWork(episodeID: settled.episodeID, operationID: settled.id) == settled
        checks["restore_read_interrupts_without_inference_replay_and_keeps_unknown_input"] = restoredActive.state == .interrupted && restoredActive.origin == .localRead(activeBinding) && restoredActive.charged == activeBefore.charged && restoredActive.held == .zero && restoredActive.unknownInputOperations == 1 && restoredUncertain.state == .outcomeUnknown && restoredUncertain.observed == nil && restoredUncertain.recovered
        checks["restore_read_releases_only_unarmed_work"] = restoredPrepared.state == .cancelledBeforeDispatch && restoredPrepared.charged == .zero && restoredPrepared.held == .zero
        let recoveredArchive = scratch.appendingPathComponent("read-recovered-archive", isDirectory: true)
        let recovered = try BackupArchive.create(from: restoredOwner!, at: recoveredArchive)
        checks["restore_read_source_counts_and_work_inventory_preserved"] = try sourceEncoder.encode(restoredOwner!.events(conversationID: conversation.id)) == before && recovered.inventory.conversations == manifest.inventory.conversations && recovered.inventory.events == manifest.inventory.events && recovered.inventory.invocations == manifest.inventory.invocations && recovered.inventory.episodeWork == manifest.inventory.episodeWork && recovered.inventory.localReadEpisodes == 2 && recovered.inventory.episodeCharged == manifest.inventory.episodeCharged && recovered.inventory.episodePreparedWork == 0 && recovered.inventory.unfinishedEpisodes == 0
        restoredOwner = nil
        restoredOwner = try MemoryStore(directory: destination)
        checks["restore_read_reopen_does_not_recharge_or_replay"] = try restoredOwner!.episodeReceipt(id: "read-active", clock: clock) == restoredActive && restoredOwner!.episodeWork(episodeID: uncertain.episodeID, operationID: uncertain.id) == restoredUncertain
        restoredOwner = nil; owner = nil
        func corrupt(_ name: String, _ statements: String) throws -> URL {
            let copy = scratch.appendingPathComponent("read-corrupt-" + name, isDirectory: true)
            try FileManager.default.copyItem(at: archive, to: copy)
            try sql(copy.appendingPathComponent("memory.sqlite3"), statements)
            try refreshDatabaseHash(copy)
            return copy
        }
        let badDigest = try corrupt("origin-digest", "UPDATE episodes SET origin_digest='altered' WHERE id='read-active'")
        checks["backup_read_origin_digest_corruption_refused_after_hash_refresh"] = rejects { _ = try BackupArchive.verify(at: badDigest) }
        let validOrigin = try JSONSerialization.jsonObject(with: JSONEncoder().encode(EpisodeOrigin.localRead(activeBinding))) as! [String: Any]
        var invalidOrigins: [(String, [String: Any])] = []
        var origin = validOrigin; origin["kind"] = "unrecognized"; invalidOrigins.append(("type", origin))
        origin = validOrigin; origin["version"] = "episode-origin-v999"; invalidOrigins.append(("version", origin))
        origin = validOrigin; origin["extra"] = true; invalidOrigins.append(("unexpected-key", origin))
        origin = validOrigin; var binding = origin["binding"] as! [String: Any]; binding["descriptorSHA256"] = String(repeating: "G", count: 64); origin["binding"] = binding; invalidOrigins.append(("descriptor-digest", origin))
        origin = ["version": "episode-origin-v1", "kind": "chat", "conversationID": conversation.id, "turnID": "seed-turn", "humanEventID": "seed-human"]; invalidOrigins.append(("chat-with-null-links", origin))
        for (name, origin) in invalidOrigins {
            let bytes = try JSONSerialization.data(withJSONObject: origin, options: [.sortedKeys])
            let hex = bytes.map { String(format: "%02x", $0) }.joined(), digest = try MemoryStore.episodeOriginDigest(projectID: "synthetic-read-only-project", originJSON: bytes)
            let copy = try corrupt(name, "UPDATE episodes SET origin_json=X'\(hex)',origin_digest='\(digest)' WHERE id='read-active'")
            checks["backup_read_origin_\(name)_refused_with_valid_file_and_origin_hashes"] = rejects { _ = try BackupArchive.verify(at: copy) }
        }
        let canonicalEncoder = JSONEncoder(); canonicalEncoder.outputFormatting = [.sortedKeys]
        let canonicalOrigin = try canonicalEncoder.encode(EpisodeOrigin.localRead(activeBinding))
        let duplicateOrigin = Data(String(decoding: canonicalOrigin, as: UTF8.self).replacingOccurrences(of: "\"kind\":\"localRead\"", with: "\"kind\":\"localRead\",\"kind\":\"localRead\"").utf8)
        let duplicateHex = duplicateOrigin.map { String(format: "%02x", $0) }.joined()
        let duplicateDigest = try MemoryStore.episodeOriginDigest(projectID: "synthetic-read-only-project", originJSON: duplicateOrigin)
        let duplicate = try corrupt("duplicate-origin-key", "UPDATE episodes SET origin_json=X'\(duplicateHex)',origin_digest='\(duplicateDigest)' WHERE id='read-active'")
        checks["backup_read_duplicate_origin_key_refused_with_valid_scope_hash"] = duplicateOrigin != canonicalOrigin && rejects { _ = try BackupArchive.verify(at: duplicate) }
        let alteredScope = try corrupt("project-scope", "UPDATE episodes SET project_id='synthetic-read-only-project-altered' WHERE id='read-active'")
        let alteredScopeManifest = alteredScope.appendingPathComponent("manifest.json")
        var scopeObject = try JSONSerialization.jsonObject(with: Data(contentsOf: alteredScopeManifest)) as! [String: Any]
        var scopeInventory = scopeObject["inventory"] as! [String: Any]
        var scopes = scopeInventory["scopes"] as! [[String: Any]]
        for index in scopes.indices where scopes[index]["projectID"] as? String == "synthetic-read-only-project" { scopes[index]["projectID"] = "synthetic-read-only-project-altered" }
        scopeInventory["scopes"] = scopes; scopeObject["inventory"] = scopeInventory
        try privateWrite(try JSONSerialization.data(withJSONObject: scopeObject, options: [.sortedKeys]), at: alteredScopeManifest)
        checks["backup_read_project_scope_change_refused_with_truthful_inventory"] = rejects { _ = try BackupArchive.verify(at: alteredScope) }
        let badInvocation = try corrupt("invocation-link", "UPDATE invocations SET episode_id='read-complete',episode_work_id='read-source-work' WHERE id='seed-invocation'")
        checks["backup_read_origin_invocation_link_refused"] = rejects { _ = try BackupArchive.verify(at: badInvocation) }
        let badChatLinks = try corrupt("non-null-chat-links", "UPDATE episodes SET conversation_id='\(conversation.id)',turn_id='seed-turn',human_event_id='seed-human' WHERE id='read-active'")
        checks["backup_read_origin_rejects_valid_non_null_chat_links"] = rejects { _ = try BackupArchive.verify(at: badChatLinks) }
        for kind in [EpisodeWorkKind.answer, .calibration, .nativeInference] {
            var request = try JSONSerialization.jsonObject(with: JSONEncoder().encode(uncertain.request)) as! [String: Any]
            request["kind"] = kind.rawValue
            let bytes = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
            let hex = bytes.map { String(format: "%02x", $0) }.joined(), digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let copy = try corrupt("disallowed-work-" + kind.rawValue, "UPDATE episode_work SET kind='\(kind.rawValue)',request_json=X'\(hex)',request_digest='\(digest)' WHERE id='read-uncertain-encoder'")
            checks["backup_read_disallows_\(kind.rawValue)_with_matching_request_and_digest"] = rejects { _ = try BackupArchive.verify(at: copy) }
        }
        let refused = scratch.appendingPathComponent("read-corrupt-unpublished", isDirectory: true)
        checks["restore_invalid_read_origin_refused_before_publication"] = rejects { _ = try BackupArchive.restore(from: badInvocation, to: refused, authority: .unmanagedNoDeletion) } && !FileManager.default.fileExists(atPath: refused.path)
        let wrongCounts = scratch.appendingPathComponent("read-corrupt-origin-inventory", isDirectory: true)
        try FileManager.default.copyItem(at: archive, to: wrongCounts)
        let manifestPath = wrongCounts.appendingPathComponent("manifest.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestPath)) as! [String: Any]
        var inventory = object["inventory"] as! [String: Any]; inventory["chatEpisodes"] = 1; inventory["localReadEpisodes"] = 1; object["inventory"] = inventory
        try privateWrite(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), at: manifestPath)
        checks["backup_read_origin_counts_must_match_types_even_when_sum_matches"] = rejects { _ = try BackupArchive.verify(at: wrongCounts) }
        object = try JSONSerialization.jsonObject(with: Data(contentsOf: archive.appendingPathComponent("manifest.json"))) as! [String: Any]
        inventory = object["inventory"] as! [String: Any]; inventory.removeValue(forKey: "localReadEpisodes"); object["inventory"] = inventory
        try privateWrite(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), at: manifestPath)
        checks["backup_schema_four_requires_explicit_read_origin_count"] = rejects { _ = try BackupArchive.verify(at: wrongCounts) }
        let forgedLegacy = try corrupt("legacy-schema-label", "PRAGMA user_version=3")
        try relabelLegacyManifest(forgedLegacy, version: 3)
        checks["backup_read_origin_cannot_masquerade_as_legacy_schema_three"] = rejects { _ = try BackupArchive.verify(at: forgedLegacy) }
        return checks
    }

    /// Independent historical fixture DDL frozen at checkpoint 22c3402.
    /// Rebuilding into these tables preserves old constraints and references.
    private static func historicalFixtureSQL(version: Int) throws -> String {
        guard (1...3).contains(version) else { throw BackupError.invalid("unsupported historical schema") }
        var sql = """
        CREATE TABLE IF NOT EXISTS conversations (
          id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL,
          created_at TEXT NOT NULL, updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS events (
          sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
          conversation_id TEXT NOT NULL REFERENCES conversations(id), project_id TEXT NOT NULL,
          role TEXT NOT NULL CHECK(role IN ('human','assistant')),
          status TEXT NOT NULL CHECK(status IN ('complete','partial','failed','cancelled')),
          turn_id TEXT NOT NULL, created_at TEXT NOT NULL, digest TEXT NOT NULL,
          byte_count INTEGER NOT NULL CHECK(byte_count >= 0 AND byte_count <= 4194304),
          payload BLOB NOT NULL CHECK(length(payload) = byte_count)
        );
        CREATE INDEX IF NOT EXISTS event_conversation ON events(conversation_id, sequence);
        CREATE INDEX IF NOT EXISTS event_project ON events(project_id, sequence);
        CREATE VIRTUAL TABLE IF NOT EXISTS event_fts USING fts5(text, content='');
        CREATE TABLE IF NOT EXISTS drafts (conversation_id TEXT PRIMARY KEY REFERENCES conversations(id), payload BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, payload BLOB NOT NULL);
        """
        if version >= 2 { sql += """

        CREATE TABLE IF NOT EXISTS invocations (
          id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id),
          project_id TEXT NOT NULL, turn_id TEXT NOT NULL,
          human_event_id TEXT NOT NULL REFERENCES events(id), assistant_event_id TEXT NOT NULL UNIQUE,
          provider_identity TEXT NOT NULL, request_body BLOB NOT NULL,
          request_digest TEXT NOT NULL, admission_json BLOB NOT NULL DEFAULT X'',
          admission_digest TEXT NOT NULL DEFAULT '', usage_json BLOB NOT NULL DEFAULT X'',
          usage_digest TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL,
          chunk_count INTEGER NOT NULL DEFAULT 0 CHECK(chunk_count >= 0 AND chunk_count <= 65536),
          observed_bytes INTEGER NOT NULL DEFAULT 0 CHECK(observed_bytes >= 0 AND observed_bytes <= 4194304),
          final_status TEXT NOT NULL DEFAULT '' CHECK(final_status IN ('','complete','partial','failed','cancelled')),
          terminal_reason TEXT NOT NULL DEFAULT '' CHECK(terminal_reason IN ('','completed','cancelled','upstreamIncomplete','transportFailure','captureFailure','admissionFailure','interrupted')),
          finalized_at TEXT NOT NULL DEFAULT '', recovered INTEGER NOT NULL DEFAULT 0 CHECK(recovered IN (0,1)),
          CHECK(length(request_body) > 0 AND length(request_body) <= 4194304),
          CHECK((final_status = '' AND terminal_reason = '' AND finalized_at = '') OR
                (final_status != '' AND terminal_reason != '' AND finalized_at != ''))
        );
        CREATE TABLE IF NOT EXISTS invocation_chunks (
          invocation_id TEXT NOT NULL REFERENCES invocations(id),
          chunk_sequence INTEGER NOT NULL CHECK(chunk_sequence >= 0 AND chunk_sequence < 65536),
          byte_count INTEGER NOT NULL CHECK(byte_count > 0 AND byte_count <= 4194304),
          digest TEXT NOT NULL, payload BLOB NOT NULL CHECK(length(payload) = byte_count),
          PRIMARY KEY(invocation_id, chunk_sequence)
        ) WITHOUT ROWID;
        """ }
        if version == 3 { sql += """

        CREATE TABLE IF NOT EXISTS episodes (
          id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id),
          project_id TEXT NOT NULL, turn_id TEXT NOT NULL, human_event_id TEXT NOT NULL UNIQUE REFERENCES events(id),
          limits_json BLOB NOT NULL CHECK(length(limits_json)>0 AND length(limits_json)<=65536),
          limits_digest TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('active','completed','failed','cancelled','interrupted','deadlineExceeded','budgetExceeded')),
          revision INTEGER NOT NULL CHECK(revision>=0), clock_domain TEXT NOT NULL,
          created_ticks INTEGER NOT NULL CHECK(created_ticks>0), deadline_ticks INTEGER NOT NULL CHECK(deadline_ticks>created_ticks),
          last_ticks INTEGER NOT NULL CHECK(last_ticks>=created_ticks), created_utc REAL NOT NULL,
          terminal_reason TEXT NOT NULL DEFAULT '', CHECK((state='active' AND terminal_reason='') OR (state!='active' AND terminal_reason!=''))
        );
        CREATE TABLE IF NOT EXISTS episode_resource_totals (
          episode_id TEXT NOT NULL REFERENCES episodes(id), resource TEXT NOT NULL,
          charged INTEGER NOT NULL CHECK(charged>=0), held INTEGER NOT NULL CHECK(held>=0), cap INTEGER NOT NULL CHECK(cap>=0),
          PRIMARY KEY(episode_id,resource)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS episode_request_snapshots (
          digest TEXT PRIMARY KEY, byte_count INTEGER NOT NULL CHECK(byte_count>0 AND byte_count<=4194304),
          payload BLOB NOT NULL CHECK(length(payload)=byte_count)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS episode_work (
          id TEXT PRIMARY KEY, episode_id TEXT NOT NULL REFERENCES episodes(id), parent_id TEXT REFERENCES episode_work(id),
          kind TEXT NOT NULL, adapter_identity TEXT NOT NULL, request_json BLOB NOT NULL CHECK(length(request_json)>0 AND length(request_json)<=65536),
          request_digest TEXT NOT NULL, snapshot_digest TEXT REFERENCES episode_request_snapshots(digest),
          revision INTEGER NOT NULL CHECK(revision>=0), state TEXT NOT NULL CHECK(state IN ('prepared','dispatchArmed','submitted','completed','failedConfirmed','outcomeUnknown','cancelledBeforeDispatch')),
          charged_json BLOB NOT NULL, held_json BLOB NOT NULL, observed_json BLOB NOT NULL DEFAULT X'',
          receipt_id TEXT, receipt_json BLOB NOT NULL DEFAULT X'', receipt_digest TEXT NOT NULL DEFAULT '',
          created_ticks INTEGER NOT NULL CHECK(created_ticks>0), armed_ticks INTEGER NOT NULL DEFAULT 0 CHECK(armed_ticks>=0),
          ended_ticks INTEGER NOT NULL DEFAULT 0 CHECK(ended_ticks>=0), recovered INTEGER NOT NULL DEFAULT 0 CHECK(recovered IN (0,1)),
          adapter_violation INTEGER NOT NULL DEFAULT 0 CHECK(adapter_violation IN (0,1)),
          UNIQUE(episode_id,receipt_id)
        );
        CREATE INDEX IF NOT EXISTS episode_work_episode ON episode_work(episode_id,id);
        ALTER TABLE invocations ADD COLUMN episode_id TEXT REFERENCES episodes(id);
        ALTER TABLE invocations ADD COLUMN episode_work_id TEXT REFERENCES episode_work(id);
        """ }
        return sql + "PRAGMA user_version=\(version);"
    }

    private static func downgrade(_ database: URL, to version: Int, alterLimitsConstraint: Bool = false) throws {
        guard (1...3).contains(version) else { throw BackupError.invalid("synthetic historical fixture version") }
        let rebuilt = database.deletingLastPathComponent().appendingPathComponent("historical-" + UUID().uuidString + ".sqlite3")
        defer { try? FileManager.default.removeItem(at: rebuilt) }
        try privateWrite(Data(), at: rebuilt)
        var fixtureSQL = try historicalFixtureSQL(version: version)
        if alterLimitsConstraint {
            guard version == 3 else { throw BackupError.invalid("synthetic historical constraint fixture") }
            fixtureSQL = fixtureSQL.replacingOccurrences(of: "length(limits_json)<=65536", with: "length(limits_json)<=65537")
        }
        try sql(rebuilt, fixtureSQL)
        do {
            var handle: OpaquePointer?
            guard sqlite3_open_v2(rebuilt.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else { throw BackupError.database }
            defer { sqlite3_close(handle) }
            var attach: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "ATTACH DATABASE ? AS newer", -1, &attach, nil) == SQLITE_OK, let attach else { throw BackupError.database }
            defer { sqlite3_finalize(attach) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard sqlite3_bind_text(attach, 1, database.path, -1, transient) == SQLITE_OK, sqlite3_step(attach) == SQLITE_DONE else { throw BackupError.database }
            var tables = ["conversations", "events", "drafts", "settings"]
            if version >= 2 { tables += ["invocations", "invocation_chunks"] }
            if version == 3 { tables += ["episodes", "episode_resource_totals", "episode_request_snapshots", "episode_work"] }
            for table in tables {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(handle, "SELECT name FROM pragma_table_info('\(table)') ORDER BY cid", -1, &statement, nil) == SQLITE_OK, let statement else { throw BackupError.database }
                var columns: [String] = []
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let text = sqlite3_column_text(statement, 0) else { sqlite3_finalize(statement); throw BackupError.database }
                    columns.append(String(cString: text))
                }
                sqlite3_finalize(statement)
                let names = columns.joined(separator: ",")
                guard sqlite3_exec(handle, "INSERT INTO \(table)(\(names)) SELECT \(names) FROM newer.\(table)", nil, nil, nil) == SQLITE_OK else { throw BackupError.database }
            }
            guard sqlite3_exec(handle, "INSERT INTO event_fts(rowid,text) SELECT sequence,CAST(payload AS TEXT) FROM events ORDER BY sequence; DETACH DATABASE newer", nil, nil, nil) == SQLITE_OK else { throw BackupError.database }
        }
        try FileManager.default.removeItem(at: database)
        try FileManager.default.moveItem(at: rebuilt, to: database)
    }

    private struct CommandCapture {
        let status: Int32?
        let output: Data
        let errors: Data
    }
    private static func captureCommand(_ arguments: [String]) throws -> CommandCapture {
        // Commands emit only a small fixed metadata object and static errors;
        // pipe capacity cannot depend on synthetic source size.
        fflush(stdout); fflush(stderr)
        var outputPipe: [Int32] = [0, 0], errorPipe: [Int32] = [0, 0]
        guard pipe(&outputPipe) == 0, pipe(&errorPipe) == 0 else { throw BackupError.io("synthetic command pipe failed") }
        let oldOutput = dup(STDOUT_FILENO), oldError = dup(STDERR_FILENO)
        guard oldOutput >= 0, oldError >= 0, dup2(outputPipe[1], STDOUT_FILENO) >= 0, dup2(errorPipe[1], STDERR_FILENO) >= 0 else { throw BackupError.io("synthetic command redirection failed") }
        let status = BackupCommand.run(arguments: arguments)
        fflush(stdout); fflush(stderr)
        _ = dup2(oldOutput, STDOUT_FILENO); _ = dup2(oldError, STDERR_FILENO)
        close(oldOutput); close(oldError); close(outputPipe[1]); close(errorPipe[1])
        let output = FileHandle(fileDescriptor: outputPipe[0], closeOnDealloc: true).readDataToEndOfFile()
        let errors = FileHandle(fileDescriptor: errorPipe[0], closeOnDealloc: true).readDataToEndOfFile()
        return CommandCapture(status: status, output: output, errors: errors)
    }

    private static func rejects(_ operation: () throws -> Void) -> Bool { do { try operation(); return false } catch { return true } }
    private static func permissions(_ url: URL) -> Int { var metadata = stat(); return lstat(url.path, &metadata) == 0 ? Int(metadata.st_mode & 0o777) : -1 }
    private static func privateWrite(_ data: Data, at url: URL) throws {
        try data.write(to: url); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func paged(_ owner: MemoryStore, _ eventID: String) throws -> Data {
        var data = Data(), offset = 0
        while true {
            let page = try owner.read(eventID: eventID, offset: offset, length: 4096)
            data.append(contentsOf: page.text.utf8)
            guard let next = page.nextOffset else { return data }; offset = next
        }
    }
    private static func sql(_ url: URL, _ sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { throw BackupError.database }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw BackupError.database }
    }
    private static func schemaSnapshot(_ url: URL) throws -> [String] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw BackupError.database }
        defer { sqlite3_close(handle) }
        var result: [String] = []
        for sql in ["PRAGMA user_version", "SELECT type||':'||name||':'||coalesce(sql,'') FROM sqlite_schema ORDER BY type,name"] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw BackupError.database }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let text = sqlite3_column_text(statement, 0) else { throw BackupError.database }
                result.append(String(cString: text))
            }
        }
        return result
    }
    private static func refreshDatabaseHash(_ archive: URL) throws { try refreshFileHash(archive, name: "memory.sqlite3") }
    private static func refreshFileHash(_ archive: URL, name: String) throws {
        let path = archive.appendingPathComponent("manifest.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        var files = object["files"] as! [[String: Any]]
        let index = files.firstIndex { $0["name"] as? String == name }!
        let data = try Data(contentsOf: archive.appendingPathComponent(name))
        files[index]["bytes"] = data.count
        files[index]["sha256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        object["files"] = files
        try privateWrite(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), at: path)
    }
}
