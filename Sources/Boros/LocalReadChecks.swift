import Foundation
import CSQLite

/// Uses isolated synthetic stores and real dispatch queues. No captured source
/// bytes or descriptor contents are printed by the verification harness.
enum LocalReadChecks {
    private final class Clock: EpisodeClockSource, @unchecked Sendable {
        private let lock = NSLock()
        private var ticks: UInt64 = 1_000_000_000
        func advance(milliseconds: UInt64) { lock.lock(); ticks += milliseconds * 1_000_000; lock.unlock() }
        func now() throws -> EpisodeClockSnapshot {
            lock.lock(); defer { lock.unlock() }
            return EpisodeClockSnapshot(domain: "synthetic-local-read-clock", continuousNanoseconds: ticks,
                utc: Date(timeIntervalSince1970: 1_700_000_000))
        }
    }
    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var deliveries: [LocalReadDelivery] = []
        let ready = DispatchSemaphore(value: 0)
        func accept(_ delivery: LocalReadDelivery) {
            lock.lock(); deliveries.append(delivery); lock.unlock(); ready.signal()
        }
        func wait() throws -> LocalReadDelivery {
            guard ready.wait(timeout: .now() + 10) == .success else { throw MemoryError.invalid("synthetic read completion timed out") }
            lock.lock(); defer { lock.unlock() }; return deliveries.last!
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return deliveries.count }
    }
    private final class Gate {
        let release = DispatchSemaphore(value: 0)
        init(queue: DispatchQueue) throws {
            let ready = DispatchSemaphore(value: 0)
            queue.async { [release] in ready.signal(); release.wait() }
            guard ready.wait(timeout: .now() + 5) == .success else { throw MemoryError.invalid("synthetic read gate timed out") }
        }
        deinit { release.signal() }
    }
    private static func drain(_ queue: DispatchQueue) throws {
        let ready = DispatchSemaphore(value: 0); queue.async { ready.signal() }
        guard ready.wait(timeout: .now() + 10) == .success else { throw MemoryError.invalid("synthetic read queue timed out") }
    }
    private static func count(_ name: String, directory: URL) throws -> Int {
        guard ["events", "conversations", "invocations", "episodes", "episode_work"].contains(name) else { throw MemoryError.invalid("invalid synthetic count") }
        var database: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("memory.sqlite3").path,
            &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw MemoryError.database("synthetic count could not open") }
        defer { sqlite3_finalize(statement); sqlite3_close(database) }
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM " + name, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { throw MemoryError.database("synthetic count failed") }
        return Int(sqlite3_column_int64(statement, 0))
    }

    static func run() throws -> [String: Bool] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-local-read-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory)
        let project = "synthetic-browser-project"
        let chat = try store.createConversation(projectID: project, title: "Synthetic source browsing")
        let other = try store.createConversation(projectID: "synthetic-browser-other", title: "Separate project")
        let payload = "browserneedle " + String(repeating: "synthetic café 中文 page content ", count: 400)
        let event = try store.append(conversationID: chat.id, role: .human, text: payload,
            status: .complete, turnID: "browser-source-turn", eventID: "browser-source")
        _ = try store.append(conversationID: other.id, role: .human, text: "browserneedle separate project",
            status: .complete, turnID: "other-source-turn", eventID: "other-browser-source")
        let source = try store.sourceReference(eventID: event.id, projectID: project)!
        let sourceCount = try count("events", directory: directory)
        let chatCount = try count("conversations", directory: directory)
        let invocationCount = try count("invocations", directory: directory)
        var checks: [String: Bool] = [:]

        let deliveryQueue = DispatchQueue(label: "dev.boros.synthetic-read.delivery")
        let coordinator = LocalReadCoordinator(store: store, projectID: project, deliveryQueue: deliveryQueue)
        defer { coordinator.close() }
        let searchInbox = Inbox()
        let search = try coordinator.search(query: "browserneedle", mode: .lexical, completion: searchInbox.accept)
        let searchDelivery = try searchInbox.wait()
        let secondOffset: Int
        if case .search(let result) = searchDelivery.content { secondOffset = result.firstPage?.nextOffset ?? 0 }
        else { secondOffset = 0 }
        checks["local_read_search_completed_authoritative_episode"] = searchDelivery.token == search
            && searchDelivery.outcome == .completed && searchDelivery.receipt?.state == .completed
        checks["local_read_search_origin_has_no_chat_bindings"] = searchDelivery.receipt?.origin.isLocalRead == true
            && searchDelivery.receipt?.conversationID == nil && searchDelivery.receipt?.turnID == nil
            && searchDelivery.receipt?.humanEventID == nil
        if case .localRead(let binding) = searchDelivery.receipt?.origin {
            checks["local_read_browser_binding_frozen"] = binding.initiator == .humanBrowser
                && binding.purpose == .searchInitialPage && binding.requestID == search.requestID
                && binding.descriptorVersion == "boros-local-browser-read-v1" && binding.descriptorSHA256.count == 64
        } else { checks["local_read_browser_binding_frozen"] = false }
        if case .search(let result) = searchDelivery.content {
            checks["local_read_search_has_scoped_hits_and_initial_page"] = result.hits.count == 1
                && result.hits.first?.projectID == project && result.firstPage?.eventID == event.id
                && result.firstPage?.digest == event.digest && result.coverage == .complete
            checks["local_read_initial_page_preserves_exact_bytes"] = result.firstPage.map {
                Data(payload.utf8).prefix($0.byteCount) == Data($0.text.utf8)
            } == true
        } else {
            checks["local_read_search_has_scoped_hits_and_initial_page"] = false
            checks["local_read_initial_page_preserves_exact_bytes"] = false
        }
        checks["local_read_search_and_first_page_share_two_slots"] = searchDelivery.receipt?.charged.memoryOperations == 2
            && searchDelivery.receipt?.charged.rawSourceBytes ?? 0 > source.byteCount

        let pageInbox = Inbox()
        let page = try coordinator.sourcePage(source: source, offset: secondOffset, completion: pageInbox.accept)
        let pageDelivery = try pageInbox.wait()
        checks["local_read_explicit_page_begins_separate_episode"] = page.episodeID != search.episodeID
            && pageDelivery.outcome == .completed && pageDelivery.receipt?.charged.memoryOperations == 1
        if case .page(let result) = pageDelivery.content {
            checks["local_read_explicit_page_checks_expected_identity"] = result.eventID == source.eventID
                && result.digest == source.digest && result.totalBytes == source.byteCount && result.offset == secondOffset && secondOffset > 0
        } else { checks["local_read_explicit_page_checks_expected_identity"] = false }
        if case .localRead(let binding) = pageDelivery.receipt?.origin {
            checks["local_read_explicit_page_has_page_purpose"] = binding.purpose == .sourcePage
        } else { checks["local_read_explicit_page_has_page_purpose"] = false }

        let altered = MemorySourceReference(sequence: source.sequence, eventID: source.eventID,
            conversationID: source.conversationID, projectID: source.projectID, role: source.role,
            status: source.status, createdAt: source.createdAt, digest: String(repeating: "f", count: 64), byteCount: source.byteCount)
        let alteredInbox = Inbox()
        _ = try coordinator.sourcePage(source: altered, offset: 0, completion: alteredInbox.accept)
        let alteredDelivery = try alteredInbox.wait()
        checks["local_read_altered_digest_rejected_before_payload"] = alteredDelivery.outcome == .failed
            && alteredDelivery.content == nil && alteredDelivery.receipt?.charged.rawSourceBytes == 0
        let alteredLength = MemorySourceReference(sequence: source.sequence, eventID: source.eventID,
            conversationID: source.conversationID, projectID: source.projectID, role: source.role,
            status: source.status, createdAt: source.createdAt, digest: source.digest, byteCount: source.byteCount - 1)
        let lengthInbox = Inbox()
        _ = try coordinator.sourcePage(source: alteredLength, offset: 0, completion: lengthInbox.accept)
        let lengthDelivery = try lengthInbox.wait()
        checks["local_read_altered_byte_count_rejected_before_payload"] = lengthDelivery.outcome == .failed
            && lengthDelivery.content == nil && lengthDelivery.receipt?.charged.rawSourceBytes == 0
        let alteredSequence = MemorySourceReference(sequence: source.sequence + 1, eventID: source.eventID,
            conversationID: source.conversationID, projectID: source.projectID, role: source.role,
            status: source.status, createdAt: source.createdAt, digest: source.digest, byteCount: source.byteCount)
        let sequenceInbox = Inbox()
        _ = try coordinator.sourcePage(source: alteredSequence, offset: 0, completion: sequenceInbox.accept)
        let sequenceDelivery = try sequenceInbox.wait()
        checks["local_read_altered_reference_sequence_rejected_before_payload"] = sequenceDelivery.outcome == .failed
            && sequenceDelivery.content == nil && sequenceDelivery.receipt?.charged.rawSourceBytes == 0
        let alien = try store.sourceReference(eventID: "other-browser-source", projectID: other.projectID)!
        let beforeAlien = try count("episodes", directory: directory)
        do {
            _ = try coordinator.sourcePage(source: alien, offset: 0, completion: { _ in })
            checks["local_read_cross_project_page_denied_before_initiation"] = false
        } catch {
            checks["local_read_cross_project_page_denied_before_initiation"] = try count("episodes", directory: directory) == beforeAlien
        }

        var lastSlotLimits = EpisodeLimits(); lastSlotLimits.resources.memoryOperations = 1
        let lastSlot = LocalReadCoordinator(store: store, projectID: project, limits: lastSlotLimits,
            deliveryQueue: deliveryQueue)
        defer { lastSlot.close() }
        let lastInbox = Inbox()
        _ = try lastSlot.search(query: "browserneedle", mode: .lexical, completion: lastInbox.accept)
        let lastDelivery = try lastInbox.wait()
        checks["local_read_search_last_slot_cannot_reset_for_initial_page"] = lastDelivery.outcome == .budgetLimited
            && lastDelivery.receipt?.state == .budgetExceeded && lastDelivery.receipt?.charged.memoryOperations == 1
        if case .search(let result) = lastDelivery.content {
            checks["local_read_last_slot_returns_explicit_partial_hits"] = result.hits.count == 1
                && result.firstPage == nil && result.coverage == .resourceLimited
        } else { checks["local_read_last_slot_returns_explicit_partial_hits"] = false }
        let lastPageInbox = Inbox()
        let lastPageToken = try lastSlot.sourcePage(source: source, offset: 0, completion: lastPageInbox.accept)
        let lastPageDelivery = try lastPageInbox.wait()
        checks["local_read_explicit_page_after_partial_is_new_human_operation"] = lastPageDelivery.outcome == .completed
            && lastPageToken.episodeID != lastDelivery.token.episodeID && lastPageDelivery.receipt?.charged.memoryOperations == 1

        var rawLimits = EpisodeLimits(); rawLimits.resources.rawSourceBytes = 0
        let rawLimited = LocalReadCoordinator(store: store, projectID: project, limits: rawLimits,
            deliveryQueue: deliveryQueue)
        defer { rawLimited.close() }
        for mode in [LocalReadSearchMode.lexical, .literal] {
            let inbox = Inbox()
            _ = try rawLimited.search(query: "browserneedle", mode: mode, completion: inbox.accept)
            let delivery = try inbox.wait()
            checks["local_read_" + mode.rawValue + "_raw_budget_explicit_no_match_uncertainty"] = delivery.outcome == .budgetLimited
                && delivery.receipt?.state == .budgetExceeded && delivery.receipt?.charged.rawSourceBytes == 0
                && delivery.receipt?.charged.memoryOperations == 1
            if case .search(let result) = delivery.content {
                checks["local_read_" + mode.rawValue + "_limited_scan_skips_implicit_page"] = result.hits.isEmpty
                    && result.firstPage == nil && result.coverage == .resourceLimited
            } else { checks["local_read_" + mode.rawValue + "_limited_scan_skips_implicit_page"] = false }
        }

        let literalInbox = Inbox()
        _ = try coordinator.search(query: "browserneedle", mode: .literal, completion: literalInbox.accept)
        let literalDelivery = try literalInbox.wait()
        checks["local_read_literal_search_and_initial_page_share_episode"] = literalDelivery.outcome == .completed
            && literalDelivery.receipt?.charged.memoryOperations == 2
        let emptyInbox = Inbox()
        _ = try coordinator.search(query: "unmatchedsyntheticneedle", mode: .lexical, completion: emptyInbox.accept)
        let emptyDelivery = try emptyInbox.wait()
        if case .search(let result) = emptyDelivery.content {
            checks["local_read_complete_no_match_is_separate_from_budget_partial"] = result.hits.isEmpty
                && result.coverage == .complete && emptyDelivery.outcome == .completed
                && emptyDelivery.receipt?.charged.memoryOperations == 1
        } else { checks["local_read_complete_no_match_is_separate_from_budget_partial"] = false }

        // A queued worker is real elapsed operation time, even before its first
        // source inspection. The fake continuous clock makes this deterministic.
        let deadlineClock = Clock(), deadlineQueue = DispatchQueue(label: "dev.boros.synthetic-read.deadline")
        let deadlineGate = try Gate(queue: deadlineQueue)
        var deadlineLimits = EpisodeLimits(); deadlineLimits.deadlineMilliseconds = 100
        let deadlineCoordinator = LocalReadCoordinator(store: store, projectID: project, limits: deadlineLimits,
            clock: deadlineClock, workQueue: deadlineQueue, deliveryQueue: deliveryQueue)
        defer { deadlineCoordinator.close() }
        let deadlineInbox = Inbox()
        let deadlineToken = try deadlineCoordinator.search(query: "browserneedle", mode: .lexical, completion: deadlineInbox.accept)
        let queued = try store.episodeReceipt(id: deadlineToken.episodeID, clock: deadlineClock.now())
        checks["local_read_persists_episode_before_worker_queue"] = queued.state == .active && queued.charged == .zero
        deadlineClock.advance(milliseconds: 101); deadlineGate.release.signal()
        let deadlineDelivery = try deadlineInbox.wait()
        checks["local_read_worker_queue_delay_consumes_original_deadline"] = deadlineDelivery.outcome == .deadlineExceeded
            && deadlineDelivery.receipt?.state == .deadlineExceeded && deadlineDelivery.receipt?.charged == .zero
            && deadlineDelivery.content == nil

        // Stop and window close interrupt before the blocked worker can read.
        for close in [false, true] {
            let queue = DispatchQueue(label: "dev.boros.synthetic-read.cancel"), gate = try Gate(queue: queue)
            let reader = LocalReadCoordinator(store: store, projectID: project, workQueue: queue, deliveryQueue: deliveryQueue)
            let inbox = Inbox()
            let token = try reader.search(query: "browserneedle", mode: .literal, completion: inbox.accept)
            let began = Date()
            if close { reader.close() } else { reader.cancel() }
            let action = close ? "close" : "stop"
            checks["local_read_" + action + "_does_not_wait_for_worker"] = Date().timeIntervalSince(began) < 0.2
            gate.release.signal(); try drain(queue); try drain(deliveryQueue)
            let receipt = try store.episodeReceipt(id: token.episodeID, clock: SystemEpisodeClock().now())
            checks["local_read_" + action + "_fences_delivery_and_source_work"] = inbox.count == 0
                && receipt.state == .cancelled && receipt.charged == .zero && receipt.held == .zero
            if close {
                do { _ = try reader.search(query: "browserneedle", mode: .lexical, completion: inbox.accept)
                    checks["local_read_closed_coordinator_cannot_begin"] = false
                } catch EpisodeBudgetError.inactive { checks["local_read_closed_coordinator_cannot_begin"] = true }
            }
            reader.close()
        }

        let supersessionQueue = DispatchQueue(label: "dev.boros.synthetic-read.supersession")
        let supersessionGate = try Gate(queue: supersessionQueue)
        let supersession = LocalReadCoordinator(store: store, projectID: project, workQueue: supersessionQueue,
            deliveryQueue: deliveryQueue)
        defer { supersession.close() }
        let oldInbox = Inbox(), newInbox = Inbox()
        let oldToken = try supersession.search(query: "browserneedle", mode: .literal, completion: oldInbox.accept)
        let newToken = try supersession.search(query: "browserneedle", mode: .lexical, completion: newInbox.accept)
        supersessionGate.release.signal()
        let newest = try newInbox.wait(); try drain(supersessionQueue); try drain(deliveryQueue)
        let oldReceipt = try store.episodeReceipt(id: oldToken.episodeID, clock: SystemEpisodeClock().now())
        checks["local_read_supersession_delivers_only_newest_generation"] = oldInbox.count == 0
            && newInbox.count == 1 && newest.token == newToken && newest.outcome == .completed
        checks["local_read_supersession_cancels_old_durable_episode"] = oldReceipt.state == .cancelled
            && oldReceipt.charged == .zero && oldReceipt.held == .zero

        // Finish may be ready while the UI queue is blocked. Cancellation and
        // generation changes still suppress that queued completion callback.
        let blockedDeliveryQueue = DispatchQueue(label: "dev.boros.synthetic-read.stale-delivery")
        let deliveryGate = try Gate(queue: blockedDeliveryQueue)
        let staleWorkQueue = DispatchQueue(label: "dev.boros.synthetic-read.stale-work")
        let stale = LocalReadCoordinator(store: store, projectID: project, workQueue: staleWorkQueue,
            deliveryQueue: blockedDeliveryQueue)
        defer { stale.close() }
        let staleInbox = Inbox(), freshInbox = Inbox()
        let staleToken = try stale.search(query: "browserneedle", mode: .lexical, completion: staleInbox.accept)
        try drain(staleWorkQueue)
        let readyReceipt = try store.episodeReceipt(id: staleToken.episodeID, clock: SystemEpisodeClock().now())
        checks["local_read_worker_completion_keeps_publication_deadline_active"] = readyReceipt.state == .active && staleInbox.count == 0
        let freshToken = try stale.sourcePage(source: source, offset: 0, completion: freshInbox.accept)
        try drain(staleWorkQueue); deliveryGate.release.signal()
        let freshDelivery = try freshInbox.wait(); try drain(blockedDeliveryQueue)
        checks["local_read_stale_finished_delivery_fenced_after_new_action"] = staleInbox.count == 0
            && freshInbox.count == 1 && freshDelivery.token == freshToken && freshDelivery.outcome == .completed

        let delayedQueue = DispatchQueue(label: "dev.boros.synthetic-read.delivery-deadline")
        let delayedGate = try Gate(queue: delayedQueue), delayedClock = Clock()
        let delayedWorker = DispatchQueue(label: "dev.boros.synthetic-read.delivery-deadline-work")
        let delayed = LocalReadCoordinator(store: store, projectID: project, limits: deadlineLimits,
            clock: delayedClock, workQueue: delayedWorker, deliveryQueue: delayedQueue)
        defer { delayed.close() }
        let delayedInbox = Inbox()
        let delayedToken = try delayed.sourcePage(source: source, offset: 0, completion: delayedInbox.accept)
        try drain(delayedWorker)
        let unpublished = try store.episodeReceipt(id: delayedToken.episodeID, clock: delayedClock.now())
        checks["local_read_ui_queue_wait_is_inside_episode_deadline"] = unpublished.state == .active
            && unpublished.charged.memoryOperations == 1 && delayedInbox.count == 0
        delayedClock.advance(milliseconds: 101); delayedGate.release.signal()
        let delayedDelivery = try delayedInbox.wait()
        checks["local_read_expired_queued_page_cannot_publish_source_bytes"] = delayedDelivery.outcome == .deadlineExceeded
            && delayedDelivery.receipt?.state == .deadlineExceeded && delayedDelivery.content == nil

        for close in [false, true] {
            let publicationQueue = DispatchQueue(label: "dev.boros.synthetic-read.publication-cancel")
            let publicationGate = try Gate(queue: publicationQueue)
            let worker = DispatchQueue(label: "dev.boros.synthetic-read.publication-cancel-worker")
            let reader = LocalReadCoordinator(store: store, projectID: project,
                workQueue: worker, deliveryQueue: publicationQueue)
            let inbox = Inbox()
            let token = try reader.sourcePage(source: source, offset: 0, completion: inbox.accept)
            try drain(worker)
            if close { reader.close() } else { reader.cancel() }
            publicationGate.release.signal(); try drain(publicationQueue)
            // The owner receipt read can race only the short cancellation
            // transaction. Drain a cancelled worker result separately before
            // checking its final state using another explicit read barrier.
            let end = Date().addingTimeInterval(2)
            var receipt = try store.episodeReceipt(id: token.episodeID, clock: SystemEpisodeClock().now())
            while receipt.state == .active && Date() < end {
                Thread.sleep(forTimeInterval: 0.001)
                receipt = try store.episodeReceipt(id: token.episodeID, clock: SystemEpisodeClock().now())
            }
            checks["local_read_" + (close ? "close" : "stop") + "_suppresses_ready_unpublished_page"] = inbox.count == 0
                && receipt.state == .cancelled && receipt.charged.memoryOperations == 1 && receipt.charged.rawSourceBytes > 0
            reader.close()
        }

        let invalidQueue = DispatchQueue(label: "dev.boros.synthetic-read.invalid-supersession")
        let invalidGate = try Gate(queue: invalidQueue)
        let invalid = LocalReadCoordinator(store: store, projectID: project,
            workQueue: invalidQueue, deliveryQueue: deliveryQueue)
        defer { invalid.close() }
        let invalidInbox = Inbox()
        let invalidPrevious = try invalid.search(query: "browserneedle", mode: .literal, completion: invalidInbox.accept)
        let beforeInvalid = try count("episodes", directory: directory)
        do {
            _ = try invalid.search(query: String(repeating: "x", count: 4097), mode: .lexical, completion: invalidInbox.accept)
            checks["local_read_invalid_replacement_does_not_start_episode"] = false
        } catch {
            checks["local_read_invalid_replacement_does_not_start_episode"] = try count("episodes", directory: directory) == beforeInvalid
        }
        invalidGate.release.signal(); try drain(invalidQueue); try drain(deliveryQueue)
        let invalidReceipt = try store.episodeReceipt(id: invalidPrevious.episodeID, clock: SystemEpisodeClock().now())
        checks["local_read_invalid_replacement_cancels_previous_read"] = invalidInbox.count == 0
            && invalidReceipt.state == .cancelled && invalidReceipt.charged == .zero

        checks["local_read_browser_never_creates_source_events"] = try count("events", directory: directory) == sourceCount
        checks["local_read_browser_never_creates_hidden_conversations"] = try count("conversations", directory: directory) == chatCount
        checks["local_read_browser_never_creates_model_invocations"] = try count("invocations", directory: directory) == invocationCount
        checks["local_read_browser_records_durable_operations"] = try count("episodes", directory: directory) >= 15
            && count("episode_work", directory: directory) > 0
        checks.merge(try unicodeScopeChecks()) { _, latest in latest }
        return checks
    }

    private static func unicodeScopeChecks() throws -> [String: Bool] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-unicode-read-scope-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(directory: directory)
        let composed = "unicode-project-caf\u{e9}", decomposed = "unicode-project-cafe\u{301}"
        let first = try store.createConversation(projectID: composed, title: "Composed scope")
        let second = try store.createConversation(projectID: decomposed, title: "Decomposed scope")
        let firstID = "unicode-event-caf\u{e9}", secondID = "unicode-event-cafe\u{301}"
        _ = try store.append(conversationID: first.id, role: .human, text: "Synthetic composed source bytes",
            status: .complete, turnID: "unicode-first-turn", eventID: firstID)
        _ = try store.append(conversationID: second.id, role: .human, text: "Synthetic decomposed source bytes",
            status: .complete, turnID: "unicode-second-turn", eventID: secondID)
        let source = try store.sourceReference(eventID: secondID, projectID: decomposed)!
        let originalSources = try count("events", directory: directory)
        let originalChats = try count("conversations", directory: directory)
        let originalInvocations = try count("invocations", directory: directory)
        let clock = SystemEpisodeClock(), id = UUID().uuidString
        let binding = EpisodeLocalReadBinding(initiator: .syntheticEvaluation, purpose: .retrievalProbe,
            requestID: UUID().uuidString, descriptorVersion: "unicode-read-scope-v1",
            descriptorSHA256: MeteredRetrieval.digest(Data("Synthetic UTF8 scope contract".utf8)))
        _ = try store.beginLocalReadEpisode(episodeID: id, projectID: composed, binding: binding,
            limits: .init(), clock: clock.now())
        let lease = EpisodeLease(ledger: store, episodeID: id, clock: clock)
        var checks: [String: Bool] = [:]
        checks["local_read_unicode_fixture_is_swift_equal_but_utf8_distinct"] = composed == decomposed
            && Data(composed.utf8) != Data(decomposed.utf8) && firstID == secondID && Data(firstID.utf8) != Data(secondID.utf8)
        checks["local_read_unicode_fixture_is_two_actual_sqlite_scopes"] = try store.listConversations(projectID: composed).count == 1
            && store.listConversations(projectID: decomposed).count == 1 && first.id != second.id
            && store.sourceReference(eventID: secondID, projectID: composed) == nil
            && store.sourceReference(eventID: firstID, projectID: decomposed) == nil
        func scopeDenied(_ body: () throws -> Void) -> Bool {
            do { try body(); return false }
            catch EpisodeBudgetError.scopeMismatch { return true }
            catch { return false }
        }
        checks["local_read_unicode_project_alias_page_denied_before_lookup"] = scopeDenied {
            _ = try MeteredRetrieval.page(store: store, eventID: secondID, projectID: decomposed,
                offset: 0, length: 16, lease: lease)
        }
        checks["local_read_unicode_project_alias_source_read_denied_before_lookup"] = scopeDenied {
            _ = try MeteredRetrieval.read(store: store, source: source, offset: 0, length: 16, lease: lease)
        }
        checks["local_read_unicode_project_alias_full_load_denied_before_lookup"] = scopeDenied {
            _ = try MeteredRetrieval.load(store: store, reference: source, lease: lease)
        }
        checks["local_read_unicode_project_alias_context_denied_before_lookup"] = scopeDenied {
            _ = try ContextAssembler.prepare(store: store, conversationID: second.id, projectID: decomposed,
                prompt: "Synthetic scoped request", system: "", episodeLease: lease)
        }
        let untouched = try lease.checkActive(projectID: composed)
        let deniedWorkCount = try count("episode_work", directory: directory)
        checks["local_read_unicode_scope_denials_preserve_zero_resources"] = untouched.state == .active
            && untouched.charged == .zero && untouched.held == .zero && untouched.unknownInputOperations == 0
            && deniedWorkCount == 0
        // A caller supplying the lease's scope while selecting the other actual
        // conversation must also fail at the conversation metadata boundary.
        do {
            _ = try ContextAssembler.prepare(store: store, conversationID: second.id, projectID: composed,
                prompt: "Synthetic scoped request", system: "", episodeLease: lease)
            checks["local_read_unicode_conversation_scope_alias_is_rejected"] = false
        } catch ContextError.scopeMismatch {
            let receipt = try lease.checkActive(projectID: composed)
            checks["local_read_unicode_conversation_scope_alias_is_rejected"] = receipt.charged.rawSourceBytes == 0
                && receipt.charged.memoryOperations == 1 && receipt.charged.metadataRows == 1 && receipt.state == .active
        }
        let finished = try lease.finish(reason: .completed)
        checks["local_read_unicode_denial_receipt_is_authoritatively_terminal"] = finished.state == .completed
            && episodeIdentifierEqual(finished.projectID, composed) && finished.held == .zero
        let reader = LocalReadCoordinator(store: store, projectID: composed,
            deliveryQueue: DispatchQueue(label: "dev.boros.synthetic-unicode-read.delivery"))
        defer { reader.close() }
        let originalEpisodes = try count("episodes", directory: directory)
        do {
            _ = try reader.sourcePage(source: source, offset: 0, completion: { _ in })
            checks["local_read_unicode_coordinator_project_alias_denied_before_episode"] = false
        } catch {
            checks["local_read_unicode_coordinator_project_alias_denied_before_episode"] = try count("episodes", directory: directory) == originalEpisodes
        }
        let changedEvent = MemorySourceReference(sequence: source.sequence, eventID: firstID,
            conversationID: source.conversationID, projectID: source.projectID, role: source.role,
            status: source.status, createdAt: source.createdAt, digest: source.digest, byteCount: source.byteCount)
        checks["local_read_unicode_event_identity_uses_utf8_bytes"] = !LocalReadSourceIdentity(reference: changedEvent).matches(source)
        let conversationA = MemorySourceReference(sequence: source.sequence, eventID: source.eventID,
            conversationID: "unicode-conversation-caf\u{e9}", projectID: source.projectID, role: source.role,
            status: source.status, createdAt: source.createdAt, digest: source.digest, byteCount: source.byteCount)
        let conversationB = MemorySourceReference(sequence: source.sequence, eventID: source.eventID,
            conversationID: "unicode-conversation-cafe\u{301}", projectID: source.projectID, role: source.role,
            status: source.status, createdAt: source.createdAt, digest: source.digest, byteCount: source.byteCount)
        checks["local_read_unicode_conversation_identity_uses_utf8_bytes"] = conversationA.conversationID == conversationB.conversationID
            && !LocalReadSourceIdentity(reference: conversationA).matches(conversationB)
        checks["local_read_unicode_denials_create_no_hidden_sources_or_chats"] = try count("events", directory: directory) == originalSources
            && count("conversations", directory: directory) == originalChats && count("invocations", directory: directory) == originalInvocations
        return checks
    }
}
