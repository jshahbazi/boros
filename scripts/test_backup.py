#!/usr/bin/env python3
"""Verify SQLite backups with synthetic stores, including a real SIGKILL."""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
import Foundation
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
                _ = try owner.append(conversationID: conversation.id, role: .human, text: "SYNTHETIC_BACKUP_CRASH_SOURCE", status: .complete, turnID: "crash-turn", eventID: "crash-source")
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
            "MemoryStore.swift", "BackupArchive.swift", "BackupCommand.swift", "BackupChecks.swift"
        )]
        subprocess.run(["swiftc", "-I", str(ROOT / "Sources/CSQLite"), "-o", str(binary),
                        *(str(path) for path in sources), str(harness)], check=True)
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
            if interrupted.stdout.readline().strip() != "ready":
                raise RuntimeError("Interrupted backup did not reach its staging boundary")
            staging = list(scratch.glob(".boros-staging-*"))
            interrupted.kill()
            interrupted.communicate(timeout=10)
            checks["backup_sigkill_private_staging_never_published"] = (
                interrupted.returncode == -9 and not archive.exists() and len(staging) == 1
                and staging[0].is_dir() and staging[0].stat().st_mode & 0o777 == 0o700
            )
        finally:
            if interrupted.poll() is None:
                interrupted.kill()
                interrupted.communicate(timeout=10)
        print(json.dumps(checks, indent=2, sort_keys=True))
        if not all(checks.values()):
            raise SystemExit(1)


if __name__ == "__main__":
    main()
