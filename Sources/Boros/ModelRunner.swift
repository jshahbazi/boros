import AppKit
import Darwin
import Foundation

let defaultRuntimePath = "/opt/homebrew/bin/llama-completion"

struct GenerationSettings {
    var profile = ModelProfile.bonsai
    var model = ModelProfile.bonsai.defaultModelPath
    var runtime = defaultRuntimePath
    var system = "Be helpful, concise, and accurate."
    var temperature = 0.2
    var context = 4096
    var maximumOutput = 512
    var seed = 42
    var thinkingEnabled = false
    var thinkingBudget = 2048
    var samplingPreset = SamplingPreset.recommended
    var endpointURL = "http://localhost:11234/v1/"
    var endpointModel = "ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit"
    // Runtime-only secret. It is never part of the durable memory/settings schema.
    var endpointAPIKey = ""
    var messagesOverride: [[String: String]]?
    // The coordinator freezes this canonical, credential-free body before
    // durable capture. The endpoint validates it against the same builder.
    var preparedEndpointBody: Data?
    var endpointContextLimit = 32768
    var endpointSafetyTokens = 256
    var endpointAdmission: EndpointAdmissionReceipt?
    var preparedNativeBody: Data?
    // One durable allowance spans preparation, calibration and answering.
    // These runtime references never enter persisted settings or request JSON.
    var episodeLease: EpisodeLease?
    var preparedAnswerWork: EpisodeWorkRecord?
    var preparedContextComponents: ContextComponentDispatchBinding?

    func messages(_ prompt: String, conversation: Conversation) -> [[String: String]] {
        messagesOverride ?? profile.chatMessages(system: system, prompt: prompt, conversation: conversation)
    }

    var effectiveThinkingEnabled: Bool {
        profile.supportsThinkingToggle ? thinkingEnabled : profile.supportsThinking
    }

    var effectiveThinkingBudget: Int {
        guard effectiveThinkingEnabled else { return 0 }
        let reserved = min(512, max(0, maximumOutput / 2))
        return max(0, min(thinkingBudget, maximumOutput - reserved))
    }

    func render(_ prompt: String, conversation: Conversation = Conversation()) -> String {
        guard let messagesOverride else {
            return profile.render(system: system, prompt: prompt, conversation: conversation, thinkingEnabled: thinkingEnabled)
        }
        if profile == .falcon3 {
            return messagesOverride.map { message in
                "<|\(message["role"] ?? "user")|>\n\(message["content"] ?? "")\n"
                    + (message["role"] == "assistant" ? "<|endoftext|>\n" : "")
            }.joined() + "<|assistant|>\n"
        }
        let prefix = profile == .minicpm || profile == .minicpmQ4 ? "<s>" : ""
        let prefill = profile == .bonsai ? "<think>\n\n</think>\n\n" : profile.assistantOutputPrefix(thinkingEnabled: effectiveThinkingEnabled)
        return prefix + messagesOverride.map { message in
            "<|im_start|>\(message["role"] ?? "user")\n\(message["content"] ?? "")<|im_end|>\n"
        }.joined() + "<|im_start|>assistant\n" + prefill
    }
}

struct GenerationResult {
    let elapsed: Double
    let tokensPerSecond: Double?
    let failure: String?
    let stopped: Bool
    var providerUsage: ProviderUsage? = nil
    var providerAdmission: EndpointAdmissionReceipt? = nil

    func reconcilingEpisodeState(_ state: EpisodeState) -> GenerationResult {
        let failure: String?
        let stopped: Bool
        switch state {
        case .deadlineExceeded: failure = "episode_deadline_exceeded"; stopped = false
        case .budgetExceeded: failure = "episode_budget_exceeded"; stopped = false
        case .cancelled: failure = self.failure; stopped = true
        case .failed, .interrupted: failure = self.failure ?? "episode_inactive"; stopped = false
        case .completed: failure = self.failure; stopped = self.stopped
        case .active: failure = "episode_accounting_failed"; stopped = false
        }
        return GenerationResult(elapsed: elapsed, tokensPerSecond: tokensPerSecond, failure: failure, stopped: stopped,
            providerUsage: providerUsage, providerAdmission: providerAdmission)
    }

