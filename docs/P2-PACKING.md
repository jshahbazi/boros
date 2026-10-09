# P2 step 3: value-density packing over a declared candidate window

Recorded October 8, 2026. This is work package P2, step 3, of the [design repair plan](DESIGN-REPAIR-PLAN.md). It builds on [steps 1 and 2](P2-EXCHANGE-QUERY.md) and is measured with the [P1 offline retrieval harness](RETRIEVAL-HARNESS.md). It measures R1 candidate recall, R2 delivered recall, prompt size, preparation time, and the standalone latency of the selection path. No answers were generated, no judge ran, and no remote or paid request was made. Nothing here measures answer quality.

Each section states whether it describes implemented behavior, measured results, or proposed design.

## Implemented

One new, explicitly versioned component policy. It is not a default. `ContextComponentPolicy.currentSelectedQwen` remains `selectedQwen` (v1/16), and ordinary Send is unchanged.

| Policy | Version | Harness arm |
|---|---|---|
| Step 3 | `selected-model-context-components-v3-exchange-packed` | `exchange_packed` |

The policy keeps the step 1 and 2 caps, renderer, reduction (`whole-source-suffix-single-v1`), selection audit version (`context-exchange-v1`), 48-span limit and per-turn in-memory index. It reuses the step 1 query and ranking and the step 2 neighbor definition. Only the packer differs: `Sources/Boros/ExchangeValuePacking.swift`, called from `ExchangeBlockQuery.select` when `packsExchangeValueDensity` is true.

### Declared parameters

All of these were committed in `7d68a75` before any development-cohort measurement of this packer, and none changed afterward.

| Parameter | Value | Meaning |
|---|---|---|
| `candidateBlockDepth` | 32 | Ranked blocks whose units are packing candidates. This is the R1 depth |
| Units | lead, replies, previous neighbor, next neighbor | Each source of a candidate block is a unit. The lead is the block's first source. Neighbors follow the step 2 rule: the opposite-role message just before the block and just after it, in the same conversation |
| `memberWeight` | 1.0 | Value of a lead or reply = block score x 1.0 |
| `neighborWeight` | 0.5 | Value of a neighbor = block score x 0.5 |
| Cost | estimated tokens / token budget + audit bytes / audit budget | Two resources, each normalized by its budget |
| Token budget | 12,000 (100 percent of the cap) | The step 1 and 2 byte-to-token estimate, unchanged |
| `deliveryAuditLimitBytes` | 32,768 | The existing `ContextSnapshot.deliveryAudit()` limit |
| `admissionHeadroomBytes` | 5,120 | Reserved for the component count proof, selection work ID and reduction receipts, which are added after selection |
| `probeSlackBytes` | 256 | Reserved for numeric fields that change after the size probe |
| `candidateIDHexDigits` | 12 | Candidate identifiers are the first 12 hex digits of SHA-256(event ID) |

The token budget at 100 percent of the cap is inherited from steps 1 and 2. That fraction was calibrated on the development cohort (the first step 1 build used 90 percent), so it is not a held-out choice.

### Packing

1. **Candidates.** The top 32 ranked blocks are expanded into units, in chronological order within each block: previous neighbor, lead, replies, next neighbor.
2. **Mandatory units.** Every member of a block that matches a quoted anchor is packed first, in rank order. A mandatory unit that does not fit is not dropped silently; it gets the receipt code `M`.
3. **Value per cost.** All other units are sorted by value divided by normalized cost. Ties go to the better block rank, then lead, reply, previous, next, then chronological order. A reply or neighbor is admitted only if its block's lead was delivered. If it outranks its lead, it waits for the lead's decision. A unit is admitted if the span cap, the estimated token budget and the audit byte budget all still hold.
4. **Delivery order.** Delivered sources are grouped by the rank of the unit that admitted them, and each group is chronological. Anchor blocks rank first, so suffix reduction reaches them last.
5. **Audit budget.** Before packing, a size probe serializes the delivery audit with no historical sources and a placeholder candidate audit of the final shape. The audit byte budget is 32,768 - 5,120 - 256 - probe. Each span's audit cost is an exact replica of the assembler's `historical_sources` entry. After delivery, the real delivery audit is measured. If it exceeds 32,768 - 5,120, or if the assembler dropped `exchange_query` from it, the last planned source is removed with code `A` and delivery repeats. This loop never ran on either cohort.
6. **Assembler trace.** For this policy the assembler's `selection_trace` is removed from the retrieval audit. It listed the packed spans, and the candidate list supersedes it. That trace was what made the delivery audit overflow in steps 1 and 2.

