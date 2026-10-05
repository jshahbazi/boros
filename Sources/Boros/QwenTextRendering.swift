import Foundation
import CoreFoundation

/// mlx-serve advertises request-time `created` values, not a load generation.
/// This descriptor pins observable metadata and explicitly leaves instance
/// continuity unknown. It is shared by live and offline journal validation.
struct ProviderObservedModelIdentity: Codable, Equatable {
    static let versionValue = "mlx-serve-model-observation-v1"
    let version: String
    let instanceIdentity: String
    let modelID: String
    let owner: String
    let engine: String
    let architecture: String
    let modelContextLimit: Int
    let maxModelLength: Int
    let capabilities: [String]
    let inputModalities: [String]
    let serverVersion: String
    let templateDigest: String

    static func observe(model: [String: Any]) throws -> Self {
        guard let loaded = model["loaded"] as? NSNumber, CFGetTypeID(loaded) == CFBooleanGetTypeID(), loaded.boolValue,
              model["state"] as? String == "ready",
              let id = model["id"] as? String, let owner = model["owned_by"] as? String,
              let meta = model["meta"] as? [String: Any], let engine = meta["engine"] as? String,
              let architecture = meta["architecture"] as? String,
              let context = positiveInteger(model["context_length"]), let maximum = positiveInteger(model["max_model_len"]),
              let capabilities = model["capabilities"] as? [String], let modalities = model["input_modalities"] as? [String] else {
            throw QwenTextRenderingError.unverifiedAdapter
        }
        let identity = Self(version: versionValue, instanceIdentity: "unobservable", modelID: id, owner: owner,
            engine: engine, architecture: architecture, modelContextLimit: context, maxModelLength: maximum,
            capabilities: capabilities.sorted(), inputModalities: modalities.sorted(),
            serverVersion: Qwen38TextRendering.serverVersion, templateDigest: Qwen38TextRendering.templateDigest)
        return try identity.validated()
    }

    func validated() throws -> Self {
        func exact(_ left: String, _ right: String) -> Bool { left.utf8.elementsEqual(right.utf8) }
        guard exact(version, Self.versionValue), exact(instanceIdentity, "unobservable"),
              exact(modelID, Qwen38TextRendering.modelID), exact(owner, "mlx-serve"), exact(engine, "mlx"),
              exact(architecture, "qwen4_exp"), modelContextLimit > 0, maxModelLength > 0,
              modelContextLimit <= maxModelLength,
              exact(serverVersion, Qwen38TextRendering.serverVersion), exact(templateDigest, Qwen38TextRendering.templateDigest),
              Self.canonicalNames(capabilities, maximumCount: 32), Self.canonicalNames(inputModalities, maximumCount: 8),
              capabilities.contains("chat"), capabilities.contains("streaming"), inputModalities.contains("text") else {
            throw QwenTextRenderingError.unverifiedAdapter
        }
        return self
    }
    func canonicalData() throws -> Data {
        _ = try validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
    static func adapterIdentity(endpoint: String, metadataDigest: String, thinking: Bool) -> String {
        "mlx-serve-qwen38-observed-text-v1|" + endpoint + "|" + Qwen38TextRendering.modelID + "|"
            + Qwen38TextRendering.serverVersion + "|" + Qwen38TextRendering.templateDigest + "|observed="
            + metadataDigest + "|instance=unobservable|thinking=" + String(thinking)
    }
    private static func canonicalNames(_ values: [String], maximumCount: Int) -> Bool {
        guard !values.isEmpty, values.count <= maximumCount, values == values.sorted(), Set(values).count == values.count else { return false }
        return values.allSatisfy { value in
            (1...64).contains(value.utf8.count) && value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }
        }
    }
    private static func positiveInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue > 0, number.doubleValue < Double(Int.max),
              number.doubleValue.rounded(.down) == number.doubleValue else { return nil }
        return number.intValue
    }
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    private enum CodingKeys: String, CodingKey {
        case version, instanceIdentity, modelID, owner, engine, architecture, modelContextLimit, maxModelLength,
             capabilities, inputModalities, serverVersion, templateDigest
    }
    init(version: String, instanceIdentity: String, modelID: String, owner: String, engine: String,
         architecture: String, modelContextLimit: Int, maxModelLength: Int, capabilities: [String], inputModalities: [String],
         serverVersion: String, templateDigest: String) {
        self.version = version; self.instanceIdentity = instanceIdentity; self.modelID = modelID; self.owner = owner
        self.engine = engine; self.architecture = architecture; self.modelContextLimit = modelContextLimit
        self.maxModelLength = maxModelLength; self.capabilities = capabilities; self.inputModalities = inputModalities
        self.serverVersion = serverVersion; self.templateDigest = templateDigest
    }
    init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: Key.self)
        guard Set(keys.allKeys.map(\.stringValue)) == Set(["version", "instanceIdentity", "modelID", "owner", "engine", "architecture",
            "modelContextLimit", "maxModelLength", "capabilities", "inputModalities", "serverVersion", "templateDigest"]) else {
            throw QwenTextRenderingError.unverifiedAdapter
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(version: try values.decode(String.self, forKey: .version), instanceIdentity: try values.decode(String.self, forKey: .instanceIdentity),
            modelID: try values.decode(String.self, forKey: .modelID), owner: try values.decode(String.self, forKey: .owner),
            engine: try values.decode(String.self, forKey: .engine), architecture: try values.decode(String.self, forKey: .architecture),
            modelContextLimit: try values.decode(Int.self, forKey: .modelContextLimit), maxModelLength: try values.decode(Int.self, forKey: .maxModelLength),
            capabilities: try values.decode([String].self, forKey: .capabilities), inputModalities: try values.decode([String].self, forKey: .inputModalities),
            serverVersion: try values.decode(String.self, forKey: .serverVersion), templateDigest: try values.decode(String.self, forKey: .templateDigest))
        _ = try validated()
    }
    static func == (left: Self, right: Self) -> Bool {
        func exact(_ left: String, _ right: String) -> Bool { left.utf8.elementsEqual(right.utf8) }
        func exactArray(_ left: [String], _ right: [String]) -> Bool {
            left.count == right.count && zip(left, right).allSatisfy { exact($0, $1) }
        }
        return exact(left.version, right.version) && exact(left.instanceIdentity, right.instanceIdentity)
            && exact(left.modelID, right.modelID) && exact(left.owner, right.owner) && exact(left.engine, right.engine)
            && exact(left.architecture, right.architecture) && left.modelContextLimit == right.modelContextLimit
            && left.maxModelLength == right.maxModelLength && exactArray(left.capabilities, right.capabilities)
            && exactArray(left.inputModalities, right.inputModalities) && exact(left.serverVersion, right.serverVersion)
            && exact(left.templateDigest, right.templateDigest)
    }
}

