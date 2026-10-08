import CryptoKit
import CoreFoundation
import Foundation

enum ProviderAdmissionError: Error {
    case invalidRequest, unavailable, unverifiedAdapter, templateMismatch, countMismatch, contextOverflow, cancelled
    case episodeBudgetExceeded, episodeDeadlineExceeded, episodeInactive, episodeInputUnobservable
    case episodeAdapterViolation, episodeClockUnavailable, episodeAccountingFailed

    var failureCode: String {
        switch self {
        case .invalidRequest: return "invalid_endpoint"
        case .unavailable: return "provider_admission_unavailable"
        case .unverifiedAdapter: return "provider_adapter_unverified"
        case .templateMismatch: return "provider_template_mismatch"
        case .countMismatch: return "provider_count_mismatch"
        case .contextOverflow: return "context_full"
        case .cancelled: return "cancelled"
        case .episodeBudgetExceeded: return "episode_budget_exceeded"
        case .episodeDeadlineExceeded: return "episode_deadline_exceeded"
        case .episodeInactive: return "episode_inactive"
        case .episodeInputUnobservable: return "episode_input_unobservable"
        case .episodeAdapterViolation: return "episode_adapter_violation"
        case .episodeClockUnavailable: return "episode_clock_unavailable"
        case .episodeAccountingFailed: return "episode_accounting_failed"
        }
    }

    static func budget(_ error: Error) -> ProviderAdmissionError {
        guard let error = error as? EpisodeBudgetError else { return .episodeAccountingFailed }
        switch error {
        case .exhausted: return .episodeBudgetExceeded
        case .deadlineExceeded: return .episodeDeadlineExceeded
        case .inactive, .staleRevision: return .episodeInactive
        case .unobservableInput: return .episodeInputUnobservable
        case .adapterViolation: return .episodeAdapterViolation
        case .clockUnavailable: return .episodeClockUnavailable
        case .invalid, .conflict, .scopeMismatch: return .episodeAccountingFailed
        }
    }
}

struct ProviderUsage: Equatable, Codable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let cachedTokens: Int?
    let reasoningTokens: Int?

    static func parse(_ value: Any?) -> ProviderUsage? {
        guard let object = value as? [String: Any],
              let input = integer(object["prompt_tokens"]), let output = integer(object["completion_tokens"]),
              let total = integer(object["total_tokens"]), input <= Int.max - output, total == input + output else { return nil }
        let inputDetails = object["prompt_tokens_details"], outputDetails = object["completion_tokens_details"]
        guard inputDetails == nil || inputDetails is NSNull || inputDetails is [String: Any],
              outputDetails == nil || outputDetails is NSNull || outputDetails is [String: Any] else { return nil }
        let cachedRaw = (inputDetails as? [String: Any])?["cached_tokens"]
        let reasoningRaw = (outputDetails as? [String: Any])?["reasoning_tokens"]
        let cached = integer(cachedRaw), reasoning = integer(reasoningRaw)
        guard cachedRaw == nil || cachedRaw is NSNull || cached != nil,
              reasoningRaw == nil || reasoningRaw is NSNull || reasoning != nil,
              cached.map({ $0 <= input }) ?? true, reasoning.map({ $0 <= output }) ?? true else { return nil }
        return ProviderUsage(promptTokens: input, completionTokens: output, totalTokens: total,
                             cachedTokens: cached, reasoningTokens: reasoning)
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue < Double(Int.max), number.doubleValue.rounded(.down) == number.doubleValue else { return nil }
        return number.intValue
    }
}

/// A receipt describes the exact body subsequently handed to the provider. It contains no credential.
struct EndpointAdmissionReceipt: Codable {
    let bodyDigest: String
    let endpoint: String
    let modelID: String
    let promptTokens: Int
    let outputReserve: Int
    let safetyTokens: Int
    let effectiveContextLimit: Int
    let envelopeBytes: Int
    let templateDigest: String
    let serverVersion: String
    let loadedModelEpoch: Int
    let calibrationUsage: ProviderUsage?
    let admittedAt: Date
    var accounting: ProviderAdmissionAccounting? = nil
    var episodeID: String? = nil
    var calibrationWorkID: String? = nil
    var thinkingEnabled = false
    // Historical nil-policy receipts decode without this observation. New
    // observations use epoch zero only as an unused legacy storage slot.
    var modelIdentity: ProviderObservedModelIdentity? = nil
    var componentProof: ProviderComponentProof? = nil

    var reservedTokens: Int { promptTokens + outputReserve + safetyTokens }

    var answerAdapterIdentity: String {
        if let modelIdentity {
            return ProviderAdmission.adapterIdentity(endpoint: endpoint, modelIdentity: modelIdentity, thinking: thinkingEnabled)
        }
        return ProviderAdmission.adapterIdentity(endpoint: endpoint, modelEpoch: loadedModelEpoch, thinking: thinkingEnabled)
    }

    func accepts(body: Data, address: String, maximumAge: TimeInterval = 30) -> Bool {
        guard let url = LocalEndpoint.chatURL(address), Date().timeIntervalSince(admittedAt) >= 0,
              Date().timeIntervalSince(admittedAt) <= maximumAge,
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              object["enable_thinking"] as? Bool == thinkingEnabled else { return false }
        if let modelIdentity {
            guard (try? modelIdentity.validated()) != nil, loadedModelEpoch == 0,
                  modelIdentity.modelContextLimit >= effectiveContextLimit else { return false }
        }
        let proofMatches = componentProof.map { proof in
            proof.bodyDigest == bodyDigest && proof.endpoint == endpoint && proof.modelEpoch == loadedModelEpoch
                && modelIdentity == proof.modelIdentity
                && episodeIdentifierEqual(proof.episodeID, episodeID) && proof.thinkingEnabled == thinkingEnabled
                && proof.wholePrompt.tokens == promptTokens && proof.outputReserve == outputReserve
                && proof.safetyTokens == safetyTokens && proof.effectiveContextLimit == effectiveContextLimit
        } ?? true
        return proofMatches && endpoint == url.absoluteString && bodyDigest == EndpointRequest.digest(body)
            && envelopeBytes == body.count && modelID == Qwen38TextAdapter.modelID
            && templateDigest == Qwen38TextAdapter.templateDigest && serverVersion == Qwen38TextAdapter.serverVersion
            && ProviderAdmission.fits(promptTokens: promptTokens, outputReserve: outputReserve,
                                      safetyTokens: safetyTokens, contextLimit: effectiveContextLimit)
    }

    /// Stable metadata for the durable invocation journal; the exact request body is stored separately.
    var metadata: [String: Any] {
        var value: [String: Any] = ["adapter": "mlx-serve-qwen38-text-v1", "model": modelID,
            "prompt_tokens": promptTokens, "output_reserve": outputReserve, "safety_tokens": safetyTokens,
            "context_limit": effectiveContextLimit, "envelope_bytes": envelopeBytes, "body_sha256": bodyDigest,
            "template_sha256": templateDigest, "server_version": serverVersion, "loaded_model_epoch": loadedModelEpoch]
        if let usage = calibrationUsage {
            value["calibration_prompt_tokens"] = usage.promptTokens
            value["calibration_completion_tokens"] = usage.completionTokens
        }
        if let episodeID { value["episode_id"] = episodeID }
        if let calibrationWorkID { value["calibration_work_id"] = calibrationWorkID }
        if let modelIdentity, let data = try? modelIdentity.canonicalData(),
           let object = try? JSONSerialization.jsonObject(with: data) {
            value["model_identity"] = object
        }
        if let componentProof, let data = try? JSONEncoder().encode(componentProof),
           let object = try? JSONSerialization.jsonObject(with: data) {
            value["context_components"] = object
        }
        return value
    }
}

