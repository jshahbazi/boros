#!/usr/bin/env python3
"""Compile and check the Swift memory core using isolated synthetic stores."""
import json
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
import Foundation
import Darwin

@main
enum MemoryHarness {
    static func main() {
        do {
            if CommandLine.arguments.count == 3 {
                let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
                if CommandLine.arguments[1] == "hold-owner" {
                    let store = try MemoryStore(directory: directory)
                    print("ready")
                    fflush(stdout)
                    _ = readLine()
                    withExtendedLifetime(store) {}
                    return
                }
                if CommandLine.arguments[1] == "probe-owner" {
                    do {
                        _ = try MemoryStore(directory: directory)
                        print("owner_was_not_rejected")
                        exit(1)
                    } catch MemoryError.ownerBusy {
                        print("owner_rejected")
                        return
                    }
                }
                if CommandLine.arguments[1] == "crash-invocation" {
                    let store = try MemoryStore(directory: directory)
                    let conversation = try store.createConversation(projectID: "crash-synthetic", title: "Synthetic terminated stream")
                    let human = try store.append(conversationID: conversation.id, role: .human, text: "synthetic crash request", status: .complete, turnID: "crash-turn", eventID: "crash-human")
                    let body = Data("{ \"model\":\"synthetic\", \"messages\":[], \"stream\":true }".utf8)
                    let admission = Data("{\"input_tokens\":4,\"context_limit\":128}".utf8)
                    _ = try store.beginInvocation(invocationID: "crash-invocation", conversationID: conversation.id, turnID: human.turnID, humanEventID: human.id, assistantEventID: "crash-assistant", providerIdentity: "http://localhost:11234/v1/chat/completions", requestBody: body, admissionJSON: admission)
                    _ = try store.appendInvocationChunk(invocationID: "crash-invocation", sequence: 0, text: "CRASH_COMMITTED_SENTINEL café ")
                    _ = try store.appendInvocationChunk(invocationID: "crash-invocation", sequence: 1, text: "\u{1F680} received suffix")
                    let secondHuman = try store.append(conversationID: conversation.id, role: .human, text: "synthetic empty crash request", status: .complete, turnID: "empty-crash-turn", eventID: "empty-crash-human")
                    _ = try store.beginInvocation(invocationID: "empty-crash-invocation", conversationID: conversation.id, turnID: secondHuman.turnID, humanEventID: secondHuman.id, assistantEventID: "empty-crash-assistant", providerIdentity: "native:synthetic", requestBody: body)
                    // Readiness follows both durable chunk acknowledgements.
                    // Parent sends SIGKILL rather than graceful store teardown.
                    print("ready")
                    fflush(stdout)
                    withExtendedLifetime(store) { _ = readLine() }
                    return
                }
                if CommandLine.arguments[1] == "recover-invocation" {
                    let store = try MemoryStore(directory: directory)
                    let conversation = try store.listConversations(projectID: "crash-synthetic").first!
                    let events = try store.events(conversationID: conversation.id)
                    let attempt = try store.invocation(id: "crash-invocation")!
                    let empty = try store.invocation(id: "empty-crash-invocation")!
                    let recoveredText = "CRASH_COMMITTED_SENTINEL café \u{1F680} received suffix"
                    let checks = [
                        "sigkill_received_committed_chunks_recovered": events.first { $0.id == "crash-assistant" }?.text == recoveredText && attempt.observedBytes == recoveredText.utf8.count && attempt.chunkCount == 2,
                        "sigkill_recovered_answer_explicitly_partial": attempt.finalStatus == .partial && attempt.terminalReason == .interrupted && attempt.recovered && events.first { $0.id == "crash-assistant" }?.status == .partial,
                        "sigkill_empty_attempt_explicitly_failed": empty.finalStatus == .failed && empty.terminalReason == .interrupted && empty.recovered && events.first { $0.id == "empty-crash-assistant" }?.text == "",
                        "sigkill_request_and_admission_bytes_preserved": attempt.requestBody == Data("{ \"model\":\"synthetic\", \"messages\":[], \"stream\":true }".utf8) && attempt.admissionJSON == Data("{\"input_tokens\":4,\"context_limit\":128}".utf8),
                        "sigkill_history_no_duplicate_publication": events.count == 4,
                        "sigkill_recovered_source_searchable": try store.search(query: "CRASH_COMMITTED_SENTINEL", projectID: "crash-synthetic").first?.eventID == "crash-assistant"
                    ]
                    print(String(decoding: try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]), as: UTF8.self))
                    if checks.values.contains(false) { exit(1) }
                    return
                }
            }
            let checks = try MemoryChecks.run()
            let data = try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            if checks.values.contains(false) { exit(1) }
        } catch {
            // Diagnostics describe operation metadata only; no payload printed.
            fputs("Memory checks failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
'''


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="boros-memory-test-") as scratch:
        temporary = Path(scratch)
        harness = temporary / "MemoryHarness.swift"
        harness.write_text(HARNESS)
        binary = temporary / "memory-checks"
        sources = [ROOT / "Sources/Boros" / name for name in (
            "EpisodeBudget.swift", "EpisodeLease.swift", "EpisodeSQLFence.swift", "MemoryStore.swift", "AuthorityState.swift", "AuthorityStateJournal.swift", "AuthorityBindings.swift", "AuthorityValidation.swift", "AuthorityBindingJournal.swift", "BackgroundIndexBudget.swift", "BackgroundIndexJournal.swift", "ContextComponentJournal.swift", "QwenTextRendering.swift", "ContextSourceFraming.swift", "MeteredRetrieval.swift", "ContextAssembler.swift", "MemoryChecks.swift"
        )]
        subprocess.run([
            "swiftc", "-I", str(ROOT / "Sources/CSQLite"),
            "-o", str(binary), *(str(path) for path in sources), str(harness)
        ], check=True)
        result = subprocess.run([str(binary)], capture_output=True, text=True, check=True)
        checks = json.loads(result.stdout)
        lock_directory = temporary / "owner-check"
        owner = subprocess.Popen(
            [str(binary), "hold-owner", str(lock_directory)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True,
        )
        try:
            if owner.stdout.readline().strip() != "ready":
                raise RuntimeError("Owner test did not reach its readiness boundary")
            probe = subprocess.run(
                [str(binary), "probe-owner", str(lock_directory)],
                capture_output=True, text=True, check=True, timeout=10,
            )
            checks["separate_process_owner_rejected"] = probe.stdout.strip() == "owner_rejected"
        finally:
            owner.communicate("release\n", timeout=10)
            if owner.returncode:
                raise RuntimeError("Owner process exited unexpectedly")
        crash_directory = temporary / "crash-check"
        interrupted = subprocess.Popen(
            [str(binary), "crash-invocation", str(crash_directory)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True,
        )
        try:
            if interrupted.stdout.readline().strip() != "ready":
                raise RuntimeError("Crash test did not acknowledge durable stream chunks")
            interrupted.kill()
            interrupted.communicate(timeout=10)
            if interrupted.returncode != -9:
                raise RuntimeError("Crash test process did not terminate through SIGKILL")
        finally:
            if interrupted.poll() is None:
                interrupted.kill()
                interrupted.communicate(timeout=10)
        recovered = subprocess.run(
            [str(binary), "recover-invocation", str(crash_directory)],
            capture_output=True, text=True, check=True, timeout=10,
        )
        checks.update(json.loads(recovered.stdout))
        recovered_again = subprocess.run(
            [str(binary), "recover-invocation", str(crash_directory)],
            capture_output=True, text=True, check=True, timeout=10,
        )
        checks["sigkill_second_reopen_preserves_single_publication"] = all(json.loads(recovered_again.stdout).values())
        print(json.dumps(checks, indent=2, sort_keys=True))
        if not all(checks.values()):
            raise SystemExit(1)


if __name__ == "__main__":
    main()