    var message: String {
        if stopped && failure != "incomplete_result" { return "Stopped." }
        switch failure {
        case "model_missing": return "Choose an existing model file in Settings."
        case "runtime_missing": return "Choose an executable llama-completion runtime in Settings."
        case "launch_failed": return "Could not start the model. Check the model and runtime settings."
        case "io_failed": return "The model connection ended unexpectedly."
        case "process_failed": return "The model could not complete this prompt. Check the settings."
        case "timeout": return "The model took too long and was stopped."
        case "busy": return "Wait for the current response or press Stop."
        case "context_full": return "Conversation reached the context limit. Increase Context in Settings or start a New Chat."
        case "empty_result": return "The model finished without an answer. Try another prompt or change the settings."
        case "incomplete_result": return "The model stopped before finishing its answer. Increase Max response in Settings or try again."
        case "response_limit": return "The response limit was reached. Increase Max response in Settings or try again."
        case "invalid_endpoint": return "Enter a loopback HTTP API address and a served model ID in Settings."
        case "http_failed": return "The local API rejected the request. Check its address, model ID, and API key."
        case "redirect_rejected": return "The local API redirected the request. Enter its direct loopback address."
        case "invalid_stream": return "The local API returned an invalid or unfinished response stream."
        case "output_limit": return "The local response exceeded Boros's safety size limit."
        case "provider_admission_unavailable": return "Exact token admission is unavailable for this server or model. Check its tokenizer and chat-template support."
        case "provider_adapter_unverified": return "Boros has no verified tokenizer adapter for this model. Choose the configured Qwen model."
        case "provider_template_mismatch": return "The server's chat template changed. Its token adapter must be verified before sending."
        case "admission_mismatch": return "The prepared request changed after token admission. Retry the request."
        case "provider_count_mismatch": return "The server's prompt token count disagreed with admission. The response is incomplete."
        case "episode_budget_exceeded": return "This request reached its work allowance. Its recorded work has been preserved."
        case "episode_deadline_exceeded": return "This request reached its time limit. Any committed response remains available."
        case "episode_inactive": return "This request has ended. Start a new request to continue."
        case "episode_input_unobservable": return "Strict accounting cannot measure this model's input. Choose a verified adapter."
        case "episode_adapter_violation": return "The model's usage disagreed with its reserved allowance. Its adapter needs verification."
        case "episode_clock_unavailable", "episode_accounting_failed": return "Boros could not safely account for this request. Its recorded work has been preserved."
        case .some: return "The model could not complete this prompt."
        case .none:
            if let speed = tokensPerSecond {
                return String(format: "Done in %.2f s · %.1f tokens/s", elapsed, speed)
            }
            return String(format: "Done in %.2f s", elapsed)
        }
    }
}

// Keep a partial UTF-8 sequence until the next pipe read. Replacement is used
// only for malformed bytes, rather than for valid characters split across reads.
private struct UTF8Stream {
    private var pending = Data()

    mutating func consume(_ data: Data, final: Bool = false) -> String {
        pending.append(data)
        var count = pending.count
        if !final && count > 0 {
            let bytes = Array(pending)
            var lead = count - 1
            while lead > 0 && bytes[lead] & 0xc0 == 0x80 { lead -= 1 }
            let byte = bytes[lead]
            let width: Int
            if byte >= 0xc2 && byte <= 0xdf { width = 2 }
            else if byte >= 0xe0 && byte <= 0xef { width = 3 }
            else if byte >= 0xf0 && byte <= 0xf4 { width = 4 }
            else { width = 1 }
            if count - lead < width { count = lead }
        }
        let text = String(decoding: pending.prefix(count), as: UTF8.self)
        pending.removeFirst(count)
        return text
    }
}