/// Includes work incurred by an admission that fails or whose optional evidence is later rebuilt.
struct ProviderAdmissionAccounting: Codable {
    let httpRequestCount: Int
    let tokenizerRequestCount: Int
    let calibrationRequestCount: Int
    let calibrationPromptTokens: Int?
    let calibrationOutputReserve: Int
    let calibrationUsage: ProviderUsage?
    let unknownCalibrationOutcome: Bool
    let elapsed: Double
}

enum ProviderComponentCountKind: String, Codable, Equatable, Sendable { case recent, evidence, wholePrompt }

struct ProviderComponentCountReceipt: Codable, Equatable {
    let kind: ProviderComponentCountKind
    let renderedDigest: String
    let tokens: Int
    let tokenizerWorkID: String?
    let episodeID: String
    let projectID: String
    let adapterIdentity: String
    let rendererVersion: String
    let verifiedAt: Date
    let clockDomain: String
    let verifiedNanoseconds: UInt64
    let sessionID: String

    func isFresh(maximumAge: TimeInterval, clock: EpisodeClockSnapshot) -> Bool {
        Self.bindingIsFresh(maximumAge: maximumAge, clock: clock, clockDomain: clockDomain, verifiedNanoseconds: verifiedNanoseconds)
    }
    static func bindingIsFresh(maximumAge: TimeInterval, clock: EpisodeClockSnapshot, clockDomain: String, verifiedNanoseconds: UInt64) -> Bool {
        guard maximumAge.isFinite, maximumAge >= 0, episodeIdentifierEqual(clock.domain, clockDomain),
              clock.continuousNanoseconds >= verifiedNanoseconds else { return false }
        return Double(clock.continuousNanoseconds - verifiedNanoseconds) / 1_000_000_000 <= maximumAge
    }
}

/// Count proofs are immutable host evidence. Source and policy digests are
/// supplied independently at handoff, so rebuilding a candidate invalidates it.
struct ProviderComponentProof: Codable {
    static let rendererVersion = "qwen38-attributed-text-v1"
    static let recentTokenLimit = 8000
    static let evidenceTokenLimit = 12000
    let bodyDigest: String
    let assignmentDigest: String
    let sourceSnapshotDigest: String
    let policyDigest: String
    let endpoint: String
    let episodeID: String
    let projectID: String
    let adapterIdentity: String
    let modelEpoch: Int
    let modelIdentity: ProviderObservedModelIdentity
    let thinkingEnabled: Bool
    let outputReserve: Int
    let safetyTokens: Int
    let effectiveContextLimit: Int
    let policyVersion: String
    let recentCap: Int
    let evidenceCap: Int
    let renderingVersion: String
    let reductionVersion: String
    let recent: ProviderComponentCountReceipt
    let evidence: ProviderComponentCountReceipt
    let wholePrompt: ProviderComponentCountReceipt

    static func assignmentsDigest(_ assignments: [ProviderMessageComponent]) -> String {
        EndpointRequest.digest(Data(assignments.map(\.rawValue).joined(separator: "\0").utf8))
    }

    /// Safe inside the serialized handoff: no ledger calls or source reads.
    func isFresh(maximumAge: TimeInterval = 30, clock: EpisodeClockSnapshot? = nil) -> Bool {
        guard let clock = clock ?? (try? SystemEpisodeClock().now()) else { return false }
        return [recent, evidence, wholePrompt].allSatisfy { receipt in
            receipt.isFresh(maximumAge: maximumAge, clock: clock)
                && episodeIdentifierEqual(receipt.clockDomain, wholePrompt.clockDomain)
                && receipt.verifiedNanoseconds == wholePrompt.verifiedNanoseconds
        }
    }

    func accepts(body: Data, assignments: [ProviderMessageComponent], sourceSnapshotDigest: String,
                 policyDigest: String, episodeLease: EpisodeLease, address: String,
                 maximumAge: TimeInterval = 30) -> Bool {
        guard let state = try? episodeLease.checkActive(projectID: projectID), case .chat = state.origin,
              episodeIdentifierEqual(episodeLease.episodeID, episodeID),
              LocalEndpoint.chatURL(address)?.absoluteString == endpoint,
              self.sourceSnapshotDigest == sourceSnapshotDigest, self.policyDigest == policyDigest,
              let frozenPolicy = state.limits.componentPolicy, let frozenPolicyData = try? frozenPolicy.canonicalData(),
              EndpointRequest.digest(frozenPolicyData) == policyDigest,
              policyVersion == frozenPolicy.version, recentCap == frozenPolicy.recentTokens,
              evidenceCap == frozenPolicy.evidenceTokens, renderingVersion == frozenPolicy.rendererVersion,
              reductionVersion == frozenPolicy.reductionVersion,
              bodyDigest == EndpointRequest.digest(body), assignmentDigest == Self.assignmentsDigest(assignments),
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              object["response_format"] == nil || modelIdentity.capabilities.contains("json_schema"),
              object["enable_thinking"] as? Bool == thinkingEnabled,
              ProviderUsage.integer(object["max_tokens"]) == outputReserve,
              let rendered = try? Qwen38TextAdapter.renderAttributed(object, assignments: assignments),
              modelEpoch == 0, (try? modelIdentity.validated()) != nil,
              effectiveContextLimit <= modelIdentity.modelContextLimit,
              adapterIdentity == ProviderAdmission.adapterIdentity(endpoint: endpoint, modelIdentity: modelIdentity, thinking: thinkingEnabled),
              recent.kind == .recent, evidence.kind == .evidence, wholePrompt.kind == .wholePrompt,
              recent.tokens <= Self.recentTokenLimit, evidence.tokens <= Self.evidenceTokenLimit,
              recent.renderedDigest == EndpointRequest.digest(Data(rendered.recent.utf8)),
              evidence.renderedDigest == EndpointRequest.digest(Data(rendered.evidence.utf8)),
              wholePrompt.renderedDigest == EndpointRequest.digest(Data(rendered.complete.utf8)),
              ProviderAdmission.fits(promptTokens: wholePrompt.tokens, outputReserve: outputReserve,
                  safetyTokens: safetyTokens, contextLimit: effectiveContextLimit) else { return false }
        guard let clock = try? episodeLease.clockSnapshot(), isFresh(maximumAge: maximumAge, clock: clock) else { return false }
        let receipts = [recent, evidence, wholePrompt]
        return receipts.allSatisfy { receipt in
            return receipt.tokens >= 0
                && receipt.rendererVersion == Self.rendererVersion
                && episodeIdentifierEqual(receipt.episodeID, episodeID)
                && episodeIdentifierEqual(receipt.projectID, projectID)
                && receipt.adapterIdentity == adapterIdentity && receipt.sessionID == wholePrompt.sessionID
                && ((receipt.tokens == 0 && receipt.tokenizerWorkID == nil) || (receipt.tokens > 0 && receipt.tokenizerWorkID != nil))
        }
    }
}