### Receipts

`exchange_query` carries a compact candidate list: one entry per candidate block, holding its anchor-match count and its units as `[id12, kind, code]`. The list is recorded at the declared depth before packing; only the codes are filled afterward.

| Code | Meaning |
|---|---|
| `D` | delivered (planned) |
| `M` | mandatory anchor unit over a budget |
| `S` | span cap |
| `T` | estimated token budget |
| `A` | delivery audit byte budget |
| `L` | its block's lead was not delivered |
| `U` | the same source was delivered by another unit |
| `Z` | empty source |

Blocks below the candidate depth are counted in `below_candidate_depth_block_count`. Exact-count removals after selection are recorded by `ContextAssembler.reducingEvidence`, only for this packing version, as `reduction_receipts`: `[id12, page offset, "token" | "envelope" | "audit"]`. The audit contains no text, question, terms or full event IDs.

### Independent R1

R1 for `exchange_packed` is computed from the candidate list, not from delivery. A positive turn is a candidate if it is in recent context, or if its SHA-256 prefix is among the recorded candidate units (top 32 blocks plus their neighbors). The harness also counts delivered positives outside the candidate list. That count was 0 in every attempt, as the construction requires. The candidate list survived the audit limit in all 114 attempts. The final delivery audit was at most 31,806 bytes (development) and 30,608 bytes (regression). Admission added 2,993 to 4,512 bytes, inside the 5,120-byte headroom.

### Contracts

- **Packer checks.** `Sources/Boros/ExchangeBlockQueryChecks.swift` adds 17 synthetic checks to `--retrieval-strategy-self-test`:
  - the policy is explicit and versioned, and the parameters are declared
  - candidate units are chronological and include neighbors
  - short leads win over a long reply
  - every unit gets a receipt, and delivery is grouped by rank
  - dependent units need their lead
  - the audit byte budget and the span cap bind, with receipts
  - quoted-anchor members are mandatory and first
  - a mandatory unit over budget gets `M`
  - the audit replica is byte-exact against the real delivery audit
  - the delivery audit keeps the headroom and the candidate list
  - the audit is content-free
  - a counted removal produces a reduction receipt
- **Journal check.** `Sources/Boros/ExchangeEpisodeChecks.swift` runs in `--retrieval-strategy-integration-test` (`scripts/test_component_preparation.py`). For each of the three exchange policies it does the following:
  - runs the actual `ComponentContextPreparationOperation` against the synthetic tokenizer, which counts 5,000 tokens per source and so forces counted single-span reductions
  - records the prepared request as a cancelled invocation
  - validates it with the unchanged `ContextComponentJournal.validate` (by invocation and whole store), `MemoryStore.validateEpisodeJournal` and `BackupArchive.verify`

  All 13 checks pass. This is the first time `ContextComponentJournal.validate` has run against an exchange-policy episode. No negative mutations were added for these policies, because the existing corruption suite covers the policy-independent fields.
- **Scorer check.** `scripts/test_retrieval_harness.py` adds one contract for the packed R1 scorer.

`python3 scripts/check.py` passed on `e43b0e8`: 4,429 checks. Its regression recall floor reproduced `exchange_packed` at R1 12 and R2 11 (cases) and 18 and 17 (turns). The floor has no entry for any exchange or global arm; those arms are reported, not enforced.

### Harness additions

The changes to the shared harness are additive:

