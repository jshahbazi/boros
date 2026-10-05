import Foundation
import Darwin

/// Content-free CLI summaries. Source/project IDs, paths, settings, provider
/// configuration, request bodies and captured text never appear in output.
struct BackupCommandReport: Codable {
    let operation: String
    let status: String
    let archiveID: String
    let archiveVersion: Int
    let databaseSchema: Int
    let controlState: String
    let conversations: Int
    let scopeCount: Int
    let archivedEvents: Int
    let archivedSourceBytes: Int64
    let invocations: Int
    let chunks: Int
    let unfinishedArchivedInvocations: Int
    let restoredInterruptedAttempts: Int?
    var episodes: Int? = nil
    var episodeWork: Int? = nil
    var unfinishedArchivedEpisodes: Int? = nil
    var uncertainArchivedWork: Int? = nil
    var restoredInterruptedEpisodes: Int? = nil
}

/// Takes argv with or without its executable name. The caller invokes this
/// before starting the GUI and exits when a nonnil status is returned.
enum BackupCommand {
    private static let operations: Set<String> = ["--backup-create", "--backup-verify", "--backup-restore"]
    private static let usage = "Usage: --backup-create --data-directory ABS --archive ABS; --backup-verify --archive ABS; --backup-restore --archive ABS --destination ABS.\n"
    private enum ArgumentError: Error { case invalid }

    static func run(arguments: [String]) -> Int32? {
        var args = arguments
        if let first = args.first, !first.hasPrefix("--") { args.removeFirst() }
        guard args.contains(where: operations.contains) else { return nil }
        do {
            let report = try perform(args)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let output = try encoder.encode(report)
            FileHandle.standardOutput.write(output)
            FileHandle.standardOutput.write(Data([0x0a]))
            return 0
        } catch ArgumentError.invalid {
            fputs("Invalid backup command arguments.\n", stderr)
            fputs(usage, stderr)
            return 2
        } catch MemoryError.ownerBusy {
            fputs("Another Boros process owns the source store; close its owner before creating a command-line backup.\n", stderr)
            return 1
        } catch BackupError.authorityUnavailable {
            fputs("Current deletion authority is unavailable or incompatible.\n", stderr)
            return 1
        } catch BackupError.publicationDurabilityUnknown {
            fputs("The verified destination was published, but parent directory sync failed; publication durability is unknown.\n", stderr)
            return 1
        } catch {
            // Error descriptions can contain imported metadata or SQLite
            // diagnostics. Only a fixed, content-free message leaves the CLI.
            fputs("Boros backup operation failed validation or could not complete.\n", stderr)
            return 1
        }
    }

    private static func perform(_ arguments: [String]) throws -> BackupCommandReport {
        guard arguments.filter({ operations.contains($0) }).count == 1,
              let operation = arguments.first, operations.contains(operation) else { throw ArgumentError.invalid }
        let allowed: Set<String>
        switch operation {
        case "--backup-create": allowed = ["--data-directory", "--archive"]
        case "--backup-verify": allowed = ["--archive"]
        default: allowed = ["--archive", "--destination"]
        }
        var options: [String: URL] = [:], index = 1
        while index < arguments.count {
            let key = arguments[index]
            guard allowed.contains(key), options[key] == nil, index + 1 < arguments.count else { throw ArgumentError.invalid }
            let path = arguments[index + 1]
            guard path.hasPrefix("/"), !path.contains("\0"),
                  !path.split(separator: "/", omittingEmptySubsequences: true).contains("."),
                  !path.split(separator: "/", omittingEmptySubsequences: true).contains("..") else { throw ArgumentError.invalid }
            options[key] = URL(fileURLWithPath: path, isDirectory: true)
            index += 2
        }
        guard Set(options.keys) == allowed, let archive = options["--archive"] else { throw ArgumentError.invalid }
        let manifest: BackupManifest
        switch operation {
        case "--backup-create":
            let source = options["--data-directory"]!
            // Never create an empty store as a side effect of a typo. Creation
            // is a backup of an existing store owned exclusively by this CLI.
            try requireExistingSource(source)
            let owner = try MemoryStore(directory: source)
            manifest = try BackupArchive.create(from: owner, at: archive, control: .unmanagedNoDeletion)
            withExtendedLifetime(owner) {}
        case "--backup-verify": manifest = try BackupArchive.verify(at: archive)
        default:
            manifest = try BackupArchive.restore(from: archive, to: options["--destination"]!, authority: .unmanagedNoDeletion)
        }
        return BackupCommandReport(operation: String(operation.dropFirst(2)), status: "verified", archiveID: manifest.archiveID,
            archiveVersion: manifest.archiveVersion, databaseSchema: manifest.databaseSchema, controlState: "unmanaged-no-deletion",
            conversations: manifest.inventory.conversations, scopeCount: manifest.inventory.scopes.count,
            archivedEvents: manifest.inventory.events, archivedSourceBytes: manifest.inventory.sourceBytes,
            invocations: manifest.inventory.invocations, chunks: manifest.inventory.chunks,
            unfinishedArchivedInvocations: manifest.inventory.unfinishedInvocations,
            restoredInterruptedAttempts: operation == "--backup-restore" ? manifest.inventory.unfinishedInvocations : nil,
            episodes: manifest.inventory.episodes, episodeWork: manifest.inventory.episodeWork,
            unfinishedArchivedEpisodes: manifest.inventory.unfinishedEpisodes,
            uncertainArchivedWork: manifest.inventory.episodeUncertainWork,
            restoredInterruptedEpisodes: operation == "--backup-restore" ? manifest.inventory.unfinishedEpisodes : nil)
    }

    private static func requireExistingSource(_ directory: URL) throws {
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0 else { throw BackupError.invalid("source directory must already exist and be private") }
        var ownerProbe: Int32 = -1
        let lockPath = directory.appendingPathComponent("owner.lock").path
        if lstat(lockPath, &metadata) == 0 {
            ownerProbe = open(lockPath, O_RDONLY | O_NOFOLLOW)
            guard ownerProbe >= 0, fstat(ownerProbe, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0, metadata.st_nlink == 1 else {
                if ownerProbe >= 0 { close(ownerProbe) }
                throw BackupError.invalid("source owner lock is not a private regular file")
            }
            guard flock(ownerProbe, LOCK_EX | LOCK_NB) == 0 else { close(ownerProbe); throw MemoryError.ownerBusy }
        } else if errno != ENOENT { throw BackupError.invalid("source owner lock cannot be inspected") }
        defer { if ownerProbe >= 0 { flock(ownerProbe, LOCK_UN); close(ownerProbe) } }
        let path = directory.appendingPathComponent("memory.sqlite3").path
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw BackupError.invalid("source database must already exist") }
        defer { close(descriptor) }
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0, metadata.st_nlink == 1,
              metadata.st_size >= 100 else { throw BackupError.invalid("source database must be a nonempty private regular file") }
        var header = [UInt8](repeating: 0, count: 100)
        guard read(descriptor, &header, header.count) == 100,
              Data(header.prefix(16)) == Data("SQLite format 3\0".utf8) else { throw BackupError.invalid("source is not a SQLite memory database") }
        // The current version can live in WAL rather than the main header.
        // Recognition checks a private main+WAL copy, never this source.
        try BackupArchive.recognizeExistingSource(at: directory)
    }
}
