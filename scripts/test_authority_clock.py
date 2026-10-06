"""Verify bounded clock checkpoints and real SIGKILL transaction recovery."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SOURCES = (
    "EpisodeBudget.swift", "EpisodeLease.swift", "EpisodeSQLFence.swift", "MemoryStore.swift",
    "AuthorityState.swift", "AuthorityStateJournal.swift", "AuthorityValidatedClock.swift", "AuthorityValidationCache.swift", "AuthorityBindings.swift", "AuthorityValidation.swift", "AuthorityBindingJournal.swift", "AuthorityClockChecks.swift",
    "BackgroundIndexBudget.swift", "BackgroundIndexJournal.swift", "ContextComponentJournal.swift",
    "QwenTextRendering.swift", "ContextSourceFraming.swift", "ContextAssembler.swift",
    "MeteredRetrieval.swift", "BackupArchive.swift", "AuthoritySchemaFive.swift", "AuthoritySchemaSix.swift",
)
HARNESS = r'''
import Foundation
import Darwin
@main enum AuthorityClockHarness {
    static func main() {
        do {
            let arguments = CommandLine.arguments
            let checks: [String: Bool]
            if arguments.count == 4 && arguments[1] == "--authority-clock-crash-producer" {
                try AuthorityClockChecks.produceCrashFixture(directory: URL(fileURLWithPath: arguments[2], isDirectory: true), coalescing: arguments[3] == "replacement")
                exit(1)
            } else if arguments.count == 4 && arguments[1] == "--authority-clock-crash-recover" {
                checks = try AuthorityClockChecks.verifyCrashFixture(directory: URL(fileURLWithPath: arguments[2], isDirectory: true), coalescing: arguments[3] == "replacement")
            } else if arguments.count == 2 && arguments[1] == "--authority-clock-self-test" {
                checks = try AuthorityClockChecks.run()
            } else { print("{\"authority_clock_arguments\":false}"); exit(2) }
            print(String(decoding: try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]), as: UTF8.self))
            exit(checks.values.allSatisfy { $0 } ? 0 : 1)
        } catch { print("{\"authority_clock_harness\":false}"); exit(1) }
    }
}
'''


def parsed(run: subprocess.CompletedProcess[str]) -> dict[str, bool]:
    if len(run.stdout.encode()) > 65536:
        raise ValueError("oversized fixed check output")
    checks = json.loads(run.stdout)
    if not isinstance(checks, dict) or not checks or any(type(v) is not bool for v in checks.values()):
        raise ValueError("invalid fixed check output")
    if any(not isinstance(k, str) or not k.startswith("authority_") for k in checks):
        raise ValueError("invalid fixed check name")
    if run.returncode or not all(checks.values()):
        raise ValueError("clock fixture failed")
    return checks


def compile_harness(scratch: Path) -> tuple[Path, dict[str, str]]:
    captured = scratch / "source"
    captured.mkdir()
    hashes = {}
    for name in SOURCES:
        source = ROOT / "Sources/Boros" / name
        destination = captured / name
        destination.write_bytes(source.read_bytes())
        hashes[name] = hashlib.sha256(destination.read_bytes()).hexdigest()
    shutil.copytree(ROOT / "Sources/CSQLite", captured / "CSQLite")
    harness = captured / "Harness.swift"
    harness.write_text(HARNESS)
    binary = scratch / "authority-clock-checks"
    subprocess.run(["/usr/bin/swiftc", "-swift-version", "5", "-I", str(captured / "CSQLite"),
                    "-o", str(binary), *(str(captured / name) for name in SOURCES), str(harness)],
                   check=True, capture_output=True, timeout=120)
    return binary, hashes


def ready(process: subprocess.Popen[bytes]) -> bool:
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    buffer = bytearray()
    deadline = time.monotonic() + 20
    try:
        while time.monotonic() < deadline:
            if process.poll() is not None:
                return False
            for key, _ in selector.select(timeout=min(0.5, max(0, deadline - time.monotonic()))):
                chunk = os.read(key.fileobj.fileno(), 1024)
                if not chunk:
                    return False
                buffer.extend(chunk)
                if len(buffer) > 1024:
                    return False
                if b"\n" in buffer:
                    return bytes(buffer).strip() == b"ready"
        return False
    finally:
        selector.close()


def run_checks(binary: Path, flag: str, directory: Path | None = None, mode: str | None = None) -> dict[str, bool]:
    arguments = [str(binary), flag]
    if directory is not None:
        arguments.append(str(directory))
    if mode is not None:
        arguments.append(mode)
    return parsed(subprocess.run(arguments, capture_output=True, text=True, timeout=120))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--process-only", action="store_true")
    arguments = parser.parse_args()
    checks: dict[str, bool] = {}
    hashes: dict[str, str] = {}
    with tempfile.TemporaryDirectory(prefix="boros-authority-clock-") as temporary:
        scratch = Path(temporary).resolve()
        binary = arguments.binary.resolve() if arguments.binary else None
        if binary is None:
            binary, hashes = compile_harness(scratch)
        if not arguments.process_only:
            checks.update(run_checks(binary, "--authority-clock-self-test"))
        for mode in ("replacement", "append"):
            mode_checks: dict[str, bool] = {}
            fixture = scratch / ("crash-store-" + mode)
            process = subprocess.Popen([str(binary), "--authority-clock-crash-producer", str(fixture), mode],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                       start_new_session=True)
            try:
                if not ready(process):
                    raise RuntimeError("clock producer did not reach the fixed barrier")
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=10)
                mode_checks["authority_clock_process_sigkill_at_uncommitted_checkpoint"] = process.returncode == -signal.SIGKILL
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=10)
                for stream in (process.stdin, process.stdout):
                    if stream is not None:
                        stream.close()
            first = run_checks(binary, "--authority-clock-crash-recover", fixture, mode)
            second = run_checks(binary, "--authority-clock-crash-recover", fixture, mode)
            mode_checks.update(first)
            mode_checks["authority_clock_process_second_reopen_preserves_recovery_checks"] = first == second
            # The producer must refuse an existing path before touching its state.
            database = fixture / "memory.sqlite3"
            before = hashlib.sha256(database.read_bytes()).hexdigest()
            refused = subprocess.run([str(binary), "--authority-clock-crash-producer", str(fixture), mode],
                                     capture_output=True, timeout=10)
            mode_checks["authority_clock_process_producer_refuses_existing_fixture_unchanged"] = (
                refused.returncode != 0 and before == hashlib.sha256(database.read_bytes()).hexdigest()
            )
            if mode == "append":
                checks.update({key.replace("authority_clock_", "authority_clock_append_", 1): value for key, value in mode_checks.items()})
            else:
                checks.update(mode_checks)
    report = {"checks": len(checks), "failed": [key for key, value in checks.items() if value is not True],
              "passed": all(checks.values()), "sourceSHA256": hashes}
    print(json.dumps(report, sort_keys=True))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        print(json.dumps({"checks": 0, "failed": ["authority_clock_process_harness"], "passed": False}))
        raise SystemExit(1)
