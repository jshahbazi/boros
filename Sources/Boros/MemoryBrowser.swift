import AppKit
import Foundation

/// Exact source reads stay in the project selected by the host UI.
final class MemoryBrowser: NSObject {
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
    private var hits: [MemoryHit] = []
    private var offsets: [Int] = []
    private var nextOffset: Int?

    init(store: MemoryStore, projectID: String) {
        self.store = store; self.projectID = projectID
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 580),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
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
        let pages = NSStackView(views: [previous, next]); pages.spacing = 10
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

    func show() { window.makeKeyAndOrderFront(nil); window.makeFirstResponder(queryField) }

    @objc private func search() {
        do {
            hits = try literal.state == .on
                ? store.literalSearch(query: queryField.stringValue, projectID: projectID, limit: 8)
                : store.search(query: queryField.stringValue, projectID: projectID, limit: 8)
            results.removeAllItems()
            results.addItems(withTitles: hits.map { "\($0.role.rawValue) · \($0.eventID) · " + String($0.preview.prefix(60)).replacingOccurrences(of: "\n", with: " ") })
            source.string = ""; offsets = []; nextOffset = nil
            previous.isEnabled = false; next.isEnabled = false
            if hits.isEmpty { status.stringValue = "No sources matched in project \(projectID)." }
            else { selectSource() }
        } catch { status.stringValue = "Memory search failed. Check the query and local store." }
    }

    @objc private func selectSource() {
        guard hits.indices.contains(results.indexOfSelectedItem) else { return }
        offsets = [0]; loadPage(offset: 0)
    }

    private func loadPage(offset: Int) {
        guard hits.indices.contains(results.indexOfSelectedItem) else { return }
        let hit = hits[results.indexOfSelectedItem]
        // Only identifiers returned by the current project-scoped query can reach this read.
        guard hit.projectID == projectID else { return }
        do {
            let page = try store.read(eventID: hit.eventID, offset: offset, length: MemoryStore.maximumPageBytes)
            source.string = page.text
            source.scrollRangeToVisible(NSRange(location: 0, length: 0))
            nextOffset = page.nextOffset
            previous.isEnabled = offsets.count > 1; next.isEnabled = nextOffset != nil
            status.stringValue = "Source \(page.eventID) · \(page.status.rawValue) · bytes \(page.offset)..<\(page.offset + page.byteCount) of \(page.totalBytes) · SHA-256 \(page.digest)"
        } catch { status.stringValue = "Exact source read failed."; next.isEnabled = false }
    }

    @objc private func nextPage() {
        guard let offset = nextOffset else { return }
        offsets.append(offset); loadPage(offset: offset)
    }

    @objc private func previousPage() {
        guard offsets.count > 1 else { return }
        offsets.removeLast(); loadPage(offset: offsets.last!)
    }
}
