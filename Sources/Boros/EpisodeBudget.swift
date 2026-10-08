import Foundation

/// SQLite identifiers use BINARY collation. Swift String equality performs
/// canonical Unicode equivalence, so it must not decide durable identity.
func episodeIdentifierEqual(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.elementsEqual(rhs.utf8)
}
func episodeIdentifierEqual(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none): return true
    case (.some(let lhs), .some(let rhs)): return episodeIdentifierEqual(lhs, rhs)
    default: return false
    }
}

enum EpisodeBudgetError: Error {
    case invalid, exhausted, deadlineExceeded, inactive, staleRevision, clockUnavailable, unobservableInput, adapterViolation, conflict, scopeMismatch
    var failureCode: String {
        switch self {
        case .exhausted: return "episode_budget_exceeded"
        case .deadlineExceeded: return "episode_deadline_exceeded"
        case .inactive, .staleRevision: return "episode_inactive"
        case .unobservableInput: return "episode_input_unobservable"
        case .adapterViolation: return "episode_adapter_violation"
        case .clockUnavailable: return "episode_clock_unavailable"
        case .scopeMismatch: return "episode_scope_mismatch"
        case .invalid, .conflict: return "episode_accounting_failed"
        }
    }
}

enum EpisodeResource: String, Codable, CaseIterable {
    case inputTokens, outputTokens, modelCalls, httpAttempts, memoryOperations, rawSourceBytes, vectorBytes, metadataRows, encoderInputBytes
}

/// Resource vectors use nonnegative checked integers. Opaque encoder input is
/// recorded as bytes and unknown tokens; bytes are never converted to tokens.
struct EpisodeResources: Codable, Equatable {
    var inputTokens = 0
    var outputTokens = 0
    var modelCalls = 0
    var httpAttempts = 0
    var memoryOperations = 0
    var rawSourceBytes = 0
    var vectorBytes = 0
    var metadataRows = 0
    var encoderInputBytes = 0

    static let zero = EpisodeResources()
    static let developmentCaps = EpisodeResources(inputTokens: 1_000_000, outputTokens: 16_000,
        modelCalls: 12, httpAttempts: 64, memoryOperations: 24, rawSourceBytes: 256 * 1_048_576,
        vectorBytes: 64 * 1_048_576, metadataRows: 100_000, encoderInputBytes: 12 * 4096)

    subscript(_ resource: EpisodeResource) -> Int {
        get {
            switch resource {
            case .inputTokens: return inputTokens
            case .outputTokens: return outputTokens
            case .modelCalls: return modelCalls
            case .httpAttempts: return httpAttempts
            case .memoryOperations: return memoryOperations
            case .rawSourceBytes: return rawSourceBytes
            case .vectorBytes: return vectorBytes
            case .metadataRows: return metadataRows
            case .encoderInputBytes: return encoderInputBytes
            }
        }
        set {
            switch resource {
            case .inputTokens: inputTokens = newValue
            case .outputTokens: outputTokens = newValue
            case .modelCalls: modelCalls = newValue
            case .httpAttempts: httpAttempts = newValue
            case .memoryOperations: memoryOperations = newValue
            case .rawSourceBytes: rawSourceBytes = newValue
            case .vectorBytes: vectorBytes = newValue
            case .metadataRows: metadataRows = newValue
            case .encoderInputBytes: encoderInputBytes = newValue
            }
        }
    }

    func validated() throws -> EpisodeResources {
        guard EpisodeResource.allCases.allSatisfy({ self[$0] >= 0 }) else { throw EpisodeBudgetError.invalid }
        return self
    }
    func adding(_ other: EpisodeResources) throws -> EpisodeResources {
        _ = try validated(); _ = try other.validated()
        var result = self
        for resource in EpisodeResource.allCases {
            let (value, overflow) = self[resource].addingReportingOverflow(other[resource])
            guard !overflow else { throw EpisodeBudgetError.invalid }
            result[resource] = value
        }
        return result
    }
    func subtracting(_ other: EpisodeResources) throws -> EpisodeResources {
        _ = try validated(); _ = try other.validated()
        var result = self
        for resource in EpisodeResource.allCases {
            guard self[resource] >= other[resource] else { throw EpisodeBudgetError.invalid }
            result[resource] = self[resource] - other[resource]
        }
        return result
    }
    func fits(within cap: EpisodeResources) -> Bool {
        EpisodeResource.allCases.allSatisfy { self[$0] >= 0 && cap[$0] >= 0 && self[$0] <= cap[$0] }
    }
}

