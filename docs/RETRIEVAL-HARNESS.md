# Offline retrieval harness (P1)

Recorded October 8, 2026. This is work package P1 of the [design repair plan](DESIGN-REPAIR-PLAN.md). It measures two stages only: R1 candidate recall and R2 delivered recall for the ordinary selected-Qwen path. No answers were generated, no judge ran, and no remote or paid request was made. Nothing here measures answer quality.

## What runs

`scripts/retrieval_harness.py` drives `Tests/Evaluation/DeliveryHarness.swift`. The harness binary is compiled from every application source except the app entry point (`BonsaiPlayground.swift`). Each attempt runs the shared `AnswerAttemptCoordinator`, the same lifecycle as ordinary GUI Send, with the frozen `ContextComponentPolicy.currentSelectedQwen` (v1/16) and the cohort's own answering configuration (32,768-token context, 1,024 output, 256 safety, thinking off).

- **Token counts.** The coordinator talks to a loopback stand-in for mlx-serve 26.10.1. It serves the pinned model metadata and template, and answers `/tokenize` and the one-token admission calibration from the selected model's own `tokenizer.json`, pinned by SHA-256 `0997f410c57a1f4e53b09e4be8f4a172d90edd9564368fb0847030937229b9f3`. It refuses every generation request with HTTP 503.
- **No generation.** The harness stops each attempt when the coordinator reaches the answering stage, which is the GUI Stop path, so the runner never starts. An injected runner that refuses dispatch is a second fence. Both recorded runs report zero refused generation requests and zero runner starts.
- **Arms.** `recent_only` is the recent-only strategy. `lexical` is the hybrid strategy with no semantic index. `hybrid` is the hybrid strategy with the history's semantic index, as ordinary Send uses it.
- **Answer blindness.** The selection process receives events, the question and the configuration. It never receives annotations. A separate process runs the existing declared-source control with the annotated turn IDs to decide budget feasibility.
- **Stores.** Each history is ingested once, with its semantic sidecar, into `.build/retrieval-harness/stores/`, keyed by the projection hash and the hashes of the store and indexing sources. Every attempt runs on a private copy. Retrieval and packing changes reuse the cache; changes to store or indexing code rebuild it.
- **Outputs.** Reports are metadata only: question IDs, categories, counts, ranks, token counts and timings. They contain no source text, questions or answers and stay under `.build/evaluation`.

## Definitions

These follow the plan's case-level gates. The candidate depth was declared in the code before the first measurement.

| Term | Definition |
|---|---|
| R1 | Every annotated positive turn is delivered, in recent context, or among the first 16 ranked candidates traced by the assembler before span and token limits |
| R2 | Every annotated positive turn is delivered whole, meaning the union of delivered byte ranges covers the source, after component token fitting and admission |
| Feasible | The declared-source control delivers every positive turn whole with no evidence exclusions under the same caps |
| Denominator | Answerable cases minus infeasible ones. Preparation and control failures stay in it. Abstention cases are excluded |

At v1/16 the traced candidate list and the evidence span cap are both 16. R1 at depth 16 can therefore differ from R2 only when token fitting or admission removes a candidate. A deeper R1 needs a wider retrieval call, which is P2 step 3.

## Cohorts and provenance

| Cohort | Identity | Cases | Answerable | Positive turns |
|---|---|---:|---:|---:|
| Development | Frozen [native-investigation-100-v1](NATIVE-INVESTIGATION-100.md) selection, rebuilt from the pinned LongMemEval S file. The harness recomputes the selection manifest including its artifact digests and requires SHA-256 `2e310e440a7aca2fa24b8474b6afe1f2115a654851b37f8948acef995649f8ae` | 100 | 90 | 165 |
| Regression | The fourteen-history [independent cohort](INDEPENDENT-LONGMEMEVAL.md), rebuilt by its case module with its native projection pins verified | 14 | 12 | 18 |

Source: LongMemEval S cleaned, revision `98d7416c24c778c2fee6e6f3006e7a073259d48f`, SHA-256 `d6f21ea9d60a0d56f34a05b609c79c88a451d2ae03597821ea3d5a9678c3a442`. All 90 and all 12 answerable cases were budget-feasible.

## Token parity

mlx-serve 26.10.1 does not apply the NFC normalizer that `tokenizer.json` declares: decomposed combining marks stay separate tokens on the server and are composed offline. The first smoke run caught this on the synthetic calibration probe, as a one-token difference. The harness now removes the normalizer to match the server. Each run then sends a deterministic sample of the exact strings it counted (the smallest content digests) to the live `/tokenize` endpoint. Tokenizing makes no generation call.

| Run | Strings checked | Equal counts | Identical token IDs |
|---|---:|---:|---:|
| Regression | 117 | 117 | 117 |
| Development | 256 | 256 | 255 |

The one development string with different IDs has the same count; the two tokenizers split one lowercase ASCII run differently. Counts are what admission uses.

## Validation against earlier records

On the regression cohort the harness reproduces the earlier end-to-end delivery result exactly: hybrid delivers 14 of 18 positive turns and 8 of 12 cases, and the same four cases miss (`51c32626`, `1b9b7252`, `4baee567`, `1a1907b4`). That number previously came from running answer attempts through the local model; here it costs no generation.

## Baseline result

Implementation: commit `cbb189d` with a clean tree, harness binary SHA-256 `759bafd90127d892f7b1a74eebce9aea2df84ed04bf3a15d4e5557b9f7eb176a`. One replicate; a second run from the cached stores reproduced every number. Private reports: `.build/evaluation/retrieval-harness-{development,regression}-20261008.json`.

### Development cohort, 90 answerable cases

