"""Frozen history-cluster estimands for retrieval and future paired comparisons."""
from __future__ import annotations

import math
import random
from collections import defaultdict
from statistics import mean


BOOTSTRAP_SEED = 104202604
BOOTSTRAP_RESAMPLES = 10000
PRIMARY_CATEGORIES = ("exact_historical_facts", "cross_session_temporal_updates",
                      "immediate_exact_followups", "scoped_instruction_lifecycle", "appropriate_abstention")


def _numeric(value, name: str, *, lower=None, upper=None):
    if type(value) not in (int, float):
        raise ValueError(f"{name} must be numeric, not boolean, text or unknown")
    try:
        finite = math.isfinite(value)
    except OverflowError:
        finite = False
    if not finite or (lower is not None and value < lower) or (upper is not None and value > upper):
        raise ValueError(f"{name} is non-finite or outside its declared range")
    return value


def _positive_integer(value, name: str):
    if type(value) is not int or value <= 0:
        raise ValueError(f"{name} must be a positive integer, not boolean or fractional")
    return value


def _bootstrap_parameters(resamples, seed):
    _positive_integer(resamples, "bootstrap resample count")
    if type(seed) is not int or seed < 0:
        raise ValueError("bootstrap seed must be a nonnegative integer, not boolean")


def percentile(values: list[float], fraction: float) -> float:
    if type(values) is not list or not values:
        raise ValueError("a percentile needs observations")
    _numeric(fraction, "percentile fraction", lower=0, upper=1)
    for value in values:
        _numeric(value, "percentile observation")
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def clustered_recall(rows: list[dict], metric: str, *, resamples: int = BOOTSTRAP_RESAMPLES,
                     seed: int = BOOTSTRAP_SEED) -> dict:
    """Equal categories; episodes within history; independent histories equal.

    Rows include only answerable byte-feasible cases. They are retrieval probes,
    not task scores and not provider-token feasibility evidence. Every resample
    uses one shared draw of history IDs across categories.
    """
    _bootstrap_parameters(resamples, seed)
    grouped: dict[str, dict[str, list[float]]] = defaultdict(lambda: defaultdict(list))
    for row in rows:
        grouped[row["historyID"]][row["category"]].append(float(_numeric(row[metric], "recall proportion", lower=0, upper=1)))
    histories = sorted(grouped)
    if not histories:
        return {"pointEstimate": None, "interval95": None, "independentHistories": 0,
                "categories": {}, "reason": "no eligible source-recall observations"}
    categories = sorted({category for history in grouped.values() for category in history})
    cells = {history: {category: mean(values) for category, values in categories_for_history.items()}
             for history, categories_for_history in grouped.items()}

    def estimate(draw: list[str], category: str | None = None) -> float:
        chosen = [category] if category is not None else categories
        return mean(mean(cells[history][key] for history in draw if key in cells[history]) for key in chosen)

    rng = random.Random(seed)
    distributions: dict[str | None, list[float]] = {key: [] for key in [None] + categories}
    for _ in range(resamples):
        draw = rng.choices(histories, k=len(histories))
        # A missing category in a resample makes its estimate undefined. It is
        # retained as an inconclusive interval, never silently discarded.
        for key in distributions:
            if all(any(cat in cells[history] for history in draw) for cat in ([key] if key else categories)):
                distributions[key].append(estimate(draw, key))
            else:
                distributions[key].append(float("nan"))

    def interval(key: str | None) -> list[float] | None:
        values = distributions[key]
        return None if any(math.isnan(value) for value in values) else [percentile(values, 0.025), percentile(values, 0.975)]

    return {"pointEstimate": estimate(histories), "interval95": interval(None),
            "independentHistories": len(histories), "bootstrapSeed": seed, "bootstrapResamples": resamples,
            "categories": {key: {"pointEstimate": estimate(histories, key), "interval95": interval(key),
                                  "independentHistories": sum(key in cells[history] for history in histories)}
                           for key in categories}}