- **`DeliveryHarness.swift`.** Maps `exchange_packed` to the policy and reports `context_audit_bytes`. This changes the store cache key.
- **`scripts/retrieval_harness.py`.** Adds the arm, packed R1 from the candidate list, per-turn `block_rank`, `unit_kind` and `block_disposition`, and per-arm counts of candidate lists, positives delivered outside the candidates, and maximum audit bytes.

The P2 step 4 `global_*` arms from the coordinator merge (`dd389da`) run alongside.

## Measured

- **Development run.** Commit `4e94230`, clean tree, harness binary SHA-256 `46e4b37d8a08fc9b25bc5b361696adf841334c12733a4a685efe8d938bcc1c9c`.
- **Regression run.** Commit `26673f7`, clean tree, the same binary. The commits between them changed only `scripts/test_retrieval_harness.py`.
- **Conditions.** Three workers, one replicate, pinned offline tokenizer, no live parity check. Stores were built cold by this harness source.
- **Manifests.** Development `2e310e44...49f8ae`, regression `bb4b3d2e...3432a9`.
- **Completion.** Every arm completed every case, with zero preparation failures, zero refused generation requests and zero runner starts. All 90 and all 12 answerable cases were budget-feasible.
- **Private reports.** `.build/evaluation/p2-packed-development-4e94230.json` and `.build/evaluation/p2-packed-iter1-regression.json`.

### Recall

| Cohort | Arm | R1 | R2 | Positive turns: candidate / whole |
|---|---|---:|---:|---:|
| Development (90) | hybrid, ordinary Send | 50 | 50 (55.6%) | 114 / 114 |
| | lexical | 60 | 60 (66.7%) | 119 / 119 |
| | exchange_lexical (step 1) | 61 (71 at 24 blocks) | 61 (67.8%) | 125 / 125 |
| | exchange_adjacent (steps 1 and 2) | 62 (71 at 24 blocks) | 62 (68.9%) | 127 / 127 |
| | **exchange_packed (step 3)** | **78 (86.7%)** | **69 (76.7%)** | **149 / 137** |
| Regression (12) | hybrid | 8 | 8 | 14 / 14 |
| | lexical | 9 | 9 | 15 / 15 |
| | exchange_lexical | 10 (11 at 24 blocks) | 10 | 16 / 16 |
| | exchange_adjacent | 10 (11 at 24 blocks) | 10 | 16 / 16 |
| | **exchange_packed** | **12** | **11** | **18 / 17** |

- **Baseline reproduction.** Every earlier arm reproduces its recorded value exactly: 50, 60, 61 and 62 on development, and 8, 9, 10 and 10 on regression.
- **Step 1 and 2 R1.** For those arms, R1 is still not independent. The table's R1 column counts delivered turns. The "at 24 blocks" figure is a diagnostic computed from their audited top-24 ranked block list, members only.
- **Step 3 R1 is independent.** R1 for `exchange_packed` is computed at the declared depth of 32 blocks plus neighbors, and a deeper candidate set raises it by construction. R2 decides.

Case-level change on development:

| Against | Wins | Losses | Net |
|---|---:|---:|---:|
| exchange_adjacent | 9 | 2 | +7 |
| exchange_lexical | 8 | 0 | +8 |
| lexical | 10 | 1 | +9 |
| hybrid | 19 | 0 | +19 |

The two losses against step 2 are:

- `73d42213`, multi-session. One positive is the lead of rank-18 block, code `T`. Step 2 delivered it as a neighbor of an included block.
- `6e984302`, temporal reasoning. The positive is the next neighbor of the rank-4 block, code `T`.

One replicate. The development interim target, R2 at 90 percent, is not met.

### Development R2 by category

| Category | Cases | hybrid | lexical | step 1 | steps 1 and 2 | step 3 (R1 / R2) |
|---|---:|---:|---:|---:|---:|---:|
| Knowledge update | 14 | 10 | 11 | 11 | 13 | 13 / 13 |
| Multi-session | 23 | 8 | 9 | 8 | 9 | 17 / 11 |
| Assistant recall | 11 | 6 | 11 | 11 | 11 | 11 / 11 |
| Preference | 5 | 2 | 3 | 4 | 4 | 4 / 4 |
| User recall | 12 | 11 | 12 | 12 | 11 | 12 / 12 |
| Temporal reasoning | 25 | 13 | 14 | 15 | 14 | 21 / 18 |

