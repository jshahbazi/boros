import Foundation
import CryptoKit
import Darwin

/// Offline ingestion into a fresh store. Imported messages never create model
/// invocations, episodes, host instructions, or credentials.
enum ChatImportCommand {
    static let maximumDocumentBytes = 128 * 1024 * 1024
    static let maximumMessages = 100_000
    private enum Failure: Error { case arguments, invalid, io, publishedSyncUnknown }

    struct Message: Codable {
        let role: String
        let content: String
        let status: CaptureStatus
    }
    struct Source: Codable {
        let dataset: String
        let url: String?
        let sha256: String
        let selection: Int
    }
    struct Document: Codable {
        let schema_version: Int
        let title: String
        let source: Source
        let messages: [Message]
        let original_json: String?
    }
    private struct ImportedMessage: Codable {
        let ordinal: Int
        let event_id: String
        let turn_id: String
        let role: String
        let status: CaptureStatus
        let source_bytes: Int
        let sha256: String
    }
    private struct Manifest: Codable {
        let version: Int
        let import_sha256: String
        let source: Source
        let conversation_id: String
        let project_id: String
        let input_messages: Int
        let imported_messages: [ImportedMessage]
        let timestamps: String
        let original_source_verified: Bool
    }
    private struct Report: Codable {
        let status: String
        let messages: Int
        let user_messages: Int
        let assistant_messages: Int
        let source_bytes: Int
        let import_sha256: String
    }

