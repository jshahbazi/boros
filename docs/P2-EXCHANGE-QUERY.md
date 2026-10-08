# P2 steps 1 and 2: exchange-block query and anchor-adjacent packing

Recorded October 8, 2026. This is work package P2, steps 1 and 2, of the [design repair plan](DESIGN-REPAIR-PLAN.md), measured with the [P1 offline retrieval harness](RETRIEVAL-HARNESS.md). It measures two stages only: R1 candidate recall and R2 delivered recall. No answers were generated, no judge ran, and no remote or paid request was made. Nothing here measures answer quality.

Each section states whether it describes implemented behavior, measured results, or proposed design.

## Implemented

Two new, explicitly versioned component policies. Neither is a default. `ContextComponentPolicy.currentSelectedQwen` remains `selectedQwen` (v1/16), and ordinary Send is unchanged.

| Policy | Version | Harness arm |
|---|---|---|
| Step 1 | `selected-model-context-components-v3-exchange` | `exchange_lexical` |
| Steps 1 and 2 | `selected-model-context-components-v3-exchange-adjacent` | `exchange_adjacent` |

Both keep the v1 token caps (8,000 recent, 12,000 evidence), recent selection, byte caps and renderer. They differ from v1 in four ways: evidence spans up to 48 instead of 16, selection audit version `context-exchange-v1`, reduction `whole-source-suffix-single-v1` (a component-cap overflow removes one lowest-ranked span per counted round instead of half the evidence), and the evidence selector below. `ChatContextPreparation.prepareEvidence` refuses both policies. Component preparation sends them to `ExchangeBlockQuery.prepareEvidence` (`Sources/Boros/ExchangeBlockQuery.swift`), which has the same preconditions, lease, exclusions and assembler revalidation as v1. Neither policy reads the semantic index.

### Step 1: full-question query over exchange blocks

- **Index.** Each turn loads the project's sources through one fixed frontier into memory. The accepted request and the recent sources are excluded. Payloads are funded as one declared source read and checked against stored digests. Nothing is persisted, and no schema changes.
- **Blocks.** Within each conversation, a block starts at each human message and runs to the next one. This is the investigation engine's construction (`NativeHistoryNavigation.swift`, ported, not called).
- **Query.** The query is every content term of the question. When a question date is present, the question text is the harness's lexical range. Terms are case- and diacritic-folded alphanumeric runs with the investigation stopword list removed. Up to eight quoted spans (`"..."`, curly double quotes, backticks) are also kept as anchor term sets.
- **Ranking.** Blocks that contain every term of more quoted anchors rank first, so anchors act as mandatory terms. Within an anchor tier, the score is the investigation score: the sum over matched terms of `idf(t) * (1 + min(2, log tf))`, divided by `sqrt(1 + block_bytes / 512)`, with `idf(t) = log(1 + (N + 0.5) / (df + 0.5))` over blocks. On equal scores the later block ranks first.
- **Packing.** Blocks are packed greedily in rank order and are atomic: every non-empty source, whole, as exact store pages of at most 4,096 bytes, or nothing. A block that does not fit the estimated budget is skipped and later blocks are still tried. The estimate is the framing bytes divided by 2.0 plus the excerpt bytes divided by 3.2, against the full 12,000-token evidence cap. The exact component count still decides.
- **Audit.** The retrieval audit carries `exchange_query`: versions, counts, a digest of the sorted query terms, estimated tokens, and the event IDs and dispositions of the top 24 ranked blocks. It contains no text. If the delivery audit exceeds its 32 KiB limit, this key is dropped after the selection trace.

### Step 2: anchor-adjacent packing

After each block is admitted, the selector looks at two neighbors in the same conversation: the message just before the block's first source and the message just after its last source. A neighbor is added only if its role is the opposite of the block's boundary message and it still fits the estimate. The spans go in chronological order beside the block: previous neighbor, block, next neighbor. Lower-ranked blocks therefore come later, and suffix reduction removes them first. A source that is already delivered is never added twice.

### Contracts

`Sources/Boros/ExchangeBlockQueryChecks.swift` adds 24 synthetic checks to the `--retrieval-strategy-self-test` suite. They cover:

- an unchanged v1 default and explicit, round-tripping exchange policies
- query terms and quoted anchors, block boundaries, same-conversation adjacency, IDF ordering, anchor-first ordering and the tie rule
- scalar-safe pages
- end-to-end delivery through the exchange entry point: the best block whole and first, atomic budget skips, no recent or request sources, valid versioned snapshots, content-free audits, and no model, encoder or vector work
- adjacent neighbors placed beside their block
- single-span overflow reduction, refusal of mismatched policies on both entry points, and empty queries

`python3 scripts/check.py` passed: 4,305 checks. One earlier run failed two timing-sensitive `endpoint-integration` transport checks while other agents loaded the machine. The checks passed on the immediate rerun, and this change does not touch that code.