The gain is in temporal reasoning (+4 over step 2) and multi-session (+2). Assistant recall stays 11 of 11, so delivering leads before replies did not cost the reply-positive cases.

### Known misses (regression cohort)

| Case | Category | hybrid | lexical | steps 1 and 2 | step 3 | Step 3 detail |
|---|---|---|---|---|---|---|
| `51c32626` | Multi-session, 2 positives | 1/2 | 2/2 | 2/2 | 2/2 | Leads of blocks 0 and 4, delivered |
| `1b9b7252` | Assistant recall | 0/1 | 0/1 | 1/1 | 1/1 | Reply of block 0, delivered |
| `4baee567` | Assistant recall | 0/1 | 0/1 | 1/1 | 1/1 | Reply of block 0, delivered |
| `1a1907b4` | Preference | 0/1 | 0/1 | 0/1 | 0/1 | Now a candidate: the next neighbor of block 17, skipped by the token budget (`T`) |

The regression case that step 1 lost against lexical, `1192316e`, is delivered by step 3. `1a1907b4` was previously accepted without its annotated turn.

### Where the remaining development misses are

28 positive turns are missed:

| Where | Turns | Detail |
|---|---:|---|
| Not a candidate unit | 16 | Not in the top 32 blocks or their neighbors |
| Candidate lead, token budget (`T`) | 11 | Block ranks 4, 18 to 31 |
| Candidate next neighbor, token budget (`T`) | 1 | |

By category: 16 multi-session, 10 temporal reasoning, 1 preference and 1 knowledge update. The remaining multi-session failures are mostly in the ranking (R1 17 of 23 against R2 11 of 23). Lexical ranking cannot reach some of them; step 1 found at least 11 cases with no question term in a positive block.

### Receipts and fitting

Across the 100 development attempts the candidate lists hold:

- **Unit codes.** 2,321 `D`, 4,073 `T`, 3,772 `L`, 816 `U` and 58 `A`. There were no `S` or `M` codes.
- **Audit byte budget.** It bound in only 3 attempts. The token budget is the binding constraint: a median of 23 spans and at most 27.
- **Exact-count removals.** The token counter removed one span in 25 attempts, 26 removals in total, each with a reduction receipt.
- **Estimate calibration.** Actual evidence tokens were 0.93 to 1.07 of the estimate (p05 to max, median 0.98). This is higher than steps 1 and 2 (median 0.93), because short spans are header-dense.
- **Verification trims.** The audit-verification trim never ran.
- **Other exclusions.** There were no exclusions other than these token removals and 14 recent-token exclusions.

### Prompt size and preparation time

| Measure | hybrid | lexical | step 1 | steps 1 and 2 | step 3 |
|---|---:|---:|---:|---:|---:|
| Development whole-prompt tokens p50 / p95 | 15,462 / 17,740 | 15,222 / 17,601 | 16,427 / 18,343 | 16,335 / 18,306 | 17,084 / 18,753 |
| Development preparation ms p50 / p95 | 3,322 / 5,939 | 750 / 1,668 | 598 / 927 | 607 / 1,035 | 724 / 2,069 |
| Regression whole-prompt tokens p50 / p95 | 13,762 / 16,853 | 13,574 / 16,363 | 14,398 / 16,259 | 14,472 / 16,799 | 14,719 / 17,336 |
| Regression preparation ms p50 / p95 | 2,704 / 3,226 | 628 / 790 | 534 / 578 | 526 / 594 | 627 / 647 |

Step 3 fills the evidence cap more fully: development evidence was 11,675 / 11,947 tokens (p50 / p95). Prompts grow by about 750 tokens at the median over step 2, and no model calls are added. Preparation includes loopback tokenizer calls, more of them when a counted removal occurs, on a machine shared with other agents. During the development run the step 3 p95 overlapped one compile of the latency diagnostic. These preparation times are not L1 measurements.

