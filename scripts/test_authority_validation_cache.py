"""Run isolated owner cache/session contracts with captured source hashes."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = (
    "EpisodeBudget.swift", "EpisodeLease.swift", "EpisodeSQLFence.swift", "MemoryStore.swift",
    "AuthorityState.swift", "AuthorityStateJournal.swift", "AuthorityValidatedClock.swift",
    "AuthorityBindings.swift", "AuthorityBindingJournal.swift", "AuthorityValidation.swift", "AuthorityPolicyRendering.swift", "AuthorityInputProof.swift",
    "AuthorityValidationCache.swift", "EpisodeAccountingJournal.swift", "AuthoritySchemaSeven.swift", "AuthoritySchemaEight.swift", "EpisodeTerminalCleanup.swift", "AuthorityValidationCacheChecks.swift",
    "BackgroundIndexBudget.swift", "BackgroundIndexJournal.swift", "ContextComponentJournal.swift",
    "QwenTextRendering.swift", "ContextSourceFraming.swift", "HistoricalQueryFormulation.swift", "MeteredExchangeExpansion.swift", "ContextAssembler.swift", "MeteredRetrieval.swift",
)
HARNESS = r'''
import Foundation
import Darwin
@main enum AuthorityValidationCacheHarness {
    static func main() {
        guard CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--authority-validation-cache-self-test" else {
            print("{\"authority_cache_arguments\":false}"); exit(2)
        }
        do {
            let checks = try AuthorityValidationCacheChecks.run()
            print(String(decoding: try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]), as: UTF8.self))
            exit(checks.values.allSatisfy { $0 } ? 0 : 1)
        } catch { print("{\"authority_cache_harness\":false}"); exit(1) }
    }
}
'''


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path)
    arguments = parser.parse_args()
    hashes = {}
    checks = {"authority_cache_harness": False}
    try:
        with tempfile.TemporaryDirectory(prefix="boros-authority-cache-") as temporary:
            scratch = Path(temporary).resolve()
            binary = arguments.binary.resolve() if arguments.binary else None
            if binary is None:
                captured = scratch / "source"
                captured.mkdir()
                for name in SOURCES:
                    destination = captured / name
                    destination.write_bytes((ROOT / "Sources/Boros" / name).read_bytes())
                    hashes[name] = hashlib.sha256(destination.read_bytes()).hexdigest()
                shutil.copytree(ROOT / "Sources/CSQLite", captured / "CSQLite")
                (captured / "Harness.swift").write_text(HARNESS)
                binary = scratch / "authority-cache-checks"
                subprocess.run(["/usr/bin/swiftc", "-swift-version", "5", "-I", str(captured / "CSQLite"),
                                "-o", str(binary), *(str(captured / name) for name in SOURCES),
                                str(captured / "Harness.swift")], capture_output=True, check=True, timeout=120)
            run = subprocess.run([str(binary), "--authority-validation-cache-self-test"], capture_output=True,
                                 text=True, timeout=120)
            if len(run.stdout.encode()) > 65536:
                raise ValueError("invalid fixed check output")
            value = json.loads(run.stdout)
            if not isinstance(value, dict) or not value or any(type(item) is not bool for item in value.values()):
                raise ValueError("invalid fixed check output")
            if any(not isinstance(key, str) or not key.startswith("authority_cache_") for key in value):
                raise ValueError("invalid fixed check name")
            checks = value
            if run.returncode and all(checks.values()):
                checks = {"authority_cache_exit_status": False}
    except (OSError, ValueError, subprocess.SubprocessError):
        checks = {"authority_cache_harness": False}
    failed = sorted(key for key, passed in checks.items() if not passed)
    print(json.dumps({"passed": not failed, "checks": len(checks), "failed": failed,
                      "source_sha256": hashes, "contracts": checks}, sort_keys=True))
    return int(bool(failed))


if __name__ == "__main__":
    raise SystemExit(main())
