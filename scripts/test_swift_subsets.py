"""Typecheck the Swift source subsets that standalone store test scripts compile.

Each scripts/test_*.py that imports swift_store_sources declares a module-level SOURCES tuple of file
names under Sources/Boros, or of paths, and a HARNESS that is Swift text or a path. This check typechecks
every SOURCES list together with its harness, so a subset that has lost a dependency fails
scripts/check.py without running the slower standalone suites.
"""
from concurrent.futures import ThreadPoolExecutor
import importlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"


def subset_scripts():
    return sorted(path for path in SCRIPTS.glob("test_*.py")
                  if path.name != Path(__file__).name and "from swift_store_sources import" in path.read_text())


def typecheck(path, scratch):
    module = importlib.import_module(path.stem)
    sources = [Path(source) if isinstance(source, Path) else ROOT / "Sources/Boros" / source
               for source in module.SOURCES]
    names = [source.name for source in sources]
    if len(names) != len(set(names)):
        return {"duplicate_sources": sorted({name for name in names if names.count(name) > 1})}
    missing = [name for name, source in zip(names, sources) if not source.is_file()]
    if missing:
        return {"missing_sources": missing}
    harness = module.HARNESS
    if not isinstance(harness, Path):
        directory = scratch / path.stem
        directory.mkdir()
        (directory / "Harness.swift").write_text(harness)
        harness = directory / "Harness.swift"
    run = subprocess.run(["/usr/bin/swiftc", "-typecheck", "-swift-version", "5", "-I", str(ROOT / "Sources/CSQLite"),
                          *map(str, sources), str(harness)], capture_output=True, text=True, timeout=300)
    if run.returncode:
        return {"errors": [line for line in run.stderr.splitlines() if ": error: " in line][:5]}
    return None


def main():
    sys.path.insert(0, str(SCRIPTS))
    scripts = subset_scripts()
    with tempfile.TemporaryDirectory(prefix="boros-swift-subsets-") as directory, ThreadPoolExecutor(4) as pool:
        results = dict(zip((path.stem for path in scripts),
                           pool.map(lambda path: typecheck(path, Path(directory)), scripts)))
    failed = sorted(name for name, problem in results.items() if problem)
    for name in failed:
        print(json.dumps({"script": name, **results[name]}), file=sys.stderr)
    print(json.dumps({"checks": len(results), "failed": failed, "errors": [], "skipped": [],
                      "scripts": sorted(results)}))
    return 1 if failed or not results else 0


if __name__ == "__main__":
    raise SystemExit(main())
