#!/usr/bin/env python3
"""Verify isolated indexed accounting and actual process-death boundaries."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import sqlite3
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SOURCES = (
    "EpisodeBudget.swift", "EpisodeLease.swift", "EpisodeSQLFence.swift", "MemoryStore.swift",
    "AuthorityState.swift", "AuthorityStateJournal.swift", "AuthorityValidatedClock.swift",
    "AuthorityBindings.swift", "AuthorityBindingJournal.swift", "AuthorityValidation.swift", "AuthorityPolicyRendering.swift",
    "AuthorityValidationCache.swift", "AuthoritySchemaSix.swift", "AuthoritySchemaSeven.swift", "AuthoritySchemaEight.swift", "EpisodeTerminalCleanup.swift",
    "EpisodeAccountingJournal.swift", "EpisodeAccountingChecks.swift",
    "BackgroundIndexBudget.swift", "BackgroundIndexJournal.swift", "ContextComponentJournal.swift",
    "QwenTextRendering.swift", "ContextSourceFraming.swift", "ContextAssembler.swift", "MeteredRetrieval.swift",
)
HARNESS = r'''
import Foundation
import Darwin
@main enum EpisodeAccountingHarness {
    static func main() {
        do {
            let arguments = CommandLine.arguments
            let checks: [String: Bool]
            let report: [String: Any]
            if arguments.count == 2 && arguments[1] == "--episode-accounting-self-test" {
                checks = try EpisodeAccountingChecks.run()
                report = ["contracts": checks, "vm_evidence": EpisodeAccountingChecks.vmEvidence]
            } else if arguments.count == 3 && arguments[1].hasPrefix("--accounting-") {
                checks = try EpisodeAccountingChecks.process(mode: String(arguments[1].dropFirst("--accounting-".count)),
                    directory: URL(fileURLWithPath: arguments[2], isDirectory: true))
                report = checks
            } else { print("{\"accounting_arguments\":false}"); exit(2) }
            print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
            exit(checks.values.allSatisfy { $0 } ? 0 : 1)
        } catch { print("{\"accounting_process_harness\":false}"); exit(1) }
    }
}
'''


def fixed_json(binary: Path, *arguments: str, evidence: dict[str, list[int]] | None = None) -> dict[str, bool]:
    result = subprocess.run([str(binary), *arguments], capture_output=True, text=True, timeout=120)
    if len(result.stdout.encode()) > 65536:
        raise ValueError("invalid output size")
    value = json.loads(result.stdout)
    if evidence is not None and isinstance(value, dict) and set(value) == {"contracts", "vm_evidence"}:
        measured = value["vm_evidence"]
        allowed = {size + "_" + operation for size in ("small", "large")
                   for operation in ("receipt", "reserve", "settlement", "duplicate_receipt")}
        if not isinstance(measured, dict) or any(
            key not in allowed or not isinstance(counts, list) or len(counts) != 3
            or any(type(count) is not int or not 0 <= count <= 100_000_000 for count in counts)
            for key, counts in measured.items()
        ):
            raise ValueError("invalid fixed VM measurements")
        evidence.update(measured)
        value = value["contracts"]
    if not isinstance(value, dict) or not value or any(
        not isinstance(key, str) or not key.startswith("accounting_") or type(passed) is not bool
        for key, passed in value.items()
    ):
        raise ValueError("invalid fixed checks")
    if result.returncode and all(value.values()):
        return {"accounting_process_exit_status": False}
    return value


def await_ready(process: subprocess.Popen[bytes]) -> bool:
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    buffered = b""
    expires = time.monotonic() + 20
    try:
        while time.monotonic() < expires:
            if process.poll() is not None:
                return False
            events = selector.select(timeout=min(0.25, max(0, expires - time.monotonic())))
            for key, _ in events:
                part = os.read(key.fd, 128)
                if not part:
                    return False
                buffered += part
                if len(buffered) > 256:
                    return False
                if b"\n" in buffered:
                    return buffered == b"ready\n"
        return False
    finally:
        selector.close()


def killed_boundary(binary: Path, stage: str, directory: Path) -> dict[str, bool]:
    checks: dict[str, bool] = {}
    process = subprocess.Popen([str(binary), "--accounting-kill-" + stage, str(directory)],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    try:
        ready = await_ready(process)
        checks["accounting_sigkill_" + stage + "_reaches_actual_transaction_checkpoint"] = ready
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
        process.communicate(timeout=5)
        checks["accounting_sigkill_" + stage + "_process_is_killed_and_reaped"] = ready and process.returncode == -signal.SIGKILL
        if not ready:
            return checks
        with sqlite3.connect(directory / "memory.sqlite3") as connection:
            scalar = lambda sql: connection.execute(sql).fetchone()[0]
            version = scalar("PRAGMA user_version")
            work_count = scalar("SELECT count(*) FROM episode_work")
            projection_count = scalar("SELECT work_count FROM episode_accounting")
            snapshot_bytes = scalar("SELECT snapshot_bytes FROM episode_accounting")
            unknown = scalar("SELECT unknown_input_operations FROM episode_accounting")
            receipts = scalar("SELECT count(*) FROM episode_settlement_receipts")
            charged = scalar("SELECT sum(charged) FROM episode_resource_totals")
            held = scalar("SELECT sum(held) FROM episode_resource_totals")
            if stage == "work":
                original = version == 9 and work_count == 0 and projection_count == 0 and snapshot_bytes == 0 and unknown == 0
                bounds = scalar("SELECT count(*) FROM episode_request_snapshots") == 0 and receipts == 0 and charged == 0 and held == 0
            else:
                original = version == 9 and work_count == projection_count == 1 and snapshot_bytes > 0 and unknown == 1
                bounds = scalar("SELECT state FROM episode_work") == "dispatchArmed" and scalar("SELECT length(receipt_json) FROM episode_work") == 0 and receipts == 0 and charged == 4 and held == 4
            checks["accounting_sigkill_" + stage + "_pre_recovery_original_and_projection_agree"] = original
            checks["accounting_sigkill_" + stage + "_uncommitted_accounting_and_receipt_prefix_is_absent"] = bounds
        for reopen in (1, 2):
            recovered = fixed_json(binary, "--accounting-recover-" + stage, str(directory))
            for key, passed in recovered.items():
                checks[key + "_" + stage + "_reopen_" + str(reopen)] = passed
        return checks
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=5)


def main() -> int:
    hashes: dict[str, str] = {}
    checks: dict[str, bool] = {"accounting_compile_harness": False}
    evidence: dict[str, list[int]] = {}
    stage = "compile"
    try:
        with tempfile.TemporaryDirectory(prefix="boros-accounting-runner-") as temporary:
            scratch = Path(temporary).resolve()
            captured = scratch / "source"
            captured.mkdir()
            for name in SOURCES:
                payload = (ROOT / "Sources/Boros" / name).read_bytes()
                (captured / name).write_bytes(payload)
                hashes[name] = hashlib.sha256(payload).hexdigest()
            shutil.copytree(ROOT / "Sources/CSQLite", captured / "CSQLite")
            (captured / "Harness.swift").write_text(HARNESS)
            binary = scratch / "accounting-checks"
            subprocess.run(["/usr/bin/swiftc", "-swift-version", "5", "-I", str(captured / "CSQLite"),
                            "-o", str(binary), *(str(captured / name) for name in SOURCES),
                            str(captured / "Harness.swift")], capture_output=True, check=True, timeout=120)
            stage = "focused"
            checks = fixed_json(binary, "--episode-accounting-self-test", evidence=evidence)
            for boundary in ("work", "settlement"):
                stage = "sigkill_" + boundary
                checks.update(killed_boundary(binary, boundary, scratch / boundary))
    except (OSError, ValueError, sqlite3.Error, subprocess.SubprocessError):
        checks["accounting_" + stage + "_harness"] = False
    failed = sorted(key for key, passed in checks.items() if not passed)
    print(json.dumps({"passed": not failed, "checks": len(checks), "failed": failed,
                      "source_sha256": hashes, "contracts": checks,
                      "vm_evidence": evidence, "vm_measurement_fields": ["vm_steps", "full_scan_steps", "profiled_statements"],
                      "runner_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}, sort_keys=True))
    return int(bool(failed))


if __name__ == "__main__":
    raise SystemExit(main())