def paired_score_interval(history_rows: list[dict], *, resamples: int = BOOTSTRAP_RESAMPLES,
                          seed: int = BOOTSTRAP_SEED) -> dict:
    """Future B/D macro-task difference after replicate-grid averaging.

    Each history row has B and D category scores. They must already average
    episodes and answering/build replicates within that independent history.
    """
    _bootstrap_parameters(resamples, seed)
    if not history_rows:
        raise ValueError("paired comparison needs independent histories")
    ids = [row["historyID"] for row in history_rows]
    if len(set(ids)) != len(ids):
        raise ValueError("replicates cannot be counted as independent histories")
    categories = set(PRIMARY_CATEGORIES)
    if any(not row["B"] or set(row["B"]) != set(row["D"]) or not set(row["B"]).issubset(categories) for row in history_rows):
        raise ValueError("each independent history needs paired category observations")
    for row in history_rows:
        for arm in ("B", "D"):
            for score in row[arm].values():
                _numeric(score, "category score", lower=0, upper=1)
    differences = [{category: row["D"][category] - row["B"][category] for category in row["B"]}
                   for row in history_rows]
    keys = sorted(categories)
    rng = random.Random(seed)
    intervals = {key: [] for key in ["overall"] + keys}
    for _ in range(resamples):
        draw = rng.choices(differences, k=len(differences))
        for key in keys:
            values = [row[key] for row in draw if key in row]
            intervals[key].append(mean(values) if values else float("nan"))
        values = [intervals[key][-1] for key in keys]
        intervals["overall"].append(mean(values) if all(math.isfinite(value) for value in values) else float("nan"))
    points = {key: (mean(row[key] for row in differences if key in row) if any(key in row for row in differences) else None) for key in keys}
    points["overall"] = mean(points.values()) if all(value is not None for value in points.values()) else None
    return {key: {"pointEstimate": points[key],
                  "interval95": None if any(math.isnan(value) for value in values) else [percentile(values, 0.025), percentile(values, 0.975)]}
            for key, values in intervals.items()}


def trajectory_cost_ratio(history_rows: list[dict], *, category_mix: dict[str, float],
                          shared_cost: dict[str, float], query_count: int,
                          resamples: int = BOOTSTRAP_RESAMPLES, seed: int = BOOTSTRAP_SEED) -> dict:
    """Paired D/B cost per success with each production build charged once.

    Each row gives each arm's per-category {successRate, marginalCost}. Build,
    ingestion, rebuild and allocated hosting cost belong in shared_cost once.
    Research replicate spend is a separate report. Missing cost must be rejected
    before this function, rather than coerced to zero.
    """
    _bootstrap_parameters(resamples, seed)
    _positive_integer(query_count, "trajectory query count")
    if type(category_mix) is not dict or not category_mix:
        raise ValueError("freeze a nonempty category mix")
    for weight in category_mix.values():
        _numeric(weight, "workload category weight", lower=0, upper=1)
    if not history_rows or not math.isclose(sum(category_mix.values()), 1.0):
        raise ValueError("freeze nonempty histories, positive query count and normalized category mix")
    if len({row["historyID"] for row in history_rows}) != len(history_rows):
        raise ValueError("cost rows must be independent paired histories")
    for arm in ("B", "D"):
        _numeric(shared_cost.get(arm), "shared production cost", lower=0)
        for row in history_rows:
            if set(row["B"]) != set(row["D"]) or not set(row[arm]).issubset(category_mix):
                raise ValueError("each history needs paired observations within the frozen workload categories")
            for values in row[arm].values():
                _numeric(values.get("successRate"), "success-rate proportion", lower=0, upper=1)
                _numeric(values.get("marginalCost"), "marginal answering cost", lower=0)
    if set().union(*(row["B"] for row in history_rows)) != set(category_mix):
        raise ValueError("the paired history population must cover all frozen workload categories")

    def ratio(draw: list[dict]) -> float | None:
        if any(not any(category in row["B"] for row in draw) for category in category_mix):
            return None
        costs = {}
        for arm in ("B", "D"):
            success = sum(weight * mean(row[arm][category]["successRate"] for row in draw if category in row[arm])
                          for category, weight in category_mix.items())
            cost = shared_cost[arm] + query_count * sum(weight * mean(row[arm][category]["marginalCost"] for row in draw if category in row[arm])
                                                       for category, weight in category_mix.items())
            costs[arm] = float("inf") if success == 0 else cost / (query_count * success)
        if math.isinf(costs["B"]):
            # Infinite/infinite and finite/infinite don't establish a useful
            # baseline comparison; retain an undefined ratio as inconclusive.
            return None
        if costs["B"] == 0:
            return None if costs["D"] == 0 else float("inf")
        return costs["D"] / costs["B"]

    rng = random.Random(seed)
    draws = [ratio(rng.choices(history_rows, k=len(history_rows))) for _ in range(resamples)]
    undefined = sum(value is None for value in draws)
    infinite = sum(value is not None and math.isinf(value) for value in draws)
    if undefined:
        bounds = None
    else:
        ordered = sorted(value for value in draws if value is not None)
        # Nearest-rank extended-real quantiles retain +infinity without inf-inf.
        bounds = [ordered[max(0, math.ceil(len(ordered) * p) - 1)] for p in (0.025, 0.975)]
    return {"pointEstimate": ratio(history_rows), "interval95": bounds,
            "undefinedResamples": undefined, "infiniteResamples": infinite,
            "decision": "inconclusive" if undefined else ("fails_cost_gate" if bounds and math.isinf(bounds[1]) else "requires_threshold_comparison")}


