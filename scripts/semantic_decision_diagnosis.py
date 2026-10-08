#!/usr/bin/env python3
"""P2 step 4 diagnosis from a retrieval harness report (metadata only).

Explains, per case, why semantic fusion displaces lexical primaries, checks the
global arms against the shipped and lexical arms, and measures the semantic
sidecar's coverage of annotated positive turns. Annotations are read here, in
the scorer, never by the selection process. Output contains question IDs,
opaque event IDs, ranks, counts and byte totals; no source text, questions or
answers. Usage:

  python3 scripts/semantic_decision_diagnosis.py --cohort regression \
      --report .build/evaluation/x.json --output .build/evaluation/x-diagnosis.json
"""
from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import sqlite3
import statistics
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import retrieval_harness as harness  # noqa: E402

DEPTH = harness.DECLARED_CANDIDATE_DEPTH


def whole(arm_score):
    return arm_score["failure"] is None and arm_score["whole"] == arm_score["positives"]


def primary_list(diagnostic):
    semantic = (diagnostic or {}).get("semantic") or {}
    return [item["e"] for item in semantic.get("primaries") or [] if item.get("d") != "excluded_primary"]


def neighbor_anchor(diagnostic, event_id):
    for item in ((diagnostic or {}).get("semantic") or {}).get("expansion") or []:
        if item.get("n") == event_id and item.get("d") in ("included_prefix", "promoted_primary", "covered_neighbor_prefix"):
            return item.get("a")
    return None


def trace_ids(diagnostic):
    return [item[0] for item in (diagnostic or {}).get("candidates") or []]


def semantic_paths(diagnostic, arm):
    """Event ID -> (fused rank, paths) of the shipped semantic stage, replayed
    from the hybrid attempt's sidecar manifest. Global arms keep only timing
    and identity in their audit, so they map to an empty result here."""
    semantic = (diagnostic or {}).get("semantic") or {}
    if arm != "hybrid":
        return {}
    results = semantic.get("shipped_results") or []
    return {item["e"]: (position + 1, item["p"]) for position, item in enumerate(results)}


def slot_use(diagnostic, arm):
    """How the traced candidate slots divide among primary origins."""
    paths = semantic_paths(diagnostic, arm)
    counts = Counter()
    expansion = {item.get("n"): item.get("a") for item in ((diagnostic or {}).get("semantic") or {}).get("expansion") or []
                 if item.get("d") in ("included_prefix", "promoted_primary")}
    for event_id in trace_ids(diagnostic)[:DEPTH]:
        if event_id in paths:
            counts["primary:" + paths[event_id][1]] += 1
        elif event_id in expansion and expansion[event_id] in paths:
            counts["neighbor_of:" + paths[expansion[event_id]][1]] += 1
        else:
            counts["other"] += 1
    return counts


def lost_turns(case_row, positives, winner, loser):
    """Positive turns the winning arm delivers whole and the losing arm does not."""
    rows = []
    diagnostics = case_row.get("diagnostics") or {}
    win, lose = diagnostics.get(winner), diagnostics.get(loser)
    wscore, lscore = case_row["arms"][winner]["turns"], case_row["arms"][loser]["turns"]
    win_primaries, lose_primaries = primary_list(win), primary_list(lose)
    lose_paths = semantic_paths(lose, loser) if loser != "lexical" else {}
    for position, event_id in enumerate(positives):
        if not (wscore[position]["whole"] and not lscore[position]["whole"]):
            continue
        anchor = event_id if event_id in win_primaries else neighbor_anchor(win, event_id)
        entry = {"event_id": event_id, "winner_trace_rank": wscore[position]["candidate_rank"],
                 "winner_origin": "primary" if anchor == event_id else ("neighbor" if anchor else "unknown"),
                 "winner_primary_rank": win_primaries.index(anchor) + 1 if anchor in win_primaries else None}
        if loser != "lexical":
            entry["loser_fused_rank_of_anchor"] = lose_paths.get(anchor, (None, None))[0]
            entry["loser_anchor_in_primaries"] = anchor in lose_primaries
            entry["loser_anchor_candidate_limit"] = any(item.get("a") == anchor and item.get("d") == "candidate_limit"
                for item in ((lose or {}).get("semantic") or {}).get("expansion") or [])
            # Semantic-only primaries ranked ahead of the lexical anchor in fusion.
            ahead = [e for e, (rank, path) in lose_paths.items()
                     if path == "semantic" and (lose_paths.get(anchor, (99, None))[0] or 99) > rank]
            entry["semantic_only_primaries_ahead"] = len(ahead)
            entry["loser_slots"] = dict(slot_use(lose, loser))
        rows.append(entry)
    return rows


