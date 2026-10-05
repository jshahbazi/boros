import Foundation

enum LocalEndpoint {
    static func chatURL(_ address: String) -> URL? {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "http", parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, let rawHost = parts.host else { return nil }
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard ["localhost", "127.0.0.1", "::1"].contains(host),
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        let path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch path {
        case "": parts.path = "/v1/chat/completions"
        case "v1": parts.path = "/v1/chat/completions"
        case "v1/chat/completions": parts.path = "/v1/chat/completions"
        default: return nil
        }
        return parts.url
    }
}

/// Decode SSE as bytes so network boundaries cannot corrupt a split UTF-8 scalar.
/// Each complete event must contain valid UTF-8. No content is logged.
struct EndpointEventDecoder {
    private var pending = Data()
    private var dataLines: [Data] = []
    private var eventBytes = 0
    private(set) var failed = false
    private let maximumEventBytes = 1_048_576

    mutating func consume(_ bytes: Data) -> [String] {
        guard !failed else { return [] }
        pending.append(bytes)
        var events: [String] = []
        while let newline = pending.firstIndex(of: 10) {
            var line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            if line.last == 13 { line.removeLast() }
            if line.isEmpty {
                if !dataLines.isEmpty {
                    var payload = Data()
                    for (index, part) in dataLines.enumerated() {
                        if index > 0 { payload.append(10) }
                        payload.append(part)
                    }
                    guard let text = String(data: payload, encoding: .utf8) else { failed = true; return events }
                    events.append(text)
                }
                dataLines.removeAll(keepingCapacity: true)
                eventBytes = 0
            } else {
                eventBytes += line.count
                if eventBytes > maximumEventBytes { failed = true; return events }
                if line.starts(with: Data("data:".utf8)) {
                    var content = Data(line.dropFirst(5))
                    if content.first == 32 { content.removeFirst() }
                    dataLines.append(content)
                }
            }
        }
        if pending.count + eventBytes > maximumEventBytes { failed = true }
        return events
    }

    var hasUnfinishedEvent: Bool { !pending.isEmpty || !dataLines.isEmpty }
}

/// Semantic stream state is independent of socket EOF and UI presentation.
struct EndpointResponseState {
    private(set) var answerBytes = 0
    private(set) var finishReason: String?
    private(set) var done = false
    private(set) var failure: String?
    private(set) var usage: ProviderUsage?
    private(set) var observedModel: String?
    private let maximumAnswerBytes = 4 * 1_048_576

    mutating func consume(_ payload: String) -> String? {
        guard failure == nil, !done else { return nil }
        if payload.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" { done = true; return nil }
        guard let bytes = payload.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else {
            failure = "invalid_stream"; return nil
        }
        if object["error"] != nil { failure = "process_failed"; return nil }
        if let model = object["model"] as? String {
            if let observedModel, observedModel != model { failure = "provider_count_mismatch"; return nil }
            observedModel = model
        }
        if let rawUsage = object["usage"], !(rawUsage is NSNull) {
            guard let value = ProviderUsage.parse(rawUsage), usage == nil || usage == value else {
                failure = "provider_count_mismatch"; return nil
            }
            usage = value
        }
        guard let choices = object["choices"] as? [[String: Any]] else {
            failure = "invalid_stream"; return nil
        }
        if choices.isEmpty {
            if object["usage"] == nil { failure = "invalid_stream" }
            return nil
        }
        guard choices.count == 1, let choice = choices.first,
              let delta = choice["delta"] as? [String: Any] else {
            failure = "invalid_stream"; return nil
        }
        if let calls = delta["tool_calls"] as? [Any], !calls.isEmpty {
            failure = "process_failed"; return nil
        }
        if delta["function_call"] != nil { failure = "process_failed"; return nil }
        var chunk: String?
        if let content = delta["content"], !(content is NSNull) {
            guard let value = content as? String, finishReason == nil || value.isEmpty else {
                failure = "invalid_stream"; return nil
            }
            let size = value.utf8.count
            guard size <= maximumAnswerBytes - answerBytes else { failure = "output_limit"; return nil }
            answerBytes += size
            if !value.isEmpty { chunk = value }
        }
        // Reasoning deltas are intentionally excluded from the durable visible-answer contract.
        if let value = choice["finish_reason"], !(value is NSNull) {
            guard let reason = value as? String, ["stop", "length"].contains(reason),
                  finishReason == nil || finishReason == reason else {
                failure = "invalid_stream"; return chunk
            }
            finishReason = reason
        }
        return chunk
    }

    var completedFailure: String? {
        if let failure { return failure }
        if !done && finishReason == nil { return "invalid_stream" }
        if finishReason == "length" { return "incomplete_result" }
        if answerBytes == 0 { return "empty_result" }
        return nil
    }
}

