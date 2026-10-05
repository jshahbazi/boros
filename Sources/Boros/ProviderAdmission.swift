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
        case .invalid, .conflict: return .episodeAccountingFailed
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

    var reservedTokens: Int { promptTokens + outputReserve + safetyTokens }

    var answerAdapterIdentity: String {
        ProviderAdmission.adapterIdentity(endpoint: endpoint, modelEpoch: loadedModelEpoch, thinking: thinkingEnabled)
    }

    func accepts(body: Data, address: String, maximumAge: TimeInterval = 30) -> Bool {
        guard let url = LocalEndpoint.chatURL(address), Date().timeIntervalSince(admittedAt) >= 0,
              Date().timeIntervalSince(admittedAt) <= maximumAge,
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              object["enable_thinking"] as? Bool == thinkingEnabled else { return false }
        return endpoint == url.absoluteString && bodyDigest == EndpointRequest.digest(body)
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
    static let modelID = "ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit"
    static let templateDigest = "c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041"
    static let serverVersion = "26.10.1"
    static let lowInstructions = "Reasoning effort is set to low. Keep your thinking brief and focused, moving directly to the conclusion without unnecessary elaboration."

    static func render(_ body: [String: Any]) throws -> String {
        guard body["model"] as? String == modelID,
              let raw = body["messages"] as? [[String: String]],
              let thinking = body["enable_thinking"] as? Bool,
              body["reasoning_effort"] as? String == (thinking ? "low" : "none"),
              let kwargs = body["chat_template_kwargs"] as? [String: Any],
              kwargs.count == 1, kwargs["preserve_thinking"] as? Bool == true,
              body["tools"] == nil, body["continue_final_message"] == nil else {
            throw ProviderAdmissionError.unverifiedAdapter
        }
        // mlx-serve drops exactly empty plain text messages before Jinja rendering.
        let messages = raw.filter { $0["content"] != "" }
        guard !messages.isEmpty, messages.allSatisfy({ Set($0.keys) == Set(["role", "content"]) }),
              !messages.dropFirst().contains(where: { $0["role"] == "system" }),
              messages.contains(where: { message in
                  let value = trim(message["content"] ?? "")
                  return message["role"] == "user" && !(value.hasPrefix("<tool_response>") && value.hasSuffix("</tool_response>"))
              }) else { throw ProviderAdmissionError.invalidRequest }
        var rendered = ""
        let system = messages.first?["role"] == "system" ? trim(messages[0]["content"] ?? "") : ""
        let instruction = thinking ? lowInstructions : ""
        if !system.isEmpty || !instruction.isEmpty {
            rendered += "<|im_start|>system\n" + instruction
            if !instruction.isEmpty && !system.isEmpty { rendered += "\n\n" }
            rendered += system + "<|im_end|>\n"
        }
        for message in messages {
            let value = trim(message["content"] ?? "")
            switch message["role"] {
            case "system": break
            case "user": rendered += "<|im_start|>user\n" + value + "<|im_end|>\n"
            case "assistant": rendered += "<|im_start|>assistant\n<think>\n\n</think>\n\n" + value + "<|im_end|>\n"
            default: throw ProviderAdmissionError.invalidRequest
            }
        }
        rendered += "<|im_start|>assistant\n" + (thinking ? "<think>\n" : "<think>\n\n</think>\n\n")
        // Server post-render normalization also affects literal occurrences inside content.
        while rendered.contains("</think></think>") {
            rendered = rendered.replacingOccurrences(of: "</think></think>", with: "</think>")
        }
        return rendered
    }

    static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\u{000B}\u{000C}"))
    }

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

    static func fits(promptTokens: Int, outputReserve: Int, safetyTokens: Int, contextLimit: Int) -> Bool {
        guard promptTokens >= 0, outputReserve > 0, safetyTokens >= 0, contextLimit > 0,
              outputReserve <= contextLimit, safetyTokens <= contextLimit - outputReserve else { return false }
        return promptTokens <= contextLimit - outputReserve - safetyTokens
    }
}

final class ProviderAdmissionOperation: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private static let cacheLock = NSLock()
    private static var calibrated = Set<String>()
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

    func start() {
        queue.async {
            self.started = Date()
            if let lease = self.episodeLease {
                do {
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
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 45
            let delegateQueue = OperationQueue(); delegateQueue.maxConcurrentOperationCount = 1
            self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
            self.request(path: "/v1/models") { object in
                guard let models = object["data"] as? [[String: Any]],
                      let model = models.first(where: { $0["id"] as? String == Qwen38TextAdapter.modelID }),
                      model["owned_by"] as? String == "mlx-serve", model["loaded"] as? Bool == true,
                      model["state"] as? String == "ready", let epoch = ProviderUsage.integer(model["created"]),
                      let cap = ProviderUsage.integer(model["context_length"]), cap > 0,
                      let meta = model["meta"] as? [String: Any], meta["engine"] as? String == "mlx",
                      meta["architecture"] as? String == "qwen4_exp" else { self.finish(.failure(.unverifiedAdapter)); return }
                self.modelEpoch = epoch; self.modelCap = cap; self.readProps()
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
        let key = (chatURL?.absoluteString ?? "") + "|\(modelEpoch)|\(thinking)|" + Qwen38TextAdapter.templateDigest + Qwen38TextAdapter.serverVersion
        Self.cacheLock.lock(); let cached = Self.calibrated.contains(key); Self.cacheLock.unlock()
        if cached { countActual(); return }
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
                Self.cacheLock.lock(); Self.calibrated.insert(key); Self.cacheLock.unlock()
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
                thinkingEnabled: self.payload["enable_thinking"] as? Bool ?? false)))
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
                    resources: resources, adapterIdentity: ProviderAdmission.adapterIdentity(endpoint: chatURL.absoluteString,
                        modelEpoch: modelEpoch, thinking: payload["enable_thinking"] as? Bool ?? false), snapshot: snapshot)
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
                protocolMismatch: protocolMismatch, observedModel: model) : nil)
        // Clear first: a ledger adapter violation is durable and must never cause
        // finish() to overwrite its receipt with an unknown transport outcome.
        activeWork = nil
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
        ended = true; finishedAt = Date(); let callback = completion; completion = nil; responseCallback = nil
        deadlineTimer?.cancel(); deadlineTimer = nil
        task?.cancel(); task = nil; session?.invalidateAndCancel(); session = nil
        if let callback { DispatchQueue.main.async { callback(result) } }
    }
}
