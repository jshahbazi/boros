"""Build and verify Boros with synthetic data and temporary stores."""
from pathlib import Path
import argparse
import json
import os
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path)
    args = parser.parse_args()
    if args.app is None:
        subprocess.run([sys.executable, str(ROOT / "scripts/build.py")], cwd=ROOT, check=True)
    app = args.app or ROOT / ".build/boros/Boros.app"
    binary = app.resolve() / "Contents/MacOS/Boros"
    total = 0
    with tempfile.TemporaryDirectory(prefix="boros-checks-") as directory:
        env = {**os.environ, "BOROS_DATA_DIR": directory}
        suites = ["--retrieval-strategy-self-test", "--background-budget-self-test", "--background-ledger-self-test", "--background-worker-self-test", "--episode-self-test", "--local-read-self-test", "--conversation-self-test", "--ui-self-test", "--reasoning-self-test", "--memory-self-test", "--endpoint-self-test", "--context-admission-self-test", "--semantic-self-test", "--backup-self-test"]
        for suite in suites:
            run = subprocess.run([str(binary), suite], capture_output=True, text=True, env=env, timeout=90)
            checks = json.loads(run.stdout)
            failed = [name for name, passed in checks.items() if passed is not True]
            total += len(checks)
            print(json.dumps({"suite": suite, "checks": len(checks), "failed": failed}))
            if run.returncode or failed:
                return 1
        fixture = subprocess.Popen([sys.executable, str(ROOT / "Tests/endpoint_fixture.py")], stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, text=True)
        try:
            port = int(fixture.stdout.readline().strip())
            run = subprocess.run([str(binary), "--endpoint-integration-test", f"http://127.0.0.1:{port}/v1"],
                                 capture_output=True, text=True, env=env, timeout=90)
            checks = json.loads(run.stdout)
            failed = [name for name, passed in checks.items() if passed is not True]
            total += len(checks)
            print(json.dumps({"suite": "endpoint-integration", "checks": len(checks), "failed": failed}))
            if run.returncode or failed:
                return 1
        finally:
            fixture.terminate()
            fixture.wait(timeout=5)
        component = subprocess.run([sys.executable, str(ROOT / "scripts/test_component_preparation.py"),
                                    "--binary", str(binary)], capture_output=True, text=True, env=env, timeout=240)
        component_report = json.loads(component.stdout)
        print(json.dumps(component_report))
        total += component_report["checks"]
        if component.returncode or component_report["failed"]:
            return 1
        answering = subprocess.run([sys.executable, str(ROOT / "scripts/test_answer_evaluation.py"),
                                    "--binary", str(binary)], capture_output=True, text=True, env=env, timeout=420)
        answering_report = json.loads(answering.stdout)
        print(json.dumps({"suite": "answer-evaluation", **answering_report}))
        total += answering_report["checks"]
        if answering.returncode or answering_report["failed"] or answering_report["errors"] or answering_report["skipped"]:
            return 1
        importer = subprocess.run([sys.executable, str(ROOT / "scripts/test_chat_import.py"),
                                   "--binary", str(binary)], capture_output=True, text=True, env=env, timeout=90)
        importer_report = json.loads(importer.stdout)
        print(json.dumps({"suite": "chat-import", **importer_report}))
        total += importer_report["checks"]
        if importer.returncode or importer_report["failed"] or importer_report["skipped"]:
            return 1
        imported_evaluation = subprocess.run([sys.executable, str(ROOT / "scripts/test_imported_chat_evaluation.py")],
                                             capture_output=True, text=True, env=env, timeout=180)
        evaluation_report = json.loads(imported_evaluation.stdout)
        print(json.dumps({"suite": "imported-chat-evaluation", **evaluation_report}))
        total += evaluation_report["checks"]
        if imported_evaluation.returncode or evaluation_report["failed"] or evaluation_report["errors"] or evaluation_report["skipped"]:
            return 1
    print(json.dumps({"total_checks": total, "passed": True}))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.SubprocessError):
        print("Boros verification failed before all checks completed.")
        raise SystemExit(1)
