#!/usr/bin/env python3
"""Verify durable episode recovery with synthetic process-kill boundaries."""
import json
import os
from pathlib import Path
import selectors
import sqlite3
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
                let clock = SystemEpisodeClock()
                if CommandLine.arguments[1].hasPrefix("migrate-kill-") {
                    let stage = String(CommandLine.arguments[1].dropFirst("migrate-kill-".count))
                    let owner = try MemoryStore(directory: directory, episodeMigrationCheckpoint: { checkpoint in
                        if checkpoint == stage { print("ready"); fflush(stdout); _ = readLine() }
                    })
                    withExtendedLifetime(owner) {}
                    return
                }
                if CommandLine.arguments[1] == "seed-migration" {
                    var owner: MemoryStore? = try MemoryStore(directory: directory)
                    let chat = try owner!.createConversation(projectID: "synthetic-migration-kill", title: "Synthetic migration kill boundary")
                    _ = try owner!.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "migration-turn", humanEventID: "migration-human",
                        episodeID: "migration-episode", text: "Synthetic migration request", limits: .init(), clock: clock.now())
                    let work = try owner!.reserveEpisodeWork(episodeID: "migration-episode", request: EpisodeWorkRequest(id: "migration-work",
                        parentID: nil, kind: .answer, resources: EpisodeResources(inputTokens: 3, outputTokens: 4, modelCalls: 1),
                        adapterIdentity: "synthetic-migration-kill", snapshot: Data("{\"messages\":[]}".utf8), inputTokensKnown: true), clock: clock.now())
                    _ = try owner!.armEpisodeWork(episodeID: "migration-episode", operationID: work.id, expectedRevision: work.revision, clock: clock.now())
                    owner = nil
                    try EpisodeChecks.downgradeSyntheticChatParentToThree(directory)
                    print("{\"migration_seeded\":true}")
                    return
                }
                let owner = try MemoryStore(directory: directory)
                if CommandLine.arguments[1] == "recover-migration" {
                    let receipt = try owner.episodeReceipt(id: "migration-episode", clock: clock.now())
                    let work = try owner.episodeWork(episodeID: receipt.id, operationID: "migration-work")!
                    let checks = [
                        "sigkill_migration_recovers_complete_chat_origin": !receipt.origin.isLocalRead && receipt.conversationID != nil && receipt.humanEventID == "migration-human",
                        "sigkill_migration_preserves_charge_unknown_bound": receipt.charged.inputTokens == 3 && receipt.charged.modelCalls == 1 && receipt.held.outputTokens == 4 && work.state == .outcomeUnknown,
                        "sigkill_migration_preserves_exact_snapshot": work.request.snapshot == Data("{\"messages\":[]}".utf8),
                        "sigkill_migration_preserves_source_count": try owner.listConversations(projectID: "synthetic-migration-kill").count == 1 && owner.events(conversationID: receipt.conversationID!).count == 1
                    ]
                    print(String(decoding: try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]), as: UTF8.self))
                    exit(checks.values.allSatisfy { $0 } ? 0 : 1)
                }
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
                    for phase in ["read-prepared", "read-armed", "read-submitted"] {
                        let binding = EpisodeLocalReadBinding(initiator: .syntheticEvaluation, purpose: .retrievalProbe,
                            requestID: phase, descriptorVersion: "synthetic-kill-v1", descriptorSHA256: String(repeating: "0", count: 64))
                        _ = try owner.beginLocalReadEpisode(episodeID: phase, projectID: "synthetic-read-crash", binding: binding,
                            limits: .init(), clock: clock.now())
                        let lease = EpisodeLease(ledger: owner, episodeID: phase, clock: clock)
                        let work = try lease.prepare(kind: .queryEmbedding, resources: EpisodeResources(modelCalls: 1, encoderInputBytes: 12),
                            adapterIdentity: "synthetic-read-crash", snapshot: Data("{\"fixture\":\"read-boundary\"}".utf8),
                            inputTokensKnown: false, operationID: phase + "-work")
                        if phase == "read-armed" { _ = try lease.arm(work) }
                        if phase == "read-submitted" { _ = try lease.dispatch(work) {} }
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
                    for phase in ["read-prepared", "read-armed", "read-submitted"] {
                        let receipt = try owner.episodeReceipt(id: phase, clock: clock.now())
                        let work = try owner.episodeWork(episodeID: phase, operationID: phase + "-work")!
                        checks["sigkill_" + phase + "_terminal_read_origin"] = receipt.origin.isLocalRead && receipt.state != .active
                            && receipt.conversationID == nil && receipt.turnID == nil && receipt.humanEventID == nil
                        checks["sigkill_" + phase + "_exact_snapshot_preserved"] = work.request.snapshot == Data("{\"fixture\":\"read-boundary\"}".utf8)
                        if phase == "read-prepared" {
                            checks["sigkill_read_unarmed_releases_without_charge"] = work.state == .cancelledBeforeDispatch && receipt.charged == .zero && receipt.held == .zero && receipt.unknownInputOperations == 0
                        } else {
                            checks["sigkill_" + phase + "_opaque_encoder_charge_retained"] = work.state == .outcomeUnknown
                                && receipt.charged.modelCalls == 1 && receipt.charged.encoderInputBytes == 12 && receipt.charged.inputTokens == 0
                                && receipt.unknownInputOperations == 1 && receipt.held == .zero
                        }
                        let binding = EpisodeLocalReadBinding(initiator: .syntheticEvaluation, purpose: .retrievalProbe,
                            requestID: phase, descriptorVersion: "synthetic-kill-v1", descriptorSHA256: String(repeating: "0", count: 64))
                        let replay = try owner.beginLocalReadEpisode(episodeID: phase, projectID: "synthetic-read-crash", binding: binding,
                            limits: .init(), clock: clock.now())
                        checks["sigkill_" + phase + "_constructor_replay_does_not_restart"] = replay == receipt
                    }
                    checks["sigkill_read_creates_no_conversation"] = try owner.listConversations(projectID: "synthetic-read-crash").isEmpty
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


def kill_at_ready(binary, command, directory):
    producer = subprocess.Popen([str(binary), command, str(directory)], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        if not ready(producer):
            raise RuntimeError("Episode producer did not reach its durable boundary")
        producer.kill()
        producer.communicate(timeout=10)
        if producer.returncode != -signal.SIGKILL:
            raise RuntimeError("Episode producer did not terminate through SIGKILL")
    finally:
        if producer.poll() is None:
            producer.kill()
            producer.communicate(timeout=10)


def database_snapshot(directory):
    with sqlite3.connect(directory / "memory.sqlite3") as connection:
        tables = ("episodes", "episode_work", "episode_resource_totals", "episode_request_snapshots", "events", "conversations", "invocations")
        return {table: connection.execute(f'SELECT * FROM "{table}" ORDER BY 1,2').fetchall() for table in tables}


def main():
    with tempfile.TemporaryDirectory(prefix="boros-episode-tests-") as temporary:
        scratch = Path(temporary)
        harness = scratch / "EpisodeHarness.swift"
        harness.write_text(HARNESS)
        binary = scratch / "episode-checks"
        sources = [ROOT / "Sources/Boros" / name for name in (
            "EpisodeBudget.swift", "EpisodeLease.swift", "EpisodeSQLFence.swift", "MemoryStore.swift", "AuthorityState.swift", "AuthorityStateJournal.swift", "AuthorityValidatedClock.swift", "AuthorityValidationCache.swift", "EpisodeAccountingJournal.swift", "AuthoritySchemaSeven.swift", "AuthoritySchemaEight.swift", "EpisodeTerminalCleanup.swift", "AuthorityBindings.swift", "AuthorityValidation.swift", "AuthorityPolicyRendering.swift", "AuthorityInputProof.swift", "AuthorityBindingJournal.swift", "BackgroundIndexBudget.swift", "BackgroundIndexJournal.swift", "ContextComponentJournal.swift", "QwenTextRendering.swift", "ContextSourceFraming.swift", "MeteredRetrieval.swift", "ContextAssembler.swift", "EpisodeChecks.swift")]
        subprocess.run(["swiftc", "-I", str(ROOT / "Sources/CSQLite"), "-o", str(binary),
                        *map(str, sources), str(harness)], check=True)
        checks = parsed(subprocess.run([str(binary)], capture_output=True, text=True, timeout=90))
        directory = scratch / "crash-store"
        kill_at_ready(binary, "produce", directory)
        first = parsed(subprocess.run([str(binary), "recover", str(directory)], capture_output=True, text=True, timeout=30))
        second = parsed(subprocess.run([str(binary), "recover", str(directory)], capture_output=True, text=True, timeout=30))
        checks.update(first)
        checks["sigkill_second_reopen_preserves_accounting"] = first == second
        for stage in ("beforeParentReplacement", "afterParentReplacement", "beforeCommit"):
            migration = scratch / ("migration-" + stage)
            parsed(subprocess.run([str(binary), "seed-migration", str(migration)], capture_output=True, text=True, timeout=30))
            before = database_snapshot(migration)
            kill_at_ready(binary, "migrate-kill-" + stage, migration)
            after = database_snapshot(migration)
            with sqlite3.connect(migration / "memory.sqlite3") as connection:
                version = connection.execute("PRAGMA user_version").fetchone()[0]
                temp_parent = connection.execute("SELECT count(*) FROM sqlite_master WHERE name='episodes_v4'").fetchone()[0]
            if before != after or version != 3 or temp_parent:
                raise RuntimeError("SIGKILL did not roll migration back atomically")
            checks["sigkill_migration_" + stage + "_rollback_exact_rows_and_schema"] = True
            recovered = parsed(subprocess.run([str(binary), "recover-migration", str(migration)], capture_output=True, text=True, timeout=30))
            repeated = parsed(subprocess.run([str(binary), "recover-migration", str(migration)], capture_output=True, text=True, timeout=30))
            checks.update({stage + "_" + key: value for key, value in recovered.items()})
            checks["sigkill_migration_" + stage + "_repeat_reopen_stable"] = recovered == repeated
            with sqlite3.connect(migration / "memory.sqlite3") as connection:
                if connection.execute("PRAGMA user_version").fetchone()[0] != 9 or connection.execute("PRAGMA foreign_key_check").fetchall():
                    raise RuntimeError("Recovered migration did not publish a complete schema nine")
            checks["sigkill_migration_" + stage + "_reopens_schema_nine_foreign_keys_intact"] = True
        print(json.dumps({"checks": len(checks), "failed": [], "passed": True}, sort_keys=True))


if __name__ == "__main__":
    main()
