import Foundation

enum EpisodeBudgetError: Error {
    case invalid, exhausted, deadlineExceeded, inactive, staleRevision, clockUnavailable, unobservableInput, adapterViolation, conflict
    var failureCode: String {
        switch self {
        case .exhausted: return "episode_budget_exceeded"
        case .deadlineExceeded: return "episode_deadline_exceeded"
        case .inactive, .staleRevision: return "episode_inactive"
        case .unobservableInput: return "episode_input_unobservable"
        case .adapterViolation: return "episode_adapter_violation"
        case .clockUnavailable: return "episode_clock_unavailable"
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

struct EpisodeLimits: Codable, Equatable {
    var version = "development-episode-v1"
    var resources = EpisodeResources.developmentCaps
    var deadlineMilliseconds = 120_000
    // Development mode retains useful local semantic inference while reporting
    // its tokens unknown. Strict mode requires verified model input counts.
    var requireKnownModelInput = false
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
    case providerDiscovery, tokenizer, calibration, answer, retrieval, sourceRead, queryEmbedding, nativeInference
}
enum EpisodeWorkState: String, Codable {
    case prepared, dispatchArmed, submitted, completed, failedConfirmed, outcomeUnknown, cancelledBeforeDispatch
}
enum EpisodeWorkOutcome: String, Codable {
    case completed, failedConfirmed, outcomeUnknown, cancelledBeforeDispatch
}

struct EpisodeReceipt: Codable, Equatable {
    let id: String
    let conversationID: String
    let projectID: String
    let turnID: String
    let humanEventID: String
    let limits: EpisodeLimits
    let state: EpisodeState
    let revision: Int
    let clockDomain: String
    let deadlineNanoseconds: UInt64
    let createdAt: Date
    let charged: EpisodeResources
    let held: EpisodeResources
    let unknownInputOperations: Int
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
