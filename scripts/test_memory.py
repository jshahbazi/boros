#!/usr/bin/env python3
"""Compile and check the Swift memory core using isolated synthetic stores."""
import json
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
import Foundation
import Darwin

@main
enum MemoryHarness {
    static func main() {
        do {
            if CommandLine.arguments.count == 3 {
                let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
                if CommandLine.arguments[1] == "hold-owner" {
                    let store = try MemoryStore(directory: directory)
                    print("ready")
                    fflush(stdout)
                    _ = readLine()
                    withExtendedLifetime(store) {}
                    return
                }
                if CommandLine.arguments[1] == "probe-owner" {
                    do {
                        _ = try MemoryStore(directory: directory)
                        print("owner_was_not_rejected")
                        exit(1)
                    } catch MemoryError.ownerBusy {
                        print("owner_rejected")
                        return
                    }
                }
            }
            let checks = try MemoryChecks.run()
            let data = try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            if checks.values.contains(false) { exit(1) }
        } catch {
            // Diagnostics describe operation metadata only; no payload printed.
            fputs("Memory checks failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
'''


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="boros-memory-test-") as scratch:
        temporary = Path(scratch)
        harness = temporary / "MemoryHarness.swift"
        harness.write_text(HARNESS)
        binary = temporary / "memory-checks"
        sources = [ROOT / "Sources/Boros" / name for name in (
            "MemoryStore.swift", "ContextAssembler.swift", "MemoryChecks.swift"
        )]
        subprocess.run([
            "swiftc", "-I", str(ROOT / "Sources/CSQLite"),
            "-o", str(binary), *(str(path) for path in sources), str(harness)
        ], check=True)
        result = subprocess.run([str(binary)], capture_output=True, text=True, check=True)
        checks = json.loads(result.stdout)
        lock_directory = temporary / "owner-check"
        owner = subprocess.Popen(
            [str(binary), "hold-owner", str(lock_directory)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True,
        )
        try:
            if owner.stdout.readline().strip() != "ready":
                raise RuntimeError("Owner test did not reach its readiness boundary")
            probe = subprocess.run(
                [str(binary), "probe-owner", str(lock_directory)],
                capture_output=True, text=True, check=True, timeout=10,
            )
            checks["separate_process_owner_rejected"] = probe.stdout.strip() == "owner_rejected"
        finally:
            owner.communicate("release\n", timeout=10)
            if owner.returncode:
                raise RuntimeError("Owner process exited unexpectedly")
        print(json.dumps(checks, indent=2, sort_keys=True))
        if not all(checks.values()):
            raise SystemExit(1)


if __name__ == "__main__":
    main()