final class ModelRunner {
    private let completion = CompletionRunner()
    private let reasoning = ReasoningRunner()
    private let lock = NSLock()
    private var running = false
    private var native = false
    private var endpoint: EndpointRunner?

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    func start(prompt: String, settings: GenerationSettings, conversation: Conversation = Conversation(),
               onText: @escaping (String) -> Void, onComplete: @escaping (GenerationResult) -> Void) {
        lock.lock()
        guard !running else {
            lock.unlock()
            DispatchQueue.main.async {
                onComplete(GenerationResult(elapsed: 0, tokensPerSecond: nil, failure: "busy", stopped: false))
            }
            return
        }
        running = true
        native = settings.profile != .bonsai && settings.profile != .customLocal
        if settings.profile != .customLocal { endpoint = nil }
        let useNative = native
        lock.unlock()
        let finished: (GenerationResult) -> Void = { result in
            self.lock.lock(); self.running = false; self.lock.unlock()
            onComplete(result)
        }
        if settings.profile == .customLocal {
            let runner = EndpointRunner()
            endpoint = runner
            runner.start(prompt: prompt, settings: settings, conversation: conversation, onText: onText, onComplete: finished)
        } else if useNative {
            reasoning.start(prompt: prompt, settings: settings, conversation: conversation,
                            onText: onText, onComplete: finished)
        } else {
            completion.start(prompt: prompt, settings: settings, conversation: conversation,
                             onText: onText, onComplete: finished)
        }
    }

    func cancel() {
        lock.lock(); let useNative = native; lock.unlock()
        if useNative { reasoning.cancel() } else if let endpoint { endpoint.cancel() } else { completion.cancel() }
    }
}

private final class CompletionRunner {
    private final class Job {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let started = Date()
        let onText: (String) -> Void
        let onComplete: (GenerationResult) -> Void
        var decoder = UTF8Stream()
        var tail = ""
        var stderr = Data()
        var outputEnded = false
        var errorsEnded = false
        var exited = false
        var status: Int32 = 0
        var stopped = false
        var failure: String?
        var outputPrefix = ""
        var profile = ModelProfile.bonsai
        var hasVisibleText = false
        var completionText = ""
        var episodeLease: EpisodeLease?
        var episodeWork: EpisodeWorkRecord?

        init(onText: @escaping (String) -> Void,
             onComplete: @escaping (GenerationResult) -> Void) {
            self.onText = onText
            self.onComplete = onComplete
        }
    }

    private let queue = DispatchQueue(label: "BonsaiPlayground.model")
    private var active: Job?