def found_turns(case_row, positives, winner, loser):
    """For cases only the semantic arm passes: how its winning turns arrived."""
    diagnostics = case_row.get("diagnostics") or {}
    win = diagnostics.get(winner)
    paths = semantic_paths(win, winner)
    primaries = primary_list(win)
    rows = []
    for position, event_id in enumerate(positives):
        if not (case_row["arms"][winner]["turns"][position]["whole"] and not case_row["arms"][loser]["turns"][position]["whole"]):
            continue
        anchor = event_id if event_id in primaries else neighbor_anchor(win, event_id)
        rows.append({"event_id": event_id, "origin": "primary" if anchor == event_id else ("neighbor" if anchor else "unknown"),
                     "anchor_fused_rank": paths.get(anchor, (None, None))[0], "anchor_paths": paths.get(anchor, (None, None))[1]})
    return rows


def coverage(store_root, ingestion, case):
    """Semantic sidecar coverage by role and of the annotated positive turns."""
    key = harness.digest(harness.canonical([ingestion, case["projection_sha256"]]))
    path = store_root / key / "baseline" / "semantic" / "index.sqlite3"
    if not path.exists():
        return None
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        role = {}
        for event_id, value in connection.execute("SELECT event_id, CAST(source AS TEXT) FROM jobs"):
            role[event_id] = json.loads(value)["role"]
        totals = Counter()
        per_event = {}
        for event_id, reason, size in connection.execute("SELECT event_id, reason, byte_count FROM chunks"):
            bucket = "vector" if reason == "" else reason
            totals[(role.get(event_id, "unknown"), bucket, "bytes")] += size
            totals[(role.get(event_id, "unknown"), bucket, "chunks")] += 1
            per_event.setdefault(event_id, Counter())[bucket] += size
    finally:
        connection.close()
    positives = []
    for event_id in case["positives"]:
        counts = per_event.get(event_id, Counter())
        size = case["sizes"][event_id]
        positives.append({"event_id": event_id, "bytes": size, "vector_bytes": counts.get("vector", 0),
                          "any_vector": counts.get("vector", 0) > 0,
                          "unsupported_reasons": sorted(k for k in counts if k != "vector")})
    return {"totals": {"|".join(k): v for k, v in totals.items()}, "positives": positives}


def sidecar_events(store_root, ingestion, case):
    """Event ID -> (role, bytes with a vector) from the case's cached sidecar."""
    key = harness.digest(harness.canonical([ingestion, case["projection_sha256"]]))
    path = store_root / key / "baseline" / "semantic" / "index.sqlite3"
    if not path.exists():
        return None
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        events = {event_id: [json.loads(value)["role"], 0] for event_id, value in connection.execute(
            "SELECT event_id, CAST(source AS TEXT) FROM jobs")}
        for event_id, size in connection.execute("SELECT event_id, byte_count FROM chunks WHERE reason=''"):
            if event_id in events:
                events[event_id][1] += size
    finally:
        connection.close()
    return events


