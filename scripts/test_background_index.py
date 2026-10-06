#!/usr/bin/env python3
"""Verify actual background accounting and SIGKILL recovery with public fixtures."""
import argparse
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SOURCES = (
    "EpisodeBudget.swift", "EpisodeLease.swift", "EpisodeSQLFence.swift", "MemoryStore.swift", "AuthorityState.swift", "AuthorityStateJournal.swift", "AuthorityBindings.swift", "AuthorityValidation.swift", "AuthorityBindingJournal.swift",
    "ContextComponentJournal.swift", "QwenTextRendering.swift", "ContextSourceFraming.swift", "ContextAssembler.swift",
    "BackgroundIndexBudget.swift", "BackgroundIndexJournal.swift", "BackgroundIndexBudgetChecks.swift",
    "BackgroundIndexLedgerChecks.swift", "MeteredRetrieval.swift", "SemanticIndex.swift",
    "BackgroundIndexWorker.swift", "BackgroundIndexWorkerChecks.swift",
)
HARNESS = r'''
import Foundation
import Darwin
@main enum BackgroundHarness {
    static func main() {
        do {
            let args = CommandLine.arguments
            var checks: [String: Bool]
            if args.count == 2 && args[1] == "full-source" {
                checks = try BackgroundIndexWorkerChecks.runFullLargeSource()
            } else if args.count == 3 && args[1] == "produce-ledger" {
                try BackgroundIndexLedgerChecks.produceProcessFixture(directory: URL(fileURLWithPath: args[2]))
                return
            } else if args.count == 3 && args[1] == "recover-ledger" {
                checks = try BackgroundIndexLedgerChecks.verifyProcessFixture(directory: URL(fileURLWithPath: args[2]))
            } else if args.count == 4 && args[1] == "produce-worker" {
                try BackgroundIndexWorkerChecks.produce(directory: URL(fileURLWithPath: args[2]), barrier: args[3])
                return
            } else if args.count == 5 && args[1] == "recover-worker" {
                checks = try BackgroundIndexWorkerChecks.verifyRecovery(directory: URL(fileURLWithPath: args[2]),
                    barrier: args[3], resume: args[4] == "resume")
            } else {
                checks = try BackgroundIndexBudgetChecks.run()
                for suite in [try BackgroundIndexLedgerChecks.run(), try BackgroundIndexWorkerChecks.run()] {
                    guard Set(checks.keys).isDisjoint(with: suite.keys) else { throw BackgroundIndexBudgetError.invalid }
                    checks.merge(suite) { _, new in new }
                }
            }
            print(String(decoding: try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]), as: UTF8.self))
            exit(checks.values.allSatisfy { $0 } ? 0 : 1)
        } catch {
            fputs("Public background accounting fixture failed.\n", stderr)
            exit(1)
        }
    }
}
'''


def run_checks(binary, *args, timeout=90):
    result = subprocess.run([str(binary), *map(str, args)], capture_output=True, text=True, timeout=timeout)
    if not result.stdout.strip():
        raise RuntimeError("Background fixture returned no structured evidence")
    checks = json.loads(result.stdout)
    failed = [name for name, passed in checks.items() if passed is not True]
    if result.returncode or failed:
        raise RuntimeError(f"Background fixture failed: {failed}")
    return checks


def kill_at_ready(binary, args, marker):
    producer = subprocess.Popen([str(binary), *map(str, args)], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        selector = selectors.DefaultSelector()
        descriptor = producer.stdout.fileno()
        os.set_blocking(descriptor, False)
        selector.register(descriptor, selectors.EVENT_READ)
        buffer = b""
        deadline = time.monotonic() + 30
        try:
            while b"\n" not in buffer and time.monotonic() < deadline:
                if not selector.select(timeout=min(1, max(0, deadline - time.monotonic()))):
                    continue
                chunk = os.read(descriptor, 1024)
                if not chunk:
                    break
                buffer += chunk
                if len(buffer) > 1024:
                    break
        finally:
            selector.close()
        if buffer.strip() != marker:
            raise RuntimeError("Background fixture did not reach the required live barrier")
        producer.kill()
        producer.communicate(timeout=10)
        if producer.returncode != -9:
            raise RuntimeError("Background fixture was not killed by SIGKILL")
    finally:
        if producer.poll() is None:
            producer.kill()
            producer.communicate(timeout=10)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--full-source", action="store_true",
                        help="Also index a complete public 4 MiB source across two budget windows")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="boros-background-tests-") as directory:
        scratch = Path(directory).resolve()
        captured = scratch / "sources"
        captured.mkdir()
        for name in SOURCES:
            (captured / name).write_bytes((ROOT / "Sources/Boros" / name).read_bytes())
        harness = scratch / "Harness.swift"
        harness.write_text(HARNESS)
        binary = scratch / "background-checks"
        subprocess.run(["swiftc", "-I", str(ROOT / "Sources/CSQLite"), "-o", str(binary),
                        *(str(captured / name) for name in SOURCES), str(harness)], check=True)
        checks = run_checks(binary)
        if args.full_source:
            for name, passed in run_checks(binary, "full-source", timeout=180).items():
                checks["full_source_" + name] = passed
        ledger = scratch / "ledger-kill"
        kill_at_ready(binary, ["produce-ledger", ledger], b"background_process_fixture_ready")
        checks["background_ledger_actual_sigkill"] = True
        for restart in (1, 2):
            for name, passed in run_checks(binary, "recover-ledger", ledger).items():
                checks[f"ledger_restart_{restart}_{name}"] = passed
        for barrier in ("armed", "encoder", "before-publication", "after-publication"):
            store = scratch / ("worker-kill-" + barrier)
            kill_at_ready(binary, ["produce-worker", store, barrier], b"BOROS_BACKGROUND_WORKER_READY")
            checks[f"background_worker_actual_sigkill_{barrier}"] = True
            for restart in (1, 2):
                for name, passed in run_checks(binary, "recover-worker", store, barrier, "observe").items():
                    checks[f"worker_{barrier}_restart_{restart}_{name}"] = passed
            for name, passed in run_checks(binary, "recover-worker", store, barrier, "resume").items():
                checks[f"worker_{barrier}_resume_{name}"] = passed
        print(json.dumps({"suite": "background-index-and-process-recovery", "checks": len(checks),
                          "failed": [name for name, passed in checks.items() if passed is not True]}))


if __name__ == "__main__":
    main()
