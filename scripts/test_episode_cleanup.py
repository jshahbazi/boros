#!/usr/bin/env python3
"""Bounded prepaid cleanup, with real SIGKILL before and during cleanup."""
from __future__ import annotations
import hashlib
import json
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SOURCES = (
    "EpisodeBudget.swift", "EpisodeLease.swift", "EpisodeSQLFence.swift", "MemoryStore.swift", "EventSourceTime.swift", "SourceTimeSchema.swift", "AuthoritySchemaNine.swift",
    "AuthorityState.swift", "AuthorityStateJournal.swift", "AuthorityValidatedClock.swift",
    "AuthorityBindings.swift", "AuthorityBindingJournal.swift", "AuthorityValidation.swift", "AuthorityPolicyRendering.swift", "AuthorityInputProof.swift",
    "AuthorityValidationCache.swift", "AuthoritySchemaSeven.swift", "AuthoritySchemaEight.swift",
    "EpisodeAccountingJournal.swift", "EpisodeTerminalCleanup.swift", "EpisodeCleanupChecks.swift",
    "BackgroundIndexBudget.swift", "BackgroundIndexJournal.swift", "ContextComponentJournal.swift",
    "QwenTextRendering.swift", "ContextSourceFraming.swift", "HistoricalQueryFormulation.swift", "MeteredExchangeExpansion.swift", "ContextAssembler.swift", "MeteredRetrieval.swift",
)
HARNESS = r'''
import Foundation
import Darwin
@main enum Harness {
    static func main() {
        do {
            let a = CommandLine.arguments
            let checks: [String: Bool]
            if a.count == 1 { checks = try EpisodeCleanupChecks.run() }
            else if a.count == 3 { checks = try EpisodeCleanupChecks.process(mode: a[1], directory: URL(fileURLWithPath: a[2])) }
            else { print("{\"cleanup_process_arguments\":false}"); exit(2) }
            let report: [String: Any] = a.count == 1 ? ["contracts": checks, "vm_evidence": EpisodeCleanupChecks.vmEvidence] : checks
            print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
            exit(checks.values.allSatisfy { $0 } ? 0 : 1)
        } catch { print("{\"cleanup_process_harness\":false}"); exit(1) }
    }
}
'''


EVIDENCE: dict[str, list[int]] = {}

def fixed(binary: Path, *args: str) -> dict[str, bool]:
    result = subprocess.run([str(binary), *args], capture_output=True, timeout=120)
    if len(result.stdout) > 65536:
        raise ValueError("output bounds")
    value = json.loads(result.stdout)
    if isinstance(value, dict) and set(value) == {"contracts", "vm_evidence"}:
        measured = value["vm_evidence"]
        if set(measured) != {"small", "large"} or any(not isinstance(v, list) or len(v) != 4 or any(type(i) is not int or not 0 <= i <= 100000000 for i in v) for v in measured.values()):
            raise ValueError("measurement contract")
        EVIDENCE.update(measured)
        value = value["contracts"]
    if not isinstance(value, dict) or not value or any(not k.startswith("cleanup_") or type(v) is not bool for k, v in value.items()):
        raise ValueError("output contract")
    if result.returncode and all(value.values()):
        value["cleanup_process_exit"] = False
    return value


def killed(binary: Path, boundary: str, folder: Path) -> dict[str, bool]:
    process = subprocess.Popen([str(binary), "seed-" + boundary, str(folder)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    ready = False
    try:
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        if selector.select(timeout=25):
            ready = process.stdout.readline(128) == b"ready\n"
        selector.close()
        process.kill()
        process.wait(timeout=5)
        checks = {"cleanup_" + boundary + "_actual_sigkill": ready and process.returncode == -signal.SIGKILL}
        if ready:
            for reopen in (1, 2):
                for key, passed in fixed(binary, "verify", str(folder)).items():
                    if reopen == 2 and key == "cleanup_process_uncommitted_batch_preserves_all_prepaid_holds":
                        continue
                    checks["cleanup_" + boundary + "_reopen_" + str(reopen) + "_" + key.removeprefix("cleanup_")] = passed
        return checks
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)


def main() -> int:
    checks = {"cleanup_compile_harness": False}
    hashes = {}
    stage = "compile"
    try:
        with tempfile.TemporaryDirectory(prefix="boros-cleanup-runner-") as name:
            scratch = Path(name)
            captured = scratch / "source"
            captured.mkdir()
            for source in SOURCES:
                content = (ROOT / "Sources/Boros" / source).read_bytes()
                (captured / source).write_bytes(content)
                hashes[source] = hashlib.sha256(content).hexdigest()
            shutil.copytree(ROOT / "Sources/CSQLite", captured / "CSQLite")
            (captured / "Harness.swift").write_text(HARNESS)
            binary = scratch / "checks"
            build = subprocess.run(["/usr/bin/swiftc", "-swift-version", "5", "-I", str(captured / "CSQLite"), "-o", str(binary),
                                    *(str(captured / source) for source in SOURCES), str(captured / "Harness.swift")], capture_output=True, timeout=120)
            if build.returncode:
                (ROOT / ".build/cleanup-compile-errors.txt").write_bytes(build.stderr)
                raise ValueError("compile failure")
            checks = {"cleanup_compile_harness": True}
            stage = "focused"
            checks.update(fixed(binary))
            for boundary in ("fence", "attempt", "batch"):
                stage = "sigkill_" + boundary
                checks.update(killed(binary, boundary, scratch / boundary))
    except (OSError, ValueError, subprocess.SubprocessError):
        checks["cleanup_" + stage + "_harness"] = False
    failed = sorted(k for k, v in checks.items() if not v)
    print(json.dumps({"passed": not failed, "checks": len(checks), "failed": failed, "contracts": checks,
                      "source_sha256": hashes, "vm_evidence": EVIDENCE, "vm_measurement_fields": ["vm_steps", "full_scan_steps", "statements", "snapshot_statements"], "runner_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}, sort_keys=True))
    return int(bool(failed))

if __name__ == "__main__":
    raise SystemExit(main())