/// Frozen selected-model component limits. They are independent of the full
/// provider envelope and byte guards never estimate a token count.
struct ContextComponentPolicy: Codable, Equatable {
    var version = "selected-model-context-components-v1"
    var recentTokens = 8_000
    var evidenceTokens = 12_000
    var recentBytes = 180_000
    var recentCandidates = 256
    var evidenceSpans = 16
    var evidenceBytes = 131_072
    var maximumMessageBytes = 1_900_000
    var reductionVersion = "whole-source-geometric-v1"
    var rendererVersion = "qwen38-attributed-text-v1"

    static let selectedQwen = ContextComponentPolicy()
    /// Explicit experimental fixtures retain this separately versioned policy.
    /// Ordinary selected-model episodes use the measured v1 default below.
    static let selectedQwenNeighborhood: ContextComponentPolicy = {
        var value = ContextComponentPolicy()
        value.version = "selected-model-context-components-v2"
        value.evidenceSpans = 48
        value.reductionVersion = "primary-first-neighbor-geometric-v1"
        return value
    }()
    /// Explicit experimental P2 policies: the whole question ranks complete
    /// human-led exchange blocks (step 1); the adjacent variant also packs
    /// each block's opposite-role neighbors beside it (step 2). Neither is a
    /// default; ordinary Send keeps v1 until the offline gate justifies it.
    static let selectedQwenExchange: ContextComponentPolicy = {
        var value = ContextComponentPolicy()
        value.version = "selected-model-context-components-v3-exchange"
        value.evidenceSpans = 48
        value.reductionVersion = "whole-source-suffix-single-v1"
        return value
    }()
    static let selectedQwenExchangeAdjacent: ContextComponentPolicy = {
        var value = selectedQwenExchange
        value.version = "selected-model-context-components-v3-exchange-adjacent"
        return value
    }()
    static let exchangeSelectionAuditVersion = "context-exchange-v1"
    // The wider candidate frontier remains experimental pending answer-quality
    // evidence that justifies changing ordinary Send and public evaluation.
    static let currentSelectedQwen = selectedQwen

    var usesBoundedNeighborhood: Bool { self == Self.selectedQwenNeighborhood }
    var usesExchangeQuery: Bool { self == Self.selectedQwenExchange || self == Self.selectedQwenExchangeAdjacent }
    var packsAdjacentExchanges: Bool { self == Self.selectedQwenExchangeAdjacent }
    var selectionAuditVersion: String {
        usesBoundedNeighborhood ? "context-neighborhood-v2"
            : usesExchangeQuery ? Self.exchangeSelectionAuditVersion : "context-geometric-v1"
    }

