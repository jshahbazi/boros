#!/usr/bin/env python3
"""Verify durable episode recovery with synthetic process-kill boundaries."""
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
import Foundation
import Darwin

@main
enum EpisodeHarness {
    static func main() {
        do {
            if CommandLine.arguments.count == 3 {
                let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
                let owner = try MemoryStore(directory: directory)
                let clock = SystemEpisodeClock()
                if CommandLine.arguments[1] == "produce" {
                    let chat = try owner.createConversation(projectID: "synthetic-episode-crash", title: "Synthetic episode recovery")
                    for phase in ["prepared", "armed", "submitted", "answer"] {
                        let lease = EpisodeLease(ledger: owner, episodeID: phase, clock: clock)
                        _ = try owner.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: phase,
                            humanEventID: phase + "-human", episodeID: phase, text: "Synthetic episode request",
                            limits: EpisodeLimits(), clock: clock.now())
                        let body = Data("{\"messages\":[],\"max_tokens\":7,\"stream\":true}".utf8)
                        let work = try lease.prepare(kind: phase == "answer" ? .answer : .calibration,
                            resources: EpisodeResources(inputTokens: 17, outputTokens: 7, modelCalls: 1, httpAttempts: 1),
                            adapterIdentity: "synthetic-crash-adapter", snapshot: body, operationID: phase + "-work")
                        if phase == "armed" { _ = try lease.arm(work) }
                        if phase == "submitted" { _ = try lease.dispatch(work, start: {}) }
                        if phase == "answer" {
                            _ = try owner.beginInvocation(invocationID: "answer-invocation", conversationID: chat.id, turnID: phase,
                                humanEventID: phase + "-human", assistantEventID: "answer-assistant", providerIdentity: "native:synthetic",
                                requestBody: body, episodeID: phase, episodeWorkID: work.id)
                            _ = try lease.dispatch(work, start: {})
                            _ = try owner.appendInvocationChunk(invocationID: "answer-invocation", sequence: 0, text: "Synthetic committed café 中文 prefix")
                        }
                    }
                    print("ready"); fflush(stdout)
                    withExtendedLifetime(owner) { _ = readLine() }
                    return
                }
                if CommandLine.arguments[1] == "recover" {
                    var checks: [String: Bool] = [:]
                    for phase in ["prepared", "armed", "submitted", "answer"] {
                        let receipt = try owner.episodeReceipt(id: phase, clock: clock.now())
                        let work = try owner.episodeWork(episodeID: phase, operationID: phase + "-work")!
                        checks["sigkill_" + phase + "_episode_terminal"] = receipt.state == .interrupted || receipt.state == .deadlineExceeded
                        checks["sigkill_" + phase + "_request_snapshot_preserved"] = work.request.snapshot == Data("{\"messages\":[],\"max_tokens\":7,\"stream\":true}".utf8)
                        if phase == "prepared" {
                            checks["sigkill_unarmed_work_cancelled_without_charge"] = work.state == .cancelledBeforeDispatch
                                && receipt.charged == .zero && receipt.held == .zero
                        } else {
                            checks["sigkill_" + phase + "_unknown_capacity_retained"] = work.state == .outcomeUnknown
                                && receipt.charged.inputTokens == 17 && receipt.charged.modelCalls == 1
                                && receipt.charged.httpAttempts == 1 && receipt.held.outputTokens == 7
                        }
                        do {
                            _ = try EpisodeLease(ledger: owner, episodeID: phase, clock: clock).prepare(kind: .providerDiscovery,
                                resources: EpisodeResources(httpAttempts: 1), adapterIdentity: "synthetic-no-resend")
                            checks["sigkill_" + phase + "_cannot_restart_work"] = false
                        } catch EpisodeBudgetError.inactive { checks["sigkill_" + phase + "_cannot_restart_work"] = true }
                        catch EpisodeBudgetError.deadlineExceeded { checks["sigkill_" + phase + "_cannot_restart_work"] = true }
                    }
                    let invocation = try owner.invocation(id: "answer-invocation")!
                    let chat = try owner.listConversations(projectID: "synthetic-episode-crash").first!
                    let sources = try owner.events(conversationID: chat.id)
                    checks["sigkill_answer_recovers_exact_committed_prefix"] = sources.last?.text == "Synthetic committed café 中文 prefix"
                        && invocation.finalStatus == .partial && invocation.terminalReason == .interrupted && invocation.recovered
                    checks["sigkill_preflight_only_does_not_publish_answer"] = sources.count == 5
                        && sources.filter { $0.role == .assistant }.count == 1
                    print(String(decoding: try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]), as: UTF8.self))
                    exit(checks.values.allSatisfy { $0 } ? 0 : 1)
                }
            }
            let checks = try EpisodeChecks.run()
            print(String(decoding: try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]), as: UTF8.self))
            exit(checks.values.allSatisfy { $0 } ? 0 : 1)
        } catch { print("{\"episode_harness_failed\":false}"); exit(1) }
    }
}
'''


def ready(process, timeout=30):
    fd = process.stdout.fileno()
    os.set_blocking(fd, False)
    selector = selectors.DefaultSelector()
    selector.register(fd, selectors.EVENT_READ)
    deadline = time.monotonic() + timeout
    data = bytearray()
    try:
        while time.monotonic() < deadline:
            if not selector.select(max(0, deadline - time.monotonic())):
                return False
            chunk = os.read(fd, 4096)
            if not chunk:
                return False
            data.extend(chunk)
            if len(data) > 4096:
                return False
            if b"ready\n" in data:
                return True
        return False
    finally:
        selector.close()


def parsed(run):
    result = json.loads(run.stdout)
    if run.returncode or not result or any(type(v) is not bool or not v for v in result.values()):
        raise RuntimeError("Synthetic episode checks failed: " + ", ".join(k for k, v in result.items() if v is not True))
    return result


def main():
    with tempfile.TemporaryDirectory(prefix="boros-episode-tests-") as temporary:
        scratch = Path(temporary)
        harness = scratch / "EpisodeHarness.swift"
        harness.write_text(HARNESS)
        binary = scratch / "episode-checks"
        sources = [ROOT / "Sources/Boros" / name for name in (
            "EpisodeBudget.swift", "EpisodeLease.swift", "EpisodeSQLFence.swift", "MemoryStore.swift", "EpisodeChecks.swift")]
        subprocess.run(["swiftc", "-I", str(ROOT / "Sources/CSQLite"), "-o", str(binary),
                        *map(str, sources), str(harness)], check=True)
        checks = parsed(subprocess.run([str(binary)], capture_output=True, text=True, timeout=90))
        directory = scratch / "crash-store"
        producer = subprocess.Popen([str(binary), "produce", str(directory)], stdin=subprocess.PIPE,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            if not ready(producer):
                raise RuntimeError("Episode producer did not reach its durable boundaries")
            producer.kill()
            producer.communicate(timeout=10)
            if producer.returncode != -signal.SIGKILL:
                raise RuntimeError("Episode producer did not terminate through SIGKILL")
        finally:
            if producer.poll() is None:
                producer.kill()
                producer.communicate(timeout=10)
        first = parsed(subprocess.run([str(binary), "recover", str(directory)], capture_output=True, text=True, timeout=30))
        second = parsed(subprocess.run([str(binary), "recover", str(directory)], capture_output=True, text=True, timeout=30))
        checks.update(first)
        checks["sigkill_second_reopen_preserves_accounting"] = first == second
        print(json.dumps({"checks": len(checks), "failed": [], "passed": True}, sort_keys=True))


if __name__ == "__main__":
    main()