final class EndpointRunner: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private let stateQueue = DispatchQueue(label: "dev.boros.endpoint.state")
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var decoder = EndpointEventDecoder()
    private var responseState = EndpointResponseState()
    private var onText: ((String) -> Void)?
    private var onComplete: ((GenerationResult) -> Void)?
    private var started = Date()
    private var ended = false
    private var wireBytes = 0
    private var receivedResponse = false
    private var cancelled = false
    private var admissionOperation: ProviderAdmissionOperation?
    private var admission: EndpointAdmissionReceipt?

    func start(prompt: String, settings: GenerationSettings, conversation: Conversation,
               onText: @escaping (String) -> Void, onComplete: @escaping (GenerationResult) -> Void) {
        stateQueue.async {
            self.onText = onText; self.onComplete = onComplete; self.started = Date()
            let bytes: Data
            do { bytes = try EndpointRequest.build(prompt: prompt, settings: settings, conversation: conversation) }
            catch let error as ProviderAdmissionError { self.finish(error.failureCode); return }
            catch { self.finish("invalid_endpoint"); return }
            if let prepared = settings.preparedEndpointBody, prepared != bytes {
                self.finish("provider_count_mismatch"); return
            }
            if let receipt = settings.endpointAdmission {
                guard receipt.accepts(body: bytes, address: settings.endpointURL),
                      receipt.outputReserve == settings.maximumOutput,
                      receipt.safetyTokens == settings.endpointSafetyTokens,
                      receipt.effectiveContextLimit <= settings.endpointContextLimit else {
                    self.finish("provider_count_mismatch"); return
                }
                self.dispatch(body: bytes, settings: settings, receipt: receipt)
            } else {
                self.admissionOperation = ProviderAdmission.prepare(requestBody: bytes, address: settings.endpointURL,
                    apiKey: settings.endpointAPIKey, contextLimit: settings.endpointContextLimit,
                    safetyTokens: settings.endpointSafetyTokens) { result in
                    self.stateQueue.async {
                        guard !self.ended else { return }
                        self.admissionOperation = nil
                        switch result {
                        case .success(let receipt): self.dispatch(body: bytes, settings: settings, receipt: receipt)
                        case .failure(let error): self.finish(error.failureCode, stopped: error == .cancelled)
                        }
                    }
                }
            }
        }
    }

    private func dispatch(body bytes: Data, settings: GenerationSettings, receipt: EndpointAdmissionReceipt) {
            guard !ended, !cancelled, let url = LocalEndpoint.chatURL(settings.endpointURL),
                  receipt.accepts(body: bytes, address: settings.endpointURL) else {
                finish(cancelled ? nil : "provider_count_mismatch", stopped: cancelled); return
            }
            admission = receipt
            var request = URLRequest(url: url)
            request.httpMethod = "POST"; request.httpBody = bytes; request.timeoutInterval = 180
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            if !settings.endpointAPIKey.isEmpty {
                guard !settings.endpointAPIKey.contains("\r"), !settings.endpointAPIKey.contains("\n") else {
                    self.finish("invalid_endpoint"); return
                }
                request.setValue("Bearer " + settings.endpointAPIKey, forHTTPHeaderField: "Authorization")
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 180; configuration.timeoutIntervalForResource = 180
            let delegateQueue = OperationQueue(); delegateQueue.maxConcurrentOperationCount = 1
            self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
            self.task = self.session!.dataTask(with: request)
            if self.cancelled { self.finish(nil, stopped: true) } else { self.task!.resume() }
    }

    func cancel() {
        stateQueue.async {
            self.cancelled = true
            if self.onComplete != nil { self.finish(nil, stopped: true) }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        stateQueue.async {
            guard !self.ended, let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
            guard (200...299).contains(http.statusCode) else {
                completionHandler(.cancel); self.finish("http_failed"); return
            }
            guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/event-stream") == true else {
                completionHandler(.cancel); self.finish("invalid_stream"); return
            }
            self.receivedResponse = true
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        stateQueue.async {
            guard !self.ended, self.receivedResponse else { return }
            self.wireBytes += data.count
            guard self.wireBytes <= 16 * 1_048_576 else { self.finish("output_limit"); return }
            let events = self.decoder.consume(data)
            for payload in events {
                if let chunk = self.responseState.consume(payload), let callback = self.onText {
                    DispatchQueue.main.async { callback(chunk) }
                }
                if let failure = self.responseState.failure { self.finish(failure); return }
                if self.responseState.done { self.finish(self.completionFailure); return }
            }
            if self.decoder.failed { self.finish("invalid_stream") }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stateQueue.async {
            guard !self.ended else { return }
            if let error = error as NSError? {
                self.finish(error.code == NSURLErrorTimedOut ? "timeout" : "io_failed"); return
            }
            guard self.receivedResponse, !self.decoder.failed, !self.decoder.hasUnfinishedEvent else {
                self.finish("invalid_stream"); return
            }
            self.finish(self.completionFailure)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        stateQueue.async { self.finish("redirect_rejected") }
    }

    private func finish(_ failure: String?, stopped: Bool = false) {
        guard !ended else { return }
        ended = true
        let callback = onComplete
        onText = nil; onComplete = nil
        let result = GenerationResult(elapsed: Date().timeIntervalSince(started), tokensPerSecond: nil,
                                      failure: failure, stopped: stopped,
                                      providerUsage: responseState.usage, providerAdmission: admission)
        admissionOperation?.cancel(); admissionOperation = nil
        task?.cancel(); task = nil
        session?.invalidateAndCancel(); session = nil
        if let callback { DispatchQueue.main.async { callback(result) } }
    }

    private var completionFailure: String? {
        if let failure = responseState.completedFailure { return failure }
        guard let admission, let usage = responseState.usage,
              usage.promptTokens == admission.promptTokens, usage.completionTokens <= admission.outputReserve,
              responseState.observedModel == admission.modelID else { return "provider_count_mismatch" }
        return nil
    }
}
