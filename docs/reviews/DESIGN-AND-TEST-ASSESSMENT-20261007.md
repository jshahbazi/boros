# Design and test assessment

Assessment date: October 7, 2026. Scope: the `main` checkpoint `e016c06` built and executed in an isolated worktree, the committed evidence on `codex/boros-foundation` through `8cb3d6a`, and the committed and uncommitted records on `codex/native-investigation` through `1dfaa9a`. No model calls, paid provider requests or evaluation reruns were made. No private question, answer, history or date was read. The companion [repair plan](../DESIGN-REPAIR-PLAN.md) proposes the response.

## Judgment

Boros does not fail its automated tests. On `main` the rebuilt application passed every documented suite with zero failures. The design fails its own quality gates, and it fails them because the tests were written to establish accounting, custody and recovery properties rather than the product promise of reliable long-history recall. The effort order inverted the plan's own instruction to make a measured retrieval baseline the checkpoint before further architecture.

Four independent limits are now measured. Each is sufficient on its own to block the product target:

1. One-pass, isolated-message retrieval misses answer-bearing turns that no context budget would recover.
2. The selected local answerer fails on clean oracle evidence that a stronger model answers.
3. The judges used so far cannot certify correctness, and one pilot leaked answerability through identifiers.
4. The only path that answers correctly costs roughly ten times the plan's latency allowance.

## Measured test result on `main`

| Suite | Result |
|---|---:|
| `python3 scripts/check.py` whole-app checks | 1,673 passed, 0 failed |
| `scripts/test_memory.py` | 108 passed |
| `scripts/test_episode.py` | passed |
| `scripts/test_local_read.py` | 77 passed |
| `scripts/test_semantic_recovery.py` | 6 passed |
| `scripts/test_backup.py` | passed |
| `scripts/test_evaluation.py` | 49 passed |

These results reproduce the counts in [IMPLEMENTATION.md](../IMPLEMENTATION.md). They are implemented-behavior checks. None of them involves a real question against a real history.

## What the check suite measures

The 1,322 named checks in the thirteen in-binary self-test suites were dumped from the `main` binary and classified by name:

| Name contains | Checks |
|---|---:|
| budget, allowance, charge, ledger, quota, reserve, hold | 400 |
| quarantine, admission, calibration, count, token | 227 |
| digest, hash, signature, identity, UTF-8, Unicode | 171 |
| excerpt, candidate, retrieve, search, lexical, semantic, vector | 172 |
| recover, reopen, restart, kill, crash, resume, migrate | 79 |
| recall, relevance, rank, BM25, neighbor, exchange, answer | 20 |

Of the twenty names in the last row, one UI check exercises recall of a synthetic source. The retrieval-named checks establish scope filtering, frontier ordering, byte identity and continuation bookkeeping, not whether the ranked result contains the needed evidence. The check code is compiled into the shipping binary: 7,509 lines of `*Checks.swift` against 14,405 lines of product code on `main`. The larger suites on the codex branches add the same kind of check; the 3,887 and 4,087 counts recorded there are not evidence about recall.

The plan's quality gates were never executed on `main`. Gate 2 requires at least 95 percent of required spans on budget-feasible answerable cases ([tracechat-plan.md](../../tracechat-plan.md), line 563). The statistical design requires at least 200 independent histories, 50 per critical category and three replicates (line 543). The `main` evaluation runs 224 synthetic lexical-only probes from a deterministic generator.

## Why the design does not meet its target

### Retrieval is one pass with hard caps

The automatic query keeps at most eight unique non-filler terms, quoted anchors first and then prompt order (`HistoricalQueryFormulation.swift:94-99`). Lexical search joins them with OR under BM25 and the ordinary path requests sixteen results (`ChatContextPreparation.swift:40`, `MemoryStore.swift:1226`). Vector search ranks only the first 4,096 eligible chunks in source-sequence order (`SemanticIndex.swift:83`, `SemanticIndex.swift:656`), so material later in a large archive cannot win the pass. The Apple encoder rejects inputs with code markers, non-ASCII letters or English confidence below 0.90 (`SemanticIndex.swift:64-70`). Fusion collapses to one range per source. Neighbor expansion looked in one direction and spent the same sixteen slots as primaries; the checks of that period asserted the displacement as correct behavior.

