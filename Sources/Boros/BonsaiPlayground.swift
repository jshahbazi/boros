import AppKit
import Darwin
import Foundation

// The document grows inside its clip view; it must not supply a preferred
// height to the surrounding window or stack view.
private final class BoundedScrollView: NSScrollView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

private final class DraftTextView: NSTextView {
    private let edits = UndoManager()
    override var undoManager: UndoManager? { edits }
}

private final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSTextViewDelegate, NSTextFieldDelegate {
    private struct ChatSession {
        let conversation: Conversation
        let transcript: NSAttributedString
        let draft: String
        let modelPath: String
        let context: String
        let maximumOutput: String
        let thinkingEnabled: Bool
        let thinkingBudget: String
        let samplingPreset: SamplingPreset
        let temperature: Double
    }

    private let runner = ModelRunner()
    private var window: NSWindow!
    private var promptView: NSTextView!
    private var responseView: NSTextView!
    private let status = NSTextField(labelWithString: "Ready. Follow-ups include this conversation.")
    private let systemEditor = SystemPromptEditor(text: "Be helpful, concise, and accurate.")
    private let modelField = NSTextField(string: "")
    private let modelSelector = NSPopUpButton(frame: .zero, pullsDown: false)
    private let conversationSelector = NSPopUpButton(frame: .zero, pullsDown: false)
    private let endpointField = NSTextField(string: "http://localhost:11234/v1/")
    private let servedModelField = NSTextField(string: "ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit")
    private let keyField = NSSecureTextField(string: "")
    private let endpointTokenLimit = NSTextField(string: "32768")
    private let memoryButton = NSButton(title: "Search Memory", target: nil, action: nil)
    private var credentialOrigin: String?
    private var store: MemoryStore?
    private var semanticIndex: SemanticIndex?
    private var archiveOperationInProgress = false
    private var storedChats: [StoredConversation] = []
    private var activeChat: StoredConversation?
    private var memoryBrowser: MemoryBrowser?
    private var preferences = LocalSettings()
    private let projectID = "default"
    private var pendingTurnID = ""
    private var pendingHumanID = ""
    private var pendingAssistantID = ""
    private var pendingInvocationID = ""
    private var pendingChunkSequence = 0
    private var pendingCaptureFailure = false
    private var pendingInvocationStarted = false
    private var pendingRequestBody: Data?
    private var pendingProviderIdentity = ""
    private var pendingAdmission: ProviderAdmissionOperation?
    private var pendingContextSnapshot: ContextSnapshot?
    private var pendingAdmissionAccounting: [ProviderAdmissionAccounting] = []
    private var pendingAdmissionReceipt: EndpointAdmissionReceipt?
    private var pendingNativeConfiguration: Data?
    private var pendingEpisode: EpisodeLease?
    private var pendingAnswerWork: EpisodeWorkRecord?
    private var preparingContext = false
    private let preparationQueue = DispatchQueue(label: "Boros.episode.preparation", qos: .userInitiated)
    private var restoringDraft = false
    private var draftValidationFailed = false
    private var memoryHealthy = false
    private var dataDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["BOROS_DATA_DIR"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Boros", isDirectory: true)
    }
    private let runtimeField = NSTextField(string: defaultRuntimePath)
    private let seedField = NSTextField(string: "42")
    private let temperature = NSSlider(value: 0.2, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let temperatureValue = NSTextField(labelWithString: "0.20")
    private let context = NSPopUpButton(frame: .zero, pullsDown: false)
    private let maximumOutput = NSPopUpButton(frame: .zero, pullsDown: false)
    private let thinking = NSButton(checkboxWithTitle: "Think before answering", target: nil, action: nil)
    private let thinkingBudget = NSPopUpButton(frame: .zero, pullsDown: false)
    private let thinkingHint = NSTextField(labelWithString: "")
    private let samplingPreset = NSPopUpButton(frame: .zero, pullsDown: false)
    private let samplingHint = NSTextField(labelWithString: "")
    private let send = NSButton(title: "Send", target: nil, action: nil)
    private let stop = NSButton(title: "Stop", target: nil, action: nil)
    private let clear = NSButton(title: "New Chat", target: nil, action: nil)
    private let settingsToggle = NSButton(checkboxWithTitle: "Show settings", target: nil, action: nil)
    private var settingsPanel: NSStackView!
    private var nativeFileRows: [NSView] = []
    private var settingsControls: [NSControl] = []
    private var generating = false
    private var quitting = false
    private var timer: Timer?
    private var started = Date()
    private var conversation = Conversation()
    private var pendingPrompt = ""
    private var pendingResponse = ""
    private var preparedSendObserverForChecks: ((ContextSnapshot) -> Void)?
    private var selectedProfile = ModelProfile.customLocal
    private var sessions: [ModelProfile: ChatSession] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        initializeMemory()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Boros — Local Chat"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentMinSize = NSSize(width: 760, height: 620)
        let content = window.contentView!
        let explanation = NSTextField(labelWithString: "Durable local chats and exact source search. Project: default. Local API requests include bounded history.")
        explanation.textColor = .secondaryLabelColor
        modelSelector.addItems(withTitles: ModelProfile.selectableProfiles.map { $0.displayName })
        modelSelector.target = self
        modelSelector.action = #selector(selectModel)
        modelSelector.toolTip = "Use the running local API or a legacy GGUF model."
        modelSelector.selectItem(at: ModelProfile.selectableProfiles.firstIndex(of: selectedProfile) ?? 0)
        let modelSelection = row([label("Model"), modelSelector])
        conversationSelector.target = self; conversationSelector.action = #selector(selectConversation)
        memoryButton.target = self; memoryButton.action = #selector(showMemory)
        let chatSelection = row([label("Project: default"), conversationSelector, memoryButton])
        let conversationLabel = label("Conversation")
        let responseScroll = textArea(editable: false)
        responseView = responseScroll.documentView as? NSTextView
        let composer = NSStackView()
        composer.orientation = .vertical
        composer.alignment = .leading
        composer.spacing = 8
        composer.detachesHiddenViews = true
        settingsToggle.target = self; settingsToggle.action = #selector(toggleSettings)
        composer.addArrangedSubview(settingsToggle)
        settingsPanel = makeSettings()
        composer.addArrangedSubview(settingsPanel)
        settingsPanel.widthAnchor.constraint(equalTo: composer.widthAnchor).isActive = true
        settingsPanel.isHidden = true
        composer.addArrangedSubview(label("Message"))
        let promptScroll = textArea(editable: true)
        promptView = promptScroll.documentView as? NSTextView
        promptView.delegate = self
        composer.addArrangedSubview(promptScroll)
        promptScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        promptScroll.widthAnchor.constraint(equalTo: composer.widthAnchor).isActive = true
        send.target = self; send.action = #selector(sendPrompt)
        send.bezelStyle = .rounded; send.keyEquivalent = "\r"; send.keyEquivalentModifierMask = [.command]
        stop.target = self; stop.action = #selector(stopGeneration)
        stop.bezelStyle = .rounded; stop.keyEquivalent = "\u{1b}"; stop.keyEquivalentModifierMask = []
        stop.isEnabled = false
        clear.target = self; clear.action = #selector(clearPrompt)
        clear.bezelStyle = .rounded; clear.keyEquivalent = "n"; clear.keyEquivalentModifierMask = [.command]
        let buttons = row([send, stop, clear])
        composer.addArrangedSubview(buttons)
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        composer.addArrangedSubview(status)
        for view in [explanation, modelSelection, chatSelection, conversationLabel, responseScroll, composer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18).isActive = true
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18).isActive = true
        }
        NSLayoutConstraint.activate([
            explanation.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            modelSelection.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 10),
            chatSelection.topAnchor.constraint(equalTo: modelSelection.bottomAnchor, constant: 10),
            conversationLabel.topAnchor.constraint(equalTo: chatSelection.bottomAnchor, constant: 10),
            responseScroll.topAnchor.constraint(equalTo: conversationLabel.bottomAnchor, constant: 6),
            responseScroll.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -14),
            responseScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            composer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
        restoreActiveConversation()
        window.center()
        window.makeFirstResponder(promptView)
        if !CommandLine.arguments.contains("--ui-self-test") {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private func label(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        return field
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        return stack
    }

    private func textArea(editable: Bool) -> NSScrollView {
        let scroll = BoundedScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder
        let frame = NSRect(x: 0, y: 0, width: 800, height: 120)
        let text: NSTextView = editable ? DraftTextView(frame: frame) : NSTextView(frame: frame)
        text.isEditable = editable
        text.isSelectable = true
        text.isRichText = false
        text.allowsUndo = editable
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        return scroll
    }

    private func makeSettings() -> NSStackView {
        let panel = NSStackView()
        panel.orientation = .vertical
        panel.detachesHiddenViews = true
        panel.alignment = .leading
        panel.spacing = 8
        let systemRow = row([label("System"), systemEditor])
        panel.addArrangedSubview(systemRow)
        systemRow.widthAnchor.constraint(equalTo: panel.widthAnchor).isActive = true
        temperature.target = self; temperature.action = #selector(updateTemperature)
        temperature.widthAnchor.constraint(equalToConstant: 140).isActive = true
        temperatureValue.widthAnchor.constraint(equalToConstant: 35).isActive = true
        configureTokenControls(for: selectedProfile)
        context.target = self; context.action = #selector(contextBudgetChanged)
        maximumOutput.target = self; maximumOutput.action = #selector(responseBudgetChanged)
        context.toolTip = "GGUF runtime token capacity. The local API has a separate verified token budget below."
        maximumOutput.toolTip = "Maximum generated tokens, including thinking and the final answer."
        runtimeField.toolTip = "Choose llama-completion. The other models also require the sibling llama-server executable in this directory."
        thinking.target = self; thinking.action = #selector(thinkingChanged)
        thinkingBudget.target = self; thinkingBudget.action = #selector(thinkingBudgetChanged)
        thinkingBudget.toolTip = "Maximum thinking tokens. The runtime then continues the final answer within Max response. A lower response limit also reduces this limit to leave room for the answer."
        samplingPreset.target = self; samplingPreset.action = #selector(samplingPresetChanged)
        samplingPreset.toolTip = "Model-specific sampling. Coding uses Qwen's recommended settings for precise coding and enables thinking."
        for hint in [thinkingHint, samplingHint] {
            hint.font = .systemFont(ofSize: 11)
            hint.textColor = .secondaryLabelColor
        }
        seedField.widthAnchor.constraint(equalToConstant: 65).isActive = true
        panel.addArrangedSubview(row([label("Temperature"), temperature, temperatureValue,
                                     label("Context"), context, label("Max response"), maximumOutput,
                                     label("Seed"), seedField]))
        panel.addArrangedSubview(row([thinking, label("Thinking limit"), thinkingBudget, thinkingHint]))
        panel.addArrangedSubview(row([label("Sampling"), samplingPreset, samplingHint]))
        configureReasoningControls(for: selectedProfile)
        let modelBrowse = NSButton(title: "Choose…", target: self, action: #selector(chooseModel))
        let runtimeBrowse = NSButton(title: "Choose…", target: self, action: #selector(chooseRuntime))
        let modelRow = row([label("Model file"), modelField, modelBrowse])
        let runtimeRow = row([label("Runtime"), runtimeField, runtimeBrowse])
        panel.addArrangedSubview(modelRow)
        panel.addArrangedSubview(runtimeRow)
        nativeFileRows = [modelRow, runtimeRow]
        for view in nativeFileRows { view.isHidden = selectedProfile == .customLocal }
        modelRow.widthAnchor.constraint(equalTo: panel.widthAnchor).isActive = true
        runtimeRow.widthAnchor.constraint(equalTo: panel.widthAnchor).isActive = true
        systemEditor.setContentHuggingPriority(.defaultLow, for: .horizontal)
        modelField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        runtimeField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for field in [modelField, runtimeField] {
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.lineBreakMode = .byTruncatingMiddle
        }
        settingsControls = [modelField, runtimeField, seedField, temperature,
                            context, maximumOutput, thinking, thinkingBudget, samplingPreset, modelBrowse, runtimeBrowse]
        endpointField.delegate = self
        servedModelField.delegate = self
        endpointField.stringValue = preferences.endpointURL
        servedModelField.stringValue = preferences.endpointModel
        endpointTokenLimit.stringValue = String(preferences.endpointTokenBudget ?? 32768)
        endpointField.placeholderString = "http://localhost:11234/v1/"
        servedModelField.placeholderString = "Served model ID from /v1/models"
        keyField.placeholderString = "Optional API key · stored in macOS Keychain"
        let saveEndpoint = NSButton(title: "Save API settings", target: self, action: #selector(saveAPISettings))
        let endpointRow = row([label("API address"), endpointField])
        let servedRow = row([label("Served model"), servedModelField])
        let keyRow = row([label("API key"), keyField, saveEndpoint])
        endpointTokenLimit.toolTip = "Maximum total prompt and response tokens. Admission also respects the server's current safe capacity and reserves a safety margin."
        let tokenRow = row([label("API token budget"), endpointTokenLimit])
        for item in [endpointRow, servedRow, keyRow, tokenRow] {
            panel.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: panel.widthAnchor).isActive = true
        }
        for field in [endpointField, servedModelField, keyField] { field.setContentHuggingPriority(.defaultLow, for: .horizontal) }
        settingsControls += [endpointField, servedModelField, keyField, endpointTokenLimit, saveEndpoint]
        if !CommandLine.arguments.contains("--ui-self-test") { reloadCredential() }
        else { credentialOrigin = try? LocalCredentialStore.origin(for: endpointField.stringValue) }
        modelField.stringValue = selectedProfile.defaultModelPath
        refreshReasoningControls()
        return panel
    }

    @objc private func updateTemperature() {
        temperatureValue.stringValue = String(format: "%.2f", temperature.doubleValue)
    }

    private var selectedSamplingPreset: SamplingPreset {
        let index = samplingPreset.indexOfSelectedItem
        return selectedProfile.samplingPresets.indices.contains(index) ? selectedProfile.samplingPresets[index] : .recommended
    }

    private var usesQwenMLXThinkingToggle: Bool {
        selectedProfile == .customLocal
            && servedModelField.stringValue == "ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit"
    }

    private var requestedThinkingEnabled: Bool {
        (selectedProfile.supportsThinking || usesQwenMLXThinkingToggle) && thinking.state == .on
    }

    private func configureReasoningControls(for profile: ModelProfile, session: ChatSession? = nil) {
        thinking.state = (session?.thinkingEnabled ?? profile.defaultThinkingEnabled) ? .on : .off
        thinkingBudget.removeAllItems()
        thinkingBudget.addItems(withTitles: profile.thinkingBudgets.map(String.init))
        if !profile.supportsThinking { thinkingBudget.addItem(withTitle: "—") }
        thinkingBudget.selectItem(withTitle: session?.thinkingBudget ?? String(profile.defaultThinkingBudget))
        samplingPreset.removeAllItems()
        samplingPreset.addItems(withTitles: profile.samplingPresets.map { $0.displayName })
        samplingPreset.selectItem(at: profile.samplingPresets.firstIndex(of: session?.samplingPreset ?? .recommended) ?? 0)
        temperature.doubleValue = session?.temperature ?? profile.sampling(preset: selectedSamplingPreset, thinking: thinking.state == .on).temperature
        updateTemperature()
        refreshReasoningControls()
    }

    private func refreshReasoningControls() {
        let isAPI = selectedProfile == .customLocal
        if isAPI && !usesQwenMLXThinkingToggle { thinking.state = .off }
        thinking.title = isAPI ? "Request thinking" : "Think before answering"
        thinking.isEnabled = !generating && (selectedProfile.supportsThinkingToggle || usesQwenMLXThinkingToggle)
        thinkingBudget.isEnabled = !generating && selectedProfile.supportsThinking && thinking.state == .on
        samplingPreset.isEnabled = !generating && !isAPI
        context.isEnabled = !generating && !isAPI
        if isAPI { thinkingHint.stringValue = "Qwen mlx-serve uses this toggle; other API models use server defaults." }
        else if !selectedProfile.supportsThinking { thinkingHint.stringValue = "This model answers directly." }
        else if thinking.state == .off { thinkingHint.stringValue = "Direct answers. Thinking is off." }
        else {
            let output = Int(maximumOutput.titleOfSelectedItem ?? "512") ?? 512
            let requested = Int(thinkingBudget.titleOfSelectedItem ?? "0") ?? 0
            let effective = min(requested, max(0, output - min(512, output / 2)))
            let suffix = selectedProfile.supportsThinkingToggle ? "" : " · thinking-only model"
            thinkingHint.stringValue = "Up to \(effective) thinking tokens\(suffix)"
        }
        let sample = selectedProfile.sampling(preset: selectedSamplingPreset, thinking: thinking.state == .on)
        samplingHint.stringValue = isAPI ? "API sends temperature and output cap; other sampling uses server defaults."
            : String(format: "Top k %d · Top p %.2f · Min p %.2f · Presence %.1f · Repeat %.2f", sample.topK, sample.topP, sample.minP, sample.presencePenalty, sample.repetitionPenalty)
    }

    @objc private func thinkingChanged() {
        guard !generating, selectedProfile.supportsThinkingToggle || usesQwenMLXThinkingToggle else { return }
        if selectedProfile == .customLocal { refreshReasoningControls(); return }
        if thinking.state == .off { samplingPreset.selectItem(at: 0) }
        temperature.doubleValue = selectedProfile.sampling(preset: selectedSamplingPreset, thinking: thinking.state == .on).temperature
        updateTemperature()
        refreshReasoningControls()
    }

    @objc private func thinkingBudgetChanged() { refreshReasoningControls() }

    @objc private func samplingPresetChanged() {
        guard !generating else { return }
        if selectedSamplingPreset == .coding { thinking.state = .on }
        temperature.doubleValue = selectedProfile.sampling(preset: selectedSamplingPreset, thinking: thinking.state == .on).temperature
        updateTemperature()
        refreshReasoningControls()
    }

    private func configureTokenControls(for profile: ModelProfile, savedContext: String? = nil,
                                        savedOutput: String? = nil) {
        context.removeAllItems()
        context.addItems(withTitles: profile.contextSizes.map(String.init))
        context.selectItem(withTitle: savedContext ?? String(profile.defaultContext))
        maximumOutput.removeAllItems()
        maximumOutput.addItems(withTitles: profile.maximumOutputs.map(String.init))
        maximumOutput.selectItem(withTitle: savedOutput ?? String(profile.defaultMaximumOutput))
    }

    @objc private func responseBudgetChanged() {
        defer { refreshReasoningControls() }
        guard !generating, selectedProfile.isQwen,
              let output = Int(maximumOutput.titleOfSelectedItem ?? ""),
              let current = Int(context.titleOfSelectedItem ?? "") else { return }
        // Leave room for conversation when the requested response grows.
        let required = output + (selectedProfile.isQwen35 ? 8192 : 2048)
        if current < required, let larger = selectedProfile.contextSizes.first(where: { $0 >= required }) {
            context.selectItem(withTitle: String(larger))
        }
    }

    @objc private func contextBudgetChanged() {
        defer { refreshReasoningControls() }
        guard !generating, selectedProfile.isQwen,
              let current = Int(context.titleOfSelectedItem ?? ""),
              let output = Int(maximumOutput.titleOfSelectedItem ?? "") else { return }
        if output > current - 512,
           let smaller = selectedProfile.maximumOutputs.last(where: { $0 <= current - 512 }) {
            maximumOutput.selectItem(withTitle: String(smaller))
        }
    }

    @objc private func toggleSettings() {
        let visible = settingsToggle.state == .on
        settingsPanel.isHidden = !visible
        window.contentMinSize = NSSize(width: 760, height: visible ? 840 : 620)
        if visible && window.contentView!.bounds.height < 840 {
            var frame = window.frame
            let addition = 840 - window.contentView!.bounds.height
            frame.origin.y -= addition
            frame.size.height += addition
            window.setFrame(frame, display: true, animate: true)
        }
    }

    @objc private func chooseModel() { chooseFile(for: modelField) }
    @objc private func chooseRuntime() { chooseFile(for: runtimeField) }

    @objc private func selectModel() {
        guard !generating, ModelProfile.selectableProfiles.indices.contains(modelSelector.indexOfSelectedItem) else { return }
        let profile = ModelProfile.selectableProfiles[modelSelector.indexOfSelectedItem]
        guard profile != selectedProfile else { return }
        selectedProfile = profile
        for view in nativeFileRows { view.isHidden = profile == .customLocal }
        modelField.stringValue = profile.defaultModelPath
        configureTokenControls(for: profile)
        configureReasoningControls(for: profile)
        preferences.profile = profile.rawValue
        savePreferences()
        status.stringValue = "Ready. " + profile.speakerName + " selected for this conversation."
        window.makeFirstResponder(promptView)
    }

    private func initializeMemory() {
        do {
            let memory = try MemoryStore(directory: dataDirectory)
            store = memory
            semanticIndex = try? SemanticIndex(store: memory)
            if !CommandLine.arguments.contains("--ui-self-test") { semanticIndex?.schedule(projectID: projectID) }
            preferences = LocalSettings.load(in: memory.directory)
            selectedProfile = ModelProfile(rawValue: preferences.profile) ?? .customLocal
            storedChats = try memory.listConversations(projectID: projectID)
            activeChat = storedChats.first(where: { $0.id == preferences.conversationID }) ?? storedChats.first
            if activeChat == nil { activeChat = try memory.createConversation(projectID: projectID, title: "Chat 1") }
            preferences.conversationID = activeChat?.id
            try preferences.save(in: memory.directory)
            memoryHealthy = true
        } catch {
            memoryHealthy = false
            status.stringValue = "The local memory store could not be opened. Close other Boros processes and check its data directory."
        }
    }

    private func savePreferences() {
        guard let store else { return }
        do { try preferences.save(in: store.directory) }
        catch { memoryHealthy = false; status.stringValue = "Settings could not be saved. Check the local data directory." }
    }

    private func restoreActiveConversation() {
        guard let store, let activeChat else { send.isEnabled = false; clear.isEnabled = false; return }
        do {
            storedChats = try store.listConversations(projectID: projectID)
            conversationSelector.removeAllItems()
            conversationSelector.addItems(withTitles: storedChats.map { "\($0.title) · \(String($0.id.prefix(8)))" })
            conversationSelector.selectItem(at: storedChats.firstIndex(where: { $0.id == activeChat.id }) ?? 0)
            responseView.string = ""
            conversation.reset()
            for event in try store.events(conversationID: activeChat.id) {
                let speaker = event.role == .human ? "You" : "Assistant · " + event.status.rawValue
                appendTranscript(speaker + " · " + event.id, body: event.text.isEmpty ? "[No output captured]" : event.text)
            }
            restoringDraft = true
            replaceDraft(try store.loadDraft(conversationID: activeChat.id))
            restoringDraft = false
            draftValidationFailed = false
            send.isEnabled = !generating && memoryHealthy
            promptView.undoManager?.removeAllActions()
            status.stringValue = "Ready. Restored \(activeChat.title) from local memory."
        } catch {
            restoringDraft = false; memoryHealthy = false; send.isEnabled = false
            status.stringValue = "Conversation could not be restored. Check the local memory store."
        }
    }

    @objc private func selectConversation() {
        guard !generating, !draftValidationFailed, storedChats.indices.contains(conversationSelector.indexOfSelectedItem) else { return }
        persistDraft()
        activeChat = storedChats[conversationSelector.indexOfSelectedItem]
        preferences.conversationID = activeChat?.id
        savePreferences(); restoreActiveConversation()
    }

    @objc private func showMemory() {
        guard let store else { return }
        if memoryBrowser == nil { memoryBrowser = MemoryBrowser(store: store, projectID: projectID) }
        memoryBrowser?.show()
    }

    @objc private func createBackup() {
        guard let store, memoryHealthy, !archiveOperationInProgress else { return }
        persistDraft()
        guard memoryHealthy else { return }
        let panel = NSSavePanel()
        panel.title = "Create Boros Backup"
        panel.nameFieldStringValue = "Boros-" + String(Int(Date().timeIntervalSince1970)) + ".borosbackup"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else { return }
            self.runArchiveOperation(success: "Backup created and verified.") {
                _ = try BackupArchive.create(from: store, at: destination)
            }
        }
    }

    @objc private func restoreBackup() {
        guard memoryHealthy, !archiveOperationInProgress else { return }
        let source = NSOpenPanel()
        source.title = "Choose Boros Backup"
        source.canChooseFiles = false; source.canChooseDirectories = true
        source.allowsMultipleSelection = false; source.treatsFilePackagesAsDirectories = true
        source.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let archive = source.url else { return }
            let destination = NSSavePanel()
            destination.title = "Restore Backup to a New Folder"
            destination.nameFieldStringValue = "Boros-Restored-" + String(Int(Date().timeIntervalSince1970))
            destination.canCreateDirectories = true
            destination.beginSheetModal(for: self.window) { [weak self] response in
                guard let self, response == .OK, let folder = destination.url else { return }
                self.runArchiveOperation(success: "Restored a separate archive copy in the selected folder.") {
                    _ = try BackupArchive.restore(from: archive, to: folder, authority: .unmanagedNoDeletion)
                }
            }
        }
    }

    private func runArchiveOperation(success: String, operation: @escaping () throws -> Void) {
        guard !archiveOperationInProgress else { return }
        archiveOperationInProgress = true
        status.stringValue = "Verifying archive operation…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let message: String
            do { try operation(); message = success }
            catch BackupError.publicationDurabilityUnknown {
                message = "The verified folder was published; directory sync failed and its durability is unknown."
            } catch {
                message = "Archive operation failed. Use a new folder in an existing local directory and check archive integrity."
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.archiveOperationInProgress = false
                self.status.stringValue = message
            }
        }
    }

    private func persistDraft() {
        guard !restoringDraft, let store, let activeChat, promptView != nil else { return }
        do {
            try store.saveDraft(conversationID: activeChat.id, text: promptView.string)
            send.isEnabled = !generating && memoryHealthy
            clear.isEnabled = !generating
            conversationSelector.isEnabled = !generating
            if draftValidationFailed { status.stringValue = "Ready. Draft is within the 4 MiB capture limit." }
            draftValidationFailed = false
        }
        catch MemoryError.invalid(_) {
            draftValidationFailed = true
            send.isEnabled = false
            clear.isEnabled = false
            conversationSelector.isEnabled = false
            status.stringValue = "Draft exceeds the 4 MiB capture limit. Shorten it to save and send it."
        }
        catch { memoryHealthy = false; send.isEnabled = false; status.stringValue = "Draft could not be saved. Check the local store." }
    }

    func textDidChange(_ notification: Notification) {
        if let view = notification.object as? NSTextView, view === promptView { persistDraft() }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField, field === endpointField { reloadCredential() }
        if let field = notification.object as? NSTextField, field === servedModelField { refreshReasoningControls() }
    }

    private func reloadCredential() {
        let newOrigin = try? LocalCredentialStore.origin(for: endpointField.stringValue)
        guard newOrigin != credentialOrigin else { return }
        credentialOrigin = newOrigin; keyField.stringValue = ""
        guard newOrigin != nil, !CommandLine.arguments.contains("--ui-self-test") else { return }
        do { keyField.stringValue = try LocalCredentialStore.read(for: endpointField.stringValue) }
        catch { status.stringValue = "The API key could not be read from Keychain. Enter a key and save API settings if required." }
    }

    @objc private func saveAPISettings() {
        do {
            let origin = try LocalCredentialStore.origin(for: endpointField.stringValue)
            guard origin == credentialOrigin else { reloadCredential(); status.stringValue = "Address changed. Enter this server's API key, then save its settings."; return }
            guard !servedModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                status.stringValue = "Enter the served model ID listed by the local API."; return
            }
            if !CommandLine.arguments.contains("--ui-self-test") { try LocalCredentialStore.write(keyField.stringValue, for: endpointField.stringValue) }
            preferences.endpointURL = endpointField.stringValue
            preferences.endpointModel = servedModelField.stringValue
            guard let budget = Int(endpointTokenLimit.stringValue), budget > 0, budget <= 262144 else {
                status.stringValue = "API token budget must be an integer between 1 and 262144."; return
            }
            preferences.endpointTokenBudget = budget
            savePreferences()
            if memoryHealthy { status.stringValue = "API settings saved. Credentials use macOS Keychain." }
        } catch { status.stringValue = "API settings could not be saved. Use a loopback HTTP address and an available Keychain." }
    }

    private func chooseFile(for field: NSTextField) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { field.stringValue = url.path }
        }
    }

    @objc private func sendPrompt() {
        guard !generating, memoryHealthy, let store, let activeChat else { return }
        let prompt = promptView.string
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status.stringValue = "Enter a prompt first."
            window.makeFirstResponder(promptView)
            return
        }
        guard let seed = Int(seedField.stringValue.trimmingCharacters(in: .whitespaces)),
              seed >= 0, seed <= Int(UInt32.max) else {
            status.stringValue = "Seed must be an integer between 0 and 4294967295."
            return
        }
        var settings = GenerationSettings()
        settings.profile = selectedProfile
        settings.model = modelField.stringValue
        settings.runtime = runtimeField.stringValue
        settings.system = systemEditor.string
        settings.temperature = temperature.doubleValue
        settings.context = Int(context.titleOfSelectedItem ?? "2048") ?? 2048
        settings.maximumOutput = Int(maximumOutput.titleOfSelectedItem ?? "512") ?? 512
        settings.thinkingEnabled = requestedThinkingEnabled
        settings.thinkingBudget = Int(thinkingBudget.titleOfSelectedItem ?? "0") ?? 0
        settings.samplingPreset = selectedSamplingPreset
        settings.seed = seed
        settings.endpointURL = endpointField.stringValue
        settings.endpointModel = servedModelField.stringValue
        if selectedProfile == .customLocal {
            guard let origin = try? LocalCredentialStore.origin(for: settings.endpointURL), origin == credentialOrigin else {
                reloadCredential(); status.stringValue = "Check the API address and its server-specific credentials."; return
            }
            guard !settings.endpointModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status.stringValue = "Enter the served model ID in Settings."; return }
            settings.endpointAPIKey = keyField.stringValue
            guard let cap = Int(endpointTokenLimit.stringValue), cap > 0, cap <= 262144 else {
                status.stringValue = "API token budget must be an integer between 1 and 262144."; return
            }
            settings.endpointContextLimit = cap
        }
        let turnID = UUID().uuidString
        let humanID = UUID().uuidString
        let assistantID = UUID().uuidString
        let invocationID = UUID().uuidString
        let clock = SystemEpisodeClock()
        let episodeID = UUID().uuidString
        let lease = EpisodeLease(ledger: store, episodeID: episodeID, clock: clock)
        do {
            _ = try store.acceptRequestAndBeginEpisode(conversationID: activeChat.id, turnID: turnID,
                humanEventID: humanID, episodeID: episodeID, text: prompt,
                limits: EpisodeLimits(), clock: clock.now())
            settings.episodeLease = lease
            // Synthetic preparation checks keep their synchronous observation;
            // ordinary Send prepares on the coordinator queue below.
            if CommandLine.arguments.contains("--ui-self-test"), let observe = preparedSendObserverForChecks {
                let snapshot = try ChatContextPreparation.prepare(store: store, conversationID: activeChat.id,
                    projectID: projectID, prompt: prompt, system: settings.system, excludingEventID: humanID,
                    semanticIndex: semanticIndex, episodeLease: lease)
                observe(snapshot)
                _ = try lease.finish(reason: .cancelled)
                return
            }
            try store.saveDraft(conversationID: activeChat.id, text: "")
            if selectedProfile == .customLocal {
                preferences.endpointURL = settings.endpointURL
                preferences.endpointModel = settings.endpointModel
                preferences.endpointTokenBudget = settings.endpointContextLimit
            }
            preferences.profile = selectedProfile.rawValue
            try preferences.save(in: store.directory)
        } catch {
            _ = try? lease.finish(reason: .failed)
            restoreActiveConversation()
            status.stringValue = "The request could not be accepted or prepared. Check its size and local store."
            return
        }
        pendingTurnID = turnID; pendingHumanID = humanID; pendingAssistantID = assistantID
        pendingInvocationID = invocationID; pendingChunkSequence = 0; pendingCaptureFailure = false
        pendingInvocationStarted = false; pendingRequestBody = nil; pendingProviderIdentity = ""
        pendingAdmissionAccounting = []; pendingAdmissionReceipt = nil
        pendingContextSnapshot = nil; pendingNativeConfiguration = nil
        pendingEpisode = lease; pendingAnswerWork = nil; preparingContext = true
        pendingPrompt = prompt; pendingResponse = ""
        appendTranscript("You", body: prompt)
        appendTranscript(selectedProfile.speakerName, body: "")
        replaceDraft("")
        setGenerating(true)
        started = Date()
        status.stringValue = "Preparing context…"
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, self.generating else { return }
            do { _ = try self.pendingEpisode?.checkActive() }
            catch {
                let failure = (error as? EpisodeBudgetError)?.failureCode ?? "episode_accounting_failed"
                self.endActiveEpisode(reason: failure == "episode_deadline_exceeded" ? .deadlineExceeded : .failed,
                    failure: failure, stopped: false)
                return
            }
            if !self.pendingCaptureFailure {
                let stage = self.preparingContext ? "Preparing context" : self.pendingInvocationStarted ? "Generating" : "Checking token budget"
                self.status.stringValue = String(format: "%@ · %.1f s", stage, Date().timeIntervalSince(self.started))
            }
        }
        let frozenSettings = settings
        let frozenConversation = conversation
        let index = semanticIndex
        let scope = projectID
        preparationQueue.async { [weak self] in
            let outcome: Result<PreparedEpisodeContext, Error>
            do {
                _ = try lease.checkActive()
                let snapshot = try ChatContextPreparation.prepare(store: store, conversationID: activeChat.id,
                    projectID: scope, prompt: prompt, system: frozenSettings.system, excludingEventID: humanID,
                    semanticIndex: index, episodeLease: lease)
                var preparedSettings = frozenSettings
                preparedSettings.messagesOverride = snapshot.messages.map { ["role": $0.role, "content": $0.content] }
                let body: Data
                let provider: String
                var nativeConfiguration: Data?
                if preparedSettings.profile == .customLocal {
                    body = try EndpointRequest.build(prompt: prompt, settings: preparedSettings, conversation: frozenConversation)
                    preparedSettings.preparedEndpointBody = body
                    guard let url = LocalEndpoint.chatURL(preparedSettings.endpointURL) else { throw MemoryError.invalid("local endpoint") }
                    provider = url.absoluteString
                } else {
                    body = preparedSettings.profile == .bonsai
                        ? try NativeRequest.completionEvidence(prompt: prompt, settings: preparedSettings, conversation: frozenConversation)
                        : try NativeRequest.reasoningBody(prompt: prompt, settings: preparedSettings, conversation: frozenConversation)
                    if preparedSettings.profile != .bonsai { preparedSettings.preparedNativeBody = body }
                    nativeConfiguration = try NativeRequest.configuration(settings: preparedSettings)
                    provider = "native:" + preparedSettings.profile.rawValue
                }
                _ = try lease.checkActive()
                outcome = .success(PreparedEpisodeContext(snapshot: snapshot, settings: preparedSettings,
                    body: body, provider: provider, nativeConfiguration: nativeConfiguration))
            } catch { outcome = .failure(error) }
            DispatchQueue.main.async {
                guard let self, self.generating, self.pendingInvocationID == invocationID else { return }
                self.preparingContext = false
                switch outcome {
                case .success(let prepared):
                    self.pendingContextSnapshot = prepared.snapshot
                    self.pendingRequestBody = prepared.body
                    self.pendingProviderIdentity = prepared.provider
                    self.pendingNativeConfiguration = prepared.nativeConfiguration
                    if prepared.settings.profile == .customLocal {
                        self.prepareEndpointAdmission(prompt: prompt, settings: prepared.settings, body: prepared.body)
                    } else { self.dispatchPreparedGeneration(prompt: prompt, settings: prepared.settings) }
                case .failure(let error):
                    self.completeGeneration(GenerationResult(elapsed: Date().timeIntervalSince(self.started),
                        tokensPerSecond: nil, failure: (error as? EpisodeBudgetError)?.failureCode ?? "context_preparation_failed", stopped: false))
                }
            }
        }
    }

    private struct PreparedEpisodeContext {
        let snapshot: ContextSnapshot
        let settings: GenerationSettings
        let body: Data
        let provider: String
        let nativeConfiguration: Data?
    }

    private func prepareEndpointAdmission(prompt: String, settings: GenerationSettings, body: Data) {
        let invocationID = pendingInvocationID
        pendingAdmission = ProviderAdmission.prepare(requestBody: body, address: settings.endpointURL,
            apiKey: settings.endpointAPIKey, contextLimit: settings.endpointContextLimit, safetyTokens: settings.endpointSafetyTokens,
            episodeLease: settings.episodeLease) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self, self.generating, self.pendingInvocationID == invocationID else { return }
                if let operation = self.pendingAdmission { self.pendingAdmissionAccounting.append(operation.accounting) }
                self.pendingAdmission = nil
                switch outcome {
                case .success(let receipt):
                    var admittedSettings = settings
                    admittedSettings.endpointAdmission = receipt
                    self.pendingAdmissionReceipt = receipt
                    self.dispatchPreparedGeneration(prompt: prompt, settings: admittedSettings)
                case .failure(let error):
                    if error.failureCode == "context_full", let snapshot = self.pendingContextSnapshot,
                       let reduced = try? snapshot.reducedForTokenAdmission() {
                        var reducedSettings = settings
                        reducedSettings.messagesOverride = reduced.messages.map { ["role": $0.role, "content": $0.content] }
                        if let reducedBody = try? EndpointRequest.build(prompt: prompt, settings: reducedSettings, conversation: self.conversation) {
                            reducedSettings.preparedEndpointBody = reducedBody
                            self.pendingContextSnapshot = reduced
                            self.pendingRequestBody = reducedBody
                            self.prepareEndpointAdmission(prompt: prompt, settings: reducedSettings, body: reducedBody)
                            return
                        }
                    }
                    self.completeGeneration(GenerationResult(elapsed: Date().timeIntervalSince(self.started), tokensPerSecond: nil,
                        failure: error.failureCode, stopped: false))
                }
            }
        }
    }

    private func dispatchPreparedGeneration(prompt: String, settings: GenerationSettings) {
        guard generating, let store, let activeChat, let body = pendingRequestBody, !pendingInvocationStarted else { return }
        var dispatchedSettings = settings
        do {
            if let lease = pendingEpisode {
                _ = try lease.checkActive()
                let input = settings.endpointAdmission?.promptTokens ?? 0
                let adapter = settings.endpointAdmission?.answerAdapterIdentity ?? ("native:" + settings.profile.rawValue)
                let work = try lease.prepare(kind: settings.profile == .customLocal ? .answer : .nativeInference,
                    resources: EpisodeResources(inputTokens: input, outputTokens: settings.maximumOutput,
                        modelCalls: 1, httpAttempts: settings.profile == .customLocal ? 1 : 0),
                    adapterIdentity: adapter, snapshot: body, inputTokensKnown: settings.profile == .customLocal)
                pendingAnswerWork = work
                dispatchedSettings.preparedAnswerWork = work
            }
            let admission = try admissionAudit()
            _ = try store.beginInvocation(invocationID: pendingInvocationID, conversationID: activeChat.id, turnID: pendingTurnID,
                humanEventID: pendingHumanID, assistantEventID: pendingAssistantID, providerIdentity: pendingProviderIdentity,
                requestBody: body, admissionJSON: admission, episodeID: pendingEpisode?.episodeID, episodeWorkID: pendingAnswerWork?.id)
            pendingInvocationStarted = true
        } catch {
            pendingCaptureFailure = !(error is EpisodeBudgetError)
            completeGeneration(GenerationResult(elapsed: 0, tokensPerSecond: nil, failure: (error as? EpisodeBudgetError)?.failureCode ?? "capture_failure", stopped: false))
            return
        }
        let invocationID = pendingInvocationID
        runner.start(prompt: prompt, settings: dispatchedSettings, conversation: conversation, onText: { [weak self] text in
            guard let self, self.pendingInvocationID == invocationID else { return }
            self.receiveGenerationText(text)
        }, onComplete: { [weak self] result in
            guard let self, self.pendingInvocationID == invocationID else { return }
            self.completeGeneration(result)
        })
    }

    private struct AdmissionAudit: Codable {
        let version: Int
        let receipt: EndpointAdmissionReceipt?
        let attempts: [ProviderAdmissionAccounting]
        let nativeConfiguration: Data?
        let context: Data?
    }

    private func admissionAudit() throws -> Data? {
        return try JSONEncoder().encode(AdmissionAudit(version: 2, receipt: pendingAdmissionReceipt,
            attempts: pendingAdmissionAccounting, nativeConfiguration: pendingNativeConfiguration,
            context: try pendingContextSnapshot?.deliveryAudit()))
    }

    private func receiveGenerationText(_ text: String) {
        guard generating, !pendingInvocationID.isEmpty, !pendingCaptureFailure, !text.isEmpty, let store else { return }
        do {
            _ = try pendingEpisode?.checkActive()
            // A visible delta is acknowledged only after its durable journal
            // commit. Failed capture cannot leave unsaved text in the transcript.
            _ = try store.appendInvocationChunk(invocationID: pendingInvocationID, sequence: pendingChunkSequence, text: text)
            pendingChunkSequence += 1
        } catch let error as EpisodeBudgetError {
            endActiveEpisode(reason: error == .deadlineExceeded ? .deadlineExceeded : .failed,
                failure: error.failureCode, stopped: false)
            return
        } catch {
            pendingCaptureFailure = true
            status.stringValue = "Response capture failed. Stopping; committed output will be recovered on restart."
            runner.cancel()
            return
        }
        let scroll = responseView.enclosingScrollView!
        let atBottom = scroll.contentView.bounds.maxY >= responseView.bounds.maxY - 24
        pendingResponse += text
        responseView.textStorage?.append(NSAttributedString(string: text, attributes: bodyAttributes))
        if atBottom { responseView.scrollRangeToVisible(NSRange(location: responseView.string.utf16.count, length: 0)) }
    }

    private func completeGeneration(_ result: GenerationResult) {
        guard !pendingAssistantID.isEmpty else { return }
        timer?.invalidate(); timer = nil
        var resolved = result
        if let lease = pendingEpisode {
            let terminal: EpisodeState = result.stopped ? .cancelled
                : result.failure == "episode_deadline_exceeded" ? .deadlineExceeded
                : result.failure == "episode_budget_exceeded" ? .budgetExceeded
                : result.failure != nil || pendingCaptureFailure || pendingResponse.isEmpty ? .failed : .completed
            do { resolved = result.reconcilingEpisodeState(try lease.finish(reason: terminal).state) }
            catch { memoryHealthy = false }
        }
        let hasAnswer = !selectedProfile.finalAnswer(pendingResponse).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let captureStatus: CaptureStatus = pendingCaptureFailure ? (pendingResponse.isEmpty ? .failed : .partial)
            : resolved.stopped ? (pendingResponse.isEmpty ? .cancelled : .partial)
            : resolved.failure != nil || pendingResponse.isEmpty ? (pendingResponse.isEmpty ? .failed : .partial) : .complete
        let reason: InvocationTerminalReason = pendingCaptureFailure ? .captureFailure
            : resolved.stopped ? .cancelled : resolved.failure == "incomplete_result" ? .upstreamIncomplete
            : !pendingInvocationStarted && resolved.failure != nil ? .admissionFailure
            : captureStatus == .complete ? .completed : .transportFailure
        if let store, !pendingInvocationID.isEmpty {
            do {
                if pendingEpisode == nil, !pendingInvocationStarted, let activeChat, let body = pendingRequestBody {
                    _ = try store.beginInvocation(invocationID: pendingInvocationID, conversationID: activeChat.id, turnID: pendingTurnID,
                        humanEventID: pendingHumanID, assistantEventID: pendingAssistantID, providerIdentity: pendingProviderIdentity, requestBody: body,
                        admissionJSON: try admissionAudit())
                    pendingInvocationStarted = true
                }
                let usage = try resolved.providerUsage.map { try JSONEncoder().encode($0) }
                if pendingInvocationStarted {
                    _ = try store.finalizeInvocation(invocationID: pendingInvocationID, status: captureStatus, reason: reason, usageJSON: usage)
                } else if let activeChat {
                    // A preparation-only failure has an episode but no model
                    // request snapshot. Preserve its empty terminal event.
                    _ = try store.append(conversationID: activeChat.id, role: .assistant, text: pendingResponse,
                        status: captureStatus, turnID: pendingTurnID, eventID: pendingAssistantID)
                }
                if !CommandLine.arguments.contains("--ui-self-test") { semanticIndex?.schedule(projectID: projectID) }
            } catch {
                memoryHealthy = false
                status.stringValue = "Response finalization failed. Restart Boros to recover its committed output."
            }
        }
        setGenerating(false)
        if memoryHealthy {
            status.stringValue = (pendingCaptureFailure ? "Response capture failed." : resolved.message) + " Captured as " + captureStatus.rawValue + "."
                + (pendingContextSnapshot?.retrievalNotice.map { " " + $0 } ?? "")
        }
        if !pendingCaptureFailure && (resolved.failure == nil || resolved.stopped) && hasAnswer && !pendingResponse.isEmpty {
            conversation.append(user: pendingPrompt, assistant: pendingResponse)
        } else { replaceDraft(pendingPrompt) }
        persistDraft()
        if resolved.failure != nil && (!resolved.stopped || resolved.failure == "incomplete_result") {
            responseView.textStorage?.append(NSAttributedString(string: "\n\n" + resolved.message))
        }
        responseView.textStorage?.append(NSAttributedString(string: "\n\n", attributes: bodyAttributes))
        pendingPrompt = ""; pendingResponse = ""; pendingTurnID = ""; pendingHumanID = ""; pendingAssistantID = ""
        pendingInvocationID = ""; pendingChunkSequence = 0; pendingCaptureFailure = false
        pendingInvocationStarted = false; pendingRequestBody = nil; pendingProviderIdentity = ""
        pendingAdmission = nil
        pendingContextSnapshot = nil
        pendingAdmissionAccounting = []; pendingAdmissionReceipt = nil
        pendingNativeConfiguration = nil
        pendingEpisode = nil; pendingAnswerWork = nil; preparingContext = false
        window.makeFirstResponder(promptView)
        if quitting { NSApplication.shared.reply(toApplicationShouldTerminate: true) }
    }

    private func setGenerating(_ value: Bool) {
        generating = value
        send.isEnabled = !value && memoryHealthy && !draftValidationFailed
        clear.isEnabled = !value && !draftValidationFailed
        stop.isEnabled = value
        modelSelector.isEnabled = !value
        conversationSelector.isEnabled = !value && !draftValidationFailed
        promptView.isEditable = !value
        systemEditor.isEditable = !value
        for control in settingsControls { control.isEnabled = !value }
        refreshReasoningControls()
    }

    private func endActiveEpisode(reason: EpisodeState, failure: String?, stopped: Bool) {
        guard generating else { return }
        // Close further reservations/handoffs before signalling cancellation.
        // Unknown server work remains held in the durable ledger.
        do { _ = try pendingEpisode?.finish(reason: reason) }
        catch { memoryHealthy = false }
        if let admission = pendingAdmission {
            pendingAdmission = nil
            admission.cancel()
            pendingAdmissionAccounting.append(admission.accounting)
        }
        let waitingForNativeCleanup = selectedProfile != .customLocal && pendingInvocationStarted && runner.isRunning
        runner.cancel()
        if waitingForNativeCleanup {
            status.stringValue = "Stopping; waiting for the local model process to close…"
            return
        }
        completeGeneration(GenerationResult(elapsed: Date().timeIntervalSince(started),
            tokensPerSecond: nil, failure: failure, stopped: stopped))
    }

    @objc private func stopGeneration() {
        if generating {
            status.stringValue = "Stopping…"
            endActiveEpisode(reason: .cancelled, failure: nil, stopped: true)
        }
    }

    @objc private func clearPrompt() {
        guard !generating, !draftValidationFailed, let store else { return }
        persistDraft()
        do {
            activeChat = try store.createConversation(projectID: projectID, title: "Chat \(try store.listConversations(projectID: projectID).count + 1)")
            preferences.conversationID = activeChat?.id
            savePreferences(); restoreActiveConversation()
            status.stringValue = "New durable chat created in project default."
        } catch { status.stringValue = "New chat could not be created." }
        window.makeFirstResponder(promptView)
    }

    private var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.textColor]
    }

    private func appendTranscript(_ speaker: String, body: String) {
        responseView.textStorage?.append(NSAttributedString(string: speaker + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor
        ]))
        if !body.isEmpty {
            responseView.textStorage?.append(NSAttributedString(string: body + "\n\n", attributes: bodyAttributes))
        }
        responseView.scrollRangeToVisible(NSRange(location: responseView.string.utf16.count, length: 0))
    }

    private func replaceDraft(_ text: String) {
        promptView.insertText(text, replacementRange: NSRange(location: 0, length: promptView.string.utf16.count))
    }

    private var activeUndoManager: UndoManager? {
        if let editor = window.firstResponder as? NSTextView, editor.isEditable { return editor.undoManager }
        return promptView.undoManager
    }

    @objc private func undoEdit(_ sender: Any?) { activeUndoManager?.undo() }
    @objc private func redoEdit(_ sender: Any?) { activeUndoManager?.redo() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(createBackup) || menuItem.action == #selector(restoreBackup) {
            return memoryHealthy && !archiveOperationInProgress
        }
        if menuItem.action == #selector(undoEdit(_:)) { return !generating && activeUndoManager?.canUndo == true }
        if menuItem.action == #selector(redoEdit(_:)) { return !generating && activeUndoManager?.canRedo == true }
        return true
    }

    /// Exercise the same preparation entry point as Send with only synthetic
    /// events. No model request is made and no message content is printed.
    private func sendContextChecks(store: MemoryStore) throws -> [String: Bool] {
        let chat = try store.createConversation(projectID: projectID, title: "Synthetic automatic recall")
        let otherChat = try store.createConversation(projectID: "synthetic-send-other-project", title: "Synthetic separate scope")
        let old = try store.append(conversationID: chat.id, role: .human,
            text: "The heliostat retry delay is seven seconds.", status: .complete,
            turnID: UUID().uuidString, eventID: UUID().uuidString)
        let other = try store.append(conversationID: otherChat.id, role: .human,
            text: "The heliostat retry delay is ninety seconds.", status: .complete,
            turnID: UUID().uuidString, eventID: UUID().uuidString)
        for index in 0..<32 {
            _ = try store.append(conversationID: chat.id, role: .assistant,
                text: "Synthetic unrelated work log \(index): " + String(repeating: "x", count: 1024), status: .complete,
                turnID: UUID().uuidString, eventID: UUID().uuidString)
        }
        let prompt = "What did we decide about heliostat retry delays?"
        let previousChat = activeChat
        let previousDraft = promptView.string
        defer {
            preparedSendObserverForChecks = nil
            activeChat = previousChat
            replaceDraft(previousDraft)
        }
        activeChat = chat
        replaceDraft(prompt)
        var submittedSnapshot: ContextSnapshot?
        preparedSendObserverForChecks = { submittedSnapshot = $0 }
        sendPrompt()
        preparedSendObserverForChecks = nil
        guard let recalled = submittedSnapshot, let current = try store.events(conversationID: chat.id).last,
              current.role == .human, current.text == prompt else {
            return ["send_entrypoint_prepares_historical_context": false]
        }
        func prepare(_ query: String) throws -> ContextSnapshot {
            try ChatContextPreparation.prepare(store: store, conversationID: chat.id, projectID: projectID,
                prompt: query, system: "Synthetic host rule", excludingEventID: current.id)
        }
        let recentOnly = try ContextAssembler.prepare(store: store, conversationID: chat.id, projectID: projectID,
            prompt: prompt, system: "Synthetic host rule", excludingEventID: current.id)
        var checks: [String: Bool] = [:]
        checks["send_entrypoint_prepares_historical_context"] = recalled.evidence.contains { $0.eventID == old.id }
        checks["send_old_source_is_beyond_recent_context"] = recentOnly.omittedRecentCount > 0
            && !recentOnly.messages.contains { $0.content.contains(old.text) }
        checks["send_question_retrieves_old_source"] = recalled.evidence.contains { $0.eventID == old.id }
            && recalled.messages.contains { $0.role == "user" && $0.content.contains("event_id: \(old.id)") && $0.content.contains(old.text) }
        checks["send_retrieval_preserves_project_scope"] = !recalled.evidence.isEmpty
            && recalled.evidence.allSatisfy { $0.projectID == projectID && $0.eventID != other.id }
        checks["send_current_prompt_is_once_and_not_evidence"] = recalled.messages.last?.content == prompt
            && recalled.messages.filter { $0.content == prompt }.count == 1
            && !recalled.evidence.contains { $0.eventID == current.id }
        let fillerQuestion = try prepare("Please could you tell me what it was that we decided about the heliostat retry delays?")
        checks["send_stopword_heavy_question_recalls_source"] = fillerQuestion.evidence.contains { $0.eventID == old.id }
        let operatorQuestion = try prepare("heliostat\" OR *")
        checks["send_search_operators_remain_data"] = operatorQuestion.evidence.map(\.eventID) == [old.id]
            && operatorQuestion.messages.last?.content == "heliostat\" OR *"
        checks["manual_search_still_requires_all_terms"] = try store.search(query: "heliostat absentneedle", projectID: projectID).isEmpty
        let longPrompt = prompt + " " + (0..<80).map { "topic\($0)" }.joined(separator: " ") + " " + String(repeating: "z", count: 4097)
        let longSnapshot = try prepare(longPrompt)
        checks["send_long_prompt_retained_with_bounded_retrieval"] = longSnapshot.messages.last?.content == longPrompt
            && longSnapshot.evidence.contains { $0.eventID == old.id } && longSnapshot.serializedBytes <= 65_536
        let oversizedTerm = String(repeating: "z", count: 4097) + " heliostat"
        let oversizedTermSnapshot = try prepare(oversizedTerm)
        checks["send_oversized_search_term_does_not_block_prompt"] = oversizedTermSnapshot.messages.last?.content == oversizedTerm
            && oversizedTermSnapshot.evidence.contains { $0.eventID == old.id }
        let repeatedPrompt = String(repeating: "heliostat ", count: 80)
        let repeatedSnapshot = try prepare(repeatedPrompt)
        checks["send_repeated_query_terms_are_bounded"] = repeatedSnapshot.messages.last?.content == repeatedPrompt
            && repeatedSnapshot.evidence.map(\.eventID) == [old.id]
        return checks
    }

    private func coordinatorStopChecks(store: MemoryStore) throws -> [String: Bool] {
        let priorChat = activeChat
        let priorDraft = promptView.string
        let priorAddress = endpointField.stringValue
        let priorTranscript = NSAttributedString(attributedString: responseView.attributedString())
        defer {
            activeChat = priorChat
            endpointField.stringValue = priorAddress; reloadCredential()
            replaceDraft(priorDraft)
            responseView.textStorage?.setAttributedString(priorTranscript)
        }
        let chat = try store.createConversation(projectID: projectID, title: "Synthetic preparation Stop")
        activeChat = chat
        endpointField.stringValue = "http://127.0.0.1:1/v1/"; reloadCredential()
        replaceDraft("Synthetic context preparation cancellation")
        sendPrompt()
        guard let lease = pendingEpisode else { return ["gui_submission_creates_durable_episode": false] }
        let submitted = generating && preparingContext && stop.isEnabled
        stopGeneration()
        let receipt = try store.episodeReceipt(id: lease.episodeID, clock: SystemEpisodeClock().now())
        let events = try store.events(conversationID: chat.id)
        // Wait for only this bounded local preparation queue, then let its
        // stale main callback run. The test endpoint cannot reach a model.
        preparationQueue.sync {}
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let after = try store.episodeReceipt(id: lease.episodeID, clock: SystemEpisodeClock().now())
        return [
            "gui_submission_creates_durable_episode": submitted,
            "gui_stop_during_preparation_closes_episode": receipt.state == .cancelled && !generating,
            "gui_stop_preserves_accepted_human_and_cancelled_result": events.count == 2
                && events.first?.role == .human && events.first?.status == .complete
                && events.last?.role == .assistant && events.last?.status == .cancelled,
            "gui_stale_preparation_cannot_dispatch": after.charged.modelCalls == 0 && after.charged.httpAttempts == 0
                && pendingInvocationID.isEmpty && !generating && memoryHealthy
        ]
    }

    private final class FinalizationClockForChecks: EpisodeClockSource {
        var ticks: UInt64 = 1_000_000
        func now() throws -> EpisodeClockSnapshot {
            EpisodeClockSnapshot(domain: "synthetic-finalization-clock", continuousNanoseconds: ticks, utc: Date())
        }
    }

    private func finalizationDeadlineChecks(store: MemoryStore) throws -> [String: Bool] {
        let priorChat = activeChat, priorDraft = promptView.string
        let transcript = NSAttributedString(attributedString: responseView.attributedString())
        defer { activeChat = priorChat; replaceDraft(priorDraft); responseView.textStorage?.setAttributedString(transcript) }
        let chat = try store.createConversation(projectID: projectID, title: "Synthetic finalization deadline")
        let clock = FinalizationClockForChecks()
        let episodeID = UUID().uuidString, turn = UUID().uuidString, human = UUID().uuidString
        var limits = EpisodeLimits(); limits.deadlineMilliseconds = 1
        _ = try store.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: turn, humanEventID: human,
            episodeID: episodeID, text: "Synthetic finalization request", limits: limits, clock: clock.now())
        let lease = EpisodeLease(ledger: store, episodeID: episodeID, clock: clock)
        let body = Data(#"{"messages":[],"stream":true}"#.utf8)
        let work = try lease.prepare(kind: .answer, resources: EpisodeResources(inputTokens: 4, outputTokens: 8, modelCalls: 1, httpAttempts: 1),
            adapterIdentity: "synthetic-finalization-adapter", snapshot: body)
        activeChat = chat
        pendingPrompt = "Synthetic finalization request"; pendingResponse = ""
        pendingTurnID = turn; pendingHumanID = human; pendingAssistantID = UUID().uuidString
        pendingInvocationID = UUID().uuidString; pendingChunkSequence = 0; pendingCaptureFailure = false
        pendingRequestBody = body; pendingProviderIdentity = "native:synthetic"
        pendingEpisode = lease; pendingAnswerWork = work
        _ = try store.beginInvocation(invocationID: pendingInvocationID, conversationID: chat.id, turnID: turn,
            humanEventID: human, assistantEventID: pendingAssistantID, providerIdentity: pendingProviderIdentity,
            requestBody: body, episodeID: episodeID, episodeWorkID: work.id)
        pendingInvocationStarted = true
        _ = try lease.dispatch(work, start: {})
        setGenerating(true)
        receiveGenerationText("Synthetic committed finalization prefix")
        let invocation = pendingInvocationID
        clock.ticks = 2_000_000
        completeGeneration(GenerationResult(elapsed: 0.001, tokensPerSecond: nil, failure: nil, stopped: false))
        let stored = try store.invocation(id: invocation)!
        let receipt = try store.episodeReceipt(id: episodeID, clock: clock.now())
        return [
            "gui_deadline_at_finalization_keeps_store_healthy": memoryHealthy && !generating,
            "gui_deadline_at_finalization_publishes_partial_prefix": stored.finalStatus == .partial
                && stored.terminalReason == .transportFailure && receipt.state == .deadlineExceeded,
            "gui_deadline_at_finalization_preserves_unknown_output": receipt.held.outputTokens == 8
                && receipt.charged.inputTokens == 4 && status.stringValue.contains("time limit")
        ]
    }

    private func nativeCleanupChecks(store: MemoryStore) throws -> [String: Bool] {
        let priorChat = activeChat, priorDraft = promptView.string
        let oldModel = modelField.stringValue, oldRuntime = runtimeField.stringValue
        let oldProfile = selectedProfile
        let transcript = NSAttributedString(attributedString: responseView.attributedString())
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("boros-native-cleanup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: scratch)
            modelSelector.selectItem(at: ModelProfile.selectableProfiles.firstIndex(of: oldProfile)!); selectModel()
            modelField.stringValue = oldModel; runtimeField.stringValue = oldRuntime
            activeChat = priorChat; replaceDraft(priorDraft); responseView.textStorage?.setAttributedString(transcript)
        }
        let runtime = scratch.appendingPathComponent("synthetic-runtime")
        let model = scratch.appendingPathComponent("synthetic-model")
        try Data("Synthetic placeholder, never loaded by a model.".utf8).write(to: model)
        // A short flushed prefix must arrive before EOF or a full read buffer.
        let script = "#!/usr/bin/python3\nimport signal,time,sys\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\nsys.stdout.write('Synthetic native prefix ' * 20); sys.stdout.flush()\nwhile True: time.sleep(0.05)\n"
        try Data(script.utf8).write(to: runtime)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
        activeChat = try store.createConversation(projectID: projectID, title: "Synthetic native cleanup")
        modelSelector.selectItem(at: ModelProfile.selectableProfiles.firstIndex(of: .bonsai)!); selectModel()
        modelField.stringValue = model.path; runtimeField.stringValue = runtime.path
        replaceDraft("Synthetic native cancellation request")
        sendPrompt()
        let startupLimit = Date().addingTimeInterval(10)
        while Date() < startupLimit && (!pendingInvocationStarted || pendingResponse.isEmpty) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        let started = pendingInvocationStarted && runner.isRunning && !pendingResponse.isEmpty
        stopGeneration()
        let gated = generating && !send.isEnabled && runner.isRunning
        let cleanupLimit = Date().addingTimeInterval(6)
        while Date() < cleanupLimit && (generating || runner.isRunning) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        if generating { runner.cancel() }
        return [
            "native_cleanup_fixture_starts_owned_synthetic_process": started,
            "native_stop_keeps_send_disabled_until_cleanup": gated,
            "native_cleanup_callback_releases_send_without_busy_retry": !generating && !runner.isRunning && send.isEnabled && memoryHealthy,
            "native_stop_late_content_is_not_capture_failure": !status.stringValue.contains("capture failed")
        ]
    }

    // Exercise the actual controls in an undisplayed window. No system input,
    // clipboard changes, model calls, or conversation text leave this process.
    func uiChecks() -> [String: Bool] {
        let frame = window.frame
        let scroll = responseView.enclosingScrollView!
        window.contentView?.layoutSubtreeIfNeeded()
        let scrollHeight = scroll.bounds.height
        var checks: [String: Bool] = [:]
        promptView.insertText("synthetic draft", replacementRange: NSRange(location: 0, length: 0))
        let fileMenu = NSApplication.shared.mainMenu?.items.first(where: { $0.title == "File" })?.submenu
        let backupItem = fileMenu?.items.first(where: { $0.action == #selector(createBackup) })
        let restoreItem = fileMenu?.items.first(where: { $0.action == #selector(restoreBackup) })
        checks["backup_restore_menu_available"] = backupItem != nil && restoreItem != nil
        if let backupItem, let restoreItem {
            checks["backup_restore_menu_requires_healthy_store"] = validateMenuItem(backupItem) && validateMenuItem(restoreItem)
            archiveOperationInProgress = true
            checks["archive_work_excludes_second_operation_and_quit"] = !validateMenuItem(backupItem)
                && !validateMenuItem(restoreItem) && applicationShouldTerminate(NSApplication.shared) == .terminateCancel
            archiveOperationInProgress = false
        }
        checks["draft_registers_undo"] = promptView.undoManager?.canUndo == true
        undoEdit(nil)
        checks["undo_restores_draft"] = promptView.string.isEmpty
        redoEdit(nil)
        checks["redo_restores_draft"] = promptView.string == "synthetic draft"
        let editMenu = NSApplication.shared.mainMenu?.items.first(where: { $0.title == "Edit" })?.submenu
        checks["undo_shortcut"] = editMenu?.item(at: 0)?.keyEquivalent == "z"
            && editMenu?.item(at: 0)?.keyEquivalentModifierMask == [.command]
        checks["redo_shortcut"] = editMenu?.item(at: 1)?.keyEquivalent == "z"
            && editMenu?.item(at: 1)?.keyEquivalentModifierMask == [.command, .shift]
        promptView.string = String(repeating: "x", count: MemoryStore.maximumPayloadBytes + 1)
        textDidChange(Notification(name: NSText.didChangeNotification, object: promptView))
        checks["oversized_draft_keeps_store_healthy"] = memoryHealthy && !send.isEnabled && draftValidationFailed
        promptView.string = "Synthetic shortened draft"
        textDidChange(Notification(name: NSText.didChangeNotification, object: promptView))
        checks["shortened_draft_restores_send"] = memoryHealthy && send.isEnabled && !draftValidationFailed
            && (try? store?.loadDraft(conversationID: activeChat!.id)) == "Synthetic shortened draft"
        let longText = Array(repeating: "Synthetic long line for checking scrolling.", count: 500).joined(separator: "\n")
        replaceDraft(longText)
        responseView.textStorage?.append(NSAttributedString(string: longText, attributes: bodyAttributes))
        promptView.layoutManager?.ensureLayout(for: promptView.textContainer!)
        responseView.layoutManager?.ensureLayout(for: responseView.textContainer!)
        promptView.sizeToFit()
        responseView.sizeToFit()
        window.contentView?.layoutSubtreeIfNeeded()
        checks["long_text_keeps_window_size"] = window.frame.size == frame.size
        checks["long_text_keeps_transcript_height"] = abs(scroll.bounds.height - scrollHeight) < 1
        checks["composer_height_bounded"] = abs(promptView.enclosingScrollView!.bounds.height - 120) < 1
        checks["composer_document_scrolls"] = promptView.bounds.height > promptView.enclosingScrollView!.contentView.bounds.height
        checks["transcript_document_scrolls"] = responseView.bounds.height > scroll.contentView.bounds.height
        conversation.append(user: "synthetic user", assistant: "synthetic answer")
        clearPrompt()
        checks["new_chat_resets_history"] = conversation.isEmpty && responseView.string.isEmpty && promptView.string.isEmpty
        checks["new_chat_resets_undo"] = promptView.undoManager?.canUndo == false && promptView.undoManager?.canRedo == false

        settingsPanel.isHidden = false
        func systemHeight(_ text: String) -> CGFloat {
            systemEditor.string = text
            window.contentView?.layoutSubtreeIfNeeded()
            systemEditor.refreshHeight()
            window.contentView?.layoutSubtreeIfNeeded()
            return systemEditor.bounds.height
        }
        let oneLine = systemHeight("synthetic one")
        let twoLines = systemHeight("synthetic one\nsynthetic two")
        let threeLines = systemHeight("synthetic one\nsynthetic two\nsynthetic three")
        let fourLines = systemHeight("synthetic one\nsynthetic two\nsynthetic three\nsynthetic four")
        checks["system_grows_to_three_lines"] = oneLine < twoLines && twoLines < threeLines
        checks["system_height_capped_at_three_lines"] = abs(fourLines - threeLines) < 1
        checks["system_document_scrolls"] = systemEditor.textView.bounds.height > systemEditor.contentView.bounds.height
        let wrappedHeight = systemHeight(Array(repeating: "synthetic wrapping text", count: 100).joined(separator: " "))
        checks["system_wrapping_keeps_height_bounded"] = abs(wrappedHeight - threeLines) < 1
        checks["system_empty_shrinks_to_one_line"] = abs(systemHeight("") - oneLine) < 1
        let systemUndo = systemEditor.textView.undoManager!
        systemUndo.removeAllActions()
        // These synchronous checks have no input event boundaries. Give each
        // synthetic edit its own group, as separate keyboard events would.
        systemUndo.groupsByEvent = false
        window.makeFirstResponder(systemEditor.textView)
        systemUndo.beginUndoGrouping()
        systemEditor.textView.insertText("synthetic edit", replacementRange: NSRange(location: 0, length: 0))
        systemUndo.endUndoGrouping()
        systemEditor.textView.breakUndoCoalescing()
        systemUndo.beginUndoGrouping()
        systemEditor.textView.insertNewline(nil)
        systemUndo.endUndoGrouping()
        checks["system_enter_inserts_newline"] = systemEditor.string == "synthetic edit\n"
        undoEdit(nil)
        checks["system_undo_uses_active_editor"] = systemEditor.string == "synthetic edit" && promptView.string.isEmpty
        redoEdit(nil)
        checks["system_redo_uses_active_editor"] = systemEditor.string == "synthetic edit\n" && promptView.string.isEmpty
        systemUndo.groupsByEvent = true
        setGenerating(true)
        checks["generation_disables_system_editor"] = !systemEditor.isEditable
        setGenerating(false)
        checks["generation_restores_system_editor"] = systemEditor.isEditable
        checks["system_edit_keeps_window_size"] = window.frame.size == frame.size
        let priorChatID = activeChat?.id
        if let store, let activeChat {
            do {
                let turn = UUID().uuidString
                let human = try store.append(conversationID: activeChat.id, role: .human, text: "Synthetic exact history 17", status: .complete, turnID: turn, eventID: UUID().uuidString)
                let partial = try store.append(conversationID: activeChat.id, role: .assistant, text: "Synthetic partial answer", status: .partial, turnID: turn, eventID: UUID().uuidString)
                restoringDraft = true; replaceDraft("Synthetic saved draft"); restoringDraft = false; persistDraft()
                restoreActiveConversation()
                checks["durable_history_renders_source_ids"] = responseView.string.contains(human.id) && responseView.string.contains(partial.id)
                checks["durable_partial_status_visible"] = responseView.string.contains("Assistant · partial") && responseView.string.contains("Synthetic partial answer")
                checks["durable_draft_restored"] = promptView.string == "Synthetic saved draft"
                preferences.conversationID = activeChat.id; savePreferences()
                checks["last_conversation_preference_saved"] = LocalSettings.load(in: store.directory).conversationID == activeChat.id
                let snapshot = try ContextAssembler.prepare(store: store, conversationID: activeChat.id, projectID: projectID,
                    prompt: "Synthetic follow-up", system: "Synthetic host rule", budgetBytes: 65_536)
                checks["context_exact_roles_preserved"] = snapshot.messages.contains { $0.role == "user" && $0.content == human.text }
                    && snapshot.messages.last?.content == "Synthetic follow-up"
                checks.merge(try sendContextChecks(store: store)) { _, new in new }
                let before = responseView.string
                modelSelector.selectItem(at: ModelProfile.selectableProfiles.firstIndex(of: .qwen35)!)
                selectModel()
                checks["model_switch_keeps_durable_chat"] = self.activeChat?.id == activeChat.id && responseView.string == before
                modelSelector.selectItem(at: 0); selectModel()
                checks["api_profile_is_default_selection"] = selectedProfile == .customLocal
                checks["api_address_and_served_id_configurable"] = endpointField.isEditable && servedModelField.isEditable
                checks["api_key_uses_secure_control"] = (keyField as NSView) is NSSecureTextField
                checks["qwen_api_thinking_defaults_off_and_can_be_requested"] = thinking.isEnabled
                    && thinking.state == .off && !requestedThinkingEnabled
                let apiTemperature = temperature.doubleValue
                thinking.state = .on; thinkingChanged()
                checks["qwen_api_thinking_request_keeps_server_sampling"] = requestedThinkingEnabled
                    && temperature.doubleValue == apiTemperature && !thinkingBudget.isEnabled
                checks["api_unsupported_context_and_sampling_controls_disabled"] = !context.isEnabled
                    && !samplingPreset.isEnabled && samplingHint.stringValue.contains("server defaults")
                    && thinkingHint.stringValue.contains("Qwen mlx-serve uses this toggle")
                servedModelField.stringValue = "synthetic-other-api-model"
                controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: servedModelField))
                checks["other_api_models_use_server_reasoning_defaults"] = !thinking.isEnabled
                    && thinking.state == .off && !requestedThinkingEnabled && !thinkingBudget.isEnabled
                servedModelField.stringValue = "ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit"
                controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: servedModelField))
                setGenerating(true)
                checks["generation_disables_qwen_api_thinking_toggle"] = !thinking.isEnabled
                setGenerating(false)
                checks["generation_restores_only_supported_api_controls"] = thinking.isEnabled
                    && !thinkingBudget.isEnabled && !context.isEnabled && !samplingPreset.isEnabled
                clearPrompt()
                checks["new_chat_preserves_previous_durable_history"] = try store.events(conversationID: activeChat.id).count == 2
                    && self.activeChat?.id != activeChat.id && responseView.string.isEmpty
                preferences.conversationID = activeChat.id; savePreferences()
                self.activeChat = activeChat; restoreActiveConversation()
                checks["conversation_reload_restores_full_history"] = responseView.string.contains(human.text) && responseView.string.contains(partial.text)
                checks.merge(try coordinatorStopChecks(store: store)) { _, new in new }
                checks.merge(try finalizationDeadlineChecks(store: store)) { _, new in new }
                checks.merge(try nativeCleanupChecks(store: store)) { _, new in new }
                let cases: [(String, String?, Bool, CaptureStatus)] = [
                    ("Synthetic truncated bytes", "io_failed", false, .partial),
                    ("", "http_failed", false, .failed),
                    ("", nil, true, .cancelled),
                    ("Synthetic stopped bytes", nil, true, .partial)
                ]
                for (index, item) in cases.enumerated() {
                    let turn = UUID().uuidString
                    let humanID = UUID().uuidString
                    let assistantID = UUID().uuidString
                    let text = "Synthetic accepted request \(index)"
                    let before = try store.events(conversationID: activeChat.id).count
                    _ = try store.append(conversationID: activeChat.id, role: .human, text: text, status: .complete, turnID: turn, eventID: humanID)
                    pendingPrompt = text; pendingResponse = ""; pendingTurnID = turn
                    pendingHumanID = humanID; pendingAssistantID = assistantID
                    pendingInvocationID = UUID().uuidString; pendingChunkSequence = 0; pendingCaptureFailure = false
                    pendingRequestBody = Data("{\"messages\":[]}".utf8); pendingProviderIdentity = "native:synthetic"
                    _ = try store.beginInvocation(invocationID: pendingInvocationID, conversationID: activeChat.id, turnID: turn,
                        humanEventID: humanID, assistantEventID: assistantID, providerIdentity: pendingProviderIdentity, requestBody: pendingRequestBody!)
                    pendingInvocationStarted = true
                    setGenerating(true)
                    receiveGenerationText(item.0)
                    let journal = try store.invocation(id: pendingInvocationID)
                    checks["stream_\(index)_journal_precedes_completion"] = journal?.observedBytes == item.0.utf8.count
                        && journal?.finalStatus == nil && pendingResponse == item.0
                    completeGeneration(GenerationResult(elapsed: 0, tokensPerSecond: nil, failure: item.1, stopped: item.2))
                    let captured = try store.events(conversationID: activeChat.id)
                    checks["completion_\(index)_captures_exact_human_and_status"] = captured.count == before + 2
                        && captured[captured.count - 2].id == humanID && captured[captured.count - 2].text == text
                        && captured.last?.id == assistantID && captured.last?.text == item.0 && captured.last?.status == item.3
                    completeGeneration(GenerationResult(elapsed: 0, tokensPerSecond: nil, failure: nil, stopped: false))
                    checks["completion_\(index)_duplicate_callback_adds_no_event"] = try store.events(conversationID: activeChat.id).count == before + 2
                }
                let failureTurn = UUID().uuidString
                let failureHuman = UUID().uuidString
                _ = try store.append(conversationID: activeChat.id, role: .human, text: "Synthetic capture failure request", status: .complete,
                    turnID: failureTurn, eventID: failureHuman)
                pendingPrompt = "Synthetic capture failure request"; pendingResponse = ""; pendingTurnID = failureTurn
                pendingHumanID = failureHuman; pendingAssistantID = UUID().uuidString; pendingInvocationID = UUID().uuidString
                pendingChunkSequence = 0; pendingCaptureFailure = false; pendingInvocationStarted = true
                pendingRequestBody = Data("{\"messages\":[]}".utf8); pendingProviderIdentity = "native:synthetic"
                _ = try store.beginInvocation(invocationID: pendingInvocationID, conversationID: activeChat.id, turnID: failureTurn,
                    humanEventID: failureHuman, assistantEventID: pendingAssistantID, providerIdentity: pendingProviderIdentity, requestBody: pendingRequestBody!)
                setGenerating(true)
                receiveGenerationText("Synthetic committed prefix")
                let visiblePrefix = responseView.string
                pendingChunkSequence += 1 // Force a real out-of-order journal rejection.
                receiveGenerationText("Synthetic uncommitted suffix")
                checks["failed_stream_capture_never_displays_unsaved_delta"] = pendingCaptureFailure
                    && responseView.string == visiblePrefix && pendingResponse == "Synthetic committed prefix"
                let failedInvocationID = pendingInvocationID
                completeGeneration(GenerationResult(elapsed: 0, tokensPerSecond: nil, failure: nil, stopped: true))
                checks["failed_stream_capture_finalizes_committed_prefix"] = try store.events(conversationID: activeChat.id).last?.text == "Synthetic committed prefix"
                    && store.invocation(id: failedInvocationID)?.terminalReason == .captureFailure
                checks["api_token_budget_is_explicit_and_enabled"] = endpointTokenLimit.stringValue == "32768" && endpointTokenLimit.isEnabled
            } catch { checks["durable_ui_checks"] = false }
        } else { checks["durable_store_available"] = false }
        checks["new_chat_has_unique_identifier"] = priorChatID != nil
        setGenerating(true)
        checks["generation_disables_model_and_chat_switch"] = !modelSelector.isEnabled && !conversationSelector.isEnabled
        setGenerating(false)
        checks["generation_restores_model_and_chat_switch"] = modelSelector.isEnabled && conversationSelector.isEnabled
        let expectedID = activeChat?.id
        let expectedTranscript = responseView.string
        semanticIndex = nil
        store = nil
        let restarted = ApplicationDelegate()
        restarted.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        checks["restart_initializer_selects_last_conversation"] = restarted.memoryHealthy && restarted.activeChat?.id == expectedID
        checks["restart_initializer_restores_accepted_history"] = restarted.responseView.string.contains("Synthetic accepted request 3")
            && restarted.responseView.string.contains("Synthetic stopped bytes")
        checks["restart_initializer_restores_saved_draft"] = restarted.promptView.string == promptView.string
        store = restarted.store
        restarted.semanticIndex = nil
        restarted.store = nil
        checks["restart_test_preserves_visible_window"] = responseView.string == expectedTranscript
        return checks
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if archiveOperationInProgress {
            status.stringValue = "Wait for the archive operation to finish before quitting."
            return .terminateCancel
        }
        if generating {
            quitting = true
            timer?.invalidate()
            DispatchQueue.main.async { [weak self] in self?.stopGeneration() }
            return .terminateLater
        }
        persistDraft()
        savePreferences()
        return .terminateNow
    }

    private func installMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Boros", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let backup = fileMenu.addItem(withTitle: "Create Backup…", action: #selector(createBackup), keyEquivalent: "")
        backup.target = self
        let restore = fileMenu.addItem(withTitle: "Restore Backup to New Folder…", action: #selector(restoreBackup), keyEquivalent: "")
        restore.target = self
        fileItem.title = "File"; fileItem.submenu = fileMenu; menu.addItem(fileItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        let undo = editMenu.addItem(withTitle: "Undo", action: #selector(undoEdit(_:)), keyEquivalent: "z")
        undo.target = self; undo.keyEquivalentModifierMask = [.command]
        let redo = editMenu.addItem(withTitle: "Redo", action: #selector(redoEdit(_:)), keyEquivalent: "z")
        redo.target = self; redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        for (title, action, key) in [("Cut", "cut:", "x"),
                                     ("Copy", "copy:", "c"), ("Paste", "paste:", "v"),
                                     ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.title = "Edit"; editItem.submenu = editMenu
        menu.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.title = "Window"; windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApplication.shared.mainMenu = menu
        NSApplication.shared.windowsMenu = windowMenu
    }
}

private enum SmokeTest {
    private struct SmokeAdmissionAudit: Codable {
        let receipt: EndpointAdmissionReceipt?
        let context: Data?
    }
    static func run() -> Never {
        var settings = GenerationSettings()
        settings.temperature = 0
        settings.context = 2048
        settings.maximumOutput = 64
        let arguments = CommandLine.arguments
        let greetingOnly = arguments.contains("--greeting-test")
        if let index = arguments.firstIndex(of: "--profile"), index + 1 < arguments.count,
           let profile = ModelProfile(rawValue: arguments[index + 1]) {
            settings.profile = profile
            settings.model = profile.defaultModelPath
            settings.maximumOutput = profile == .bonsai ? 64 : (greetingOnly ? 2048 : profile.defaultMaximumOutput)
            settings.context = profile == .bonsai ? 2048 : profile.defaultContext
            settings.thinkingEnabled = profile.defaultThinkingEnabled
            settings.thinkingBudget = profile.defaultThinkingBudget
            settings.temperature = profile.sampling(thinking: settings.thinkingEnabled).temperature
        }
        if arguments.contains("--thinking"), settings.profile.supportsThinking {
            settings.thinkingEnabled = true
            settings.temperature = settings.profile.sampling(thinking: true).temperature
        }
        if let index = arguments.firstIndex(of: "--thinking-budget"), index + 1 < arguments.count,
           let budget = Int(arguments[index + 1]), budget >= 0 { settings.thinkingBudget = budget }
        if let index = arguments.firstIndex(of: "--max-response"), index + 1 < arguments.count,
           let budget = Int(arguments[index + 1]), budget > 0 { settings.maximumOutput = budget }
        for (flag, apply) in [
            ("--model", { (value: String) in settings.model = value }),
            ("--runtime", { (value: String) in settings.runtime = value }),
            ("--api-address", { (value: String) in settings.endpointURL = value }),
            ("--served-model", { (value: String) in settings.endpointModel = value })
        ] {
            if let index = arguments.firstIndex(of: flag), index + 1 < arguments.count {
                apply(arguments[index + 1])
            }
        }
        let runner = ModelRunner()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("boros-smoke-" + UUID().uuidString, isDirectory: true)
        let owner: MemoryStore
        let chat: StoredConversation
        do {
            owner = try MemoryStore(directory: scratch)
            chat = try owner.createConversation(projectID: "synthetic-smoke", title: "Synthetic smoke")
        } catch { print("{\"pass\":false,\"failure\":\"capture_failure\"}"); exit(1) }
        var answer = ""
        var conversation = Conversation()
        var turn = 0
        var admissionOperation: ProviderAdmissionOperation?
        func runTurn() {
            let prompt = greetingOnly ? "hi" : turn == 0 ? "Compute 17 + 25. Reply with only the integer."
                : "Add one to your last answer. Reply with only the integer."
            answer = ""
            let turnID = UUID().uuidString, humanID = UUID().uuidString, assistantID = UUID().uuidString
            let invocationID = UUID().uuidString, episodeID = UUID().uuidString
            let clock = SystemEpisodeClock()
            let lease = EpisodeLease(ledger: owner, episodeID: episodeID, clock: clock)
            var frozenSettings = settings
            frozenSettings.episodeLease = lease
            var invocationStarted = false
            var chunkSequence = 0
            var captureFailed = false
            var snapshot: ContextSnapshot?
            func complete(_ result: GenerationResult) {
                let finalAnswer = settings.profile.finalAnswer(answer)
                let trimmed = finalAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
                let expected = greetingOnly
                    ? trimmed.count < 500 && trimmed.range(of: "\\b(?:hello|hi|hey)\\b", options: [.regularExpression, .caseInsensitive]) != nil
                    : trimmed == (turn == 0 ? "42" : "43")
                var passed = result.failure == nil && !result.stopped && !captureFailed && expected
                let terminal: EpisodeState = result.failure == "episode_deadline_exceeded" ? .deadlineExceeded
                    : result.failure == "episode_budget_exceeded" ? .budgetExceeded
                    : result.stopped ? .cancelled : passed ? .completed : .failed
                var resolved = result
                do { resolved = result.reconcilingEpisodeState(try lease.finish(reason: terminal).state) }
                catch { passed = false }
                passed = passed && resolved.failure == nil && !resolved.stopped
                let capture: CaptureStatus = passed ? .complete : answer.isEmpty ? (resolved.stopped ? .cancelled : .failed) : .partial
                do {
                    if invocationStarted {
                        _ = try owner.finalizeInvocation(invocationID: invocationID, status: capture,
                            reason: passed ? .completed : resolved.stopped ? .cancelled : captureFailed ? .captureFailure : .transportFailure,
                            usageJSON: try result.providerUsage.map { try JSONEncoder().encode($0) })
                    } else {
                        _ = try owner.append(conversationID: chat.id, role: .assistant, text: "", status: capture,
                            turnID: turnID, eventID: assistantID)
                    }
                } catch { passed = false }
                if passed && turn == 0 && !greetingOnly {
                    conversation.append(user: prompt, assistant: answer)
                    turn = 1
                    runTurn()
                    return
                }
                var metadata: [String: Any] = ["pass": passed, "turns_checked": turn + 1,
                    "test": greetingOnly ? "greeting" : "multi_turn_arithmetic",
                    "elapsed_seconds": result.elapsed,
                    "failure": resolved.failure ?? (captureFailed ? "capture_failure" : passed ? "none" : "answer_mismatch")]
                if let receipt = try? owner.episodeReceipt(id: episodeID, clock: clock.now()) {
                    metadata["episode_state"] = receipt.state.rawValue
                    metadata["charged_input_tokens"] = receipt.charged.inputTokens
                    metadata["charged_output_tokens"] = receipt.charged.outputTokens
                    metadata["held_output_tokens"] = receipt.held.outputTokens
                    metadata["model_calls"] = receipt.charged.modelCalls
                    metadata["http_attempts"] = receipt.charged.httpAttempts
                    metadata["raw_source_bytes"] = receipt.charged.rawSourceBytes
                    metadata["unknown_input_operations"] = receipt.unknownInputOperations
                }
                if settings.profile != .bonsai {
                    metadata["thinking_enabled"] = settings.thinkingEnabled
                    metadata["thinking_closed"] = !settings.thinkingEnabled || answer.contains("</think>")
                    metadata["response_characters"] = answer.count
                    if !greetingOnly {
                        metadata["expected_integer_present"] = answer.contains(turn == 0 ? "42" : "43")
                        metadata["final_is_integer"] = Int(trimmed) != nil
                    }
                }
                if let speed = result.tokensPerSecond { metadata["tokens_per_second"] = speed }
                if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]) {
                    print(String(decoding: data, as: UTF8.self))
                }
                try? FileManager.default.removeItem(at: scratch)
                exit(passed ? 0 : 1)
            }
            func dispatch(_ admitted: GenerationSettings, body: Data) {
                var ready = admitted
                do {
                    let work = try lease.prepare(kind: admitted.profile == .customLocal ? .answer : .nativeInference,
                        resources: EpisodeResources(inputTokens: admitted.endpointAdmission?.promptTokens ?? 0,
                            outputTokens: admitted.maximumOutput, modelCalls: 1, httpAttempts: admitted.profile == .customLocal ? 1 : 0),
                        adapterIdentity: admitted.endpointAdmission?.answerAdapterIdentity ?? ("native:" + admitted.profile.rawValue),
                        snapshot: body, inputTokensKnown: admitted.profile == .customLocal)
                    ready.preparedAnswerWork = work
                    let audit = try JSONEncoder().encode(SmokeAdmissionAudit(receipt: admitted.endpointAdmission,
                        context: try snapshot?.deliveryAudit()))
                    _ = try owner.beginInvocation(invocationID: invocationID, conversationID: chat.id, turnID: turnID,
                        humanEventID: humanID, assistantEventID: assistantID,
                        providerIdentity: admitted.profile == .customLocal ? LocalEndpoint.chatURL(admitted.endpointURL)!.absoluteString : "native:" + admitted.profile.rawValue,
                        requestBody: body, admissionJSON: audit, episodeID: episodeID, episodeWorkID: work.id)
                    invocationStarted = true
                } catch {
                    complete(GenerationResult(elapsed: 0, tokensPerSecond: nil,
                        failure: (error as? EpisodeBudgetError)?.failureCode ?? "capture_failure", stopped: false))
                    return
                }
                runner.start(prompt: prompt, settings: ready, conversation: conversation, onText: { text in
                    do {
                        _ = try lease.checkActive()
                        _ = try owner.appendInvocationChunk(invocationID: invocationID, sequence: chunkSequence, text: text)
                        chunkSequence += 1
                        answer += text
                    } catch { captureFailed = true; runner.cancel() }
                }, onComplete: complete)
            }
            do {
                _ = try owner.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: turnID, humanEventID: humanID,
                    episodeID: episodeID, text: prompt, limits: EpisodeLimits(), clock: clock.now())
                let context = try ChatContextPreparation.prepare(store: owner, conversationID: chat.id, projectID: chat.projectID,
                    prompt: prompt, system: frozenSettings.system, excludingEventID: humanID, episodeLease: lease)
                snapshot = context
                frozenSettings.messagesOverride = context.messages.map { ["role": $0.role, "content": $0.content] }
                if frozenSettings.profile == .customLocal {
                    let body = try EndpointRequest.build(prompt: prompt, settings: frozenSettings, conversation: conversation)
                    frozenSettings.preparedEndpointBody = body
                    admissionOperation = ProviderAdmission.prepare(requestBody: body, address: frozenSettings.endpointURL,
                        apiKey: frozenSettings.endpointAPIKey, contextLimit: frozenSettings.endpointContextLimit,
                        safetyTokens: frozenSettings.endpointSafetyTokens, episodeLease: lease) { outcome in
                        DispatchQueue.main.async {
                            // Retain the operation through the completion
                            // handoff; it owns the in-flight admission state.
                            withExtendedLifetime(admissionOperation) { admissionOperation = nil }
                            switch outcome {
                            case .success(let receipt):
                                var admitted = frozenSettings; admitted.endpointAdmission = receipt
                                dispatch(admitted, body: body)
                            case .failure(let error):
                                complete(GenerationResult(elapsed: 0, tokensPerSecond: nil, failure: error.failureCode, stopped: false))
                            }
                        }
                    }
                } else {
                    let body = frozenSettings.profile == .bonsai
                        ? try NativeRequest.completionEvidence(prompt: prompt, settings: frozenSettings, conversation: conversation)
                        : try NativeRequest.reasoningBody(prompt: prompt, settings: frozenSettings, conversation: conversation)
                    if frozenSettings.profile != .bonsai { frozenSettings.preparedNativeBody = body }
                    dispatch(frozenSettings, body: body)
                }
            } catch {
                complete(GenerationResult(elapsed: 0, tokensPerSecond: nil,
                    failure: (error as? EpisodeBudgetError)?.failureCode ?? "capture_failure", stopped: false))
            }
        }
        runTurn()
        dispatchMain()
    }
}

