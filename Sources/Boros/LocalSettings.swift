import Foundation
import Darwin
import Security
import LocalAuthentication

/// Private UI preferences, including explicitly saved instructions. Accepted
/// requests/answers belong to the application store; credentials use Keychain.
struct LocalSettings: Codable {
    var conversationID: String?
    var endpointURL = "http://localhost:11234/v1/"
    var endpointModel = "ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit"
    var profile = ModelProfile.customLocal.rawValue
    // Optional so existing settings JSON retains its conversation selection.
    var endpointTokenBudget: Int?
    var endpointJSONOutput: Bool?
    // Missing keeps the historical default; empty deliberately clears it.
    var systemInstructions: String?
    static let maximumInstructionBytes = 131072
    static let maximumEncodedBytes = 1048576
    enum Failure: Error { case instructionsTooLarge, settingsTooLarge }

    static func load(in directory: URL) -> LocalSettings {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("settings.json")),
              data.count <= maximumEncodedBytes,
              let settings = try? JSONDecoder().decode(LocalSettings.self, from: data) else { return LocalSettings() }
        guard (settings.systemInstructions?.utf8.count ?? 0) <= maximumInstructionBytes else { return LocalSettings() }
        return settings
    }

    func save(in directory: URL) throws {
        guard (systemInstructions?.utf8.count ?? 0) <= Self.maximumInstructionBytes else { throw Failure.instructionsTooLarge }
        let bytes = try JSONEncoder().encode(self)
        guard bytes.count <= Self.maximumEncodedBytes else { throw Failure.settingsTooLarge }
        let destination = directory.appendingPathComponent("settings.json")
        let staging = directory.appendingPathComponent(".settings-" + UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: staging) }
        try bytes.write(to: staging, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        // Set permissions before publication. No fallible step follows rename:
        // a reported failure cannot replace the previously saved preference.
        guard rename(staging.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// The server origin is the Keychain account: credentials cannot silently follow an address change.
enum LocalCredentialStore {
    enum Failure: Error { case invalidAddress, unavailable }
    private static let service = "dev.boros.local-model-api"

    static func origin(for address: String) throws -> String {
        guard let url = URL(string: address), url.scheme == "http",
              let host = url.host, ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true else { throw Failure.invalidAddress }
        return "http://\(host.lowercased()):\(url.port ?? 80)"
    }

    private static func query(_ address: String) throws -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: try origin(for: address)]
    }

    static func read(for address: String) throws -> String {
        var request = try query(address)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw Failure.unavailable
        }
        return value
    }

    static func write(_ key: String, for address: String) throws {
        var request = try query(address)
        // Empty keys remove a previously stored credential.
        if key.isEmpty {
            let status = SecItemDelete(request as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.unavailable }
            return
        }
        let attributes = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Failure.unavailable }
        request[kSecValueData as String] = Data(key.utf8)
        request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw Failure.unavailable }
    }
}