### Standalone latency at 1,000, 10,000 and 100,000 events

The harness and workload:

- **Diagnostic.** `scripts/exchange_latency.py` with `Tests/Evaluation/ExchangeLatencyHarness.swift`. The application sources are compiled without the app entry point.
- **Workload.** The same deterministic synthetic scaling fixture as [SCALING.md](SCALING.md) (`evaluation_fixtures.generate("development", scale_events=N)`): one history per size and nine probes per profile. There is a warm profile (ingest, then probe) and a restart profile (reopen, then probe).
- **Measurement.** Each probe accepts the prompt in a real chat episode with the policy frozen. It times `ContextAssembler.prepareRecent` and then `ExchangeBlockQuery.prepareEvidence` under the episode lease.
- **Excluded.** Token counting and admission are not timed.
- **Added path.** The added memory path over recent-only is the `prepareEvidence` time; recent selection is common to both.
- **Uncapped stages.** A diagnostic-only path, with no lease and no snapshot cap, times the stages: manifest, load and digest check of every source, index build, rank and plan.
- **Implementation.** Commit `e43b0e8`, clean tree, binary SHA-256 `3d9da794...2d24`. Report: `.build/evaluation/p2-exchange-latency-e43b0e8/report.json`.

| Events | Profile | Policy | Status | Added p50 / p95 (ms) |
|---:|---|---|---|---:|
| 1,000 | warm | exchange_adjacent | 9/9 selected | 84 / 327 |
| | | exchange_packed | 9/9 selected | 92 / 356 |
| | restart | exchange_adjacent | 9/9 selected | 91 / 344 |
| | | exchange_packed | 9/9 selected | 108 / 362 |
| 10,000 | warm | exchange_adjacent | 9/9 selected | 640 / 1,000 |
| | | exchange_packed | 9/9 selected | 633 / 902 |
| | restart | exchange_adjacent | 9/9 selected | 655 / 1,030 |
| | | exchange_packed | 9/9 selected | 669 / 930 |
| 100,000 | warm | exchange_adjacent | **9/9 refused** (`snapshotLimit`) | 74 / 95 |
| | | exchange_packed | **9/9 refused** (`snapshotLimit`) | 73 / 78 |
| | restart | exchange_adjacent | **9/9 refused** | 77 / 89 |
| | | exchange_packed | **9/9 refused** | 80 / 91 |

Recent selection took 55 / 94 ms warm and 127 / 191 ms after restart (p50 / p95) for every policy, recent-only included.

Uncapped stages, p50 / p95 in milliseconds:

| Events | Manifest | Load and verify | Index | Rank | Plan | Total |
|---:|---:|---:|---:|---:|---:|---:|
| 1,000 | 0.4 / 0.5 | 32 / 42 | 6 / 8 | 0.2 / 0.5 | 1.3 / 2.6 | 41 / 50 (warm) |
| 10,000 | 3.7 / 3.9 | 343 / 364 | 41 / 43 | 1.7 / 4.9 | 1.3 / 2.8 | 392 / 413 (warm) |
| 100,000 | 42 / 46 | 3,282 / 3,324 | 395 / 402 | 17 / 49 | 1.3 / 2.6 | 3,742 / 3,789 (warm); 3,880 / 4,225 (restart) |

What this shows:

