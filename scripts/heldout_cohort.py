#!/usr/bin/env python3
"""Freeze the held-out LongMemEval S cohort for the registered comparison (docs/DESIGN-REPAIR-PLAN.md P6).

Selection is deterministic and answer-blind: it reads question_id and question_type only, excludes
every identity an earlier cohort used, stratifies the rest by type (abstentions form their own
stratum) and takes a fixed quota per stratum in sha256 rank order. The committed manifest carries
identities, hashes, quotas and the rules; never question text, answers, dates or session content.
Stdout carries counts, identities and hashes only.

    python3 scripts/heldout_cohort.py --source DATASET --output scripts/heldout_cohort.json [--force]
    python3 scripts/heldout_cohort.py --source DATASET --verify
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import evaluate_answers as e  # noqa: E402
import framing_v4_temporal_cases as v4  # noqa: E402
import framing_v5_preference_cases as v5  # noqa: E402
import local_longmemeval_qa as qa  # noqa: E402
import longmemeval_independent_cases as independent  # noqa: E402
import native_investigation_hundred_cases as hundred  # noqa: E402

ROOT = SCRIPTS.parent
VERSION = "boros-heldout-cohort-v1"
COHORT = "heldout-65-v1"
RANK_DOMAIN = VERSION
MANIFEST_PATH = SCRIPTS / "heldout_cohort.json"
SOURCE_ENVIRONMENT = "BOROS_LONGMEMEVAL_S_SOURCE"
DEFAULT_SOURCE = ROOT / ".build/datasets" / f"longmemeval-{qa.SOURCE_REVISION}" / qa.SOURCE_NAME
SOURCE_RECORDS = 500
ANSWERABLE_QUOTA = 12
ABSTENTION_QUOTA = 5
ABSTENTION_SUFFIX = "_abs"
ABSTENTION_STRATUM = "abstention"
QUESTION_TYPES = tuple(sorted(set(qa.CASE_TYPES)))
STRATA = QUESTION_TYPES + (ABSTENTION_STRATUM,)
QUESTION_KEYS = ("question_id", "question_type", "abstention", "rank_sha256", "row_sha256")
USAGE_RULE = ("Held-out. Not for tuning, prompt iteration, retrieval parameter choice, or any decision before a "
              "registered comparison (docs/DESIGN-REPAIR-PLAN.md P6). Any run on it must be declared before "
              "generation and reported in full.")
SELECTION_RULE = (
    "Exclude every question_id an earlier cohort used: local_longmemeval_qa.CASE_IDS, "
    "longmemeval_independent_cases.CASE_IDS, native_investigation_hundred_cases.EARLY_CASE_IDS, the frozen "
    "100-question development selection recomputed by native_investigation_hundred_cases.select_rows on the "
    "pinned dataset, framing_v5_preference_cases.PROJECTION_PINS and framing_v4_temporal_cases.PROJECTION_PINS. "
    "Stratify the unused questions by question_type; questions whose question_id ends in _abs form the "
    "abstention stratum regardless of type. Within each stratum order by sha256(rank_domain + NUL + question_id, "
    "UTF-8) hex, then question_id, and take the first 12 per answerable type and the first 5 abstentions. A "
    "stratum with fewer unused questions than its quota contributes what it has and is recorded as short. "
    "Selection reads question_id and question_type only; questions, answers, dates and sessions are never "
    "read before the identities are frozen.")
RANK_RULE = "sha256(rank_domain + NUL + question_id, UTF-8) hex, then question_id"
ROW_HASH_RULE = "sha256 of the canonical JSON (sorted keys, compact separators, UTF-8) of the full dataset row"


class HeldoutError(Exception):
    """Fixed diagnostics only; never echo question or answer content."""


def require(condition, code):
    if not condition:
        raise HeldoutError(code)


def source_path():
    declared = os.environ.get(SOURCE_ENVIRONMENT)
    return Path(declared) if declared else DEFAULT_SOURCE


def rank_sha256(question_id):
    require(isinstance(question_id, str) and bool(question_id), "heldout_identity_invalid")
    return qa.digest((RANK_DOMAIN + "\0" + question_id).encode())


def is_abstention(question_id):
    return question_id.endswith(ABSTENTION_SUFFIX)


def stratum_of(question_id, question_type):
    return ABSTENTION_STRATUM if is_abstention(question_id) else question_type


def identities(rows):
    """{question_id: question_type}. Nothing else in a row is read."""
    require(isinstance(rows, list) and bool(rows), "heldout_inventory_invalid")
    by_id = {}
    for row in rows:
        require(isinstance(row, dict) and isinstance(row.get("question_id"), str) and bool(row["question_id"])
                and row["question_id"] not in by_id and row.get("question_type") in QUESTION_TYPES,
                "heldout_identity_invalid")
        by_id[row["question_id"]] = row["question_type"]
    return by_id


def used_case_ids(rows):
    """(sorted union of every identity an earlier cohort used, {source: count})."""
    development, _manifest = hundred.select_rows(rows)
    sources = {
        "local_longmemeval_qa.CASE_IDS": tuple(qa.CASE_IDS),
        "longmemeval_independent_cases.CASE_IDS": tuple(independent.CASE_IDS),
        "native_investigation_hundred_cases.EARLY_CASE_IDS": tuple(hundred.EARLY_CASE_IDS),
        "native_investigation_hundred_cases.select_rows": tuple(development),
        "framing_v5_preference_cases.PROJECTION_PINS": tuple(v5.PROJECTION_PINS),
        "framing_v4_temporal_cases.PROJECTION_PINS": tuple(v4.PROJECTION_PINS),
    }
    union = tuple(sorted(set().union(*sources.values())))
    return union, {name: len(ids) for name, ids in sources.items()}


def select_rows(rows, excluded=None):
    """Answer-blind stratified selection. Reads question_id and question_type only."""
    by_id = identities(rows)
    if excluded is None:
        excluded, sources = used_case_ids(rows)
    else:
        sources = {"declared": len(set(excluded))}
    excluded = tuple(sorted(set(excluded)))
    require(set(excluded).issubset(by_id), "heldout_excluded_identity_missing")
    unused = [qid for qid in by_id if qid not in set(excluded)]
    pools = {name: [] for name in STRATA}
    for qid in unused:
        pools[stratum_of(qid, by_id[qid])].append(qid)
    strata, questions = {}, []
    for name in STRATA:
        quota = ABSTENTION_QUOTA if name == ABSTENTION_STRATUM else ANSWERABLE_QUOTA
        ordered = sorted(pools[name], key=lambda qid: (rank_sha256(qid), qid))
        taken = ordered[:quota]
        strata[name] = {"quota": quota, "available": len(ordered), "taken": len(taken), "short": len(taken) < quota}
        questions.extend({"question_id": qid, "question_type": by_id[qid], "abstention": is_abstention(qid),
                          "rank_sha256": rank_sha256(qid)} for qid in taken)
    require(len({item["question_id"] for item in questions}) == len(questions), "heldout_selection_duplicate")
    return {"excluded": {"count": len(excluded), "question_ids": list(excluded), "sources": sources},
            "unused_count": len(unused), "strata": strata,
            "short_strata": [name for name in STRATA if strata[name]["short"]], "questions": questions}


def manifest_for(rows):
    """The committed manifest. Row hashes are computed only after the identities are selected."""
    selection = select_rows(rows)
    by_row = {row["question_id"]: row for row in rows}
    questions = [dict(item, row_sha256=qa.digest(qa.canonical(by_row[item["question_id"]])))
                 for item in selection["questions"]]
    abstentions = sum(1 for item in questions if item["abstention"])
    return {"version": VERSION, "cohort": COHORT, "rank_domain": RANK_DOMAIN,
            "source": {"sha256": qa.SOURCE_SHA256, "bytes": qa.SOURCE_BYTES, "revision": qa.SOURCE_REVISION,
                       "name": qa.SOURCE_NAME, "records": len(rows)},
            "usage_rule": USAGE_RULE, "selection_rule": SELECTION_RULE, "rank_rule": RANK_RULE,
            "abstention_rule": "question_id ends with " + ABSTENTION_SUFFIX, "row_hash_rule": ROW_HASH_RULE,
            "quotas": {"answerable_per_type": ANSWERABLE_QUOTA, "abstention": ABSTENTION_QUOTA},
            "selection_uses_answers": False, "selection_uses_positive_labels": False,
            "selection_uses_history_or_question_content": False,
            "excluded": selection["excluded"], "unused_count": selection["unused_count"],
            "strata": selection["strata"], "short_strata": selection["short_strata"],
            "declared_questions": len(questions), "answerable_questions": len(questions) - abstentions,
            "abstention_questions": abstentions, "questions": questions}


def render(manifest):
    return (json.dumps(manifest, indent=2, sort_keys=True, ensure_ascii=True) + "\n").encode()


def load_rows(source):
    raw = qa.read_file(Path(source), qa.SOURCE_BYTES)
    require(len(raw) == qa.SOURCE_BYTES and qa.digest(raw) == qa.SOURCE_SHA256, "heldout_source_pin_mismatch")
    rows = qa.strict_json(raw)
    require(isinstance(rows, list) and len(rows) == SOURCE_RECORDS, "heldout_source_record_count_invalid")
    return rows


def load_manifest(path=MANIFEST_PATH):
    manifest = qa.strict_json(qa.read_file(Path(path)))
    require(isinstance(manifest, dict) and manifest.get("version") == VERSION, "heldout_manifest_invalid")
    return manifest


def summary(manifest):
    """Counts and hashes only; no identities."""
    return {"version": manifest["version"], "declared_questions": manifest["declared_questions"],
            "answerable_questions": manifest["answerable_questions"],
            "abstention_questions": manifest["abstention_questions"], "excluded": manifest["excluded"]["count"],
            "excluded_sources": dict(manifest["excluded"]["sources"]), "unused": manifest["unused_count"],
            "strata": {name: entry["taken"] for name, entry in manifest["strata"].items()},
            "short_strata": list(manifest["short_strata"]), "manifest_sha256": qa.digest(render(manifest))}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--source", type=Path, default=source_path(), help="Pinned longmemeval_s_cleaned.json")
    parser.add_argument("--output", type=Path, default=MANIFEST_PATH, help="Committed manifest path")
    parser.add_argument("--force", action="store_true", help="Overwrite an existing manifest")
    parser.add_argument("--verify", action="store_true",
                        help="Recompute from --source and compare with --output; print counts and hashes only")
    args = parser.parse_args(argv)
    try:
        manifest = manifest_for(load_rows(args.source))
        report = {"mode": "verify" if args.verify else "generate", **summary(manifest)}
        if args.verify:
            committed_raw = qa.read_file(args.output)
            committed = load_manifest(args.output)
            report["committed_sha256"] = qa.digest(committed_raw)
            report["match"] = qa.canonical(committed) == qa.canonical(manifest) and committed_raw == render(manifest)
            print(json.dumps(report, sort_keys=True))
            return 0 if report["match"] else 1
        require(args.force or not args.output.exists(), "heldout_manifest_exists_use_force")
        args.output.write_bytes(render(manifest))
        print(json.dumps(report, sort_keys=True))
        return 0
    except (HeldoutError, qa.GradeError, e.EvaluationError) as error:
        print(json.dumps({"error": str(error)}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