    static func run(arguments: [String]) -> Int32? {
        var args = arguments
        if let first = args.first, !first.hasPrefix("--") { args.removeFirst() }
        guard args.contains("--import-chat") else { return nil }
        do {
            let report = try perform(args)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(report))
            FileHandle.standardOutput.write(Data([10]))
            return 0
        } catch Failure.arguments {
            fputs("Usage: --import-chat ABS --destination ABS [--through-message COUNT].\n", stderr)
            return 2
        } catch Failure.publishedSyncUnknown {
            fputs("Import was published, but its parent directory sync failed; publication durability is unknown.\n", stderr)
            return 1
        } catch {
            // Error descriptions and SQLite diagnostics can contain source text.
            fputs("Chat import failed validation or publication. The destination must be new and its parent must exist without symbolic links.\n", stderr)
            return 1
        }
    }

    private static func perform(_ arguments: [String]) throws -> Report {
        guard arguments.first == "--import-chat", arguments.count == 4 || arguments.count == 6 else { throw Failure.arguments }
        var options: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let key = arguments[index]
            guard ["--import-chat", "--destination", "--through-message"].contains(key), options[key] == nil else { throw Failure.arguments }
            options[key] = arguments[index + 1]
        }
        guard let input = options["--import-chat"], let destination = options["--destination"] else { throw Failure.arguments }
        try validatePath(input); try validatePath(destination)
        let through: Int?
        if let count = options["--through-message"] {
            guard let value = Int(count), value > 0 else { throw Failure.arguments }
            through = value
        } else { through = nil }
        let bytes = try readDocument(URL(fileURLWithPath: input))
        let document = try decode(bytes)
        guard through.map({ $0 <= document.messages.count }) ?? true else { throw Failure.invalid }
        let selected = Array(document.messages.prefix(through ?? document.messages.count))
        let target = try Destination(URL(fileURLWithPath: destination, isDirectory: true))
        let staging = try target.stage()
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: staging) } }
        let digest = sha256(bytes)
        // Close both owners before syncing and renaming. Store startup and
        // readback run through the same APIs used by the application.
        let manifest = try ingest(document, selected: selected, digest: digest, at: staging)
        try writePrivate(bytes, at: staging.appendingPathComponent("chat-import.json"))
        if let original = document.original_json {
            try writePrivate(Data(original.utf8), at: staging.appendingPathComponent("chat-source.json"))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try writePrivate(try encoder.encode(manifest), at: staging.appendingPathComponent("import-manifest.json"))
        try verify(selected, manifest: manifest, at: staging)
        for file in try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
            try sync(file, directory: false)
        }
        try sync(staging, directory: true)
        try target.publish(staging)
        published = true
        try target.syncParent()
        return Report(status: "verified", messages: selected.count,
            user_messages: selected.filter { $0.role == "user" }.count,
            assistant_messages: selected.filter { $0.role == "assistant" }.count,
            source_bytes: selected.reduce(0) { $0 + $1.content.utf8.count }, import_sha256: digest)
    }

    private static func decode(_ bytes: Data) throws -> Document {
        guard String(data: bytes, encoding: .utf8) != nil else { throw Failure.invalid }
        var scanner = KeyScanner(bytes: Array(bytes)); try scanner.scan()
        guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(root.keys).isSubset(of: ["schema_version", "title", "source", "messages", "original_json"]),
              Set(root.keys).isSuperset(of: ["schema_version", "title", "source", "messages"]),
              let source = root["source"] as? [String: Any],
              Set(source.keys).isSubset(of: ["dataset", "url", "sha256", "selection"]),
              Set(source.keys).isSuperset(of: ["dataset", "sha256", "selection"]),
              let raw = root["messages"] as? [[String: Any]],
              raw.allSatisfy({ Set($0.keys) == ["role", "content", "status"] }) else { throw Failure.invalid }
        let value = try JSONDecoder().decode(Document.self, from: bytes)
        guard value.schema_version == 1, !value.title.isEmpty, value.title.utf8.count <= 1024,
              !value.title.contains("\0"), !value.source.dataset.isEmpty, value.source.dataset.utf8.count <= 256,
              value.source.selection >= 0, value.source.sha256.count == 64,
              value.source.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !value.messages.isEmpty, value.messages.count <= maximumMessages else { throw Failure.invalid }
        if let address = value.source.url {
            guard address.utf8.count <= 4096, let url = URL(string: address), url.scheme == "https",
                  url.host != nil, url.user == nil, url.password == nil else { throw Failure.invalid }
        }
        if let original = value.original_json {
            guard sha256(Data(original.utf8)) == value.source.sha256 else { throw Failure.invalid }
        }
        // Validate the entire input even for a prefix import. Nothing is
        // accepted with an oversized, unsupported, or malformed later turn.
        guard value.messages.allSatisfy({ ["user", "assistant"].contains($0.role)
            && $0.content.utf8.count <= MemoryStore.maximumPayloadBytes }) else { throw Failure.invalid }
        return value
    }

    private static func ingest(_ document: Document, selected: [Message], digest: String, at directory: URL) throws -> Manifest {
        let store = try MemoryStore(directory: directory)
        let chat = try store.createConversation(projectID: "default", title: document.title)
        var records: [ImportedMessage] = []
        var turn = 0
        for (ordinal, message) in selected.enumerated() {
            if message.role == "user" || turn == 0 { turn += 1 }
            let eventID = "import-\(digest)-\(ordinal)"
            let turnID = "import-\(digest)-turn-\(turn)"
            let event = try store.append(conversationID: chat.id, role: message.role == "user" ? .human : .assistant,
                text: message.content, status: message.status, turnID: turnID, eventID: eventID)
            records.append(ImportedMessage(ordinal: ordinal, event_id: event.id, turn_id: event.turnID,
                role: message.role, status: message.status, source_bytes: event.byteCount, sha256: event.digest))
        }
        return Manifest(version: 1, import_sha256: digest, source: document.source, conversation_id: chat.id,
            project_id: "default", input_messages: document.messages.count, imported_messages: records,
            timestamps: "Store event timestamps record ingestion. Source order is the original message order; no original chronology is inferred.",
            original_source_verified: document.original_json != nil)
    }

    private static func verify(_ messages: [Message], manifest: Manifest, at directory: URL) throws {
        let owner = try MemoryStore(directory: directory)
        let events = try owner.events(conversationID: manifest.conversation_id)
        guard events.count == messages.count else { throw Failure.invalid }
        for index in messages.indices {
            let message = messages[index], event = events[index], record = manifest.imported_messages[index]
            guard Data(event.text.utf8) == Data(message.content.utf8), event.status == message.status,
                  event.role == (message.role == "user" ? .human : .assistant),
                  event.id == record.event_id, event.turnID == record.turn_id,
                  event.byteCount == record.source_bytes, event.digest == record.sha256,
                  event.digest == sha256(Data(message.content.utf8)) else { throw Failure.invalid }
        }
    }

    private static func validatePath(_ path: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/").contains("."), !path.split(separator: "/").contains("..") else { throw Failure.arguments }
    }
    private static func readDocument(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.io }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= maximumDocumentBytes else { throw Failure.invalid }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { return result }
            if count < 0 { if errno == EINTR { continue }; throw Failure.io }
            guard result.count <= maximumDocumentBytes - count else { throw Failure.invalid }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
    private static func writePrivate(_ bytes: Data, at url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.io }; defer { close(fd) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw Failure.io }
                guard count > 0 else { throw Failure.io }; offset += count
            }
        }
        guard fsync(fd) == 0 else { throw Failure.io }
    }
    private static func sync(_ url: URL, directory: Bool) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | (directory ? O_DIRECTORY : 0))
        guard fd >= 0 else { throw Failure.io }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw Failure.io }
    }
    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private final class Destination {
        let parent: URL, name: String
        let parentFD: Int32
        init(_ url: URL) throws {
            parent = url.deletingLastPathComponent(); name = url.lastPathComponent
            guard !name.isEmpty, name != "/" else { throw Failure.arguments }
            parentFD = try Self.openChain(parent)
            var info = stat()
            guard fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
                close(parentFD); throw Failure.invalid
            }
        }
        deinit { close(parentFD) }
        func validateParent() throws {
            let current = try Self.openChain(parent); defer { close(current) }
            var held = stat(), actual = stat()
            guard fstat(parentFD, &held) == 0, fstat(current, &actual) == 0,
                  held.st_ino == actual.st_ino, held.st_dev == actual.st_dev else { throw Failure.io }
        }
        func stage() throws -> URL {
            try validateParent()
            let name = ".boros-import-" + UUID().uuidString
            guard mkdirat(parentFD, name, 0o700) == 0 else { throw Failure.io }
            return parent.appendingPathComponent(name, isDirectory: true)
        }
        func publish(_ directory: URL) throws {
            try validateParent()
            guard renameatx_np(parentFD, directory.lastPathComponent, parentFD, name, UInt32(RENAME_EXCL)) == 0 else { throw Failure.io }
        }
        func syncParent() throws { guard fsync(parentFD) == 0 else { throw Failure.publishedSyncUnknown } }
        private static func openChain(_ url: URL) throws -> Int32 {
            var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard fd >= 0 else { throw Failure.io }
            for part in url.pathComponents.dropFirst() {
                let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                close(fd); guard next >= 0 else { throw Failure.io }; fd = next
            }
            return fd
        }
    }

    /// Reject duplicate object keys (including escaped spellings) before the
    /// Foundation decoder can choose one value. JSON syntax is then decoded by
    /// Foundation. Nesting is bounded independently of total input size.
    private struct KeyScanner {
        let bytes: [UInt8]
        var position = 0
        mutating func scan() throws {
            try value(depth: 0); whitespace()
            guard position == bytes.count else { throw Failure.invalid }
        }
        mutating func whitespace() { while position < bytes.count && [9, 10, 13, 32].contains(bytes[position]) { position += 1 } }
        mutating func take(_ byte: UInt8) throws {
            whitespace(); guard position < bytes.count, bytes[position] == byte else { throw Failure.invalid }; position += 1
        }
        mutating func string() throws -> String {
            whitespace(); let start = position; try take(34)
            while position < bytes.count {
                let byte = bytes[position]; position += 1
                if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<position])) }
                if byte == 92 { guard position < bytes.count else { throw Failure.invalid }; position += 1 }
            }
            throw Failure.invalid
        }
        mutating func value(depth: Int) throws {
            whitespace(); guard depth <= 64, position < bytes.count else { throw Failure.invalid }
            switch bytes[position] {
            case 123:
                position += 1; whitespace(); var keys = Set<Data>()
                if position < bytes.count, bytes[position] == 125 { position += 1; return }
                while true {
                    let key = Data(try string().utf8)
                    guard keys.insert(key).inserted else { throw Failure.invalid }
                    try take(58); try value(depth: depth + 1); whitespace()
                    guard position < bytes.count else { throw Failure.invalid }
                    if bytes[position] == 125 { position += 1; return }; try take(44)
                }
            case 91:
                position += 1; whitespace()
                if position < bytes.count, bytes[position] == 93 { position += 1; return }
                while true {
                    try value(depth: depth + 1); whitespace(); guard position < bytes.count else { throw Failure.invalid }
                    if bytes[position] == 93 { position += 1; return }; try take(44)
                }
            case 34: _ = try string()
            default:
                let start = position
                while position < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[position]) { position += 1 }
                guard position > start else { throw Failure.invalid }
            }
        }
    }
}