1. **At 100,000 events both exchange policies fail closed.** The per-turn loader refuses any project with more than `maximumSources = 20,000` sources, and the synthetic history keeps about 99,990 events in one project. The refusal itself takes about 80 ms, and no historical evidence is delivered. Against L1 (2 s) and Gate 3 (1 s) this is a pass on time and a failure on function. A Send at this size would get recent context only.
2. **Lifting the cap would fail both gates.** The work that the cap refuses costs 3.7 to 4.2 s per turn at 100,000 events, almost all of it in reading and verifying every source (3.3 to 3.7 s). That fails L1 (2 s) and Gate 3 (1 s). The cost is linear: about 0.4 s at 10,000 events and 0.04 s at 1,000.
3. **At 10,000 events.** The added p95 is 0.90 to 0.93 s for step 3 and 1.00 to 1.03 s for step 2. That is within L1's 2 s and at the edge of Gate 3's 1 s. The metered entry point costs about 0.25 s more than the bare stages, through lease charging and the assembler's re-read of every delivered span.
4. **Packing is not a cost.** The planner takes at most 3 ms at every size. Step 3's latency is step 2's.

These numbers come from one synthetic history per size, and its distractors are uniform single-message blocks. They are not a production latency distribution.

## What did not work, and iteration disclosure

- **Development.** Step 3 was measured once on the development cohort, at `4e94230`, with the parameters declared at `7d68a75`. No variant was measured on development and none was abandoned.
- **Regression.** One regression run at `26673f7` (11 of 12) preceded the development run. Nothing was changed after it, because its only miss is `1a1907b4`, and tuning for that case would be fitting the regression set.
- **Discarded latency smoke run.** A 1,000-event smoke run of the latency diagnostic overlapped the development harness run. It was used only to check that the diagnostic works, and its timings were discarded.
- **The offline simulator.** The uncommitted simulator from the step 1 and 2 record predicted about 67 of 90 for lead-first packing. The implemented packer reached 69, but the simulator was not this packer: it used a 40 to 60 percent lead fraction rather than value density, and it ignored framing and audit bytes. It is therefore not validated by this result.
- **Audit-size finding.** The 32 KiB delivery audit is near its limit at about 21 spans for steps 1 and 2. This is because each historical source costs about 750 bytes of audit and the assembler trace about 5 KB. Step 3 removes that trace and budgets audit bytes explicitly. On this cohort the token cap still binds first.

## Proposed (not implemented, not measured)

- **A persistent, incrementally maintained exchange index (plan step 1, second clause).** This is now justified. Step 3 raises R2 by 7 cases over step 2 using the same ranking, but the per-turn rebuild refuses large projects and would cost about 3.8 s at 100,000 events. Term statistics and block boundaries kept in the store would remove the full load, which accounts for 88 percent of the uncapped cost. Ranking then reads only matched blocks, and assembly re-reads only delivered spans. This needs its own measurement against L1 and Gate 3.
- **Ranking work for multi-session questions.** 16 of the 28 missed turns are outside the candidate units, mostly in multi-session questions. The step 4 result reports that semantic fusion recovers none of them, so this is a lexical or temporal-routing question.
- **Answer-quality checks** for `exchange_packed` before any default change, as the plan requires.

## Recommendation

Do not make `exchange_packed` the default yet. It is the best measured selection on both cohorts:

- development R2 69 of 90 (76.7 percent), against 62 for step 2, 60 for lexical and 50 for ordinary Send
- regression 11 of 12, with three of the four known misses delivered and the fourth now a candidate
- no measured loss in assistant recall
- about 750 more prompt tokens than step 2 and no added model calls

Three things block a default change:

1. **It fails closed above 20,000 sources in a project.** At the plan's 100,000-event scale it delivers no evidence. Without that cap the per-turn index would cost about 3.8 s and fail both latency gates.
2. **R2 is still below 90 percent.**
3. **There is no answer-quality evidence.**

If a default must change before the persistent index exists, `exchange_packed` dominates `exchange_adjacent` on recall at equal latency, but it inherits the same size refusal.

## Running it

```bash
python3 scripts/retrieval_harness.py --cohort development --workers 3 --output .build/evaluation/p2-packed-development.json
python3 scripts/exchange_latency.py --output-directory "$PWD/.build/evaluation/p2-exchange-latency"
```

The first harness run after a `DeliveryHarness.swift` change rebuilds the store cache. Here the cold development run took 2,026 s with three workers and eight arms, and the cold regression run took 434 s. The latency diagnostic takes about 3 minutes, including its compile.