/// Prefix intervals use SQLite BINARY ordering. Each lower bound ends in '|';
/// replacing that byte with '}' is its exact exclusive prefix upper bound.
struct ProviderAdapterQuarantinePrefixRange: Equatable {
    let lowerInclusive: String
    let upperExclusive: String
    static func == (left: Self, right: Self) -> Bool {
        left.lowerInclusive.utf8.elementsEqual(right.lowerInclusive.utf8)
            && left.upperExclusive.utf8.elementsEqual(right.upperExclusive.utf8)
    }
}

/// A count/body binding retains the full adapter identity. Quarantine instead
/// spans observations and historical epoch slots in the same pinned provider
/// family, so changing capacity or capabilities cannot clear a violation.
struct ProviderAdapterQuarantineFamily: Equatable {
    let identity: String
    let prefixRanges: [ProviderAdapterQuarantinePrefixRange]
    let thinkingSuffix: String

    static func recognize(_ adapterIdentity: String) -> Self? {
        guard !adapterIdentity.contains("\0"), adapterIdentity.utf8.count <= 2_048 else { return nil }
        // Generated URLs percent-encode '|' and never contain a literal field
        // separator. Validate their canonical representation before using it.
        let fields = adapterIdentity.components(separatedBy: "|")
        guard fields.count == 7 || fields.count == 8,
              validEndpoint(fields[1]), exact(fields[2], Qwen38TextRendering.modelID),
              exact(fields[3], Qwen38TextRendering.serverVersion), exact(fields[4], Qwen38TextRendering.templateDigest) else { return nil }
        let suffix: String
        if fields.count == 7 {
            guard exact(fields[0], "mlx-serve-qwen38-text-v1"), let epoch = Int(fields[5]), epoch >= 0,
                  exact(fields[5], String(epoch)) else { return nil }
            suffix = fields[6]
        } else {
            let marker = "observed=", descriptor = fields[5]
            guard exact(fields[0], "mlx-serve-qwen38-observed-text-v1"), descriptor.utf8.starts(with: marker.utf8),
                  descriptor.utf8.count == marker.utf8.count + 64,
                  descriptor.utf8.dropFirst(marker.utf8.count).allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  exact(fields[6], "instance=unobservable") else { return nil }
            suffix = fields[7]
        }
        guard exact(suffix, "thinking=true") || exact(suffix, "thinking=false") else { return nil }
        let pinned = fields[1...4].joined(separator: "|") + "|"
        let prefixes = ["mlx-serve-qwen38-text-v1|", "mlx-serve-qwen38-observed-text-v1|"].map { format in
            let lower = format + pinned
            return ProviderAdapterQuarantinePrefixRange(lowerInclusive: lower, upperExclusive: String(lower.dropLast()) + "}")
        }
        return Self(identity: "mlx-serve-qwen38-quarantine-v1|" + pinned + suffix,
            prefixRanges: prefixes, thinkingSuffix: "|" + suffix)
    }
    /// Use after a prefix query when generic malformed lookalikes can occur.
    func contains(_ adapterIdentity: String) -> Bool {
        guard let other = Self.recognize(adapterIdentity) else { return false }
        return Self.exact(identity, other.identity)
    }
    private static func exact(_ left: String, _ right: String) -> Bool { left.utf8.elementsEqual(right.utf8) }
    private static func validEndpoint(_ value: String) -> Bool {
        guard let parts = URLComponents(string: value), parts.scheme?.lowercased() == "http",
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let rawHost = parts.host, let url = parts.url, exact(url.absoluteString, value),
              parts.percentEncodedPath == "/v1/chat/completions",
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return false }
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }
    static func == (left: Self, right: Self) -> Bool {
        exact(left.identity, right.identity) && left.prefixRanges == right.prefixRanges && exact(left.thinkingSuffix, right.thinkingSuffix)
    }
}