def minimum_power_histories(cluster_standard_deviation: float | None, margin: float,
                            minimum: int, *, power: float = 0.9) -> dict:
    """Individual lower-confidence-bound test; not joint quality-gate power.

    Paired per-history differences are the observations. A two-sided 95% lower
    bound and 90% power are frozen. ``margin`` is alternative minus the null
    boundary. For quality delta=.05 against zero, this estimates significance
    alone: a point estimate at least .05 has about 50% probability at that exact
    alternative. Missing pilot variance is inconclusive.
    """
    _numeric(margin, "alternative-minus-null margin", lower=0)
    _positive_integer(minimum, "minimum independent history count")
    _numeric(power, "target power", lower=0, upper=1)
    if margin == 0 or not 0.5 < power < 1:
        raise ValueError("invalid effect-minus-null gap, minimum or target power")
    if cluster_standard_deviation is None:
        return {"requiredHistories": None, "minimumHistories": minimum, "status": "pilot_variance_pending"}
    _numeric(cluster_standard_deviation, "paired cluster standard deviation", lower=0)
    from statistics import NormalDist
    z = NormalDist().inv_cdf(0.975) + NormalDist().inv_cdf(power)
    count = max(minimum, math.ceil((z * cluster_standard_deviation / margin) ** 2))
    return {"requiredHistories": count, "minimumHistories": minimum,
            "test": "individual_lower_bound_test_only",
            "status": "approximation_requires_cluster_simulation_confirmation"}


def quality_joint_power_histories(cluster_standard_deviation: float | None,
                                 assumed_true_difference: float | None, minimum: int = 200,
                                 *, power: float = 0.9) -> dict:
    """Conservative normal planning bound for point>=.05 AND lower95>0.

    Allocate half the target failure probability to each condition. Full paired
    cluster simulation of every conjunctive gate remains necessary.
    """
    _positive_integer(minimum, "minimum independent history count")
    _numeric(power, "target joint power", lower=0, upper=1)
    if not 0.5 < power < 1:
        raise ValueError("target joint power must be strictly between 0.5 and 1")
    if assumed_true_difference is not None:
        _numeric(assumed_true_difference, "assumed true score difference", lower=-1, upper=1)
    if cluster_standard_deviation is not None:
        _numeric(cluster_standard_deviation, "paired cluster standard deviation", lower=0)
    if assumed_true_difference is None or cluster_standard_deviation is None:
        return {"requiredHistories": None, "status": "paired_pilot_variance_and_alternative_pending"}
    if assumed_true_difference <= 0.05:
        return {"requiredHistories": None, "status": "joint_gate_power_requires_alternative_above_point_threshold"}
    from statistics import NormalDist
    z_each = NormalDist().inv_cdf(1 - (1 - power) / 2)
    significance = ((NormalDist().inv_cdf(0.975) + z_each) * cluster_standard_deviation / assumed_true_difference) ** 2
    point = (z_each * cluster_standard_deviation / (assumed_true_difference - 0.05)) ** 2
    return {"requiredHistories": max(minimum, math.ceil(significance), math.ceil(point)),
            "assumedTrueDifference": assumed_true_difference, "targetJointPower": power,
            "status": "normal_union_bound_requires_all_gate_cluster_simulation"}