### Harness additions

The harness additions are additive. `DeliveryHarness.swift` accepts the two `exchange_*` arms, freezes their policy in the episode limits, uses no semantic index for them, and copies the `exchange_query` audit into its output. `scripts/retrieval_harness.py` adds the arms to `ARMS`, and per positive turn it reports `block_rank` and `block_disposition` from the answer-blind top-24 list. The existing arms are unchanged and reproduce the P1 baseline exactly (below).

## Measured

Implementation commit `05dc43c`, clean tree (`working_tree_modified: false`), harness binary SHA-256 `74dd240877e4139f19b64bb651c8fce140f0005b05d766a590d0d1ad8e7ef89c`. Three workers, one replicate. The offline pinned tokenizer was used, with no live parity check. Stores were built cold by this harness source, because changes to `DeliveryHarness.swift` change the store cache key. Development manifest SHA-256: `2e310e44...49f8ae`. Regression manifest SHA-256: `bb4b3d2e...3432a9`. Private reports: `.build/evaluation/p2-exchange-{development,regression}-05dc43c.json`. Every arm completed every case with zero preparation failures, zero refused generation requests and zero runner starts. All 90 development cases and all 12 regression cases were budget-feasible.

### Recall

| Cohort | Arm | R1 | R2 | Positive turns whole |
|---|---|---:|---:|---:|
| Development (90) | hybrid, ordinary Send | 50 | 50 (55.6%) | 114/165 |
| | lexical | 60 | 60 (66.7%) | 119/165 |
| | exchange_lexical (step 1) | 61 | 61 (67.8%) | 125/165 |
| | exchange_adjacent (steps 1 and 2) | 62 | 62 (68.9%) | 127/165 |
| Regression (12) | hybrid, ordinary Send | 8 | 8 | 14/18 |
| | lexical | 9 | 9 | 15/18 |
| | exchange_lexical | 10 | 10 | 16/18 |
| | exchange_adjacent | 10 | 10 | 16/18 |

The baseline arms match the P1 record exactly (50, 60, 8, 9).

R1 is not an independent measure for the exchange arms. The trace lists the packed spans in delivery order, so its first 16 entries are already selected evidence. In 6 step-1 and 13 step-2 development attempts the delivery audit exceeded 32 KiB and the selection trace was omitted (`trace_omitted`), so R1 falls back to delivered turns. R1 equals R2 in every arm.

Case-level change on development against lexical: step 1 wins 5 and loses 4 (+1 net); step 2 wins 6 and loses 4 (+2). Against hybrid: step 1 wins 16 and loses 5; step 2 wins 18 and loses 6. One replicate cannot separate a one- or two-case difference from noise. The development interim target, R2 at 90 percent, is not met.

### Development R2 by category

| Category | Cases | hybrid | lexical | step 1 | steps 1 and 2 |
|---|---:|---:|---:|---:|---:|
| Knowledge update | 14 | 10 | 11 | 11 | 13 |
| Multi-session | 23 | 8 | 9 | 8 | 9 |
| Assistant recall | 11 | 6 | 11 | 11 | 11 |
| Preference | 5 | 2 | 3 | 4 | 4 |
| User recall | 12 | 11 | 12 | 12 | 11 |
| Temporal reasoning | 25 | 13 | 14 | 15 | 14 |

### Known misses (regression cohort)

| Case | Category | hybrid | lexical | step 1 | steps 1 and 2 | Detail |
|---|---|---|---|---|---|---|
| `51c32626` | Multi-session, 2 positives | 1/2 | 2/2 | 2/2 | 2/2 | Step 1 ranks both positives' blocks at 0 and 4 and delivers both whole |
| `1b9b7252` | Assistant recall | 0/1 | 0/1 | 1/1 | 1/1 | The positive's block ranks first |
| `4baee567` | Assistant recall | 0/1 | 0/1 | 1/1 | 1/1 | The positive's block ranks first; the full-question query finds the lexical match the eight-term query lacked |
| `1a1907b4` | Preference | 0/1 | 0/1 | 0/1 | 0/1 | The positive's block is not in the top 24 ranked blocks |

The plan expected step 1 alone to miss `51c32626` and `1b9b7252`, because their targets sit in the block next to the old primary. Under the full-question query, the target's own block ranks directly, so step 2 was not needed for either case. The one regression case that step 1 loses against lexical, `1192316e`, has its positive's block at rank 8 to 23, skipped by the budget estimate.

### Where the remaining development misses are

Missed positive turns are classified by their block's rank in the answer-blind ranked list.

| Arm | Missed turns | Block not in top 24 | Ranked in top 24, skipped by the budget estimate |
|---|---:|---:|---:|
| Step 1 | 40 | 25 | 15 (all at rank 8 to 23) |
| Steps 1 and 2 | 38 | 22 | 16 (3 at rank 0 to 7) |