On the fourteen-history LongMemEval development cohort, hybrid delivered 14 of 18 annotated positive turns and the local judge accepted 9 of 12 answerable answers. The three rejected answerable cases were selection misses with zero byte, token or envelope exclusions; the missing turns were 135 to 927 bytes. The matched bounded-neighborhood repeat recovered zero of the four missing turns and local acceptance fell from 10 of 14 to 8 of 14 ([adversarial review](JUDGING-RETRIEVAL-ADVERSARIAL-20261006.md), [reassessment](ARCHITECTURE-REASSESSMENT-20261006.md)). Measured required-turn recovery is about 78 percent against a 95 percent gate, on one replicate of fourteen cases.

### The answerer is a second ceiling

On five oracle-selected clean evidence packs, Qwen was accepted 2 of 5 by itself and 3 of 5 by GPT-6.1 Sol; Sol was accepted 4 of 5 by both judges ([OpenAI answerer controls](../OPENAI-ANSWERER-CONTROLS.md)). Earlier DevGPT sufficient-evidence controls delivered all nine curated packs and passed five tasks. Perfect retrieval would not meet the target with the selected model and presentation.

### Judging cannot certify the results

The baseline judge shares the answerer's model identifier, receives no evidence, and has no measured false-accept or false-reject rate. Qwen gave the same pack opposite sufficiency labels depending on which answer it judged. The orientation pilot's 11 of 13 headline was contaminated by an answerability cue in event and session identifiers and cost about 14 dollars before it was held ([audit](ORIENTATION-ZOOM-AUDIT-20261006.md)). JevK5 agreement with Sol on 36 of 39 judgments is agreement between two uncalibrated models.

### The working path misses the latency and cost gates

At 100,000 events the legacy automatic-context p95 was 111.7 seconds because `event_fts JOIN events` let SQLite drive the loop from the project index. The CROSS JOIN repair lowers the standalone path to 0.62 seconds ([SCALING.md](../SCALING.md)). The repair exists only on the codex branches; `main` retains the slow shape. The plan's Gate 6 allows at most 500 milliseconds of added memory latency (line 567), and the repaired warm context path still exceeds it.

The native investigation loop is the only path with a positive quality result: 3 of 3 accepted against 0 of 3 for recent-only, with 4 of 4 annotated turns delivered ([local repeat](../NATIVE-INVESTIGATION-LOCAL-REPEAT.md) on `codex/native-investigation`). It took 58 to 101 seconds per turn, 44 model calls and 229,804 input tokens across three questions, against 2 to 12 seconds and 10,492 tokens for recent-only. The map and exchange index are rebuilt for every accepted turn.

### Evaluation scale never reached a decision

Cohort sizes to date: 7, 14, 30 with contaminated abstentions, 3, and 100 stopped after ten attempts with six accepted, one rejected and two preparation failures. Every result is one replicate. No cohort approaches the registered 200-history design, and category-level findings rest on two cases each.

## Underlying cause

The plan said to make the read-only baseline a measured checkpoint before adding the tree or further architecture (plan line 21; [adversarial review](../../tracechat-adversarial-review.md) line 136). The implementation instead delivered ten schema versions, episode leases, provider-family quarantine, durable background budgets, authority bindings and verified backups, with exhaustive checks for each, before any real-question evaluation ran. The reassessment on this branch states the consequence: contract checks establish implementation properties, not that search finds the material or that the model answers correctly. Reported progress has been check counts, and this assessment shows those counts are uncorrelated with the product target.

## Branch state

`main` at `e016c06` is 51 commits behind `codex/boros-foundation` and lacks the FTS repair, the shared answer coordinator, the investigation engine and all evaluation records. The original checkout carries uncommitted modifications to eleven Swift sources and seven scripts plus two untracked neighborhood sources. `codex/native-investigation` carries the native investigation route and an uncommitted stop record. The `main` STATUS.md describes working-tree files that do not exist on `main`. Design work should proceed from the codex branches after consolidation.

## Boundary of this assessment

This assessment reads code and committed records. It does not establish that any specific repair will meet the gates, that the Apple encoder failed a specific target, or that a local judge label is wrong in any specific case. Check counts quoted from other documents retain their original source captures.
