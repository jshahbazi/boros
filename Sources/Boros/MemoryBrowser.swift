import AppKit
import Foundation

/// Exact source reads stay in the project selected by the host UI.
final class MemoryBrowser: NSObject, NSWindowDelegate {
    private let store: MemoryStore
    private let projectID: String
    private let window: NSWindow
    private let queryField = NSTextField(string: "")
    private let literal = NSButton(checkboxWithTitle: "Literal (case sensitive)", target: nil, action: nil)
    private let results = NSPopUpButton(frame: .zero, pullsDown: false)
    private let source = NSTextView()
    private let status = NSTextField(labelWithString: "Search the default project; choose a source to read its exact payload.")
    private let previous = NSButton(title: "Previous page", target: nil, action: nil)
    private let next = NSButton(title: "Next page", target: nil, action: nil)
    private let stop = NSButton(title: "Stop", target: nil, action: nil)
    private var coordinator: LocalReadCoordinator?
    private var activeToken: LocalReadToken?
    private var hits: [MemoryHit] = []
    private var offsets: [Int] = []
    private var nextOffset: Int?

    init(store: MemoryStore, projectID: String) {
        self.store = store; self.projectID = projectID
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 580),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        coordinator = LocalReadCoordinator(store: store, projectID: projectID)
        window.delegate = self
        window.title = "Boros — Memory · project: \(projectID)"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentMinSize = NSSize(width: 680, height: 400)
        queryField.placeholderString = "Search accepted history"
        queryField.target = self; queryField.action = #selector(search)
        let searchButton = NSButton(title: "Search", target: self, action: #selector(search))
        results.target = self; results.action = #selector(selectSource)
        previous.target = self; previous.action = #selector(previousPage)
        next.target = self; next.action = #selector(nextPage)
        stop.target = self; stop.action = #selector(stopRead); stop.isEnabled = false
        previous.isEnabled = false; next.isEnabled = false
        source.isEditable = false; source.isSelectable = true; source.isRichText = false
        source.frame = NSRect(x: 0, y: 0, width: 780, height: 300)
        source.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        source.textContainerInset = NSSize(width: 10, height: 10)
        source.isVerticallyResizable = true; source.isHorizontallyResizable = false
        source.minSize = .zero
        source.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        source.autoresizingMask = [.width]
        source.textContainer?.widthTracksTextView = true
        source.textContainer?.containerSize = NSSize(width: 780, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.documentView = source
        let searchRow = NSStackView(views: [queryField, literal, searchButton])
        searchRow.orientation = .horizontal; searchRow.spacing = 10
        let pages = NSStackView(views: [previous, next, stop]); pages.spacing = 10
        let stack = NSStackView(views: [searchRow, results, scroll, pages, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        for view in [searchRow, results, scroll] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -16),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        window.center()
    }

    func show() {
        if coordinator == nil { coordinator = LocalReadCoordinator(store: store, projectID: projectID) }
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(queryField)
    }

    func windowWillClose(_ notification: Notification) {
        coordinator?.close(); coordinator = nil; activeToken = nil
        stop.isEnabled = false
    }

    @objc private func search() {
        guard let coordinator else { return }
        hits = []; results.removeAllItems(); clearPage()
        setBusy(true); status.stringValue = "Searching accepted sources in project \(projectID)…"
        do {
            activeToken = try coordinator.search(query: queryField.stringValue,
                mode: literal.state == .on ? .literal : .lexical, limit: 8) { [weak self] delivery in
                    guard let self, self.activeToken == delivery.token else { return }
                    self.activeToken = nil; self.setBusy(false)
                    guard case .search(let result) = delivery.content,
                          delivery.outcome == .completed || delivery.outcome == .budgetLimited else {
                        self.status.stringValue = self.failureMessage(delivery.outcome); return
                    }
                    self.hits = result.hits
                    self.results.removeAllItems()
                    self.results.addItems(withTitles: self.hits.map {
                        "\($0.role.rawValue) · \($0.eventID) · " + String($0.preview.prefix(60)).replacingOccurrences(of: "\n", with: " ")
                    })
                    self.results.isEnabled = !self.hits.isEmpty
                    if let page = result.firstPage { self.display(page: page, offsets: [0]) }
                    switch result.coverage {
                    case .resourceLimited:
                        self.status.stringValue = "Partial search: its operation budget was reached. \(self.hits.count) sources found; select a source to read a page."
                    case .candidateWindow:
                        self.status.stringValue = "Showing \(self.hits.count) ranked sources. Additional sources may match."
                    case .resultLimit:
                        self.status.stringValue = "Showing \(self.hits.count) literal matches. Additional sources remain unsearched."
                    case .sourceWindow:
                        self.status.stringValue = "Partial literal search: the source window was reached. \(self.hits.count) matches found."
                    case .complete:
                        if self.hits.isEmpty { self.status.stringValue = "No sources matched in project \(self.projectID)." }
                    }
                }
        } catch { coordinator.cancel(); activeToken = nil; setBusy(false); status.stringValue = "Memory search failed. Check the query and local store." }
    }

    @objc private func selectSource() {
        guard hits.indices.contains(results.indexOfSelectedItem) else { return }
        loadPage(offset: 0, proposedOffsets: [0])
    }

    private func loadPage(offset: Int, proposedOffsets: [Int]) {
        guard let coordinator, hits.indices.contains(results.indexOfSelectedItem) else { return }
        let hit = hits[results.indexOfSelectedItem]
        guard episodeIdentifierEqual(hit.projectID, projectID) else { return }
        clearPage(); setBusy(true); status.stringValue = "Reading selected source page…"
        do {
            activeToken = try coordinator.sourcePage(source: LocalReadSourceIdentity(hit: hit), offset: offset) { [weak self] delivery in
                guard let self, self.activeToken == delivery.token else { return }
                self.activeToken = nil; self.setBusy(false)
                guard delivery.outcome == .completed, case .page(let page) = delivery.content else {
                    self.status.stringValue = self.failureMessage(delivery.outcome); return
                }
                self.display(page: page, offsets: proposedOffsets)
            }
        } catch { coordinator.cancel(); activeToken = nil; setBusy(false); status.stringValue = "Exact source read failed." }
    }

    @objc private func nextPage() {
        guard let offset = nextOffset else { return }
        loadPage(offset: offset, proposedOffsets: offsets + [offset])
    }

    @objc private func previousPage() {
        guard offsets.count > 1 else { return }
        let proposed = Array(offsets.dropLast())
        loadPage(offset: proposed.last!, proposedOffsets: proposed)
    }

    @objc private func stopRead() {
        coordinator?.cancel(); activeToken = nil; clearPage(); setBusy(false)
        status.stringValue = "Read stopped. Start a search or select a source to read again."
    }

    private func clearPage() {
        source.string = ""; offsets = []; nextOffset = nil
        previous.isEnabled = false; next.isEnabled = false
    }

    private func setBusy(_ busy: Bool) {
        results.isEnabled = !busy && !hits.isEmpty; stop.isEnabled = busy
        if busy { previous.isEnabled = false; next.isEnabled = false }
    }

    private func display(page: PayloadPage, offsets: [Int]) {
        source.string = page.text; source.scrollRangeToVisible(NSRange(location: 0, length: 0))
        self.offsets = offsets; nextOffset = page.nextOffset
        previous.isEnabled = offsets.count > 1; next.isEnabled = nextOffset != nil
        status.stringValue = "Source \(page.eventID) · \(page.status.rawValue) · bytes \(page.offset)..<\(page.offset + page.byteCount) of \(page.totalBytes) · SHA-256 \(page.digest)"
    }

    private func failureMessage(_ outcome: LocalReadOutcome) -> String {
        switch outcome {
        case .budgetLimited: return "This read reached its operation budget. Select a source or page to start another read."
        case .deadlineExceeded: return "This read exceeded its deadline. Start another read when ready."
        case .cancelled: return "Read stopped."
        case .completed, .failed: return "Exact source read failed. The source or local store could not be verified."
        }
    }
}
