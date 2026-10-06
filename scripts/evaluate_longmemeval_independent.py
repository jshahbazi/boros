#!/usr/bin/env python3
"""Predeclared session-disjoint development comparison; private answering exports."""
from pathlib import Path
import json
import sys

import evaluate_answers as evidence
import evaluate_longmemeval as baseline


def main(argv=None):
    parser = evidence.SafeParser(description=__doc__)
    for name in ("source", "output", "hypotheses-directory", "binary", "binary-verification"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--timeout", type=int, default=10800)
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args(argv)
    try:
        if not args.execute or not args.output.is_absolute() or not args.hypotheses_directory.is_absolute():
            raise evidence.EvaluationError("explicit execution and absolute fresh destinations required")
        report = baseline.run(args.source, args.output, args.hypotheses_directory,
            binary=args.binary, binary_verification=args.binary_verification, timeout=args.timeout,
            cohort="independent-v1")
        print(json.dumps({"declared_attempts": 28, "official_qa_score": None, "summary": report["summary"]}, sort_keys=True))
        return 0
    except Exception:
        print("Independent LongMemEval evaluation failed; content diagnostics suppressed.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
