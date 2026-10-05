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
        return checks
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
        let allowedMetadata = Set(["operation", "status", "archive_id", "archive_version", "database_schema", "control_state", "conversations", "scope_count", "archived_events", "archived_source_bytes", "invocations", "chunks", "unfinished_archived_invocations", "episodes", "episode_work", "unfinished_archived_episodes", "uncertain_archived_work"])
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
        for version in [1, 2, 3] {
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
            legacyReadback = try legacyOwner.events(conversationID: legacyConversationID).first?.text == "Synthetic recognized legacy history" && BackupArchive.verify(at: legacyArchive).databaseSchema == 3
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
        checks["backup_cli_strict_recognition_accepts_genuine_schema_two_upgrade"] = try versionTwoCommand.status == 0 && versionTwoCommand.errors.isEmpty && BackupArchive.verify(at: versionTwoArchive).databaseSchema == 3
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

    /// One live schema-3 snapshot includes completed receipts, interrupted
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
        checks["backup_schema_three_episode_inventory_captures_active_and_settled_work"] = manifest.databaseSchema == 3 && manifest.inventory.episodes == 3 && manifest.inventory.unfinishedEpisodes == 2 && manifest.inventory.episodeWork == 6 && manifest.inventory.episodePreparedWork == 2 && manifest.inventory.episodeUncertainWork == 2 && manifest.inventory.episodeCharged == expectedCharged && manifest.inventory.episodeHeld == expectedHeld
        checks["backup_episode_request_snapshots_deduplicate_exact_bodies"] = manifest.inventory.episodeSnapshots == 2 && manifest.inventory.episodeSnapshotBytes == Int64(body.count + calibrationBody.count)
        checks["backup_episode_manifest_roundtrip_verified"] = try BackupArchive.verify(at: archive) == manifest
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
        checks["backup_cli_corrupt_schema_three_journal_refused_before_source_mutation"] = try refusedCommand.status == 1 && refusedCommand.output.isEmpty && Data(contentsOf: sourceDatabase) == sourceBytesBefore && schemaSnapshot(sourceDatabase) == sourceSchemaBefore && FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == sourceFilesBefore && !FileManager.default.fileExists(atPath: commandArchive.path)
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
        let manifestPath = legacy.appendingPathComponent("manifest.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestPath)) as! [String: Any]
        object["databaseSchema"] = 2
        var inventory = object["inventory"] as! [String: Any]
        for key in Array(inventory.keys) where key.hasPrefix("episode") || key == "unfinishedEpisodes" { inventory.removeValue(forKey: key) }
        object["inventory"] = inventory
        try privateWrite(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), at: manifestPath)
        try refreshDatabaseHash(legacy)
        let verified = try BackupArchive.verify(at: legacy)
        checks["backup_schema_two_manifest_decodes_without_episode_inventory"] = verified.databaseSchema == 2 && verified.inventory.episodes == nil && verified.inventory.episodeCharged == nil && verified.inventory.episodeHeld == nil
        let destination = scratch.appendingPathComponent("schema-two-restored", isDirectory: true)
        _ = try BackupArchive.restore(from: legacy, to: destination, authority: .unmanagedNoDeletion)
        do {
            let owner = try MemoryStore(directory: destination)
            let invocation = try owner.invocation(id: "complete-attempt")!
            checks["restore_schema_two_invocations_remain_unmetered_historical"] = invocation.episodeID == nil && invocation.episodeWorkID == nil && invocation.finalStatus == .complete && invocation.usageJSON == Data("{\"prompt_tokens\":37,\"completion_tokens\":9}".utf8)
            checks["restore_schema_two_private_upgrade_preserves_recovery_and_counts"] = try owner.invocation(id: "interrupted-attempt")?.finalStatus == .partial && owner.invocation(id: "empty-attempt")?.finalStatus == .failed && owner.sourceManifest(projectID: "synthetic-backup-alpha", afterSequence: 0, limit: 1000).count == 6
            let upgradedArchive = scratch.appendingPathComponent("schema-two-upgraded-archive", isDirectory: true)
            let upgraded = try BackupArchive.create(from: owner, at: upgradedArchive)
            checks["restore_schema_two_upgrades_private_staging_to_schema_three"] = upgraded.databaseSchema == 3 && upgraded.inventory.episodes == 0 && upgraded.inventory.episodeWork == 0 && upgraded.inventory.invocations == verified.inventory.invocations && upgraded.inventory.events == verified.inventory.events + verified.inventory.unfinishedInvocations
        }
        checks["restore_schema_two_preserves_original_verified_archive"] = try BackupArchive.verify(at: legacy) == verified
        return checks
    }

    private static func downgrade(_ database: URL, to version: Int) throws {
        guard version == 1 || version == 2 else { throw BackupError.invalid("synthetic downgrade version") }
        try sql(database, "ALTER TABLE invocations DROP COLUMN episode_work_id; ALTER TABLE invocations DROP COLUMN episode_id; DROP TABLE episode_work; DROP TABLE episode_resource_totals; DROP TABLE episode_request_snapshots; DROP TABLE episodes")
        if version == 1 { try sql(database, "DROP TABLE invocation_chunks; DROP TABLE invocations") }
        try sql(database, "PRAGMA user_version=\(version)")
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