def displacement(rows, by_id, store_root, ingestion):
    """Which lexical primaries the shipped fusion drops, and what takes their place.

    Level "fused": the shipped semantic stage's 16 results against lexical
    primaries 1-16. Level "traced": lexical primaries in the 16 traced slots
    after exchange expansion, lexical arm against hybrid arm."""
    totals = Counter()
    for row in rows:
        diagnostics = row.get("diagnostics") or {}
        lexical, fused = diagnostics.get("lexical"), diagnostics.get("hybrid")
        results = ((fused or {}).get("semantic") or {}).get("shipped_results")
        events = sidecar_events(store_root, ingestion, by_id[row["question_id"]])
        if not lexical or not results or events is None or not trace_ids(fused) or not trace_ids(lexical):
            totals["skipped"] += 1
            continue
        top = primary_list(lexical)[:DEPTH]
        chosen = {item["e"] for item in results}
        for event_id in top:
            role, vector = events.get(event_id, ["unknown", 0])
            kind = f"{role}_{'vector' if vector else 'no_vector'}"
            totals["lexical_top16:" + kind] += 1
            if event_id not in chosen:
                totals["fused_dropped:" + kind] += 1
        for item in results:
            role, vector = events.get(item["e"], ["unknown", 0])
            if item["p"] == "semantic":
                totals["fused_entrant:semantic_only"] += 1
            elif item["e"] not in top:
                totals["fused_entrant:lexical_rank_17_100_" + ("vector" if vector else "no_vector")] += 1
        lexical_traced = [e for e in trace_ids(lexical)[:DEPTH] if e in set(top)]
        fused_traced = set(trace_ids(fused)[:DEPTH])
        for event_id in lexical_traced:
            role, vector = events.get(event_id, ["unknown", 0])
            kind = f"{role}_{'vector' if vector else 'no_vector'}"
            totals["traced_lexical_primary:" + kind] += 1
            if event_id not in fused_traced:
                totals["traced_dropped:" + kind] += 1
    return dict(sorted(totals.items()))


def summarize_coverage(items):
    totals = Counter()
    for item in items:
        if item:
            totals.update(item["totals"])
    def share(role):
        all_bytes = sum(v for k, v in totals.items() if k.startswith(role + "|") and k.endswith("|bytes"))
        vec = totals.get(f"{role}|vector|bytes", 0)
        reasons = {k.split("|")[1]: v for k, v in totals.items() if k.startswith(role + "|") and k.endswith("|bytes")}
        return {"bytes": all_bytes, "vector_bytes": vec, "vector_fraction": round(vec / all_bytes, 4) if all_bytes else None,
                "bytes_by_reason": reasons,
                "chunks_by_reason": {k.split("|")[1]: v for k, v in totals.items() if k.startswith(role + "|") and k.endswith("|chunks")}}
    positives = [p for item in items if item for p in item["positives"]]
    return {"human": share("human"), "assistant": share("assistant"),
            "positive_turns": len(positives), "positive_turns_with_any_vector": sum(p["any_vector"] for p in positives),
            "positive_bytes": sum(p["bytes"] for p in positives), "positive_vector_bytes": sum(p["vector_bytes"] for p in positives),
            "positive_unsupported_reasons": dict(Counter(r for p in positives for r in p["unsupported_reasons"]))}


def same_selection(a, b):
    return bool(a) and bool(b) and a.get("candidates") == b.get("candidates") and a.get("evidence") == b.get("evidence")


def same_evidence(a, b):
    return bool(a) and bool(b) and sorted(map(tuple, a.get("evidence") or [])) == sorted(map(tuple, b.get("evidence") or []))


def evidence_superset(smaller, larger):
    return bool(smaller) and bool(larger) and set(map(tuple, smaller.get("evidence") or [])) <= set(map(tuple, larger.get("evidence") or []))


