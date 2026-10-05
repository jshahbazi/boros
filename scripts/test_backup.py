#!/usr/bin/env python3
"""Verify SQLite backups with synthetic stores, including a real SIGKILL."""
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
import Foundation
import CryptoKit
import Darwin

@main
enum BackupHarness {
    static func main() {
        do {
            if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "interrupt-backup" {
                let source = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
                let destination = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
                let owner = try MemoryStore(directory: source)
                let conversation = try owner.createConversation(projectID: "synthetic-crash-backup", title: "Synthetic crash")
                let clock = EpisodeClockSnapshot(domain: "synthetic-backup-kill-clock", continuousNanoseconds: 1_000_000_000, utc: Date(timeIntervalSince1970: 1_700_000_000))
                _ = try owner.acceptRequestAndBeginEpisode(conversationID: conversation.id, turnID: "crash-turn", humanEventID: "crash-source", episodeID: "crash-episode", text: "SYNTHETIC_BACKUP_CRASH_SOURCE", limits: EpisodeLimits(), clock: clock)
                let body = Data("{\"model\":\"synthetic-crash-model\",\"messages\":[{\"role\":\"user\",\"content\":\"SYNTHETIC_BACKUP_CRASH_PROBE\"}]}".utf8)
                _ = try owner.reserveEpisodeWork(episodeID: "crash-episode", request: EpisodeWorkRequest(id: "crash-prepared", parentID: nil, kind: .tokenizer, resources: EpisodeResources(httpAttempts: 1), adapterIdentity: "synthetic-backup-kill-adapter", snapshot: body, inputTokensKnown: true), clock: clock)
                let armed = try owner.reserveEpisodeWork(episodeID: "crash-episode", request: EpisodeWorkRequest(id: "crash-armed", parentID: nil, kind: .calibration, resources: EpisodeResources(inputTokens: 17, outputTokens: 1, modelCalls: 1, httpAttempts: 1), adapterIdentity: "synthetic-backup-kill-adapter", snapshot: body, inputTokensKnown: true), clock: clock)
                _ = try owner.armEpisodeWork(episodeID: "crash-episode", operationID: armed.id, expectedRevision: armed.revision, clock: clock)
                let descriptor = Data("synthetic-backup-read-kill-v1".utf8)
                let descriptorDigest = SHA256.hash(data: descriptor).map { String(format: "%02x", $0) }.joined()
                let binding = EpisodeLocalReadBinding(initiator: .syntheticEvaluation, purpose: .retrievalProbe, requestID: "crash-read-request", descriptorVersion: "backup-read-kill-v1", descriptorSHA256: descriptorDigest)
                _ = try owner.beginLocalReadEpisode(episodeID: "crash-read-episode", projectID: "synthetic-crash-backup", binding: binding, limits: .init(), clock: clock)
                _ = try owner.reserveEpisodeWork(episodeID: "crash-read-episode", request: EpisodeWorkRequest(id: "crash-read-prepared", parentID: nil, kind: .sourceRead, resources: EpisodeResources(memoryOperations: 1, rawSourceBytes: 23), adapterIdentity: "synthetic-backup-read-v1", snapshot: nil, inputTokensKnown: true), clock: clock)
                let query = try owner.reserveEpisodeWork(episodeID: "crash-read-episode", request: EpisodeWorkRequest(id: "crash-read-armed", parentID: nil, kind: .queryEmbedding, resources: EpisodeResources(modelCalls: 1, encoderInputBytes: 13), adapterIdentity: "synthetic-backup-read-encoder-v1", snapshot: nil, inputTokensKnown: false), clock: clock)
                _ = try owner.armEpisodeWork(episodeID: query.episodeID, operationID: query.id, expectedRevision: query.revision, clock: clock)
                var first = true
                _ = try BackupArchive.create(from: owner, at: destination, cancellation: {
                    if first {
                        first = false
                        // The unpublished private staging directory exists.
                        print("ready"); fflush(stdout); _ = readLine()
                    }
                    return false
                })
                exit(1)
            }
            if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "recover-interrupted-backup" {
                let owner = try MemoryStore(directory: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
                let clock = EpisodeClockSnapshot(domain: "synthetic-backup-kill-clock", continuousNanoseconds: 1_000_000_000, utc: Date(timeIntervalSince1970: 1_700_000_000))
                let episode = try owner.episodeReceipt(id: "crash-episode", clock: clock)
                let prepared = try owner.episodeWork(episodeID: episode.id, operationID: "crash-prepared")!
                let armed = try owner.episodeWork(episodeID: episode.id, operationID: "crash-armed")!
                let readEpisode = try owner.episodeReceipt(id: "crash-read-episode", clock: clock)
                let readPrepared = try owner.episodeWork(episodeID: readEpisode.id, operationID: "crash-read-prepared")!
                let readArmed = try owner.episodeWork(episodeID: readEpisode.id, operationID: "crash-read-armed")!
                let sources = try owner.sourceManifest(projectID: "synthetic-crash-backup", afterSequence: 0, limit: 10)
                let checks = [
                    "episode_interrupted": episode.state == .interrupted,
                    "accepted_source_survives": sources.count == 1 && sources[0].eventID == "crash-source",
                    "prepared_work_released": prepared.state == .cancelledBeforeDispatch && prepared.charged == .zero && prepared.held == .zero,
                    "armed_usage_stays_unknown": armed.state == .outcomeUnknown && armed.observed == nil && armed.recovered,
                    "charges_and_output_bound_retained": episode.charged == EpisodeResources(inputTokens: 17, modelCalls: 1, httpAttempts: 1) && episode.held == EpisodeResources(outputTokens: 1),
                    "read_episode_interrupted_without_chat_bindings": readEpisode.state == .interrupted && readEpisode.origin.isLocalRead && readEpisode.conversationID == nil && readEpisode.turnID == nil && readEpisode.humanEventID == nil,
                    "read_prepared_work_released": readPrepared.state == .cancelledBeforeDispatch && readPrepared.charged == .zero && readPrepared.held == .zero,
                    "read_armed_encoder_unknown_and_charged": readArmed.state == .outcomeUnknown && readArmed.observed == nil && readArmed.recovered && readEpisode.charged == EpisodeResources(modelCalls: 1, encoderInputBytes: 13) && readEpisode.held == .zero && readEpisode.unknownInputOperations == 1
                ]
                print(String(decoding: try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]), as: UTF8.self))
                if checks.values.contains(false) { exit(1) }
                return
            }
            let checks = try BackupChecks.run()
            print(String(decoding: try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]), as: UTF8.self))
            if checks.values.contains(false) { exit(1) }
        } catch {
            fputs("Synthetic backup checks failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
'''


def main():
    with tempfile.TemporaryDirectory(prefix="boros-backup-tests-") as directory:
        scratch = Path(directory).resolve()
        harness = scratch / "BackupHarness.swift"
        harness.write_text(HARNESS)
        binary = scratch / "backup-checks"
        sources = [ROOT / "Sources/Boros" / name for name in (
            "EpisodeBudget.swift", "EpisodeLease.swift", "EpisodeSQLFence.swift", "MemoryStore.swift", "MeteredRetrieval.swift",
            "BackupArchive.swift", "BackupCommand.swift", "BackupChecks.swift", "ReadIdentityChecks.swift"
        )]
        # Compile one captured dependency set. Other integration agents may be
        # editing shared Swift sources while this isolated suite is running.
        captured = scratch / "sources"
        captured.mkdir()
        for source in sources:
            (captured / source.name).write_bytes(source.read_bytes())
        subprocess.run(["swiftc", "-I", str(ROOT / "Sources/CSQLite"), "-o", str(binary),
                        *(str(captured / path.name) for path in sources), str(harness)], check=True)
        run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=90)
        if run.returncode:
            if run.stdout.strip():
                failed = [name for name, value in json.loads(run.stdout).items() if value is not True]
                print(json.dumps({"failed": failed}))
            else:
                print(run.stderr.strip())
            raise RuntimeError("Synthetic backup checks failed")
        checks = json.loads(run.stdout)
        source = scratch / "crash-source"
        archive = scratch / "crash-archive"
        interrupted = subprocess.Popen([str(binary), "interrupt-backup", str(source), str(archive)],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True)
        try:
            selector = selectors.DefaultSelector()
            descriptor = interrupted.stdout.fileno()
            os.set_blocking(descriptor, False)
            selector.register(descriptor, selectors.EVENT_READ)
            buffer = b""
            deadline = time.monotonic() + 30
            while b"\n" not in buffer and time.monotonic() < deadline:
                if not selector.select(timeout=min(1, max(0, deadline - time.monotonic()))):
                    continue
                chunk = os.read(descriptor, 1024)
                if not chunk:
                    break
                buffer += chunk
                if len(buffer) > 1024:
                    break
            selector.close()
            if buffer.strip() != b"ready":
                raise RuntimeError("Interrupted backup did not reach its staging boundary")
            staging = list(scratch.glob(".boros-staging-*"))
            interrupted.kill()
            interrupted.communicate(timeout=10)
            checks["backup_sigkill_private_staging_never_published"] = (
                interrupted.returncode == -9 and not archive.exists() and len(staging) == 1
                and staging[0].is_dir() and staging[0].stat().st_mode & 0o777 == 0o700
            )
            for restart in (1, 2):
                recovered = subprocess.run([str(binary), "recover-interrupted-backup", str(source)],
                                           capture_output=True, text=True, timeout=30)
                if recovered.returncode:
                    raise RuntimeError("Interrupted synthetic backup source failed recovery")
                for name, passed in json.loads(recovered.stdout).items():
                    checks[f"backup_sigkill_restart_{restart}_{name}"] = passed is True
        finally:
            if interrupted.poll() is None:
                interrupted.kill()
                interrupted.communicate(timeout=10)
        print(json.dumps(checks, indent=2, sort_keys=True))
        if not all(checks.values()):
            raise SystemExit(1)


if __name__ == "__main__":
    main()
