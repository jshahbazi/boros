"""Verify finite standalone browser reads against an isolated synthetic store."""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
import Foundation
private final class CoverageEncoder: SemanticEmbeddingAdapter {
    let dimension = 3
    let metadata = ["provider": "synthetic-read-coverage", "version": "1"]
    var calls = 0
    func encode(_ text: String) throws -> SemanticEncoding { calls += 1; return .vector([1, 0, 0]) }
}
@main
enum LocalReadHarness {
    static func main() {
        do {
            var checks = try LocalReadChecks.run()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-read-coverage-script-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try MemoryStore(directory: directory), encoder = CoverageEncoder()
            let semantic = try SemanticIndex(store: store, encoder: encoder)
            checks.merge(try ReadCoverageChecks.run(store: store, semantic: semantic)) { _, latest in latest }
            checks["read_coverage_synthetic_encoder_is_never_called"] = encoder.calls == 0
            print(String(decoding: try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys]), as: UTF8.self))
            exit(checks.values.allSatisfy { $0 } ? 0 : 1)
        } catch { print("{\"local_read_harness_failed\":false}"); exit(1) }
    }
}
'''


def main():
    with tempfile.TemporaryDirectory(prefix="boros-local-read-tests-") as temporary:
        scratch = Path(temporary)
        harness = scratch / "LocalReadHarness.swift"
        harness.write_text(HARNESS)
        binary = scratch / "local-read-checks"
        sources = [ROOT / "Sources/Boros" / name for name in (
            "EpisodeBudget.swift", "EpisodeLease.swift", "EpisodeSQLFence.swift", "MemoryStore.swift", "EventSourceTime.swift", "SourceTimeSchema.swift", "AuthoritySchemaNine.swift", "AuthorityState.swift", "AuthorityStateJournal.swift", "AuthorityValidatedClock.swift", "AuthorityValidationCache.swift", "EpisodeAccountingJournal.swift", "AuthoritySchemaSeven.swift", "AuthoritySchemaEight.swift", "EpisodeTerminalCleanup.swift", "AuthorityBindings.swift", "AuthorityValidation.swift", "AuthorityPolicyRendering.swift", "AuthorityInputProof.swift", "AuthorityBindingJournal.swift", "BackgroundIndexBudget.swift", "BackgroundIndexJournal.swift", "ContextComponentJournal.swift", "QwenTextRendering.swift", "ContextSourceFraming.swift",
            "MeteredRetrieval.swift", "HistoricalQueryFormulation.swift", "MeteredExchangeExpansion.swift", "ContextAssembler.swift", "SemanticIndex.swift", "BackgroundIndexWorker.swift", "ChatContextPreparation.swift", "ContextRetrievalStrategy.swift",
            "LocalReadCoordinator.swift", "LocalReadChecks.swift", "ReadCoverageChecks.swift")]
        subprocess.run(["/usr/bin/swiftc", "-swift-version", "5", "-I", str(ROOT / "Sources/CSQLite"),
                        "-framework", "NaturalLanguage", "-o", str(binary), *map(str, sources), str(harness)], check=True)
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=90)
        checks = json.loads(result.stdout)
        failed = [name for name, passed in checks.items() if passed is not True]
        print(json.dumps({"suite": "local-read", "checks": len(checks), "failed": failed}))
        return int(bool(result.returncode or failed or not checks))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.SubprocessError):
        print("Local read verification failed before all checks completed.")
        raise SystemExit(1)
