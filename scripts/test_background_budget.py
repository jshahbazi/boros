#!/usr/bin/env python3
"""Compile and execute content-free Foundation-only background contracts."""
from pathlib import Path
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
import Foundation
@main enum BackgroundContractMain {
    static func main() throws {
        let checks = try BackgroundIndexBudgetChecks.run()
        let failed = checks.filter { !$0.value }.keys.sorted()
        let result: [String: Any] = ["checks": checks.count, "passed": checks.count - failed.count, "failed": failed]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        if !failed.isEmpty { throw BackgroundIndexBudgetError.invalid }
    }
}
'''


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="boros-background-contract-") as temporary:
        folder = Path(temporary)
        harness = folder / "Harness.swift"
        binary = folder / "background-contract-checks"
        harness.write_text(HARNESS)
        subprocess.run([
            "swiftc", "-o", str(binary),
            str(ROOT / "Sources/Boros/BackgroundIndexBudget.swift"),
            str(ROOT / "Sources/Boros/BackgroundIndexBudgetChecks.swift"), str(harness),
        ], cwd=ROOT, check=True)
        completed = subprocess.run([str(binary)], cwd=ROOT, check=True, capture_output=True, text=True)
        result = json.loads(completed.stdout)
        assert result["checks"] > 0 and result["passed"] == result["checks"] and result["failed"] == []
        print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