/// One cancellable transport/verification binding for the complete preparation.
/// All requests retain the original lease; closing the session never renews it.
final class ProviderComponentSession {
    private let operation: ProviderAdmissionOperation
    var accounting: ProviderAdmissionAccounting { operation.accounting }

    fileprivate init(operation: ProviderAdmissionOperation) { self.operation = operation }
    func cancel() { operation.cancel() }
    func close() { operation.closeComponentSession() }
    func countComponent(requestBody: Data, assignments: [ProviderMessageComponent], component: ProviderMessageComponent,
                        completion: @escaping (Result<ProviderComponentCountReceipt, ProviderAdmissionError>) -> Void) {
        operation.countComponent(requestBody: requestBody, assignments: assignments, component: component, completion: completion)
    }
    func admit(requestBody: Data, assignments: [ProviderMessageComponent], sourceSnapshotDigest: String, policyDigest: String,
               recentReceipt: ProviderComponentCountReceipt, evidenceReceipt: ProviderComponentCountReceipt,
               completion: @escaping (Result<EndpointAdmissionReceipt, ProviderAdmissionError>) -> Void) {
        operation.admitComponents(requestBody: requestBody, assignments: assignments, sourceSnapshotDigest: sourceSnapshotDigest,
            policyDigest: policyDigest, recentReceipt: recentReceipt, evidenceReceipt: evidenceReceipt, completion: completion)
    }
}

enum EndpointRequest {
    static let maximumEnvelopeBytes = 2 * 1_048_576

    static func build(prompt: String, settings: GenerationSettings, conversation: Conversation) throws -> Data {
        guard LocalEndpoint.chatURL(settings.endpointURL) != nil,
              !settings.endpointModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              settings.maximumOutput > 0, settings.maximumOutput <= Int(Int32.max),
              settings.temperature.isFinite, (0...2).contains(settings.temperature),
              !settings.endpointAPIKey.contains("\r"), !settings.endpointAPIKey.contains("\n") else {
            throw ProviderAdmissionError.invalidRequest
        }
        let messages = settings.messages(prompt, conversation: conversation)
        guard !messages.isEmpty, messages.allSatisfy({ message in
            Set(message.keys) == Set(["role", "content"])
                && ["system", "user", "assistant"].contains(message["role"] ?? "")
        }), !messages.dropFirst().contains(where: { $0["role"] == "system" }) else {
            throw ProviderAdmissionError.invalidRequest
        }
        var body: [String: Any] = ["model": settings.endpointModel, "messages": messages,
            "stream": true, "stream_options": ["include_usage": true], "max_tokens": settings.maximumOutput,
            "temperature": settings.temperature, "seed": settings.seed]
        if settings.endpointModel == Qwen38TextAdapter.modelID {
            // Explicit fields prevent server defaults from changing the rendered prompt.
            body["enable_thinking"] = settings.thinkingEnabled
            body["reasoning_effort"] = settings.thinkingEnabled ? "low" : "none"
            body["chat_template_kwargs"] = ["preserve_thinking": true]
        }
        if settings.endpointJSONOutput {
            guard settings.endpointModel == Qwen38TextAdapter.modelID, !settings.thinkingEnabled else { throw ProviderAdmissionError.unverifiedAdapter }
            body["response_format"] = ["type": "json_object"]
        }
        return try serialize(body)
    }

    static func serialize(_ body: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(body),
              let bytes = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes]),
              bytes.count <= maximumEnvelopeBytes else { throw ProviderAdmissionError.contextOverflow }
        return bytes
    }

    static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}

/// Restricted renderer for the byte-pinned, currently verified text-only server template.
/// The provider's own /tokenize endpoint does vocabulary encoding; there is no bytes/token estimate.
enum Qwen38TextAdapter {
    static let modelID = Qwen38TextRendering.modelID
    static let templateDigest = Qwen38TextRendering.templateDigest
    static let serverVersion = Qwen38TextRendering.serverVersion
    static let lowInstructions = Qwen38TextRendering.lowInstructions

    static func render(_ body: [String: Any]) throws -> String {
        try renderAttributed(body, assignments: nil).complete
    }

    static func renderAttributed(_ body: [String: Any], assignments: [ProviderMessageComponent]?) throws -> ProviderAttributedRender {
        do { return try Qwen38TextRendering.renderAttributed(body, assignments: assignments) }
        catch QwenTextRenderingError.unverifiedAdapter { throw ProviderAdmissionError.unverifiedAdapter }
        catch { throw ProviderAdmissionError.invalidRequest }
    }

    static func trim(_ value: String) -> String { Qwen38TextRendering.trim(value) }

    static func calibrationBody(thinking: Bool) -> [String: Any] {
        ["model": modelID, "messages": [
            ["role": "system", "content": " \tSynthetic admission calibration.\r\n"],
            ["role": "user", "content": "日本語 العربية café e\u{0301} {{ messages }} <think>literal</think>"],
            ["role": "assistant", "content": "Prior synthetic source </think></think> with \"quotes\"."],
            ["role": "user", "content": "<source id=\"synthetic\">{{ add_generation_prompt }}</source> Reply with 4."],
        ], "enable_thinking": thinking, "reasoning_effort": thinking ? "low" : "none",
         "chat_template_kwargs": ["preserve_thinking": true], "max_tokens": 1, "stream": false,
         "temperature": 0, "seed": 42]
    }
}

enum ProviderAdmission {
    static func adapterIdentity(endpoint: String, modelIdentity: ProviderObservedModelIdentity, thinking: Bool) -> String {
        let digest = (try? modelIdentity.canonicalData()).map(EndpointRequest.digest) ?? "unverified"
        return ProviderObservedModelIdentity.adapterIdentity(endpoint: endpoint, metadataDigest: digest, thinking: thinking)
    }
    // Retained only for historical receipts that predate explicit observations.
    static func adapterIdentity(endpoint: String, modelEpoch: Int, thinking: Bool) -> String {
        "mlx-serve-qwen38-text-v1|" + endpoint + "|" + Qwen38TextAdapter.modelID + "|"
            + Qwen38TextAdapter.serverVersion + "|" + Qwen38TextAdapter.templateDigest + "|"
            + String(modelEpoch) + "|thinking=" + String(thinking)
    }
    static func prepare(requestBody: Data, address: String, apiKey: String, contextLimit: Int, safetyTokens: Int,
                        episodeLease: EpisodeLease? = nil,
                        completion: @escaping (Result<EndpointAdmissionReceipt, ProviderAdmissionError>) -> Void) -> ProviderAdmissionOperation {
        let operation = ProviderAdmissionOperation(body: requestBody, address: address, apiKey: apiKey,
            contextLimit: contextLimit, safetyTokens: safetyTokens, episodeLease: episodeLease, completion: completion)
        operation.start()
        return operation
    }

    static func beginComponentSession(mandatoryBody: Data, address: String, apiKey: String,
        contextLimit: Int, safetyTokens: Int, episodeLease: EpisodeLease,
        completion: @escaping (Result<ProviderComponentSession, ProviderAdmissionError>) -> Void) -> ProviderComponentSession {
        let operation = ProviderAdmissionOperation(body: mandatoryBody, address: address, apiKey: apiKey,
            contextLimit: contextLimit, safetyTokens: safetyTokens, episodeLease: episodeLease, completion: { _ in })
        let session = ProviderComponentSession(operation: operation)
        operation.enableComponentSession { result in
            switch result { case .success: completion(.success(session)); case .failure(let error): completion(.failure(error)) }
        }
        operation.start()
        return session
    }