    func start(prompt: String, settings: GenerationSettings, conversation: Conversation = Conversation(),
               onText: @escaping (String) -> Void,
               onComplete: @escaping (GenerationResult) -> Void) {
        queue.async {
            guard self.active == nil else {
                DispatchQueue.main.async {
                    onComplete(GenerationResult(elapsed: 0, tokensPerSecond: nil,
                                                failure: "busy", stopped: false))
                }
                return
            }
            let job = Job(onText: onText, onComplete: onComplete)
            job.episodeLease = settings.episodeLease
            job.episodeWork = settings.preparedAnswerWork
            job.outputPrefix = settings.profile.assistantOutputPrefix
            job.profile = settings.profile
            let model = (settings.model as NSString).expandingTildeInPath
            let runtime = (settings.runtime as NSString).expandingTildeInPath
            var directory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: model, isDirectory: &directory)
                || directory.boolValue {
                self.completeUnstarted(job, failure: "model_missing")
                return
            }
            if !FileManager.default.isExecutableFile(atPath: runtime) {
                self.completeUnstarted(job, failure: "runtime_missing")
                return
            }
            self.active = job
            job.process.executableURL = URL(fileURLWithPath: runtime)
            job.process.arguments = NativeRequest.completionArguments(settings: settings)
            job.process.standardInput = job.input
            job.process.standardOutput = job.output
            job.process.standardError = job.errors
            job.process.terminationHandler = { process in
                self.queue.async {
                    job.exited = true
                    job.status = process.terminationStatus
                    self.finishIfReady(job)
                }
            }
            do {
                if let lease = job.episodeLease {
                    let evidence = try NativeRequest.completionEvidence(prompt: prompt, settings: settings, conversation: conversation)
                    let work = try job.episodeWork ?? lease.prepare(kind: .nativeInference,
                        resources: EpisodeResources(outputTokens: settings.maximumOutput, modelCalls: 1),
                        adapterIdentity: "native:" + settings.profile.rawValue, snapshot: evidence, inputTokensKnown: false)
                    guard work.request.kind == .nativeInference, work.request.snapshot == evidence,
                          work.episodeID == lease.episodeID, !work.request.inputTokensKnown,
                          work.request.adapterIdentity == "native:" + settings.profile.rawValue,
                          work.request.resources == EpisodeResources(outputTokens: settings.maximumOutput, modelCalls: 1) else { throw EpisodeBudgetError.conflict }
                    var launchError: Error?
                    job.episodeWork = try lease.dispatch(work) {
                        do { try job.process.run() } catch { launchError = error }
                    }
                    if let launchError { throw launchError }
                } else { try job.process.run() }
            } catch {
                job.process.terminationHandler = nil
                self.active = nil
                if let work = job.episodeWork { _ = try? job.episodeLease?.settle(work, outcome: .outcomeUnknown) }
                self.completeUnstarted(job, failure: (error as? EpisodeBudgetError)?.failureCode ?? "launch_failed")
                return
            }
            self.drain(job.output.fileHandleForReading, job: job, isOutput: true)
            self.drain(job.errors.fileHandleForReading, job: job, isOutput: false)
            let rendered = Data(settings.render(prompt, conversation: conversation).utf8)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    _ = try job.episodeLease?.checkActive()
                    try job.input.fileHandleForWriting.write(contentsOf: rendered)
                    try job.input.fileHandleForWriting.close()
                } catch {
                    try? job.input.fileHandleForWriting.close()
                    self.queue.async {
                        if job.failure == nil { job.failure = (error as? EpisodeBudgetError)?.failureCode ?? "io_failed" }
                        self.stop(job)
                        self.finishIfReady(job)
                    }
                }
            }
            let timeLimit = settings.profile.generationTimeout(maximumOutput: settings.maximumOutput)
            self.queue.asyncAfter(deadline: .now() + timeLimit) { [weak self, weak job] in
                guard let self, let job, self.active === job else { return }
                job.failure = "timeout"
                self.stop(job)
            }
            if let lease = job.episodeLease, let remaining = try? lease.remainingSeconds() {
                self.queue.asyncAfter(deadline: .now() + remaining) { [weak self, weak job] in
                    guard let self, let job, self.active === job else { return }
                    job.failure = "episode_deadline_exceeded"
                    _ = try? job.episodeLease?.finish(reason: .deadlineExceeded)
                    self.stop(job)
                }
            }
        }
    }

    func cancel() {
        queue.async {
            guard let job = self.active else { return }
            job.stopped = true
            self.stop(job)
        }
    }

    private func stop(_ job: Job) {
        guard active === job else { return }
        if job.process.isRunning { job.process.terminate() }
        queue.asyncAfter(deadline: .now() + 2) { [weak self, weak job] in
            guard let self, let job, self.active === job, job.process.isRunning else { return }
            // This PID belongs to the still-running Process owned by this job.
            Darwin.kill(job.process.processIdentifier, SIGKILL)
        }
    }

    private func completeUnstarted(_ job: Job, failure: String) {
        let result = GenerationResult(elapsed: Date().timeIntervalSince(job.started),
                                      tokensPerSecond: nil, failure: failure, stopped: false)
        DispatchQueue.main.async { job.onComplete(result) }
    }

    private func drain(_ handle: FileHandle, job: Job, isOutput: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            var failed = false
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                // Foundation's read(upToCount:) can wait for all requested
                // bytes or EOF. read(2) returns a flushed live pipe prefix.
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count)
                }
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    failed = true
                    break
                }
                let data = Data(buffer.prefix(count))
                self.queue.async {
                    if isOutput {
                        self.emit(job.decoder.consume(data), job: job, final: false)
                    } else {
                        job.stderr.append(data)
                        if job.stderr.count > 131_072 {
                            job.stderr.removeFirst(job.stderr.count - 131_072)
                        }
                    }
                }
            }
            try? handle.close()
            let readFailed = failed
            self.queue.async {
                if readFailed && job.failure == nil { job.failure = "io_failed" }
                if isOutput {
                    self.emit(job.decoder.consume(Data(), final: true), job: job, final: true)
                    job.outputEnded = true
                } else {
                    job.errorsEnded = true
                }
                self.finishIfReady(job)
            }
        }
    }

    private func emit(_ text: String, job: Job, final: Bool) {
        do { _ = try job.episodeLease?.checkActive() }
        catch {
            if job.failure == nil { job.failure = (error as? EpisodeBudgetError)?.failureCode ?? "episode_accounting_failed" }
            stop(job)
            return
        }
        job.tail += text
        let visible: String
        if final {
            visible = job.profile.cleanCompletionTail(job.tail.replacingOccurrences(
                of: "\\s+\\[end of text\\]\\s*\\z", with: "", options: .regularExpression))
            job.tail = ""
        } else if job.tail.count > 80 {
            let boundary = job.tail.index(job.tail.endIndex, offsetBy: -80)
            visible = String(job.tail[..<boundary])
            job.tail = String(job.tail[boundary...])
        } else { return }
        if !visible.isEmpty {
            if final && !job.hasVisibleText && visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return
            }
            if !visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                job.hasVisibleText = true
            }
            let chunk = job.outputPrefix + visible
            job.outputPrefix = ""
            job.completionText += chunk
            DispatchQueue.main.async { job.onText(chunk) }
        }
    }

    private func finishIfReady(_ job: Job) {
        guard active === job, job.exited, job.outputEnded, job.errorsEnded else { return }
        active = nil
        job.process.terminationHandler = nil
        let diagnostics = String(decoding: job.stderr, as: UTF8.self)
        func number(_ pattern: String) -> Double? {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: diagnostics,
                    range: NSRange(diagnostics.startIndex..., in: diagnostics)),
                  let range = Range(match.range(at: 1), in: diagnostics) else { return nil }
            return Double(diagnostics[range])
        }
        let milliseconds = number("(?<!prompt )eval time\\s*=\\s*([\\d.]+)\\s*ms")
        let steps = number("(?<!prompt )eval time\\s*=\\s*[\\d.]+\\s*ms\\s*/\\s*(\\d+)\\s*runs")
        let speed: Double?
        if let ms = milliseconds, let count = steps, ms > 0 { speed = count * 1000 / ms }
        else { speed = nil }
        let contextFull = diagnostics.range(of: "prompt is too long", options: .caseInsensitive) != nil
            || diagnostics.range(of: "context full", options: .caseInsensitive) != nil
        let incomplete = job.hasVisibleText && job.profile != .bonsai
            && job.profile.finalAnswer(job.completionText).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let failure = job.failure ?? (contextFull ? "context_full"
            : (incomplete ? "incomplete_result"
                : (job.status != 0 ? "process_failed" : (job.hasVisibleText ? nil : "empty_result"))))
        let result = GenerationResult(elapsed: Date().timeIntervalSince(job.started),
                                      tokensPerSecond: speed, failure: failure, stopped: job.stopped)
        // This adapter has no verified complete token receipt. Keep its
        // output bound held rather than deriving tokens from visible text.
        if let work = job.episodeWork { _ = try? job.episodeLease?.settle(work, outcome: .outcomeUnknown) }
        job.stderr.removeAll(keepingCapacity: false)
        job.completionText.removeAll(keepingCapacity: false)
        DispatchQueue.main.async { job.onComplete(result) }
    }
}