| Arm | R1 | R2 | Positive turns delivered whole |
|---|---:|---:|---:|
| recent_only | 0/90 | 0/90 | 2/165 |
| lexical | 60/90 (66.7%) | 60/90 (66.7%) | 119/165 (72.1%) |
| hybrid (ordinary Send) | 50/90 (55.6%) | 50/90 (55.6%) | 114/165 (69.1%) |

R2 by category:

| Category | Cases | lexical | hybrid |
|---|---:|---:|---:|
| Knowledge update | 14 | 11 | 10 |
| Multi-session | 23 | 9 | 8 |
| Assistant recall | 11 | 11 | 6 |
| Preference | 5 | 3 | 2 |
| User recall | 12 | 12 | 11 |
| Temporal reasoning | 25 | 14 | 13 |

### Regression cohort, 12 answerable cases

| Arm | R1 | R2 | Positive turns delivered whole |
|---|---:|---:|---:|
| recent_only | 0/12 | 0/12 | 0/18 |
| lexical | 9/12 | 9/12 | 15/18 |
| hybrid (ordinary Send) | 8/12 | 8/12 | 14/18 |

Known misses under hybrid: `1b9b7252`, `4baee567` and `1a1907b4` have their single positive turn outside the 16 candidates in both lexical and hybrid. `51c32626` has two positives. Lexical ranks them 0 and 9 and delivers both; hybrid delivers the first and loses the second from the candidate list.

### Cost of the measurement

| Measure | Development | Regression |
|---|---:|---:|
| Wall time, 4 workers, cold / warm store cache | 840 / 340 s | 103 / 48 s |
| Semantic index build per history, p50 | 19.2 s | 17.1 s |
| Hybrid preparation p50 / p95 | 2.69 / 3.91 s | 2.32 / 2.78 s |
| Lexical preparation p50 / p95 | 0.61 / 1.45 s | 0.55 / 0.61 s |
| Hybrid whole-prompt tokens p50 / p95 | 15,446 / 17,712 | 13,742 / 16,821 |

Preparation times include loopback tokenizer calls and these histories are about 500 events each, so they are not an L1 latency measurement.

## What the baseline shows

1. **Every miss is a ranking miss.** R1 equals R2 in every arm on both cohorts. Evidence token, envelope, byte and row exclusions are zero in all 228 lexical and hybrid attempts, and no positive turn was a candidate without being delivered. The largest whole prompt is 18,542 of the 31,488 admissible tokens. At v1/16 the packer is not where recall is lost; the candidate list is. Cost-aware packing (P2 step 3) only matters once the window is wider.
2. **Semantic fusion lowers recall on this path.** Hybrid wins 5 development cases that lexical misses, and loses 15 that lexical finds. The largest loss is assistant recall, 6 of 11 against 11 of 11. This is the question P2 step 4 poses, measured before any change: fusion, as configured, displaces lexical primaries from the 16 slots.
3. **Multi-session and temporal questions are the weak categories** for both arms: 8 to 9 of 23, and 13 to 14 of 25. These need several turns delivered together, and a single missing turn fails the case.
4. **The plan's R2 interim target is 90 percent.** The ordinary path is at 55.6 percent and lexical alone at 66.7 percent.

## Running it

The pinned source file is read from `.build/datasets/` in this checkout or the repository's primary checkout. The tokenizer defaults to the mlx-serve model directory. A model server is needed only for the optional parity check, which makes no generation calls.

```bash
python3 scripts/retrieval_harness.py --cohort development --output .build/evaluation/retrieval-harness-development.json --live-tokenizer http://localhost:11234
```

`--cohort regression` runs the fourteen-history set in under two minutes with a warm cache. `--rebuild-stores` discards the store cache. `scripts/test_retrieval_harness.py` holds 12 synthetic contracts for the scorer, feasibility, denominators, the stand-in endpoint and failure output, and runs in `scripts/check.py`.

## Recall floor in check.py

Implemented October 8, 2026. `scripts/retrieval_floor.py` runs `--cohort regression` with three workers into a temporary report under `.build/`, then compares each arm's case-level R1 and R2 and turn-level counts with the committed numbers in `scripts/retrieval_floor.json`: the cohort manifest hash, the denominators, and per arm the minimum passed cases and turns (hybrid 8/12 cases and 14/18 turns, lexical 9/12 and 15/18, recent-only 0). A lower count, a missing arm, a changed manifest hash or a changed denominator fails `scripts/check.py`. An arm present in a run but absent from the floor is reported and does not fail. `--update` rewrites the floor from a run and refuses to lower any number without `--allow-lower`.

The floor needs the pinned dataset and the pinned tokenizer, neither of which is committed. When either is missing, or the `tokenizers` package is absent, the script prints one skip reason and exits 0 with zero checks, and `check.py` prints the skip as a skip, not a pass. 22 synthetic contracts in `scripts/test_retrieval_floor.py` cover the comparison and skip logic without the dataset or tokenizer. Measured October 8, 2026 with a warm store cache and a cached harness binary: about 60 to 75 seconds added to `check.py` (a cold store cache needs about 100 seconds at four workers plus the first Swift compile of the harness, about 225 seconds in total on the first run in a fresh checkout). The check contributes 19 comparisons. The floor guards the regression cohort only; the development cohort takes minutes and is not part of `check.py`.

- One replicate per build. Selection is deterministic, so replicates matter for model-involved stages, not this one.
- LongMemEval positive-turn annotations are a proxy for sufficient source spans. `1a1907b4` was previously accepted without its annotated turn.
- R1 at depth 16 cannot separate from R2 at v1/16, as explained above.
- Cached stores carry the ingestion and indexing timings of the run that built them.
- The parity sample is a deterministic subset of the counted strings, not every request.
- The recall floor in `scripts/check.py` covers only the regression cohort and needs the pinned dataset and tokenizer. See the next section.
