#!/usr/bin/env python3
"""Synthetic scale measurement for the P2 step 4 global semantic search.

Compiles Tests/Evaluation/GlobalSemanticScale.swift with the application
sources (as the retrieval harness does) and times GlobalSemanticSearch.search
over disposable synthetic sidecars of the requested row counts. No user data,
dataset, model server or network is used. The report holds counts and timings.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import retrieval_harness as harness  # noqa: E402

SOURCE = "Tests/Evaluation/GlobalSemanticScale.swift"


def compile_benchmark(cache_root: Path):
    sources = sorted(p for p in (ROOT / "Sources/Boros").glob("*.swift") if p.name not in harness.EXCLUDED_SOURCES)
    files = [*sources, ROOT / SOURCE, ROOT / "Sources/CSQLite/module.modulemap", ROOT / "Sources/CSQLite/shim.h"]
    hashes = {str(path.relative_to(ROOT)): harness.digest(path.read_bytes()) for path in files}
    build = harness.digest(harness.canonical(hashes))
    binary = cache_root / "bin-scale" / build / "GlobalSemanticScale"
    if not binary.exists():
        (binary.parent / "staging").mkdir(parents=True, exist_ok=True)
        command = ["/usr/bin/swiftc", "-O", "-swift-version", "5", "-parse-as-library", "-target", "arm64-apple-macos14.0",
                   "-framework", "AppKit", "-framework", "Foundation", "-framework", "Security",
                   "-framework", "LocalAuthentication", "-framework", "NaturalLanguage",
                   "-I", str(ROOT / "Sources/CSQLite"), "-lsqlite3", "-o", str(binary.parent / "staging" / "GlobalSemanticScale"),
                   *(str(ROOT / name) for name in hashes if name.endswith(".swift"))]
        process = subprocess.run(command, capture_output=True, timeout=1800)
        harness.require(process.returncode == 0, "scale_compilation_failed")
        os.replace(binary.parent / "staging" / "GlobalSemanticScale", binary)
    revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    dirty = bool(subprocess.run(["git", "status", "--porcelain", "--", "Sources", "Tests", "scripts"], cwd=ROOT,
                                capture_output=True, text=True).stdout.strip())
    return binary, {"git_revision": revision, "working_tree_modified": dirty, "build_sha256": build,
                    "binary_sha256": harness.digest(binary.read_bytes())}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--rows", type=int, nargs="+", default=[1000, 10000, 50000, 140000])
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.absolute()
    harness.require(not output.exists(), "output_exists")
    binary, implementation = compile_benchmark((ROOT / ".build/retrieval-harness").absolute())
    results = []
    with tempfile.TemporaryDirectory(prefix="boros-global-scale-") as temporary:
        for rows in args.rows:
            target = Path(temporary) / f"rows-{rows}.json"
            process = subprocess.run([str(binary), str(rows), str(args.repeats), str(target)], capture_output=True,
                                     timeout=3600, env={**os.environ, "TMPDIR": temporary + "/"})
            if process.returncode or not target.exists():
                results.append({"rows": rows, "failure": "exit_" + str(process.returncode)})
                continue
            results.append(json.loads(target.read_bytes()))
            print(json.dumps({"rows": rows, "unleased_milliseconds": results[-1]["unleased_milliseconds"],
                              "default_episode_limits": results[-1]["default_episode_limits"]}, sort_keys=True), flush=True)
    report = {"global_semantic_scale_version": 1, "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
              "purpose": "P2 step 4: brute-force global vector search time against synthetic sidecars",
              "implementation": implementation, "results": results,
              "limitations": ["synthetic one-chunk sources and random unit vectors", "warm page cache after population",
                              "no lexical matches, so the measured search is the vector stage plus sixteen verified reads"]}
    harness.private_write(output, harness.canonical(report) + b"\n")
    print("Metadata-only report: " + str(output))


if __name__ == "__main__":
    main()
