#!/usr/bin/env python3
"""Run the isolated SIGKILL/recovery semantic-index protocol."""

import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
SOURCES = [ROOT / "Sources/Boros" / name for name in (
    "EpisodeBudget.swift", "EpisodeLease.swift", "EpisodeSQLFence.swift", "MemoryStore.swift", "AuthorityState.swift", "AuthorityStateJournal.swift", "AuthorityBindings.swift", "AuthorityValidation.swift", "AuthorityBindingJournal.swift",
    "BackgroundIndexBudget.swift", "BackgroundIndexJournal.swift", "ContextComponentJournal.swift",
    "QwenTextRendering.swift", "ContextSourceFraming.swift", "ContextAssembler.swift", "MeteredRetrieval.swift",
    "SemanticIndex.swift", "BackgroundIndexWorker.swift",
)]
HARNESS = ROOT / "Tests/SemanticCrashHarness.swift"
TIMEOUT = 60


def ready_line(process: subprocess.Popen[str], deadline: float) -> bool:
    selector = selectors.DefaultSelector()
    fd = process.stdout.fileno()
    os.set_blocking(fd, False)
    buffer = bytearray()
    try:
        selector.register(fd, selectors.EVENT_READ)
        while time.monotonic() < deadline:
            events = selector.select(max(0.0, deadline - time.monotonic()))
            if not events:
                return False
            try:
                chunk = os.read(fd, 4096)
            except BlockingIOError:
                continue
            if not chunk:
                return False
            buffer.extend(chunk)
            if len(buffer) > 4096:
                return False
            lines = buffer.split(b"\n")
            buffer = bytearray(lines[-1])
            if any(line.strip() == b"ready" for line in lines[:-1]):
                return True
        return False
    finally:
        selector.close()


def terminate(process: subprocess.Popen[str], sigkill: bool = False) -> None:
    if process.poll() is None:
        process.kill() if sigkill else process.terminate()
    try:
        process.wait(timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=TIMEOUT)


def checks_from(process: subprocess.CompletedProcess[str]) -> dict[str, bool]:
    try:
        value = json.loads(process.stdout)
    except (json.JSONDecodeError, TypeError) as error:
        raise RuntimeError("recovery output was not JSON") from error
    expected = {
        "sigkill_semantic_committed_cursor_retained",
        "sigkill_semantic_unsealed_source_not_served",
        "sigkill_semantic_original_source_digest_preserved",
        "sigkill_semantic_resumes_to_complete_without_holes",
        "sigkill_semantic_persisted_manifest_replays",
        "sigkill_semantic_completed_replay_no_new_work",
    }
    if set(value) != expected or any(not isinstance(v, bool) for v in value.values()):
        raise RuntimeError("recovery output did not contain the expected six boolean checks")
    return value


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="boros-semantic-recovery-") as scratch:
        temporary = Path(scratch)
        binary = temporary / "semantic-crash"
        subprocess.run(
            ["swiftc", "-I", str(ROOT / "Sources/CSQLite"), *map(str, SOURCES), str(HARNESS),
             "-o", str(binary), "-lsqlite3", "-framework", "NaturalLanguage"],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
        )
        store = temporary / "store"
        producer = subprocess.Popen(
            [str(binary), "produce", str(store)], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        try:
            if not ready_line(producer, time.monotonic() + TIMEOUT):
                raise RuntimeError("produce did not reach readiness")
            producer.kill()
            producer.wait(timeout=TIMEOUT)
            if producer.returncode != -signal.SIGKILL:
                raise RuntimeError("produce did not terminate via SIGKILL")
        finally:
            terminate(producer, sigkill=True)
            for stream in (producer.stdin, producer.stdout, producer.stderr):
                if stream is not None:
                    stream.close()

        for _ in range(2):
            recovered = subprocess.run(
                [str(binary), "recover", str(store)], capture_output=True, text=True,
                check=False, timeout=TIMEOUT,
            )
            if recovered.returncode != 0:
                raise RuntimeError("recover exited unsuccessfully")
            checks = checks_from(recovered)
            failed = [name for name, passed in checks.items() if not passed]
            if failed:
                raise RuntimeError("recovery checks failed: " + ",".join(failed))
        print(json.dumps({"stage": "semantic_recovery", "checks": 6, "failed": []}, sort_keys=True))


if __name__ == "__main__":
    main()