    init() {}
    private enum CodingKeys: String, CodingKey {
        case version, recentTokens, evidenceTokens, recentBytes, recentCandidates, evidenceSpans,
             evidenceBytes, maximumMessageBytes, reductionVersion, rendererVersion
    }
    init(from decoder: Decoder) throws {
        try requireEpisodeKeys(decoder, ["version", "recentTokens", "evidenceTokens", "recentBytes",
            "recentCandidates", "evidenceSpans", "evidenceBytes", "maximumMessageBytes",
            "reductionVersion", "rendererVersion"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(String.self, forKey: .version)
        recentTokens = try values.decode(Int.self, forKey: .recentTokens)
        evidenceTokens = try values.decode(Int.self, forKey: .evidenceTokens)
        recentBytes = try values.decode(Int.self, forKey: .recentBytes)
        recentCandidates = try values.decode(Int.self, forKey: .recentCandidates)
        evidenceSpans = try values.decode(Int.self, forKey: .evidenceSpans)
        evidenceBytes = try values.decode(Int.self, forKey: .evidenceBytes)
        maximumMessageBytes = try values.decode(Int.self, forKey: .maximumMessageBytes)
        reductionVersion = try values.decode(String.self, forKey: .reductionVersion)
        rendererVersion = try values.decode(String.self, forKey: .rendererVersion)
        _ = try validated()
    }

    func validated() throws -> ContextComponentPolicy {
        guard self == Self.selectedQwen || self == Self.selectedQwenNeighborhood
            || self == Self.selectedQwenExchange || self == Self.selectedQwenExchangeAdjacent else { throw EpisodeBudgetError.invalid }
        return self
    }

    func canonicalData() throws -> Data {
        _ = try validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        episodeIdentifierEqual(lhs.version, rhs.version) && lhs.recentTokens == rhs.recentTokens
            && lhs.evidenceTokens == rhs.evidenceTokens && lhs.recentBytes == rhs.recentBytes
            && lhs.recentCandidates == rhs.recentCandidates && lhs.evidenceSpans == rhs.evidenceSpans
            && lhs.evidenceBytes == rhs.evidenceBytes && lhs.maximumMessageBytes == rhs.maximumMessageBytes
            && episodeIdentifierEqual(lhs.reductionVersion, rhs.reductionVersion)
            && episodeIdentifierEqual(lhs.rendererVersion, rhs.rendererVersion)
    }
}

struct EpisodeLimits: Codable, Equatable {
    var version = "development-episode-v1"
    var resources = EpisodeResources.developmentCaps
    var deadlineMilliseconds = 120_000
    // Development mode retains useful local semantic inference while reporting
    // its tokens unknown. Strict mode requires verified model input counts.
    var requireKnownModelInput = false
    // Historical and standalone-read journals retain nil. Only selected-model
    // answering explicitly freezes this policy and obtains a count proof.
    var componentPolicy: ContextComponentPolicy? = nil
    // Frozen independently from content resources; historical encodings omit it.
    var terminalCleanup: EpisodeCleanupLimits? = .defaults
}

struct EpisodeClockSnapshot: Codable, Equatable {
    let domain: String
    let continuousNanoseconds: UInt64
    let utc: Date
}
protocol EpisodeClockSource: AnyObject {
    func now() throws -> EpisodeClockSnapshot
}

enum EpisodeState: String, Codable {
    case active, completed, failed, cancelled, interrupted, deadlineExceeded, budgetExceeded
}
enum EpisodeWorkKind: String, Codable {
    case providerDiscovery, tokenizer, calibration, answer, retrieval, sourceRead, queryEmbedding, nativeInference, authorityValidation
}
enum EpisodeWorkState: String, Codable {
    case prepared, dispatchArmed, submitted, completed, failedConfirmed, outcomeUnknown, cancelledBeforeDispatch
}
enum EpisodeWorkOutcome: String, Codable {
    case completed, failedConfirmed, outcomeUnknown, cancelledBeforeDispatch
}

enum EpisodeLocalReadInitiator: String, Codable { case humanBrowser, localReadCLI, syntheticEvaluation }
enum EpisodeLocalReadPurpose: String, Codable { case searchInitialPage, sourcePage, contextSelection, retrievalProbe }

private struct EpisodeOriginKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
func requireEpisodeKeys(_ decoder: Decoder, _ expected: Set<String>) throws {
    let values = try decoder.container(keyedBy: EpisodeOriginKey.self)
    guard Set(values.allKeys.map(\.stringValue)) == expected else { throw EpisodeBudgetError.invalid }
}
private func validateEpisodeBindingIdentifier(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 256, !value.contains("\0") else { throw EpisodeBudgetError.invalid }
}

struct EpisodeLocalReadBinding: Codable, Equatable {
    let version: String
    let initiator: EpisodeLocalReadInitiator
    let purpose: EpisodeLocalReadPurpose
    let requestID: String
    let descriptorVersion: String
    let descriptorSHA256: String
    init(version: String = "local-read-v1", initiator: EpisodeLocalReadInitiator, purpose: EpisodeLocalReadPurpose,
         requestID: String, descriptorVersion: String, descriptorSHA256: String) {
        self.version = version; self.initiator = initiator; self.purpose = purpose
        self.requestID = requestID; self.descriptorVersion = descriptorVersion; self.descriptorSHA256 = descriptorSHA256
    }
    func validated() throws -> Self {
        guard version == "local-read-v1" else { throw EpisodeBudgetError.invalid }
        try validateEpisodeBindingIdentifier(requestID)
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".utf8)
        guard (1...128).contains(descriptorVersion.utf8.count), descriptorVersion.utf8.allSatisfy({ allowed.contains($0) }),
              descriptorSHA256.utf8.count == 64,
              descriptorSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw EpisodeBudgetError.invalid }
        return self
    }
    private enum CodingKeys: String, CodingKey { case version, initiator, purpose, requestID, descriptorVersion, descriptorSHA256 }
    init(from decoder: Decoder) throws {
        try requireEpisodeKeys(decoder, ["version", "initiator", "purpose", "requestID", "descriptorVersion", "descriptorSHA256"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(version: try values.decode(String.self, forKey: .version),
            initiator: try values.decode(EpisodeLocalReadInitiator.self, forKey: .initiator),
            purpose: try values.decode(EpisodeLocalReadPurpose.self, forKey: .purpose),
            requestID: try values.decode(String.self, forKey: .requestID),
            descriptorVersion: try values.decode(String.self, forKey: .descriptorVersion),
            descriptorSHA256: try values.decode(String.self, forKey: .descriptorSHA256))
        _ = try validated()
    }
}

enum EpisodeOrigin: Codable, Equatable {
    case chat(conversationID: String, turnID: String, humanEventID: String)
    case localRead(EpisodeLocalReadBinding)
    var isLocalRead: Bool { if case .localRead = self { return true }; return false }
    func validated() throws -> Self {
        switch self {
        case .chat(let conversationID, let turnID, let humanEventID):
            for value in [conversationID, turnID, humanEventID] { try validateEpisodeBindingIdentifier(value) }
        case .localRead(let binding): _ = try binding.validated()
        }
        return self
    }
    private enum CodingKeys: String, CodingKey { case version, kind, conversationID, turnID, humanEventID, binding }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .version) == "episode-origin-v1" else { throw EpisodeBudgetError.invalid }
        switch try values.decode(String.self, forKey: .kind) {
        case "chat":
            try requireEpisodeKeys(decoder, ["version", "kind", "conversationID", "turnID", "humanEventID"])
            self = .chat(conversationID: try values.decode(String.self, forKey: .conversationID),
                turnID: try values.decode(String.self, forKey: .turnID), humanEventID: try values.decode(String.self, forKey: .humanEventID))
        case "localRead":
            try requireEpisodeKeys(decoder, ["version", "kind", "binding"])
            self = .localRead(try values.decode(EpisodeLocalReadBinding.self, forKey: .binding))
        default: throw EpisodeBudgetError.invalid
        }
        _ = try validated()
    }
    func encode(to encoder: Encoder) throws {
        _ = try validated()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode("episode-origin-v1", forKey: .version)
        switch self {
        case .chat(let conversationID, let turnID, let humanEventID):
            try values.encode("chat", forKey: .kind)
            try values.encode(conversationID, forKey: .conversationID)
            try values.encode(turnID, forKey: .turnID)
            try values.encode(humanEventID, forKey: .humanEventID)
        case .localRead(let binding):
            try values.encode("localRead", forKey: .kind); try values.encode(binding, forKey: .binding)
        }
    }
}

struct EpisodeReceipt: Codable, Equatable {
    let id: String
    let conversationID: String?
    let projectID: String
    let turnID: String?
    let humanEventID: String?
    let origin: EpisodeOrigin
    let limits: EpisodeLimits
    let state: EpisodeState
    let revision: Int
    let clockDomain: String
    let deadlineNanoseconds: UInt64
    let createdAt: Date
    let charged: EpisodeResources
    let held: EpisodeResources
    let unknownInputOperations: Int