Every missed development positive is a user turn (byte size p50 about 280). Every assistant-turn positive (11) was delivered. In the first 20 development histories, user messages have a byte p50 of 185 and assistant messages a p50 of 1,733. Whole blocks therefore spend most of the evidence budget on assistant replies. Step 1 delivers about 9 blocks in 18 spans at the median, and step 2 about 6 blocks plus 8 neighbors.

### Cost

| Measure (development, all 100 attempts) | hybrid | lexical | step 1 | steps 1 and 2 |
|---|---:|---:|---:|---:|
| Whole-prompt tokens p50 / p95 | 15,458 / 17,716 | 15,214 / 17,569 | 16,441 / 18,319 | 16,374 / 18,308 |
| Preparation ms p50 / p95 | 2,982 / 3,597 | 672 / 773 | 548 / 688 | 555 / 681 |

On regression, step 1 used 14,374 / 16,279 prompt tokens (p50 / p95) and 489 / 566 ms; step 2 used 14,443 / 16,819 tokens and 500 / 542 ms. Exchange evidence fills more of the 12,000-token cap: the development evidence component was 10,932 / 11,708 tokens (p50 / p95) for step 1. That adds about 1,000 to 1,200 whole-prompt tokens over lexical. No model calls are added. Preparation includes loopback tokenizer calls on a machine shared with other agents. These histories have about 500 events, so this is not an L1 measurement. The per-turn in-memory index reads every eligible source, so its cost grows with the archive. The 100,000-event profile has not been run; a persistent incremental index (plan step 1, second clause) is not justified by these results alone.

Estimate calibration: actual evidence tokens were 0.87 to 1.01 of the estimate on development (p05 to max, median 0.93). Two step-2 attempts and no step-1 attempts needed a one-span overflow reduction. No exclusions of any other kind occurred.

## What did not work, and iteration disclosure

1. **The first build used 90 percent of the evidence cap for the estimate.** On a dirty tree, development R2 was 59 for both exchange arms (one below lexical), and the estimate overstated actual tokens by about 7 percent at the median. The fraction was raised to 100 percent with single-span overflow reduction. This is a calibration fitted on the development cohort, not a held-out result.
2. **Anchor-adjacent packing adds little.** It gained one development case over step 1 and none on regression. Neighbors compete with lower-ranked blocks for the same budget, and three development positive turns whose blocks ranked in the top 8 were skipped by the budget.
3. **Alternative scorings did not help.** An offline Python simulation of the ranking, which approximates the Swift selector (it reproduced 57 of the harness's 59 at the 90 percent budget), tried three alternatives: normalizing by lead-message length only, log-damped length, and IDF coverage fraction. None was better than the ported score (57 to 59 of 90). In that simulation, the worst-ranked positive block falls within the top 12 blocks in 68 of 90 development cases. In 11 cases at least one positive block contains no question term at all, so no lexical ranking can reach it. These are diagnostics, not harness measurements.

## Proposed (not implemented, not measured by the harness)

- **Lead-first, cost-aware packing (plan step 3).** The packer is now the binding constraint, not the ranking. The same offline simulation used two passes. First it packed the human lead message of each ranked block up to 40 to 60 percent of the cap. Then it completed blocks with their replies in rank order. This delivered 67 of 90 development cases against 59 for whole-block packing, stable across those fractions, and 11 of 12 on regression. This is an estimate from an approximate simulator, not a harness measurement. It should be implemented as its own versioned policy and measured before any claim.
- **Semantic or temporal routes for the lexical ceiling.** At least 11 development cases are unreachable by any lexical block ranking. This is the question for step 4 (global vector search).
- **Journal validation of a live answer.** The harness stops at the answering boundary, so invocation-publication validation (`ContextComponentJournal.validate`) has not run against an exchange-policy episode. Its checks are written against the policy fields (`selectionAuditVersion`, `evidenceSpans` and the rest), not fixed v1 values, but they are unexercised for these policies until a local answer run.

## Recommendation

Do not make either exchange policy the default yet. Steps 1 and 2 deliver three of the four known misses and beat ordinary Send (hybrid) by 11 to 12 development cases at lower preparation time. Against lexical-only selection the gain is one or two cases on one replicate, and R2 (68.9 percent) remains far below the 90 percent interim gate. If the default is to change before step 3, the evidence favors `exchange_adjacent` over current hybrid, and it should go through the plan's answer-quality checks first. The larger measured opportunity is the packer: whole assistant replies crowd out user-turn evidence that the ranking already places in the top 24.

## Running it

```bash
python3 scripts/retrieval_harness.py --cohort development --workers 3 --output .build/evaluation/p2-exchange-development.json
```

The `exchange_lexical` and `exchange_adjacent` arms run with the existing arms. The first run after a `DeliveryHarness.swift` change rebuilds the store cache, because the harness source is part of the cache key. The P1 record measured 840 seconds cold for development with four workers. The warm development run here took 728 seconds with three workers and five arms.
