import Foundation

// Standalone P2 latency diagnostic for the explicit exchange policies. The
// application build never compiles this file. Input is the public synthetic
// scaling fixture; output contains only counts, statuses and timings.
private struct FixtureSet: Decodable { let histories: [FixtureHistory] }
private struct FixtureHistory: Decodable {
    let id: String
    let events: [FixtureEvent]
    let episodes: [FixtureEpisode]
}
private struct FixtureEvent: Decodable {
    let id: String
    let projectID: String
    let conversationKey: String
    let role: MemoryRole
    let status: CaptureStatus
    let text: String
}
private struct FixtureEpisode: Decodable {
    let id: String
    let projectID: String
    let conversationKey: String
    let prompt: String
}

@main
enum ExchangeLatencyHarness {
    static let policies: [(String, ContextComponentPolicy)] = [("recent_only", .selectedQwen),
        ("exchange_adjacent", .selectedQwenExchangeAdjacent), ("exchange_packed", .selectedQwenExchangePacked)]

    static func elapsed(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 4, ["warm", "restart"].contains(args[0]), args.dropFirst().allSatisfy({ $0.hasPrefix("/") }),
              !FileManager.default.fileExists(atPath: args[3]) else {
            fputs("Usage: ExchangeLatencyHarness (warm|restart) ABS_FIXTURES ABS_RUNTIME NEW_ABS_OUTPUT\n", stderr); exit(2)
        }
        do {
            let fixtures = try JSONDecoder().decode(FixtureSet.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
            guard fixtures.histories.count == 1, let history = fixtures.histories.first else { throw MemoryError.database("fixture") }
            let report = try run(history, mode: args[0], runtime: URL(fileURLWithPath: args[2], isDirectory: true))
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            FileManager.default.createFile(atPath: args[3], contents: data, attributes: [.posixPermissions: 0o600])
        } catch {
            fputs("Exchange latency diagnostic failed.\n", stderr); exit(1)
        }
    }

    fileprivate static func run(_ history: FixtureHistory, mode: String, runtime: URL) throws -> [String: Any] {
        let directory = runtime.appendingPathComponent("store", isDirectory: true)
        let mappingURL = runtime.appendingPathComponent("conversations.json")
        let openStart = DispatchTime.now().uptimeNanoseconds
        let store = try MemoryStore(directory: directory)
        let openMilliseconds = elapsed(openStart)
        var conversations: [String: String] = [:]
        var ingestion: Any = NSNull()
        if mode == "warm" {
            let start = DispatchTime.now().uptimeNanoseconds
            for source in history.events {
                let key = source.projectID + ":" + source.conversationKey
                if conversations[key] == nil {
                    conversations[key] = try store.createConversation(projectID: source.projectID, title: "Public synthetic evaluation").id
                }
                _ = try store.append(conversationID: conversations[key]!, role: source.role, text: source.text,
                                     status: source.status, turnID: source.id + "-turn", eventID: source.id)
            }
            try JSONEncoder().encode(conversations).write(to: mappingURL, options: .atomic)
            ingestion = elapsed(start)
        } else {
            conversations = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: mappingURL))
        }
        var probes: [[String: Any]] = []
        for (index, episode) in history.episodes.enumerated() {
            guard let conversation = conversations[episode.projectID + ":" + episode.conversationKey] else {
                throw MemoryError.database("fixture conversation")
            }
            var probe: [String: Any] = ["index": index]
            for (name, policy) in policies {
                probe[name] = try attempt(store: store, conversationID: conversation, projectID: episode.projectID,
                    prompt: episode.prompt, label: mode + "-\(index)-" + name, policy: policy)
            }
            probe["uncapped_stages"] = try uncapped(store: store, projectID: episode.projectID, prompt: episode.prompt)
            probes.append(probe)
        }
        return ["mode": mode, "event_count": history.events.count,
                "source_bytes": history.events.reduce(0) { $0 + $1.text.utf8.count },
                "store_open_milliseconds": openMilliseconds, "ingestion_milliseconds": ingestion, "probes": probes,
                "limits": ["maximum_sources": ExchangeBlockQuery.maximumSources, "maximum_source_bytes": ExchangeBlockQuery.maximumSourceBytes]]
    }

    /// One accepted request per policy: recent selection, then (for the
    /// exchange policies) the ordinary-path evidence entry point.
    static func attempt(store: MemoryStore, conversationID: String, projectID: String, prompt: String, label: String,
                        policy: ContextComponentPolicy) throws -> [String: Any] {
        var limits = EpisodeLimits(); limits.componentPolicy = policy
        let clock = SystemEpisodeClock(), episodeID = UUID().uuidString, humanID = "latency-" + label + "-" + episodeID
        _ = try store.acceptRequestAndBeginEpisode(conversationID: conversationID, turnID: humanID + "-turn",
            humanEventID: humanID, episodeID: episodeID, text: prompt, limits: limits, clock: clock.now())
        let lease = EpisodeLease(ledger: store, episodeID: episodeID, clock: clock)
        defer { _ = try? lease.finish(reason: .cancelled) }
        let recentStart = DispatchTime.now().uptimeNanoseconds
        let recent = try ContextAssembler.prepareRecent(store: store, conversationID: conversationID, projectID: projectID,
            prompt: prompt, system: "Synthetic latency host", excludingEventID: humanID, episodeLease: lease, componentPolicy: policy)
        var result: [String: Any] = ["recent_milliseconds": elapsed(recentStart)]
        guard policy.usesExchangeQuery else { return result }
        let evidenceStart = DispatchTime.now().uptimeNanoseconds
        do {
            let snapshot = try ExchangeBlockQuery.prepareEvidence(recent: recent, store: store, conversationID: conversationID,
                projectID: projectID, prompt: prompt, excludingEventID: humanID, episodeLease: lease,
                lexicalQueryUTF8Range: nil, componentPolicy: policy)
            result["status"] = "selected"; result["evidence_spans"] = snapshot.evidence.count
            let audit = try snapshot.retrievalAuditJSON.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            result["indexed_source_count"] = (audit?["exchange_query"] as? [String: Any])?["indexed_source_count"] ?? NSNull()
        } catch ExchangeBlockQuery.Failure.snapshotLimit {
            result["status"] = "refused_snapshot_limit"
        } catch {
            result["status"] = "error"
        }
        result["evidence_milliseconds"] = elapsed(evidenceStart)
        return result
    }

    /// Diagnostic only: the same stages with the 20,000-source snapshot cap
    /// lifted and no lease, to show what the in-memory index costs at scale.
    static func uncapped(store: MemoryStore, projectID: String, prompt: String) throws -> [String: Any] {
        var start = DispatchTime.now().uptimeNanoseconds
        let frontier = try store.sourceFrontier(projectID: projectID)
        var references: [MemorySourceReference] = [], after = 0
        while true {
            let page = try store.sourceManifest(projectID: projectID, afterSequence: after, throughSequence: frontier, limit: 1000)
            references += page
            guard let last = page.last, page.count == 1000 else { break }
            after = last.sequence
        }
        let manifest = elapsed(start); start = DispatchTime.now().uptimeNanoseconds
        let sources = try references.map { ExchangeBlockQuery.Source(reference: $0, text: try store.loadCandidate(reference: $0).text) }
        let load = elapsed(start); start = DispatchTime.now().uptimeNanoseconds
        let index = ExchangeBlockQuery.Index(sources: sources)
        let build = elapsed(start); start = DispatchTime.now().uptimeNanoseconds
        let ranked = index.rank(ExchangeBlockQuery.query(prompt))
        let rank = elapsed(start); start = DispatchTime.now().uptimeNanoseconds
        let plan = try ExchangeBlockQuery.ValuePacking.plan(index: index, ranked: ranked, maximumSpans: 48, tokenBudget: 12_000,
            auditBudget: 22_000, selectionVersion: ContextSourceFraming.currentSelectionVersion)
        let pack = elapsed(start)
        return ["sources": sources.count, "bytes": sources.reduce(0) { $0 + $1.reference.byteCount },
                "blocks": index.blocks.count, "matched_blocks": ranked.count, "planned_spans": plan.hits.count,
                "manifest_milliseconds": manifest, "load_milliseconds": load, "index_milliseconds": build,
                "rank_milliseconds": rank, "pack_milliseconds": pack, "total_milliseconds": manifest + load + build + rank + pack]
    }
}