def is_prefix(prefix, full):
    p, f = trace_ids(prefix), trace_ids(full)
    return bool(prefix) and bool(full) and f[:len(p)] == p


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--cohort", choices=("development", "regression"), required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source", type=Path, default=None)
    args = parser.parse_args()
    report = json.loads(args.report.read_bytes())
    cases, cohort, _configuration = harness.load_cohort(args.cohort, args.source or harness.default_source())
    harness.require(cohort["manifest_sha256"] == report["cohort"]["manifest_sha256"], "cohort_mismatch")
    by_id = {case["question_id"]: case for case in cases}
    rows = report["cases"]
    eligible = [row for row in rows if row["feasibility"] == "feasible"]
    store_root = ROOT / ".build/retrieval-harness/stores"
    ingestion = report["implementation"]["ingestion_sha256"]
    result = {"report": str(args.report.name), "cohort": cohort["cohort"], "implementation": report["implementation"],
              "lexical_wins_over": {}, "semantic_wins_over_lexical": {}, "slot_use": {}, "fusion_detail": {}}
    for arm in ("hybrid", "global_hybrid", "global_fill"):
        if arm not in rows[0]["arms"]:
            continue
        losses, wins = [], []
        for row in eligible:
            positives = by_id[row["question_id"]]["positives"]
            if whole(row["arms"]["lexical"]) and not whole(row["arms"][arm]):
                losses.append({"question_id": row["question_id"], "question_type": row["question_type"],
                               "turns": lost_turns(row, positives, "lexical", arm)})
            if whole(row["arms"][arm]) and not whole(row["arms"]["lexical"]):
                wins.append({"question_id": row["question_id"], "question_type": row["question_type"],
                             "turns": found_turns(row, positives, arm, "lexical")})
        result["lexical_wins_over"][arm] = losses
        result["semantic_wins_over_lexical"][arm] = wins
        if arm != "hybrid":
            continue
        slots = Counter()
        semantic_only_primaries, results_seen = [], 0
        for row in eligible:
            diagnostic = (row.get("diagnostics") or {}).get(arm)
            slots.update(slot_use(diagnostic, arm))
            paths = semantic_paths(diagnostic, arm)
            if paths:
                results_seen += 1
                semantic_only_primaries.append(sum(1 for _, path in paths.values() if path == "semantic"))
        result["slot_use"][arm] = {"attempts": len(eligible), "traced_slots": dict(slots)}
        result["fusion_detail"][arm] = {"attempts_with_semantic_results": results_seen,
            "semantic_only_results_per_attempt_mean": round(statistics.mean(semantic_only_primaries), 2) if semantic_only_primaries else None,
            "semantic_only_results_per_attempt_median": statistics.median(semantic_only_primaries) if semantic_only_primaries else None}
    lexical_primaries = [len(primary_list((row.get("diagnostics") or {}).get("lexical"))) for row in eligible]
    lexical_retained = [sum(1 for e in trace_ids((row.get("diagnostics") or {}).get("lexical"))[:DEPTH]
                            if e in primary_list((row.get("diagnostics") or {}).get("lexical"))) for row in eligible]
    result["lexical_primary_counts"] = {"primaries_returned": dict(Counter(lexical_primaries)),
                                        "primaries_in_traced_slots": dict(Counter(lexical_retained))}
    if "global_hybrid" in rows[0]["arms"]:
        result["global_hybrid_equals_hybrid"] = {
            "identical_selection": sum(same_selection((r.get("diagnostics") or {}).get("hybrid"), (r.get("diagnostics") or {}).get("global_hybrid")) for r in rows),
            "identical_evidence": sum(same_evidence((r.get("diagnostics") or {}).get("hybrid"), (r.get("diagnostics") or {}).get("global_hybrid")) for r in rows),
            "cases": len(rows),
            "shipped_vector_continuation": sum(bool((((r.get("diagnostics") or {}).get("hybrid") or {}).get("semantic") or {}).get("vector_continuation_available")) for r in rows),
            "shipped_vector_rows_max": max(((((r.get("diagnostics") or {}).get("hybrid") or {}).get("semantic") or {}).get("vector_candidates_inspected") or 0) for r in rows)}
    if "global_fill" in rows[0]["arms"]:
        result["global_fill_extends_lexical"] = {
            "lexical_trace_is_prefix": sum(is_prefix((r.get("diagnostics") or {}).get("lexical"), (r.get("diagnostics") or {}).get("global_fill")) for r in rows),
            "identical_selection": sum(same_selection((r.get("diagnostics") or {}).get("lexical"), (r.get("diagnostics") or {}).get("global_fill")) for r in rows),
            "lexical_evidence_contained": sum(evidence_superset((r.get("diagnostics") or {}).get("lexical"), (r.get("diagnostics") or {}).get("global_fill")) for r in rows),
            "cases": len(rows)}
    result["displacement_hybrid"] = displacement(eligible, by_id, store_root, ingestion)
    # Role and vector coverage of the lexical anchor behind each lost turn.
    for arm, losses in result["lexical_wins_over"].items():
        for loss in losses:
            events = sidecar_events(store_root, ingestion, by_id[loss["question_id"]]) or {}
            row = next(r for r in rows if r["question_id"] == loss["question_id"])
            lexical = (row.get("diagnostics") or {}).get("lexical")
            for turn in loss["turns"]:
                anchor = turn["event_id"] if turn["winner_origin"] == "primary" else neighbor_anchor(lexical, turn["event_id"])
                role, vector = events.get(anchor, ["unknown", 0])
                turn["anchor_role"] = role
                turn["anchor_has_vector"] = vector > 0
    per_case = [coverage(store_root, ingestion, by_id[row["question_id"]]) for row in eligible]
    result["coverage"] = summarize_coverage(per_case)
    result["known_misses"] = {}
    for row in rows:
        if row["question_id"] in harness.KNOWN_MISSES:
            positives = by_id[row["question_id"]]["positives"]
            item = coverage(store_root, ingestion, by_id[row["question_id"]])
            detail = {"question_type": row["question_type"], "coverage": item["positives"] if item else None, "arms": {}}
            for arm, score in row["arms"].items():
                if arm == "recent_only":
                    continue
                diagnostic = (row.get("diagnostics") or {}).get(arm)
                primaries = primary_list(diagnostic)
                paths = semantic_paths(diagnostic, arm) if arm != "lexical" else {}
                detail["arms"][arm] = [{"whole": t["whole"], "trace_rank": t["candidate_rank"],
                    "primary_rank": primaries.index(e) + 1 if e in primaries else None,
                    "fused_rank": paths.get(e, (None, None))[0], "paths": paths.get(e, (None, None))[1]}
                    for e, t in zip(positives, score["turns"])]
            result["known_misses"][row["question_id"]] = detail
    harness.private_write(args.output.absolute(), harness.canonical(result) + b"\n")
    printable = {"cohort": result["cohort"], "losses": {k: len(v) for k, v in result["lexical_wins_over"].items()},
                 "wins": {k: len(v) for k, v in result["semantic_wins_over_lexical"].items()},
                 "slot_use": result["slot_use"], "fusion_detail": result["fusion_detail"],
                 "lexical_primary_counts": result["lexical_primary_counts"],
                 "global_hybrid_equals_hybrid": result.get("global_hybrid_equals_hybrid"),
                 "global_fill_extends_lexical": result.get("global_fill_extends_lexical"),
                 "displacement_hybrid": result.get("displacement_hybrid"),
                 "lost_turn_anchors": {arm: dict(Counter(f"{t['winner_origin']}:{t.get('anchor_role')}:{'vector' if t.get('anchor_has_vector') else 'no_vector'}"
                                                        for loss in losses for t in loss["turns"]))
                                       for arm, losses in result["lexical_wins_over"].items()},
                 "coverage": {k: v for k, v in result["coverage"].items()}}
    print(json.dumps(printable, sort_keys=True, indent=1))
    print("Metadata-only diagnosis: " + str(args.output))


if __name__ == "__main__":
    main()