    static func fits(promptTokens: Int, outputReserve: Int, safetyTokens: Int, contextLimit: Int) -> Bool {
        guard promptTokens >= 0, outputReserve > 0, safetyTokens >= 0, contextLimit > 0,
              outputReserve <= contextLimit, safetyTokens <= contextLimit - outputReserve else { return false }
        return promptTokens <= contextLimit - outputReserve - safetyTokens
    }
}

final class ProviderAdmissionOperation: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private let queue = DispatchQueue(label: "dev.boros.provider.admission")
    private let body: Data
    private let address: String
    private let apiKey: String
    private let requestedLimit: Int
    private let safety: Int
    private let episodeLease: EpisodeLease?
    private var completion: ((Result<EndpointAdmissionReceipt, ProviderAdmissionError>) -> Void)?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response = Data()
    private var receivedBytes = 0
    private var responseLimitExceeded = false
    private var responseCallback: (([String: Any]) -> Void)?
    private var ended = false
    private var modelEpoch = 0
    private var observedModelIdentity: ProviderObservedModelIdentity?
    private var contextLimit = 0
    private var modelCap = 0
    private var payload: [String: Any] = [:]
    private var chatURL: URL?
    private var calibrationUsage: ProviderUsage?
    private var started = Date()
    private var finishedAt: Date?
    private var httpRequestCount = 0
    private var tokenizerRequestCount = 0
    private var calibrationRequestCount = 0
    private var calibrationPromptTokens: Int?
    private var unknownCalibrationOutcome = false
    private var activeWork: EpisodeWorkRecord?
    private var activeInference = false
    private var activeDispatched = false
    private var lateWork: EpisodeWorkRecord?
    private var lateViolationRecorded = false
    private var calibrationWorkID: String?
    private var deadlineTimer: DispatchSourceTimer?
    private var componentSessionEnabled = false
    private var componentReady = false
    private var componentBusy = false
    private let componentSessionID = UUID().uuidString
    private var componentVerifiedAt: Date?
    private var componentVerifiedClock: EpisodeClockSnapshot?
    private var componentProjectID: String?
    private var componentPolicyDigest: String?
    private var componentPolicy: ContextComponentPolicy?
    private var componentCountCompletion: ((Result<ProviderComponentCountReceipt, ProviderAdmissionError>) -> Void)?
    private var componentAdmissionCompletion: ((Result<EndpointAdmissionReceipt, ProviderAdmissionError>) -> Void)?
    private var issuedComponentReceipts: [ProviderComponentCountReceipt] = []
    private var lastTokenizerWorkID: String?
    private var terminalError: ProviderAdmissionError?

    private var currentAdapterIdentity: String {
        let endpoint = chatURL?.absoluteString ?? "unresolved"
        if let observedModelIdentity {
            return ProviderAdmission.adapterIdentity(endpoint: endpoint, modelIdentity: observedModelIdentity,
                thinking: payload["enable_thinking"] as? Bool ?? false)
        }
        return "mlx-serve-qwen38-discovery-v1|" + endpoint
    }

    var accounting: ProviderAdmissionAccounting { queue.sync { accountingSnapshot() } }

    private func accountingSnapshot() -> ProviderAdmissionAccounting {
        ProviderAdmissionAccounting(httpRequestCount: httpRequestCount, tokenizerRequestCount: tokenizerRequestCount,
            calibrationRequestCount: calibrationRequestCount, calibrationPromptTokens: calibrationPromptTokens,
            calibrationOutputReserve: calibrationRequestCount > 0 || unknownCalibrationOutcome ? 1 : 0, calibrationUsage: calibrationUsage,
            unknownCalibrationOutcome: unknownCalibrationOutcome, elapsed: max(0, (finishedAt ?? Date()).timeIntervalSince(started)))
    }

    init(body: Data, address: String, apiKey: String, contextLimit: Int, safetyTokens: Int,
         episodeLease: EpisodeLease? = nil,
         completion: @escaping (Result<EndpointAdmissionReceipt, ProviderAdmissionError>) -> Void) {
        self.body = body; self.address = address; self.apiKey = apiKey
        requestedLimit = contextLimit; safety = safetyTokens; self.episodeLease = episodeLease; self.completion = completion
    }

    fileprivate func enableComponentSession(_ completion: @escaping (Result<EndpointAdmissionReceipt, ProviderAdmissionError>) -> Void) {
        componentSessionEnabled = true; self.completion = completion
    }

    fileprivate func closeComponentSession() {
        queue.async {
            guard !self.ended else { return }
            if self.componentBusy || !self.componentReady { self.finish(.failure(.cancelled)); return }
            self.ended = true; self.finishedAt = Date(); self.terminalError = .cancelled
            self.deadlineTimer?.cancel(); self.deadlineTimer = nil
            self.session?.invalidateAndCancel(); self.session = nil
        }
    }

    private func validateComponentBinding(_ requestBody: Data, assignments: [ProviderMessageComponent]) throws -> ([String: Any], ProviderAttributedRender) {
        guard componentReady, !ended, componentVerifiedAt != nil,
              let verifiedClock = componentVerifiedClock,
              let lease = episodeLease, let project = componentProjectID,
              case .chat = try lease.checkActive(projectID: project).origin,
              let object = (try? JSONSerialization.jsonObject(with: requestBody)) as? [String: Any],
              let messages = object["messages"] as? [[String: String]],
              let mandatory = payload["messages"] as? [[String: String]],
              assignments.count == messages.count, requestBody.count <= EndpointRequest.maximumEnvelopeBytes,
              messages.count >= 2, assignments.first == .mandatory, assignments.last == .mandatory,
              messages.first?["role"] == "system", messages.last?["role"] == "user" else { throw ProviderAdmissionError.unverifiedAdapter }
        let currentClock = try lease.clockSnapshot()
        guard ProviderComponentCountReceipt.bindingIsFresh(maximumAge: 30, clock: currentClock,
            clockDomain: verifiedClock.domain, verifiedNanoseconds: verifiedClock.continuousNanoseconds) else { throw ProviderAdmissionError.unverifiedAdapter }
        let optional = Array(assignments.dropFirst().dropLast())
        guard optional.allSatisfy({ $0 != .mandatory }), optional.filter({ $0 == .evidence }).count <= 1,
              !optional.contains(.evidence) || optional.last == .evidence,
              zip(messages, assignments).allSatisfy({ message, component in component != .evidence || message["role"] == "user" }) else {
            throw ProviderAdmissionError.invalidRequest
        }
        let selectedMandatory = zip(messages, assignments).filter { $0.1 == .mandatory }.map { $0.0 }
        let encoderOptions: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        guard try JSONSerialization.data(withJSONObject: selectedMandatory, options: encoderOptions)
                == JSONSerialization.data(withJSONObject: mandatory, options: encoderOptions) else { throw ProviderAdmissionError.invalidRequest }
        var immutable = object, original = payload
        immutable.removeValue(forKey: "messages"); original.removeValue(forKey: "messages")
        guard try JSONSerialization.data(withJSONObject: immutable, options: encoderOptions)
                == JSONSerialization.data(withJSONObject: original, options: encoderOptions) else { throw ProviderAdmissionError.unverifiedAdapter }
        return (object, try Qwen38TextAdapter.renderAttributed(object, assignments: assignments))
    }

    private func countReceipt(kind: ProviderComponentCountKind, text: String, tokens: Int, workID: String?) -> ProviderComponentCountReceipt {
        ProviderComponentCountReceipt(kind: kind, renderedDigest: EndpointRequest.digest(Data(text.utf8)), tokens: tokens,
            tokenizerWorkID: workID, episodeID: episodeLease!.episodeID, projectID: componentProjectID!,
            adapterIdentity: currentAdapterIdentity, rendererVersion: ProviderComponentProof.rendererVersion,
            verifiedAt: componentVerifiedAt!, clockDomain: componentVerifiedClock!.domain,
            verifiedNanoseconds: componentVerifiedClock!.continuousNanoseconds, sessionID: componentSessionID)
    }

    fileprivate func countComponent(requestBody: Data, assignments: [ProviderMessageComponent], component: ProviderMessageComponent,
        completion: @escaping (Result<ProviderComponentCountReceipt, ProviderAdmissionError>) -> Void) {
        queue.async {
            guard !self.ended else { let error = self.terminalError ?? .cancelled; DispatchQueue.main.async { completion(.failure(error)) }; return }
            guard !self.componentBusy else { DispatchQueue.main.async { completion(.failure(.invalidRequest)) }; return }
            self.componentBusy = true; self.componentCountCompletion = completion
            do {
                guard component != .mandatory else { throw ProviderAdmissionError.invalidRequest }
                let (_, rendered) = try self.validateComponentBinding(requestBody, assignments: assignments)
                let text = component == .recent ? rendered.recent : rendered.evidence
                let kind: ProviderComponentCountKind = component == .recent ? .recent : .evidence
                if text.isEmpty {
                    self.publishComponentCount(self.countReceipt(kind: kind, text: text, tokens: 0, workID: nil)); return
                }
                self.count(text) { tokens in
                    self.publishComponentCount(self.countReceipt(kind: kind, text: text, tokens: tokens, workID: self.lastTokenizerWorkID))
                }
            } catch let error as ProviderAdmissionError { self.finish(.failure(error)) }
            catch { self.finish(.failure(.budget(error))) }
        }
    }

    private func publishComponentCount(_ receipt: ProviderComponentCountReceipt) {
        issuedComponentReceipts.append(receipt)
        let callback = componentCountCompletion; componentCountCompletion = nil; componentBusy = false
        guard let callback else { return }
        DispatchQueue.main.async {
            if let error = self.queue.sync(execute: { self.terminalError }) { callback(.failure(error)); return }
            do {
                _ = try self.episodeLease?.checkActive(projectID: receipt.projectID)
                guard let clock = try self.episodeLease?.clockSnapshot(), receipt.isFresh(maximumAge: 30, clock: clock) else {
                    callback(.failure(.unverifiedAdapter)); return
                }
                callback(.success(receipt))
            }
            catch { callback(.failure(.budget(error))) }
        }
    }

    fileprivate func admitComponents(requestBody: Data, assignments: [ProviderMessageComponent], sourceSnapshotDigest: String,
        policyDigest: String, recentReceipt: ProviderComponentCountReceipt, evidenceReceipt: ProviderComponentCountReceipt,
        completion: @escaping (Result<EndpointAdmissionReceipt, ProviderAdmissionError>) -> Void) {
        queue.async {
            guard !self.ended else { let error = self.terminalError ?? .cancelled; DispatchQueue.main.async { completion(.failure(error)) }; return }
            guard !self.componentBusy else { DispatchQueue.main.async { completion(.failure(.invalidRequest)) }; return }
            self.componentBusy = true; self.componentAdmissionCompletion = completion
            do {
                let (object, rendered) = try self.validateComponentBinding(requestBody, assignments: assignments)
                guard Self.validDigest(sourceSnapshotDigest), Self.validDigest(policyDigest),
                      self.componentPolicyDigest == policyDigest,
                      self.issuedComponentReceipts.contains(recentReceipt), self.issuedComponentReceipts.contains(evidenceReceipt),
                      recentReceipt.kind == .recent, evidenceReceipt.kind == .evidence,
                      recentReceipt.renderedDigest == EndpointRequest.digest(Data(rendered.recent.utf8)),
                      evidenceReceipt.renderedDigest == EndpointRequest.digest(Data(rendered.evidence.utf8)),
                      let output = ProviderUsage.integer(object["max_tokens"]),
                      let policy = self.componentPolicy else { throw ProviderAdmissionError.invalidRequest }
                guard
                      recentReceipt.tokens <= ProviderComponentProof.recentTokenLimit,
                      evidenceReceipt.tokens <= ProviderComponentProof.evidenceTokenLimit else { throw ProviderAdmissionError.contextOverflow }
                self.verifyComponentIdentity {
                    self.count(rendered.complete) { tokens in
                        guard ProviderAdmission.fits(promptTokens: tokens, outputReserve: output, safetyTokens: self.safety,
                            contextLimit: self.contextLimit) else { self.publishComponentAdmission(.failure(.contextOverflow)); return }
                        let whole = self.countReceipt(kind: .wholePrompt, text: rendered.complete, tokens: tokens, workID: self.lastTokenizerWorkID)
                        let proof = ProviderComponentProof(bodyDigest: EndpointRequest.digest(requestBody), assignmentDigest: ProviderComponentProof.assignmentsDigest(assignments),
                            sourceSnapshotDigest: sourceSnapshotDigest, policyDigest: policyDigest, endpoint: self.chatURL!.absoluteString,
                            episodeID: self.episodeLease!.episodeID, projectID: self.componentProjectID!, adapterIdentity: whole.adapterIdentity,
                            modelEpoch: self.modelEpoch, modelIdentity: self.observedModelIdentity!, thinkingEnabled: self.payload["enable_thinking"] as? Bool ?? false,
                            outputReserve: output, safetyTokens: self.safety, effectiveContextLimit: self.contextLimit,
                            policyVersion: policy.version, recentCap: policy.recentTokens,
                            evidenceCap: policy.evidenceTokens, renderingVersion: policy.rendererVersion,
                            reductionVersion: policy.reductionVersion,
                            recent: recentReceipt, evidence: evidenceReceipt, wholePrompt: whole)
                        guard proof.accepts(body: requestBody, assignments: assignments, sourceSnapshotDigest: sourceSnapshotDigest,
                            policyDigest: policyDigest, episodeLease: self.episodeLease!, address: self.address) else {
                            self.finish(.failure(.unverifiedAdapter)); return
                        }
                        var receipt = EndpointAdmissionReceipt(bodyDigest: EndpointRequest.digest(requestBody), endpoint: self.chatURL!.absoluteString,
                            modelID: Qwen38TextAdapter.modelID, promptTokens: tokens, outputReserve: output, safetyTokens: self.safety,
                            effectiveContextLimit: self.contextLimit, envelopeBytes: requestBody.count, templateDigest: Qwen38TextAdapter.templateDigest,
                            serverVersion: Qwen38TextAdapter.serverVersion, loadedModelEpoch: self.modelEpoch, calibrationUsage: self.calibrationUsage,
                            admittedAt: Date(), accounting: self.accountingSnapshot(), episodeID: self.episodeLease?.episodeID,
                            calibrationWorkID: self.calibrationWorkID, thinkingEnabled: self.payload["enable_thinking"] as? Bool ?? false,
                            modelIdentity: self.observedModelIdentity)
                        receipt.componentProof = proof
                        self.publishComponentAdmission(.success(receipt))
                    }
                }
            } catch let error as ProviderAdmissionError { self.publishComponentAdmission(.failure(error)) }
            catch { self.finish(.failure(.budget(error))) }
        }
    }

    private static func validDigest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }

    private func publishComponentAdmission(_ result: Result<EndpointAdmissionReceipt, ProviderAdmissionError>) {
        let callback = componentAdmissionCompletion; componentAdmissionCompletion = nil; componentBusy = false
        guard let callback else { return }
        DispatchQueue.main.async {
            if let error = self.queue.sync(execute: { self.terminalError }) { callback(.failure(error)); return }
            do {
                _ = try self.episodeLease?.checkActive(projectID: self.componentProjectID!)
                if case .success(let receipt) = result {
                    guard let clock = try self.episodeLease?.clockSnapshot(), receipt.componentProof?.isFresh(clock: clock) == true else {
                        callback(.failure(.unverifiedAdapter)); return
                    }
                }
                callback(result)
            }
            catch { callback(.failure(.budget(error))) }
        }
    }

    private func verifyComponentIdentity(completion: @escaping () -> Void) {
        request(path: "/v1/models") { object in
            guard let models = object["data"] as? [[String: Any]],
                  let model = models.first(where: { $0["id"] as? String == Qwen38TextAdapter.modelID }),
                  let identity = try? ProviderObservedModelIdentity.observe(model: model),
                  identity == self.observedModelIdentity else { self.finish(.failure(.unverifiedAdapter)); return }
            self.request(path: "/props", modelQuery: true) { object in
                guard let settings = object["settings"] as? [String: Any], settings["version"] as? String == Qwen38TextAdapter.serverVersion,
                      settings["engine"] as? String == "mlx", let defaults = object["default_generation_settings"] as? [String: Any],
                      let cap = ProviderUsage.integer(defaults["n_ctx"]), cap > 0 else { self.finish(.failure(.unverifiedAdapter)); return }
                let memoryCap = (object["memory"] as? [String: Any]).flatMap { ProviderUsage.integer($0["max_safe_context"]) }
                guard min(self.requestedLimit, self.modelCap, cap, memoryCap ?? cap) == self.contextLimit else { self.finish(.failure(.unverifiedAdapter)); return }
                self.request(path: "/api/show", json: ["model": Qwen38TextAdapter.modelID]) { object in
                    guard let info = object["model_info"] as? [String: Any], info["general.basename"] as? String == Qwen38TextAdapter.modelID,
                          let template = object["template"] as? String, EndpointRequest.digest(Data(template.utf8)) == Qwen38TextAdapter.templateDigest else {
                        self.finish(.failure(.templateMismatch)); return
                    }
                    completion()
                }
            }
        }
    }

    func start() {
        queue.async {
            self.started = Date()
            if let lease = self.episodeLease {
                do {
                    if self.componentSessionEnabled {
                        let receipt = try lease.checkActive()
                        guard case .chat = receipt.origin else { self.finish(.failure(.episodeAccountingFailed)); return }
                        guard let policy = receipt.limits.componentPolicy else { self.finish(.failure(.episodeAccountingFailed)); return }
                        self.componentPolicy = try policy.validated()
                        self.componentPolicyDigest = EndpointRequest.digest(try policy.canonicalData())
                        self.componentProjectID = receipt.projectID
                    }
                    let remaining = try lease.remainingSeconds()
                    let timer = DispatchSource.makeTimerSource(queue: self.queue)
                    timer.schedule(deadline: .now() + remaining)
                    timer.setEventHandler { [weak self] in self?.finish(.failure(.episodeDeadlineExceeded)) }
                    self.deadlineTimer = timer; timer.resume()
                } catch { self.finish(.failure(.budget(error))); return }
            }
            guard let url = LocalEndpoint.chatURL(self.address), self.requestedLimit > 0, self.safety >= 0,
                  self.body.count <= EndpointRequest.maximumEnvelopeBytes,
                  !self.apiKey.contains("\r"), !self.apiKey.contains("\n"),
                  let object = (try? JSONSerialization.jsonObject(with: self.body)) as? [String: Any],
                  object["model"] as? String == Qwen38TextAdapter.modelID,
                  (try? Qwen38TextAdapter.render(object)) != nil,
                  ProviderUsage.integer(object["max_tokens"]).map({ $0 > 0 }) == true else {
                self.finish(.failure(.unverifiedAdapter)); return
            }
            self.payload = object; self.chatURL = url
            if self.componentSessionEnabled {
                guard let mandatory = object["messages"] as? [[String: String]], mandatory.count == 2,
                      mandatory.first?["role"] == "system", mandatory.last?["role"] == "user" else {
                    self.finish(.failure(.invalidRequest)); return
                }
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 45
            let delegateQueue = OperationQueue(); delegateQueue.maxConcurrentOperationCount = 1
            self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
            self.request(path: "/v1/models") { object in
                guard let models = object["data"] as? [[String: Any]],
                      let model = models.first(where: { $0["id"] as? String == Qwen38TextAdapter.modelID }),
                      let identity = try? ProviderObservedModelIdentity.observe(model: model) else { self.finish(.failure(.unverifiedAdapter)); return }
                if self.payload["response_format"] != nil && !identity.capabilities.contains("json_schema") {
                    self.finish(.failure(.unverifiedAdapter)); return
                }
                self.observedModelIdentity = identity
                // The server exposes no load generation. This legacy slot is
                // unused; the explicit observation mode is authoritative.
                self.modelEpoch = 0; self.modelCap = identity.modelContextLimit; self.readProps()
            }
        }
    }

    func cancel() { queue.async { self.finish(.failure(.cancelled)) } }

    private func readProps() {
        request(path: "/props", modelQuery: true) { object in
            guard let settings = object["settings"] as? [String: Any],
                  settings["version"] as? String == Qwen38TextAdapter.serverVersion,
                  settings["engine"] as? String == "mlx",
                  let defaults = object["default_generation_settings"] as? [String: Any],
                  let cap = ProviderUsage.integer(defaults["n_ctx"]), cap > 0 else {
                self.finish(.failure(.unverifiedAdapter)); return
            }
            let memoryCap = (object["memory"] as? [String: Any]).flatMap { ProviderUsage.integer($0["max_safe_context"]) }
            self.contextLimit = min(self.requestedLimit, self.modelCap, cap, memoryCap ?? cap)
            self.request(path: "/api/show", json: ["model": Qwen38TextAdapter.modelID]) { object in
                guard let info = object["model_info"] as? [String: Any],
                      info["general.basename"] as? String == Qwen38TextAdapter.modelID,
                      let template = object["template"] as? String,
                      EndpointRequest.digest(Data(template.utf8)) == Qwen38TextAdapter.templateDigest else {
                    self.finish(.failure(.templateMismatch)); return
                }
                self.calibrateOrCount()
            }
        }
    }

    private func calibrateOrCount() {
        let thinking = payload["enable_thinking"] as? Bool ?? false
        // No instance/load identity is observable, so an independent operation
        // cannot inherit a process-wide calibration. Component calls reuse this
        // operation's one verification and original continuous validity bound.
        let probe = Qwen38TextAdapter.calibrationBody(thinking: thinking)
        guard let rendered = try? Qwen38TextAdapter.render(probe) else { finish(.failure(.unverifiedAdapter)); return }
        count(rendered) { expected in
            self.calibrationPromptTokens = expected
            self.request(path: "/v1/chat/completions", json: probe, inferencePromptTokens: expected, outputReserve: 1) { object in
                if let usage = ProviderUsage.parse(object["usage"]) {
                    self.calibrationUsage = usage; self.unknownCalibrationOutcome = false
                }
                guard object["model"] as? String == Qwen38TextAdapter.modelID,
                      let usage = self.calibrationUsage, usage.promptTokens == expected,
                      usage.completionTokens <= 1 else { self.finish(.failure(.countMismatch)); return }
                self.countActual()
            }
        }
    }

    private func countActual() {
        guard let rendered = try? Qwen38TextAdapter.render(payload),
              let output = ProviderUsage.integer(payload["max_tokens"]) else { finish(.failure(.invalidRequest)); return }
        count(rendered) { tokens in
            guard ProviderAdmission.fits(promptTokens: tokens, outputReserve: output, safetyTokens: self.safety,
                                         contextLimit: self.contextLimit) else { self.finish(.failure(.contextOverflow)); return }
            self.finish(.success(EndpointAdmissionReceipt(bodyDigest: EndpointRequest.digest(self.body),
                endpoint: self.chatURL!.absoluteString, modelID: Qwen38TextAdapter.modelID, promptTokens: tokens,
                outputReserve: output, safetyTokens: self.safety, effectiveContextLimit: self.contextLimit,
                envelopeBytes: self.body.count, templateDigest: Qwen38TextAdapter.templateDigest,
                serverVersion: Qwen38TextAdapter.serverVersion, loadedModelEpoch: self.modelEpoch,
                calibrationUsage: self.calibrationUsage, admittedAt: Date(), accounting: self.accountingSnapshot(),
                episodeID: self.episodeLease?.episodeID, calibrationWorkID: self.calibrationWorkID,
                thinkingEnabled: self.payload["enable_thinking"] as? Bool ?? false,
                modelIdentity: self.observedModelIdentity)))
        }
    }

    private func count(_ rendered: String, completion: @escaping (Int) -> Void) {
        request(path: "/tokenize", json: ["model": Qwen38TextAdapter.modelID, "content": rendered]) { object in
            guard let tokens = object["tokens"] as? [Any], !tokens.isEmpty,
                  tokens.allSatisfy({ ProviderUsage.integer($0).map({ $0 < 248320 }) == true }) else {
                self.finish(.failure(.countMismatch)); return
            }
            completion(tokens.count)
        }
    }

    private func request(path: String, json: [String: Any]? = nil, modelQuery: Bool = false,
                         inferencePromptTokens: Int? = nil, outputReserve: Int = 0,
                         completion: @escaping ([String: Any]) -> Void) {
        guard !ended, Date().timeIntervalSince(started) < 45, let chatURL,
              var parts = URLComponents(url: chatURL, resolvingAgainstBaseURL: false) else {
            finish(.failure(.unavailable)); return
        }
        parts.path = path
        if modelQuery { parts.queryItems = [URLQueryItem(name: "model", value: Qwen38TextAdapter.modelID)] }
        guard let url = parts.url else { finish(.failure(.invalidRequest)); return }
        let remaining: TimeInterval
        do { remaining = try episodeLease?.remainingSeconds() ?? 45 - Date().timeIntervalSince(started) }
        catch { finish(.failure(.budget(error))); return }
        var request = URLRequest(url: url); request.timeoutInterval = min(15, remaining, 45 - Date().timeIntervalSince(started))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        if let json {
            guard let bytes = try? EndpointRequest.serialize(json) else { finish(.failure(.contextOverflow)); return }
            request.httpMethod = "POST"; request.httpBody = bytes
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        response = Data(); receivedBytes = 0; responseLimitExceeded = false; responseCallback = completion
        activeInference = inferencePromptTokens != nil; activeDispatched = false
        do {
            if let lease = episodeLease {
                let snapshot = try request.httpBody ?? EndpointRequest.serialize(["method": "GET", "endpoint": url.absoluteString])
                let resources = EpisodeResources(inputTokens: inferencePromptTokens ?? 0, outputTokens: outputReserve,
                    modelCalls: activeInference ? 1 : 0, httpAttempts: 1)
                activeWork = try lease.prepare(kind: activeInference ? .calibration : (path == "/tokenize" ? .tokenizer : .providerDiscovery),
                    resources: resources, adapterIdentity: currentAdapterIdentity, snapshot: snapshot)
            }
            let next = session!.dataTask(with: request); task = next
            let start = {
                self.activeDispatched = true
                self.httpRequestCount += 1
                if path == "/tokenize" { self.tokenizerRequestCount += 1 }
                if self.activeInference {
                    self.calibrationRequestCount += 1; self.unknownCalibrationOutcome = true
                    self.calibrationWorkID = self.activeWork?.id
                }
                next.resume()
            }
            if let lease = episodeLease, let work = activeWork { activeWork = try lease.dispatch(work, start: start) }
            else { start() }
        } catch { finish(.failure(.budget(error))) }
    }

    /// HTTP success alone establishes no model usage. Missing inference usage keeps
    /// the conservative reservation, including the one-token calibration output.
    private func settleActive(object: [String: Any]? = nil) throws {
        guard let lease = episodeLease, let work = activeWork else { return }
        let usage = activeInference ? ProviderUsage.parse(object?["usage"]) : nil
        if let usage { calibrationUsage = usage; unknownCalibrationOutcome = false }
        let outcome: EpisodeWorkOutcome
        let observed: EpisodeResources?
        if !activeDispatched { outcome = .cancelledBeforeDispatch; observed = nil }
        else if activeInference {
            if let usage {
                outcome = .completed
                observed = EpisodeResources(inputTokens: usage.promptTokens, outputTokens: usage.completionTokens,
                    modelCalls: 1, httpAttempts: 1)
            } else { outcome = .outcomeUnknown; observed = nil }
        } else {
            outcome = object == nil ? .failedConfirmed : .completed
            observed = EpisodeResources(httpAttempts: 1)
        }
        let model = object?["model"] as? String
        let identityMismatch = activeInference && (model.map { $0 != Qwen38TextAdapter.modelID } ?? (usage != nil))
        let rawUsage = object?["usage"]
        let protocolMismatch = activeInference && rawUsage != nil && !(rawUsage is NSNull) && usage == nil
        let violation = identityMismatch || protocolMismatch
        let evidence = try usage.map { try JSONEncoder().encode($0) }
            ?? (activeInference ? unknownCalibrationEvidence(identityMismatch: identityMismatch,
                protocolMismatch: protocolMismatch, observedModel: model) : tokenizerEvidence(work: work, object: object))
        // Clear first: a ledger adapter violation is durable and must never cause
        // finish() to overwrite its receipt with an unknown transport outcome.
        activeWork = nil
        if work.request.kind == .tokenizer, outcome == .completed { lastTokenizerWorkID = work.id }
        if outcome == .outcomeUnknown { lateWork = work; lateViolationRecorded = violation }
        do {
            _ = try lease.settle(work, outcome: outcome, observed: observed, evidence: evidence,
                adapterViolation: violation)
        } catch EpisodeBudgetError.conflict where outcome == .cancelledBeforeDispatch {
            // The durable arm may precede a lease-local Stop that suppressed
            // resume. Preserve that reservation instead of asserting nonuse.
            lateWork = work
            if activeInference { unknownCalibrationOutcome = true; calibrationWorkID = work.id }
            _ = try lease.settle(work, outcome: .outcomeUnknown)
        }
    }

    private func tokenizerEvidence(work: EpisodeWorkRecord, object: [String: Any]?) throws -> Data? {
        guard work.request.kind == .tokenizer,
              let tokens = object?["tokens"] as? [Any], !tokens.isEmpty,
              tokens.allSatisfy({ ProviderUsage.integer($0).map({ $0 < 248320 }) == true }),
              let snapshot = work.request.snapshot,
              let request = (try? JSONSerialization.jsonObject(with: snapshot)) as? [String: Any],
              request["model"] as? String == Qwen38TextAdapter.modelID,
              let rendered = request["content"] as? String else { return nil }
        return try EndpointRequest.serialize(["version": "provider-tokenizer-count-v1", "model": Qwen38TextAdapter.modelID,
            "token_count": tokens.count, "rendered_sha256": EndpointRequest.digest(Data(rendered.utf8)),
            "tokenizer_work_id": work.id, "adapter_identity": work.request.adapterIdentity])
    }

    private func unknownCalibrationEvidence(identityMismatch: Bool, protocolMismatch: Bool, observedModel: String?) throws -> Data {
        var evidence: [String: Any] = ["usage_observed": false, "model_identity_mismatch": identityMismatch,
            "protocol_count_mismatch": protocolMismatch, "expected_model_sha256": EndpointRequest.digest(Data(Qwen38TextAdapter.modelID.utf8))]
        if let observedModel { evidence["observed_model_sha256"] = EndpointRequest.digest(Data(observedModel.utf8)) }
        return try EndpointRequest.serialize(evidence)
    }

    private func settleLateUsage(_ object: [String: Any]) {
        guard let lease = episodeLease, let work = lateWork, work.request.kind == .calibration else { return }
        let model = object["model"] as? String
        guard let usage = ProviderUsage.parse(object["usage"]) else {
            let identityMismatch = model.map { $0 != Qwen38TextAdapter.modelID } ?? false
            let rawUsage = object["usage"]
            let protocolMismatch = rawUsage != nil && !(rawUsage is NSNull)
            if !lateViolationRecorded, identityMismatch || protocolMismatch {
                do {
                    _ = try lease.settle(work, outcome: .outcomeUnknown,
                        evidence: unknownCalibrationEvidence(identityMismatch: identityMismatch, protocolMismatch: protocolMismatch, observedModel: model),
                        adapterViolation: true)
                    lateViolationRecorded = true
                } catch EpisodeBudgetError.adapterViolation { lateViolationRecorded = true }
                catch { return }
            }
            return
        }
        lateWork = nil
        calibrationUsage = usage; unknownCalibrationOutcome = false
        _ = try? lease.settle(work, outcome: .completed,
            observed: EpisodeResources(inputTokens: usage.promptTokens, outputTokens: usage.completionTokens, modelCalls: 1, httpAttempts: 1),
            evidence: try? JSONEncoder().encode(usage),
            adapterViolation: lateViolationRecorded || model != Qwen38TextAdapter.modelID)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        queue.async {
            guard !self.ended, let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("application/json") == true,
                  response.expectedContentLength <= 4 * 1_048_576 else {
                completionHandler(.cancel); self.finish(.failure(.unavailable)); return
            }
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.async {
            guard (!self.ended || self.lateWork != nil), !self.responseLimitExceeded else { return }
            guard data.count <= 4 * 1_048_576 - self.receivedBytes else {
                self.responseLimitExceeded = true; self.response.removeAll(keepingCapacity: true)
                self.finish(.failure(.unavailable)); return
            }
            self.receivedBytes += data.count
            self.response.append(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async {
            if self.ended {
                if let object = (try? JSONSerialization.jsonObject(with: self.response)) as? [String: Any] {
                    self.settleLateUsage(object)
                    self.response.removeAll(keepingCapacity: true)
                }
                return
            }
            guard error == nil, let object = (try? JSONSerialization.jsonObject(with: self.response)) as? [String: Any],
                  let callback = self.responseCallback else { self.finish(.failure(.unavailable)); return }
            do {
                try self.settleActive(object: object)
                _ = try self.episodeLease?.checkActive()
            } catch { self.finish(.failure(.budget(error))); return }
            self.responseCallback = nil; self.task = nil; self.response = Data(); callback(object)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil); queue.async { self.finish(.failure(.unavailable)) }
    }

    private func finish(_ result: Result<EndpointAdmissionReceipt, ProviderAdmissionError>) {
        guard !ended else { return }
        var result = result
        do {
            let object = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any]
            try settleActive(object: object)
        } catch { result = .failure(.budget(error)) }
        if componentSessionEnabled, !componentReady, case .success = result {
            do { componentVerifiedClock = try episodeLease?.clockSnapshot() }
            catch { finish(.failure(.budget(error))); return }
            componentReady = true; componentVerifiedAt = componentVerifiedClock?.utc ?? Date()
            let callback = completion; completion = nil; responseCallback = nil
            let verifiedClock = componentVerifiedClock!
            if let callback {
                DispatchQueue.main.async {
                    if let error = self.queue.sync(execute: { self.terminalError }) { callback(.failure(error)); return }
                    do {
                        _ = try self.episodeLease?.checkActive(projectID: self.componentProjectID!)
                        guard let clock = try self.episodeLease?.clockSnapshot(),
                              ProviderComponentCountReceipt.bindingIsFresh(maximumAge: 30, clock: clock,
                                clockDomain: verifiedClock.domain, verifiedNanoseconds: verifiedClock.continuousNanoseconds) else {
                            callback(.failure(.unverifiedAdapter)); return
                        }
                        callback(result)
                    }
                    catch { callback(.failure(.budget(error))) }
                }
            }
            return
        }
        let error: ProviderAdmissionError
        if case .failure(let value) = result { error = value } else { error = .cancelled }
        terminalError = error
        let countCallback = componentCountCompletion; componentCountCompletion = nil
        let admissionCallback = componentAdmissionCompletion; componentAdmissionCompletion = nil
        componentBusy = false
        ended = true; finishedAt = Date(); let callback = completion; completion = nil; responseCallback = nil
        deadlineTimer?.cancel(); deadlineTimer = nil
        task?.cancel(); task = nil; session?.invalidateAndCancel(); session = nil
        if let callback { DispatchQueue.main.async { callback(result) } }
        if let countCallback { DispatchQueue.main.async { countCallback(.failure(error)) } }
        if let admissionCallback { DispatchQueue.main.async { admissionCallback(.failure(error)) } }
    }
}