def tree_gate_decision(evidence: dict) -> dict:
    """Apply every conjunctive section-13 gate; absent evidence is inconclusive.

    Inputs are completed, paired held-out aggregate evidence. This helper is
    contract groundwork; a caller still must prove the manifests and raw data.
    """
    allowed = {"primaryMode", "allApplicableInvariantsPassed", "minimumHistoriesAndPowerSatisfied",
               "eachReplicateBuildFeasibleRecall", "declared100kWarmEndpointP95Milliseconds", "pairedTaskScore",
               "targetCostPerSuccessRatio95Upper", "criticalCategoryDifference95Lower", "worstReplicateProfiles"}
    if type(evidence) is not dict or not set(evidence).issubset(allowed):
        raise ValueError("unexpected tree-decision evidence fields")
    mode = evidence.get("primaryMode", "quality-first")
    if mode not in ("quality-first", "cost-first"):
        raise ValueError("freeze one valid primary mode before held-out evaluation")
    gates: dict[str, bool | None] = {}
    for field, name in (("allApplicableInvariantsPassed", "applicable_invariants"),
                        ("minimumHistoriesAndPowerSatisfied", "sample_size_and_power")):
        value = evidence.get(field)
        if value is not None and type(value) is not bool:
            raise ValueError("invariant and sample/power evidence must be strict booleans or unknown")
        gates[name] = value

    def number(value, *, lower=None, upper=None, allow_infinite=False):
        if value is None:
            return None
        if allow_infinite and type(value) is float and value == float("inf"):
            return value
        return _numeric(value, "tree-decision numeric evidence", lower=lower, upper=upper)

    def combined(conditions):
        return False if any(value is False for value in conditions) else (None if any(value is None for value in conditions) else True)

    retrieval = evidence.get("eachReplicateBuildFeasibleRecall")
    if retrieval is not None and type(retrieval) is not list:
        raise ValueError("replicate/build recall must be a list")
    retrieval = [number(value, lower=0, upper=1) for value in retrieval] if retrieval else []
    gates["finite_suite_recall"] = combined([None if value is None else value >= 0.95 for value in retrieval]) if retrieval else None
    endpoint = number(evidence.get("declared100kWarmEndpointP95Milliseconds"), lower=0)
    gates["100k_endpoint"] = None if endpoint is None else endpoint < 1000
    score = evidence.get("pairedTaskScore")
    if score is not None and (type(score) is not dict or not set(score).issubset({"point", "lower95"})):
        raise ValueError("paired score needs declared point/lower95 fields")
    point = number(score.get("point"), lower=-1, upper=1) if score else None
    lower = number(score.get("lower95"), lower=-1, upper=1) if score else None
    cost = number(evidence.get("targetCostPerSuccessRatio95Upper"), lower=0, allow_infinite=True)
    if mode == "quality-first":
        gates["primary_benefit"] = combined([None if point is None else point >= 0.05, None if lower is None else lower > 0])
    else:
        gates["primary_benefit"] = combined([None if lower is None else lower > -0.02, None if cost is None else cost <= 0.8])
    critical = evidence.get("criticalCategoryDifference95Lower", {})
    if type(critical) is not dict or not set(critical).issubset(PRIMARY_CATEGORIES):
        raise ValueError("unknown critical category evidence")
    for category in ("immediate_exact_followups", "scoped_instruction_lifecycle", "appropriate_abstention"):
        bound = number(critical.get(category), lower=-1, upper=1)
        gates[category + "_regression"] = None if bound is None else bound > -0.02
    gates["cost_envelope"] = None if cost is None else cost <= 1.25
    profiles = evidence.get("worstReplicateProfiles", {})
    if type(profiles) is not dict or not set(profiles).issubset({"warm", "cold_restart", "paused"}):
        raise ValueError("unknown latency profile evidence")
    for profile in ("warm", "cold_restart", "paused"):
        observation = profiles.get(profile)
        if observation is not None and (type(observation) is not dict or not set(observation).issubset({"addedMemoryPathP95Milliseconds", "fullEpisodeP95Ratio"})):
            raise ValueError("latency profile needs declared memory delta and episode ratio")
        delta = number(observation.get("addedMemoryPathP95Milliseconds")) if observation else None
        ratio = number(observation.get("fullEpisodeP95Ratio"), lower=0) if observation else None
        gates[profile + "_interaction"] = combined([None if delta is None else delta <= 500, None if ratio is None else ratio <= 1.1])
    outcome = "fails" if any(value is False for value in gates.values()) else (
        "inconclusive" if any(value is None for value in gates.values()) else "passes")
    return {"primaryMode": mode, "gates": gates, "outcome": outcome}