    init(id: String, conversationID: String?, projectID: String, turnID: String?, humanEventID: String?, origin: EpisodeOrigin,
        limits: EpisodeLimits, state: EpisodeState, revision: Int, clockDomain: String, deadlineNanoseconds: UInt64,
        createdAt: Date, charged: EpisodeResources, held: EpisodeResources, unknownInputOperations: Int) {
        self.id = id; self.conversationID = conversationID; self.projectID = projectID; self.turnID = turnID
        self.humanEventID = humanEventID; self.origin = origin; self.limits = limits; self.state = state
        self.revision = revision; self.clockDomain = clockDomain; self.deadlineNanoseconds = deadlineNanoseconds
        self.createdAt = createdAt; self.charged = charged; self.held = held; self.unknownInputOperations = unknownInputOperations
    }
    /// Existing trusted chat fixtures and adapters retain their constructor.
    init(id: String, conversationID: String, projectID: String, turnID: String, humanEventID: String,
        limits: EpisodeLimits, state: EpisodeState, revision: Int, clockDomain: String, deadlineNanoseconds: UInt64,
        createdAt: Date, charged: EpisodeResources, held: EpisodeResources, unknownInputOperations: Int) {
        self.init(id: id, conversationID: conversationID, projectID: projectID, turnID: turnID, humanEventID: humanEventID,
            origin: .chat(conversationID: conversationID, turnID: turnID, humanEventID: humanEventID), limits: limits, state: state,
            revision: revision, clockDomain: clockDomain, deadlineNanoseconds: deadlineNanoseconds,
            createdAt: createdAt, charged: charged, held: held, unknownInputOperations: unknownInputOperations)
    }
}

struct EpisodeWorkRequest: Codable, Equatable {
    let id: String
    let parentID: String?
    let kind: EpisodeWorkKind
    let resources: EpisodeResources
    let adapterIdentity: String
    let snapshot: Data?
    let inputTokensKnown: Bool
}
struct EpisodeWorkRecord: Codable, Equatable {
    let id: String
    let episodeID: String
    let request: EpisodeWorkRequest
    let revision: Int
    let state: EpisodeWorkState
    let charged: EpisodeResources
    let held: EpisodeResources
    let observed: EpisodeResources?
    let receiptID: String?
    let recovered: Bool
}
struct EpisodeWorkSettlement: Codable, Equatable {
    let receiptID: String
    let outcome: EpisodeWorkOutcome
    let observed: EpisodeResources?
    let evidence: Data?
    // Identity/body violations can occur even when token totals fit.
    var adapterViolation = false
}

/// Implemented by the exclusive MemoryStore owner. Consumers cannot start an
/// inference or network task until armEpisodeWork durably returns.
protocol EpisodeLedger: AnyObject {
    func beginLocalReadEpisode(episodeID: String, projectID: String, binding: EpisodeLocalReadBinding,
        limits: EpisodeLimits, clock: EpisodeClockSnapshot) throws -> EpisodeReceipt
    func acceptRequestAndBeginEpisode(conversationID: String, turnID: String, humanEventID: String,
        episodeID: String, text: String, limits: EpisodeLimits, clock: EpisodeClockSnapshot) throws -> EpisodeReceipt
    func reserveEpisodeWork(episodeID: String, request: EpisodeWorkRequest, clock: EpisodeClockSnapshot) throws -> EpisodeWorkRecord
    func armEpisodeWork(episodeID: String, operationID: String, expectedRevision: Int, clock: EpisodeClockSnapshot) throws -> EpisodeWorkRecord
    func performEpisodeHandoff(episodeID: String, operationID: String, expectedRevision: Int,
        clock: EpisodeClockSnapshot, start: () -> Void) throws -> EpisodeWorkRecord
    func settleEpisodeWork(episodeID: String, operationID: String, settlement: EpisodeWorkSettlement,
        clock: EpisodeClockSnapshot) throws -> EpisodeWorkRecord
    func finishEpisode(episodeID: String, reason: EpisodeState, clock: EpisodeClockSnapshot) throws -> EpisodeReceipt
    func episodeReceipt(id: String, clock: EpisodeClockSnapshot) throws -> EpisodeReceipt
}

// Ledgers used solely by provider adapter fixtures have no local-read capture
// authority. Production owners implement the durable constructor explicitly.
extension EpisodeLedger {
    func beginLocalReadEpisode(episodeID: String, projectID: String, binding: EpisodeLocalReadBinding,
        limits: EpisodeLimits, clock: EpisodeClockSnapshot) throws -> EpisodeReceipt { throw EpisodeBudgetError.invalid }
}

// Durable metadata equality preserves the exact UTF-8 identity stored by SQLite.
extension EpisodeLimits {
    static func == (lhs: Self, rhs: Self) -> Bool {
        episodeIdentifierEqual(lhs.version, rhs.version) && lhs.resources == rhs.resources
            && lhs.deadlineMilliseconds == rhs.deadlineMilliseconds && lhs.requireKnownModelInput == rhs.requireKnownModelInput
            && lhs.componentPolicy == rhs.componentPolicy
    }
}
extension EpisodeClockSnapshot {
    static func == (lhs: Self, rhs: Self) -> Bool {
        episodeIdentifierEqual(lhs.domain, rhs.domain) && lhs.continuousNanoseconds == rhs.continuousNanoseconds && lhs.utc == rhs.utc
    }
}
extension EpisodeLocalReadBinding {
    static func == (lhs: Self, rhs: Self) -> Bool {
        episodeIdentifierEqual(lhs.version, rhs.version) && lhs.initiator == rhs.initiator && lhs.purpose == rhs.purpose
            && episodeIdentifierEqual(lhs.requestID, rhs.requestID) && episodeIdentifierEqual(lhs.descriptorVersion, rhs.descriptorVersion)
            && episodeIdentifierEqual(lhs.descriptorSHA256, rhs.descriptorSHA256)
    }
}
extension EpisodeOrigin {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.chat(let lc, let lt, let lh), .chat(let rc, let rt, let rh)):
            return episodeIdentifierEqual(lc, rc) && episodeIdentifierEqual(lt, rt) && episodeIdentifierEqual(lh, rh)
        case (.localRead(let lhs), .localRead(let rhs)): return lhs == rhs
        default: return false
        }
    }
}
extension EpisodeReceipt {
    static func == (lhs: Self, rhs: Self) -> Bool {
        episodeIdentifierEqual(lhs.id, rhs.id) && episodeIdentifierEqual(lhs.conversationID, rhs.conversationID)
            && episodeIdentifierEqual(lhs.projectID, rhs.projectID) && episodeIdentifierEqual(lhs.turnID, rhs.turnID)
            && episodeIdentifierEqual(lhs.humanEventID, rhs.humanEventID) && lhs.origin == rhs.origin && lhs.limits == rhs.limits
            && lhs.state == rhs.state && lhs.revision == rhs.revision && episodeIdentifierEqual(lhs.clockDomain, rhs.clockDomain)
            && lhs.deadlineNanoseconds == rhs.deadlineNanoseconds && lhs.createdAt == rhs.createdAt && lhs.charged == rhs.charged
            && lhs.held == rhs.held && lhs.unknownInputOperations == rhs.unknownInputOperations
    }
}
extension EpisodeWorkRequest {
    static func == (lhs: Self, rhs: Self) -> Bool {
        episodeIdentifierEqual(lhs.id, rhs.id) && episodeIdentifierEqual(lhs.parentID, rhs.parentID) && lhs.kind == rhs.kind
            && lhs.resources == rhs.resources && episodeIdentifierEqual(lhs.adapterIdentity, rhs.adapterIdentity)
            && lhs.snapshot == rhs.snapshot && lhs.inputTokensKnown == rhs.inputTokensKnown
    }
}
extension EpisodeWorkRecord {
    static func == (lhs: Self, rhs: Self) -> Bool {
        episodeIdentifierEqual(lhs.id, rhs.id) && episodeIdentifierEqual(lhs.episodeID, rhs.episodeID) && lhs.request == rhs.request
            && lhs.revision == rhs.revision && lhs.state == rhs.state && lhs.charged == rhs.charged && lhs.held == rhs.held
            && lhs.observed == rhs.observed && episodeIdentifierEqual(lhs.receiptID, rhs.receiptID) && lhs.recovered == rhs.recovered
    }
}
extension EpisodeWorkSettlement {
    static func == (lhs: Self, rhs: Self) -> Bool {
        episodeIdentifierEqual(lhs.receiptID, rhs.receiptID) && lhs.outcome == rhs.outcome && lhs.observed == rhs.observed
            && lhs.evidence == rhs.evidence && lhs.adapterViolation == rhs.adapterViolation
    }
}
