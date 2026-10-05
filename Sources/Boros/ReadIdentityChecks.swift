import Foundation
import CryptoKit
import CSQLite
import Darwin

/// Unicode identifiers remain byte identities, matching SQLite BINARY text.
/// These public synthetic fixtures exercise backup and restore boundaries;
/// they never open a user store or print source content.
enum ReadIdentityChecks {
    static func run() throws -> [String: Bool] {
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw BackupError.io("cannot resolve synthetic identity directory")
        }
        let temporaryRoot = String(cString: resolved)
        free(resolved)
        let scratch = URL(fileURLWithPath: temporaryRoot, isDirectory: true)
            .appendingPathComponent("boros-read-identity-check-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }

        let composed = "caf\u{00e9}"
        let decomposed = "cafe\u{0301}"
        let identities = [composed, decomposed]
        let expectedIdentityBytes = Set(identities.map { Data($0.utf8) })
        let sourceDirectory = scratch.appendingPathComponent("source", isDirectory: true)
        var owner: MemoryStore? = try MemoryStore(directory: sourceDirectory)
        let first = try owner!.createConversation(projectID: composed, title: "Synthetic identity scope A")
        let second = try owner!.createConversation(projectID: decomposed, title: "Synthetic identity scope B")
        owner = nil

        // Conversation creation normally uses UUIDs. Set up valid existing
        // Unicode conversation IDs while the owner is closed, before sources
        // or foreign-key references exist. The reopened owner supplies all
        // subsequent accepted source and invocation writes.
        try executeSQL(sourceDirectory.appendingPathComponent("memory.sqlite3"), """
            UPDATE conversations SET id=CAST(X'\(hex(composed))' AS TEXT) WHERE id='\(first.id)';
            UPDATE conversations SET id=CAST(X'\(hex(decomposed))' AS TEXT) WHERE id='\(second.id)';
            """)
        owner = try MemoryStore(directory: sourceDirectory)
        let store = owner!
        let humanText = "Synthetic identity human source"
        let assistantText = "Synthetic identity assistant source"
        for identity in identities {
            _ = try store.append(conversationID: identity, role: .human, text: humanText,
                status: .complete, turnID: identity, eventID: identity)
            let body = try JSONSerialization.data(withJSONObject: ["model": identity, "messages": []] as [String: Any],
                options: [.sortedKeys])
            _ = try store.beginInvocation(invocationID: "invocation-" + identity, conversationID: identity,
                turnID: identity, humanEventID: identity, assistantEventID: "answer-" + identity,
                providerIdentity: "http://localhost:11234/v1/" + identity, requestBody: body)
            _ = try store.appendInvocationChunk(invocationID: "invocation-" + identity, sequence: 0, text: assistantText)
            _ = try store.finalizeInvocation(invocationID: "invocation-" + identity, status: .complete)
        }

        let clock = SystemEpisodeClock()
        let binding = EpisodeLocalReadBinding(initiator: .syntheticEvaluation, purpose: .sourcePage,
            requestID: "synthetic-unicode-scope-request", descriptorVersion: "identity-fixture-v1",
            descriptorSHA256: digest(Data("synthetic Unicode scope fixture".utf8)))
        _ = try store.beginLocalReadEpisode(episodeID: "synthetic-unicode-scope", projectID: composed,
            binding: binding, limits: .init(), clock: clock.now())
        let lease = EpisodeLease(ledger: store, episodeID: "synthetic-unicode-scope", clock: clock)
        var refusedScope = false
        do {
            _ = try MeteredRetrieval.page(store: store, eventID: decomposed, projectID: decomposed,
                offset: 0, length: 100, lease: lease)
        } catch EpisodeBudgetError.scopeMismatch { refusedScope = true }
        let untouchedReceipt = try lease.checkActive()
        _ = try lease.finish(reason: .cancelled)

        let archive = scratch.appendingPathComponent("archive", isDirectory: true)
        let manifest = try BackupArchive.create(from: store, at: archive)
        var checks: [String: Bool] = [
            "read_identity_unicode_foreign_scope_refused_before_work": refusedScope
                && untouchedReceipt.charged == .zero && untouchedReceipt.held == .zero,
            "backup_unicode_archive_verified_exact_inventory": try BackupArchive.verify(at: archive) == manifest,
            "backup_unicode_scope_counts_preserve_distinct_project_bytes": manifest.inventory.scopes.count == 2
                && Set(manifest.inventory.scopes.map { Data($0.projectID.utf8) }) == expectedIdentityBytes
                && manifest.inventory.scopes.allSatisfy { $0.conversations == 1 && $0.events == 2 && $0.invocations == 1 },
            "backup_unicode_provider_identity_bytes_preserved": manifest.inventory.providerIdentities.count == 2
                && Set(manifest.inventory.providerIdentities.map { Data($0.utf8) })
                    == Set(identities.map { Data(("http://localhost:11234/v1/" + $0).utf8) }),
            "backup_unicode_model_identity_bytes_preserved": manifest.inventory.servedModels.count == 2
                && Set(manifest.inventory.servedModels.map { Data($0.utf8) }) == expectedIdentityBytes
        ]

        let restoredDirectory = scratch.appendingPathComponent("restored", isDirectory: true)
        _ = try BackupArchive.restore(from: archive, to: restoredDirectory, authority: .unmanagedNoDeletion)
        do {
            let restored = try MemoryStore(directory: restoredDirectory)
            var preserved = true
            for identity in identities {
                let conversations = try restored.listConversations(projectID: identity)
                let events = try restored.events(conversationID: identity)
                preserved = preserved && conversations.count == 1
                    && conversations.allSatisfy { Data($0.id.utf8) == Data(identity.utf8) && Data($0.projectID.utf8) == Data(identity.utf8) }
                    && events.count == 2
                    && Set(events.map { Data($0.id.utf8) }) == Set([Data(identity.utf8), Data(("answer-" + identity).utf8)])
                    && events.allSatisfy { Data($0.projectID.utf8) == Data(identity.utf8)
                        && Data($0.conversationID.utf8) == Data(identity.utf8) && Data($0.turnID.utf8) == Data(identity.utf8) }
                    && events.contains { $0.role == .human && Data($0.text.utf8) == Data(humanText.utf8) }
                    && events.contains { $0.role == .assistant && Data($0.text.utf8) == Data(assistantText.utf8) }
            }
            checks["restore_unicode_conversation_and_source_identities_preserved"] = preserved
        }

        // The database remains valid. Only the manifest substitutes equivalent
        // looking project IDs, making its binary scope inventory incorrect.
        let scopeAlias = scratch.appendingPathComponent("scope-alias", isDirectory: true)
        try FileManager.default.copyItem(at: archive, to: scopeAlias)
        try mutateManifest(scopeAlias) { object in
            var inventory = object["inventory"] as! [String: Any]
            var scopes = inventory["scopes"] as! [[String: Any]]
            for index in scopes.indices { scopes[index]["projectID"] = composed }
            inventory["scopes"] = scopes
            object["inventory"] = inventory
        }
        checks["backup_unicode_manifest_scope_alias_refused"] = rejectsInvalid(containing: "inventory") {
            _ = try BackupArchive.verify(at: scopeAlias)
        }
        let refusedScopeDirectory = scratch.appendingPathComponent("scope-alias-restored", isDirectory: true)
        checks["restore_unicode_manifest_scope_alias_never_published"] = rejectsInvalid(containing: "inventory") {
            _ = try BackupArchive.restore(from: scopeAlias, to: refusedScopeDirectory, authority: .unmanagedNoDeletion)
        } && !FileManager.default.fileExists(atPath: refusedScopeDirectory.path)

        // Move one terminal assistant to the other valid conversation/project
        // and turn, preserving payload and foreign-key integrity. Update the
        // file hash and per-project inventory so only invocation linkage can
        // reject this otherwise self-consistent archive.
        let terminalAlias = scratch.appendingPathComponent("terminal-alias", isDirectory: true)
        try FileManager.default.copyItem(at: archive, to: terminalAlias)
        let database = terminalAlias.appendingPathComponent("memory.sqlite3")
        try executeSQL(database, """
            UPDATE events SET conversation_id=CAST(X'\(hex(decomposed))' AS TEXT),
                project_id=CAST(X'\(hex(decomposed))' AS TEXT), turn_id=CAST(X'\(hex(decomposed))' AS TEXT)
                WHERE id=CAST(X'\(hex("answer-" + composed))' AS TEXT);
            """)
        let databaseBytes = try Data(contentsOf: database)
        try mutateManifest(terminalAlias) { object in
            var files = object["files"] as! [[String: Any]]
            for index in files.indices where files[index]["name"] as? String == "memory.sqlite3" {
                files[index]["bytes"] = databaseBytes.count
                files[index]["sha256"] = digest(databaseBytes)
            }
            object["files"] = files
            var inventory = object["inventory"] as! [String: Any]
            var scopes = inventory["scopes"] as! [[String: Any]]
            for index in scopes.indices {
                if Data((scopes[index]["projectID"] as! String).utf8) == Data(composed.utf8) {
                    scopes[index]["events"] = 1
                    scopes[index]["sourceBytes"] = humanText.utf8.count
                } else {
                    scopes[index]["events"] = 3
                    scopes[index]["sourceBytes"] = humanText.utf8.count + 2 * assistantText.utf8.count
                }
            }
            inventory["scopes"] = scopes
            object["inventory"] = inventory
        }
        checks["backup_unicode_terminal_invocation_scope_alias_refused"] = rejectsInvalid(containing: "terminal invocation disagrees") {
            _ = try BackupArchive.verify(at: terminalAlias)
        }
        let refusedTerminalDirectory = scratch.appendingPathComponent("terminal-alias-restored", isDirectory: true)
        checks["restore_unicode_terminal_alias_never_published"] = rejectsInvalid(containing: "terminal invocation disagrees") {
            _ = try BackupArchive.restore(from: terminalAlias, to: refusedTerminalDirectory, authority: .unmanagedNoDeletion)
        } && !FileManager.default.fileExists(atPath: refusedTerminalDirectory.path)
        return checks
    }

    private static func rejectsInvalid(containing reason: String, _ body: () throws -> Void) -> Bool {
        do { try body(); return false }
        catch BackupError.invalid(let message) { return message.contains(reason) }
        catch { return false }
    }

    private static func executeSQL(_ path: URL, _ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw BackupError.database
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw BackupError.database }
    }

    private static func mutateManifest(_ archive: URL, _ change: (inout [String: Any]) -> Void) throws {
        let path = archive.appendingPathComponent("manifest.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        change(&object)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    private static func hex(_ value: String) -> String {
        Data(value.utf8).map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
