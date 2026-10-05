import Foundation
import Darwin

/// Separate-process synthetic harness. The caller kills `produce` after ready;
/// no private runtime store, source text, or credentials are read or printed.
@main
enum SemanticCrashHarness {
    private final class Encoder: SemanticEmbeddingAdapter {
        let metadata = ["provider": "test-only-crash-protocol", "revision": "1", "dimension": "1"]
        let dimension = 1
        var block = false
        func encode(_ text: String) throws -> SemanticEncoding {
            if block {
                print("ready")
                fflush(stdout)
                _ = readLine() // Parent terminates this process with SIGKILL.
            }
            return .vector([1])
        }
    }

    static func main() {
        do {
            guard CommandLine.arguments.count == 3 else { throw SemanticError.invalid }
            let mode = CommandLine.arguments[1], directory = URL(fileURLWithPath: CommandLine.arguments[2])
            let store = try MemoryStore(directory: directory)
            let encoder = Encoder()
            var configuration = SemanticIndexConfiguration(); configuration.chunkBytes = 64
            let index = try SemanticIndex(store: store, encoder: encoder, configuration: configuration)
            if mode == "produce" {
                let conversation = try store.createConversation(projectID: "semantic-crash", title: "Synthetic killed worker")
                _ = try store.append(conversationID: conversation.id, role: .human,
                    text: String(repeating: "The bicycle crosses a river by the old stone bridge. café 🐈 ", count: 12),
                    status: .complete, turnID: "crash-turn", eventID: "semantic-crash-source")
                let first = try index.process(projectID: "semantic-crash", maximumChunks: 1)
                guard first.publishedChunks == 1 else { throw SemanticError.publicationConflict }
                encoder.block = true
                // At ready: first chunk+cursor are durable, second calculation
                // is armed, and its vector has not been published.
                _ = try index.process(projectID: "semantic-crash", maximumChunks: 1)
                throw SemanticError.invalid
            }
            guard mode == "recover" else { throw SemanticError.invalid }
            let before = try index.search(query: "unmatched fixture identifier", projectID: "semantic-crash")
            let work = try index.process(projectID: "semantic-crash", maximumChunks: 128)
            let after = try index.search(query: "unmatched fixture identifier", projectID: "semantic-crash")
            let source = try store.sourceReference(eventID: "semantic-crash-source", projectID: "semantic-crash")!
            var hasherBytes = Data(), offset = 0
            repeat {
                let page = try store.read(eventID: source.eventID, offset: offset, length: 4096)
                hasherBytes.append(Data(page.text.utf8))
                guard let next = page.nextOffset else { break }
                offset = next
            } while true
            let checks = [
                "sigkill_semantic_committed_cursor_retained": before.manifest.coverage.indexedChunks >= 1 && before.manifest.coverage.sources.first!.nextOffset > 0,
                "sigkill_semantic_unsealed_source_not_served": before.manifest.coverage.complete || before.manifest.vectorCandidatesInspected == 0,
                "sigkill_semantic_original_source_digest_preserved": SemanticIndex.digest(hasherBytes) == source.digest && hasherBytes.count == source.byteCount,
                "sigkill_semantic_resumes_to_complete_without_holes": after.manifest.coverage.complete && after.manifest.coverage.indexedChunks > 1 && after.manifest.coverage.indexedBytes == source.byteCount && work.failedChunks == 0,
                "sigkill_semantic_persisted_manifest_replays": try index.replay(manifestID: before.manifestID, projectID: "semantic-crash").manifest == before.manifest,
                "sigkill_semantic_completed_replay_no_new_work": try index.process(projectID: "semantic-crash").publishedChunks == 0
            ]
            print(String(decoding: try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]), as: UTF8.self))
            if checks.values.contains(false) { exit(1) }
        } catch {
            fputs("Semantic crash checks failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
