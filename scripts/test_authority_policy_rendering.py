"""Run isolated policy rendering contracts with captured source hashes."""
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
    "AuthorityBindings.swift", "AuthorityBindingJournal.swift", "AuthorityValidation.swift", "AuthorityPolicyRendering.swift",
    "AuthorityValidationCache.swift", "EpisodeAccountingJournal.swift", "AuthoritySchemaSeven.swift", "AuthoritySchemaEight.swift", "EpisodeTerminalCleanup.swift", "AuthorityPolicyRenderingChecks.swift",
    "BackgroundIndexBudget.swift", "BackgroundIndexJournal.swift", "ContextComponentJournal.swift",
    "QwenTextRendering.swift", "ContextSourceFraming.swift", "ContextAssembler.swift", "MeteredRetrieval.swift",
)
HARNESS = r'''
import Foundation
import Darwin
@main enum AuthorityPolicyRenderingHarness {
    static func main() {
        if CommandLine.arguments.count == 3 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            do {
                if CommandLine.arguments[1] == "--interrupt-authority-policy-rendering" {
                    try AuthorityPolicyRenderingChecks.interruptRenderingForProcessChecks(directory: directory)
                    exit(1)
                }
                if CommandLine.arguments[1] == "--recover-authority-policy-rendering" {
                    let checks = try AuthorityPolicyRenderingChecks.recoverRenderingForProcessChecks(directory: directory)
                    print(String(decoding: try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]), as: UTF8.self))
                    exit(checks.values.allSatisfy { $0 } ? 0 : 1)
                }
            } catch { print("{\"authority_policy_process_harness\":false}"); exit(1) }
        }
        guard CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--authority-policy-rendering-self-test" else {
            print("{\"authority_policy_arguments\":false}"); exit(2)
        }
        do {
            let checks = try AuthorityPolicyRenderingChecks.run()
            print(String(decoding: try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]), as: UTF8.self))
            exit(checks.values.allSatisfy { $0 } ? 0 : 1)
        } catch { print("{\"authority_policy_harness\":false}"); exit(1) }
    }
}
'''


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path)
    arguments = parser.parse_args()
    hashes = {}
    checks = {"authority_policy_harness": False}
    try:
        with tempfile.TemporaryDirectory(prefix="boros-authority-policy-") as temporary:
            scratch = Path(temporary).resolve()
            captured = scratch / "source"
            captured.mkdir()
            for name in SOURCES:
                destination = captured / name
                destination.write_bytes((ROOT / "Sources/Boros" / name).read_bytes())
                hashes[name] = hashlib.sha256(destination.read_bytes()).hexdigest()
            shutil.copytree(ROOT / "Sources/CSQLite", captured / "CSQLite")
            (captured / "Harness.swift").write_text(HARNESS)
            binary = scratch / "authority-policy-checks"
            subprocess.run(["/usr/bin/swiftc", "-swift-version", "5", "-I", str(captured / "CSQLite"),
                            "-o", str(binary), *(str(captured / name) for name in SOURCES),
                            str(captured / "Harness.swift")], capture_output=True, check=True, timeout=120)
            # An optional application binary verifies its actual wired self-test;
            # the crash fixture always uses this captured private harness.
            check_binary = arguments.binary.resolve() if arguments.binary else binary
            run = subprocess.run([str(check_binary), "--authority-policy-rendering-self-test"], capture_output=True,
                                 text=True, timeout=120)
            if len(run.stdout.encode()) > 65536:
                raise ValueError("invalid fixed check output")
            value = json.loads(run.stdout)
            if not isinstance(value, dict) or not value or any(type(item) is not bool for item in value.values()):
                raise ValueError("invalid fixed check output")
            if any(not isinstance(key, str) or not key.startswith("authority_policy_") for key in value):
                raise ValueError("invalid fixed check name")
            checks = value
            if run.returncode and all(checks.values()):
                checks = {"authority_policy_exit_status": False}
            directory = scratch / "process-store"
            killed = subprocess.run([str(binary), "--interrupt-authority-policy-rendering", str(directory)],
                                    capture_output=True, text=True, timeout=30)
            checks["authority_policy_sigkill_after_durable_arm_before_render"] = (
                killed.returncode == -9 and not killed.stdout and not killed.stderr
            )
            for restart in (1, 2):
                reopened = subprocess.run([str(binary), "--recover-authority-policy-rendering", str(directory)],
                                          capture_output=True, text=True, timeout=30)
                result = json.loads(reopened.stdout)
                if len(reopened.stdout.encode()) > 65536 or not isinstance(result, dict) or not result:
                    raise ValueError("invalid fixed process check output")
                if any(not isinstance(key, str) or not key.startswith("authority_policy_") or type(passed) is not bool
                       for key, passed in result.items()):
                    raise ValueError("invalid fixed process check output")
                for key, passed in result.items():
                    checks[f"authority_policy_sigkill_restart_{restart}_" + key.removeprefix("authority_policy_")] = passed
                checks[f"authority_policy_sigkill_restart_{restart}_exit_status"] = reopened.returncode == 0
    except (OSError, ValueError, subprocess.SubprocessError):
        checks = {"authority_policy_harness": False}
    failed = sorted(key for key, passed in checks.items() if not passed)
    print(json.dumps({"passed": not failed, "checks": len(checks), "failed": failed,
                      "source_sha256": hashes, "contracts": checks}, sort_keys=True))
    return int(bool(failed))


if __name__ == "__main__":
    raise SystemExit(main())