/// Host provenance labels shared by rendering and offline journal validation.
enum ProviderMessageComponent: String, Codable, Equatable, Sendable { case mandatory, recent, evidence }

struct ProviderAttributedRender {
    let complete: String
    let recent: String
    let evidence: String
}

enum QwenTextRenderingError: Error { case invalidRequest, unverifiedAdapter }

/// Foundation-only implementation of the byte-pinned mlx-serve text template.
/// Live admission and offline journal verification call this same renderer.
enum Qwen38TextRendering {
    static let modelID = "ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit"
    static let templateDigest = "c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041"
    static let serverVersion = "26.10.1"
    static let lowInstructions = "Reasoning effort is set to low. Keep your thinking brief and focused, moving directly to the conclusion without unnecessary elaboration."

    static func render(_ body: [String: Any]) throws -> String {
        try renderAttributed(body, assignments: nil).complete
    }

    /// Provenance is supplied by the host; the message role does not determine
    /// which allocation owns a historical block.
    static func renderAttributed(_ body: [String: Any], assignments: [ProviderMessageComponent]?) throws -> ProviderAttributedRender {
        guard body["model"] as? String == modelID,
              let raw = body["messages"] as? [[String: String]],
              let thinking = body["enable_thinking"] as? Bool,
              body["reasoning_effort"] as? String == (thinking ? "low" : "none"),
              let kwargs = body["chat_template_kwargs"] as? [String: Any],
              kwargs.count == 1, kwargs["preserve_thinking"] as? Bool == true,
              body["tools"] == nil, body["continue_final_message"] == nil else {
            throw QwenTextRenderingError.unverifiedAdapter
        }
        // mlx-serve drops exactly empty plain text messages before Jinja rendering.
        if let assignments {
            guard assignments.count == raw.count,
                  raw.enumerated().allSatisfy({ index, message in message["role"] != "system" || assignments[index] == .mandatory }) else {
                throw QwenTextRenderingError.invalidRequest
            }
        }
        let indexed = raw.enumerated().filter { $0.element["content"] != "" }
        let messages = indexed.map(\.element)
        guard !messages.isEmpty, messages.allSatisfy({ Set($0.keys) == Set(["role", "content"]) }),
              !messages.dropFirst().contains(where: { $0["role"] == "system" }),
              messages.contains(where: { message in
                  let value = trim(message["content"] ?? "")
                  return message["role"] == "user" && !(value.hasPrefix("<tool_response>") && value.hasSuffix("</tool_response>"))
              }) else { throw QwenTextRenderingError.invalidRequest }
        var rendered = "", recent = "", evidence = ""
        let system = messages.first?["role"] == "system" ? trim(messages[0]["content"] ?? "") : ""
        let instruction = thinking ? lowInstructions : ""
        if !system.isEmpty || !instruction.isEmpty {
            rendered += "<|im_start|>system\n" + instruction
            if !instruction.isEmpty && !system.isEmpty { rendered += "\n\n" }
            rendered += system + "<|im_end|>\n"
        }
        for (index, message) in indexed {
            let value = trim(message["content"] ?? "")
            let block: String
            switch message["role"] {
            case "system": continue
            case "user": block = "<|im_start|>user\n" + value + "<|im_end|>\n"
            case "assistant": block = "<|im_start|>assistant\n<think>\n\n</think>\n\n" + value + "<|im_end|>\n"
            default: throw QwenTextRenderingError.invalidRequest
            }
            let normalized = normalize(block)
            rendered += normalized
            if assignments?[index] == .recent { recent += normalized }
            if assignments?[index] == .evidence { evidence += normalized }
        }
        rendered += "<|im_start|>assistant\n" + (thinking ? "<think>\n" : "<think>\n\n</think>\n\n")
        // Server post-render normalization also affects literal occurrences inside content.
        return ProviderAttributedRender(complete: normalize(rendered), recent: recent, evidence: evidence)
    }

    private static func normalize(_ value: String) -> String {
        var value = value
        while value.contains("</think></think>") { value = value.replacingOccurrences(of: "</think></think>", with: "</think>") }
        return value
    }

    static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\u{000B}\u{000C}"))
    }

}