@main
private enum BonsaiPlayground {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        _ = ReasoningSupervisor.runIfRequested()
        if let code = BackupCommand.run(arguments: CommandLine.arguments) { exit(code) }
        if CommandLine.arguments.contains("--backup-self-test") {
            do {
                let checks = try BackupChecks.run()
                print(String(decoding: try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]), as: UTF8.self))
                exit(checks.values.allSatisfy { $0 } ? 0 : 1)
            } catch { print("{\"backup_self_test\":false}"); exit(1) }
        }
        if CommandLine.arguments.contains("--semantic-self-test") {
            do {
                let checks = try SemanticChecks.run()
                print(String(decoding: try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]), as: UTF8.self))
                exit(checks.values.allSatisfy { $0 } ? 0 : 1)
            } catch { print("{\"semantic_self_test\":false}"); exit(1) }
        }
        if CommandLine.arguments.contains("--episode-self-test") {
            do {
                let checks = try EpisodeChecks.run()
                print(String(decoding: try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]), as: UTF8.self))
                exit(checks.values.allSatisfy { $0 } ? 0 : 1)
            } catch { print("{\"episode_self_test\":false}"); exit(1) }
        }
        if CommandLine.arguments.contains("--memory-self-test") {
            do {
                let checks = try MemoryChecks.run()
                let data = try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self)); exit(checks.values.allSatisfy { $0 } ? 0 : 1)
            } catch { print("{\"memory_self_test\":false}"); exit(1) }
        }
        if CommandLine.arguments.contains("--endpoint-self-test") {
            let checks = EndpointChecks.run()
            if let data = try? JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
            exit(checks.values.allSatisfy { $0 } ? 0 : 1)
        }
        if CommandLine.arguments.contains("--context-admission-self-test") {
            do {
                let checks = try ContextAdmissionChecks.run()
                let data = try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self)); exit(checks.values.allSatisfy { $0 } ? 0 : 1)
            } catch { print("{\"context_admission_self_test\":false}"); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--endpoint-integration-test"), index + 1 < CommandLine.arguments.count {
            let checks = EndpointChecks.runIntegration(baseURL: CommandLine.arguments[index + 1])
            if let data = try? JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
            exit(checks.values.allSatisfy { $0 } ? 0 : 1)
        }
        if CommandLine.arguments.contains("--reasoning-self-test") {
            let checks = ReasoningChecks.run()
            if let data = try? JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print(text) }
            exit(checks.values.allSatisfy { $0 } ? 0 : 1)
        }
        if CommandLine.arguments.contains("--conversation-self-test") {
            let checks = ConversationChecks.run().merging(ModelProfileChecks.run()) { first, _ in first }
                .merging(ManagedMessageChecks.run()) { first, _ in first }
            if let data = try? JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print(text) }
            exit(checks.values.allSatisfy { $0 } ? 0 : 1)
        }
        if CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--greeting-test") { SmokeTest.run() }
        var testDirectory: URL?
        if CommandLine.arguments.contains("--ui-self-test") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-ui-" + UUID().uuidString, isDirectory: true)
            setenv("BOROS_DATA_DIR", directory.path, 1)
            testDirectory = directory
        }
        let app = NSApplication.shared
        let delegate = ApplicationDelegate()
        app.delegate = delegate
        if CommandLine.arguments.contains("--ui-self-test") {
            app.setActivationPolicy(.prohibited)
            delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            let checks = delegate.uiChecks()
            if let data = try? JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print(text) }
            if let testDirectory { try? FileManager.default.removeItem(at: testDirectory) }
            exit(checks.values.allSatisfy { $0 } ? 0 : 1)
        }
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
