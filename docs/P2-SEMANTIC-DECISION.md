# P2 step 4: semantic retrieval on the ordinary path

Recorded October 8, 2026. This is work package P2 step 4 of the [design repair plan](DESIGN-REPAIR-PLAN.md), measured on the [offline retrieval harness](RETRIEVAL-HARNESS.md). It measures R1 candidate recall, R2 delivered recall and retrieval latency only. No answers were generated, no judge ran, and no remote or paid request was made. Nothing here measures answer quality.

Each section says whether it describes **implemented** code, **measured** results, or a **proposed** change.

## Summary

- **Measured.** Semantic fusion lowers R2 on both cohorts: development 50/90 against 60/90 for lexical alone, regression 8/12 against 9/12. Searching every chunk instead of a 4,096-chunk prefix changes nothing at cohort scale, because no history has more than 407 eligible vectors. A fusion that cannot displace lexical primaries delivers exactly what lexical alone delivers (60/90, 9/12) and wins no case.
- **Diagnosis.** Displacement comes from vector coverage, not from semantic-only results. Reciprocal-rank fusion gives a bonus to every lexical hit that has a vector. The English-only gate leaves 96 percent of assistant bytes without a vector. Lexical hits on assistant turns therefore sink below lexical hits ranked 17 to 100 that happen to have vectors.
- **Recommendation (proposed).** Turn semantic retrieval off the ordinary path and use lexical selection alone. Do not adopt either global variant. Stop spending background maintenance budget on the semantic index for the ordinary path.
- **Decision (implemented).** On October 8, 2026, the user turned semantic retrieval off for ordinary Send and stopped background semantic indexing. Both are controlled by one policy value. See [Decision](#decision).

## What was implemented

- `Sources/Boros/GlobalSemanticSearch.swift` adds brute-force cosine search over every eligible published chunk. It is an explicit evaluation option and is not the shipped default. It opens a separate read-only, query-only connection to the semantic sidecar and applies the same eligibility rules as `SemanticIndex.search`, but without the 4,096-row cap. Those rules cover scope, the source frontier, the publication frontier, ready jobs, supported chunks and exclusions. The search reads every row in one deferred read transaction. It decodes each row with the same little-endian float32 layout, unit-norm check and in-order Double dot product, and keeps the best chunk per source. A different encoder identity is refused. So is a population above 1,048,576 rows; the search never truncates. Only the selected results are verified against their original sources and re-read. Vector bytes, metadata rows and the query embedding are charged to the episode lease. The returned manifest is not written to the sidecar, so `SemanticIndex.replay` cannot replay it.
- `SemanticSearchSelection` reaches `ChatContextPreparation.prepareEvidence` through `AnswerAttemptCoordinator` and `ComponentContextPreparationOperation`. It defaults to `.shipped` at every level, so at the time of this measurement ordinary Send still called `SemanticIndex.search` unchanged. The [Decision](#decision) below later removed semantic retrieval from ordinary Send. `ContextRetrievalStrategy` is unchanged; its public values stay frozen.
- Harness arms `global_hybrid` and `global_fill` select the two modes. The harness also records content-free diagnostics: primary order, exchange-expansion decisions, and the shipped manifest's per-result paths and scores, replayed from each attempt's sidecar.
- `scripts/semantic_decision_diagnosis.py` computes the diagnosis below from a harness report, the cohort annotations and the cached sidecars. It reads annotations only in the scorer.
- `scripts/global_semantic_scale.py` with `Tests/Evaluation/GlobalSemanticScale.swift` times the committed search over synthetic sidecars.
- Fifteen synthetic contracts in `Sources/Boros/GlobalSemanticSearchChecks.swift` run inside `--semantic-self-test`. They cover:
  - declared parameters, and the shipped defaults left unchanged;
  - reaching rows beyond the shipped cap;
  - scope, frontier and exclusions applied before ranking;
  - original bytes returned;
  - exact reproduction of `SemanticIndex.search` when the population fits;
  - fill keeping the lexical prefix and appending semantic-only results only after it;
  - an unsupported query scanning no vectors;
  - refusal of a foreign encoder;
  - refusal of the shipped mode as a global call;
  - shipped default preparation;
  - explicit preparation recording its mode;
  - vector and embedding charges;
  - a content-free audit;
  - a corrupt vector failing closed.

## Declared arms

Parameters were declared in `GlobalSemanticSearchParameters` before any development-cohort measurement. Iteration used the regression cohort only, and no parameter changed after the first regression run. Two audit-only changes followed: stage timing was added, and the audit was compacted (see Limits). Neither changes selection.

| Arm | Population | Fusion | Lexical window | Parameter digest |
|---|---|---|---|---|
| lexical | none | lexical order | 16 | n/a |
| hybrid (ordinary Send before the decision) | first 4,096 eligible chunks in source order | reciprocal rank, constant 60, equal weights; the fused score of each source is the sum over the lexical and semantic lists | 100 | n/a |
| global_hybrid | every eligible chunk | same as hybrid | 100 | `dff7d1c9…` |
| global_fill | every eligible chunk | lexical primaries keep their slots and order; semantic-only sources fill only the slots lexical leaves empty | 16 (the result limit) | `ac77ab20…` |

`global_fill` is the variant that cannot displace lexical primaries. It was measured because the diagnosis showed displacement.

## Measured results

Implementation: commit `9ca96cd` with a clean tree. Retrieval harness binary SHA-256 `b5e6743dfa58d12840daf45f02603cb58f5ca677edbe9315e5a0cecbbeecccbd`, build digest `8ca7c531…`, ingestion digest `696d1f38…`. One replicate; selection is deterministic. The `recent_only`, `lexical` and `hybrid` arms reproduce the P1 baseline exactly on both cohorts. No arm fell back to lexical. There were zero preparation failures, zero runner starts and zero refused generation requests. Private reports: `.build/evaluation/p2s4/final-{development,regression}.json`, their `-diagnosis.json` companions, and `final-scale.json`.

### R1 and R2

| Arm | Development R1 | Development R2 | Development turns whole | Regression R1 | Regression R2 | Regression turns whole |
|---|---:|---:|---:|---:|---:|---:|
| recent_only | 0/90 | 0/90 | 2/165 | 0/12 | 0/12 | 0/18 |
| lexical | 60/90 | 60/90 (66.7%) | 119/165 | 9/12 | 9/12 | 15/18 |
| hybrid (ordinary Send before the decision) | 50/90 | 50/90 (55.6%) | 114/165 | 8/12 | 8/12 | 14/18 |
| global_hybrid | 50/90 | 50/90 (55.6%) | 114/165 | 8/12 | 8/12 | 14/18 |
| global_fill | 60/90 | 60/90 (66.7%) | 119/165 | 9/12 | 9/12 | 15/18 |

All 90 development and all 12 regression answerable cases were budget-feasible. R1 equals R2 in every arm, as in P1.

How the global arms relate to the existing arms:

- `global_hybrid` selected the same ranked candidates and the same delivered byte ranges as `hybrid` in every attempt: 100 of 100 development attempts and 14 of 14 regression attempts. The shipped search never hit its cap; the largest eligible population was 407 vectors.
- `global_fill` delivered every byte range that `lexical` delivered in all 114 attempts. Its traced candidate list equals the lexical one in 93 of 100 development attempts and 13 of 14 regression attempts. In two development attempts and one regression attempt, semantic-only sources filled slots that lexical left empty. The remaining five development attempts dropped their trace (see Limits). None of these changed a case result.

### R2 by category, development cohort

| Category | Cases | lexical | hybrid | global_hybrid | global_fill |
|---|---:|---:|---:|---:|---:|
| Knowledge update | 14 | 11 | 10 | 10 | 11 |
| Multi-session | 23 | 9 | 8 | 8 | 9 |
| Assistant recall | 11 | 11 | 6 | 6 | 11 |
| Preference | 5 | 3 | 2 | 2 | 3 |
| User recall | 12 | 12 | 11 | 11 | 12 |
| Temporal reasoning | 25 | 14 | 13 | 13 | 14 |

On the regression cohort (two cases per category), the arms differ only in multi-session: lexical and `global_fill` pass 2, while `hybrid` and `global_hybrid` pass 1. That case is `51c32626`.

## Diagnosis (measured)

### The population cap is not the cause at cohort scale

`SemanticIndex.search` reads eligible chunks `ORDER BY source_sequence, offset` with a limit of 4,097 and ranks only the first 4,096. The plan calls this a chronological population. A cohort history has 732 to 910 published chunks, and only 210 to 407 eligible chunks carry a vector. The cap never applied, and no attempt reported a vector continuation. Four questions (one development, three regression) were themselves refused by the encoder as ambiguousLanguage. Those attempts scanned no vectors and ranked lexically in every fused arm. The global search therefore reproduced the shipped ranking exactly. At 100,000 events the cap would apply; see Latency.

### The English-only gate leaves most of the archive without vectors

The adapter refuses a chunk unless every sentence is English with at least 0.90 confidence and the chunk has no code markers. Coverage in the cached development sidecars (90 eligible histories) and the regression sidecars (12):

| Role | Cohort | Bytes | Bytes with a vector | Fraction | Main refusal |
|---|---|---:|---:|---:|---|
| Assistant | Development | 38,471,813 | 1,480,349 | 3.8% | ambiguousLanguage, 33.9 MB |
| Human | Development | 5,520,213 | 4,123,883 | 74.7% | ambiguousLanguage, 1.0 MB |
| Assistant | Regression | 5,141,242 | 198,097 | 3.9% | ambiguousLanguage, 4.5 MB |
| Human | Regression | 751,165 | 569,797 | 75.9% | ambiguousLanguage, 0.1 MB |

Of the annotated positive turns, 152 of 165 (development) and 16 of 18 (regression) have at least one vector. The 13 development positive turns without one were refused as ambiguousLanguage (12), codeLike (2) and nonEnglish (2); one turn can have several reasons.

### Fusion re-ranks lexical hits by whether they have a vector

Every source in the semantic population receives `1/(60 + semantic rank)`, however low its cosine. A lexical hit with a vector therefore always gains a bonus over one without. A lexical hit at rank 1 with no vector scores 1/61, about 0.0164. A lexical hit at rank 30 with semantic rank 5 scores 1/90 + 1/65, about 0.0265. The fused top 16 then go to sources with vectors, which are mostly human turns.

Development cohort, over the 90 eligible attempts:

| Lexical primaries 1–16 | Count | Dropped from the fused top 16 | Dropped share |
|---|---:|---:|---:|
| Assistant, no vector | 633 | 592 | 94% |
| Assistant, with vector | 123 | 24 | 20% |
| Human, no vector | 39 | 35 | 90% |
| Human, with vector | 624 | 43 | 7% |

The fused top 16 took in 715 entrants: 648 lexical hits ranked 17 to 100 that have a vector, and 67 semantic-only sources. Regression shows the same pattern. There, 65 of 84 unvectorized assistant primaries were dropped against 3 of 80 human primaries with vectors; the entrants were 60 lexical hits ranked 17 to 100 and 16 semantic-only sources.

Slot allocation compounds this. Exchange expansion fills the same 16 traced slots with each primary's adjacent message, so only 8 to 15 primaries survive in either arm (lexical: 8 to 15 per attempt). In the hybrid arm's traced slots, primaries reached only by the semantic path occupied 16 of 1,440 development slots, and their neighbors another 16. Semantic-only displacement is therefore minor. The loss comes from reordering which lexical hits keep the surviving primary slots.

### Cases lost and won

Development: hybrid loses 15 cases that lexical passes and wins 5 that lexical misses. The global arm is identical. For each lost case, the lexical anchor of the missing turn is either the turn itself (a primary) or the primary whose adjacent message it is (a neighbor):

| Anchor of the lost turn in the lexical arm | Cases |
|---|---:|
| Human primary with a vector | 4 |
| Human primary without a vector | 4 |
| Assistant primary without a vector | 3 |
| Assistant primary with a vector | 1 |
| Neighbor of an assistant primary without a vector | 3 |

The lost anchors had lexical primary ranks 1 to 9. In hybrid, 8 of the 15 anchors fell outside the fused top 16. The other 7 had fused ranks 9 to 14 and were removed by the 16-slot expansion cap. In 13 of the 15 cases, no semantic-only result ranked ahead of the anchor. Five of the losses are in assistant recall.

All five hybrid wins came through a source with both lexical and semantic paths, never through a semantic-only result. In four, the anchor was a lexical primary ranked 11 to 16 that the lexical arm lost at the expansion cap; fusion moved it up. In the fifth, the anchor was a lexical hit ranked between 17 and 100. Both effects belong to candidate-window ordering (P2 step 3), not to semantic recall.

Regression: hybrid loses one case, `51c32626`. It wins none.

### The four known misses

| Case | Category | Positive turns | Vector coverage of positives | lexical | hybrid | global_hybrid | global_fill |
|---|---|---:|---|---|---|---|---|
| `51c32626` | Multi-session | 2 | both have vectors | both whole | first only | first only | both whole |
| `1b9b7252` | Assistant recall | 1 | none (ambiguousLanguage) | missed | missed | missed | missed |
| `4baee567` | Assistant recall | 1 | has a vector | missed | missed | missed | missed |
| `1a1907b4` | Preference | 1 | has a vector | missed | missed | missed | missed |

- **`51c32626`.** The first positive is lexical primary 1, with fused rank 1 in every fused arm. The second is not a primary. Lexical delivers it as the adjacent message of lexical primary 8 (traced rank 9), an assistant turn with no vector. Shipped and global fusion push that anchor out of the fused top 16, so the second turn is never traced. `global_fill` keeps the anchor and delivers both turns.
- **`1b9b7252`.** The positive turn has no vector, so no semantic variant can retrieve it under the current gate. It is outside every arm's 16 candidates. This matches the plan's diagnosis of a neighbor-block miss.
- **`4baee567`.** The positive turn has a vector, but it is not among the 16 fused results of either fused arm. Fusion would admit a semantic-only result only at a very high semantic rank, so its semantic rank is beyond that point. The audit does not record ranks beyond the 16 results. This matches the plan's diagnosis of a query with no lexical match.
- **`1a1907b4`.** The positive turn has a vector and is outside every arm's candidates. It was accepted earlier without its annotated turn.

No semantic variant recovers any of the three misses that are shared by all arms.

## Latency

### Cohort scale (measured, leased, three concurrent harness workers)

Times come from the global search's own stage timers inside ordinary preparation, with the episode lease active. Every stage that reads metadata or sources writes a durable accounting charge, and that dominates every stage except the vector loop.

| Development, 100 searches | global_hybrid p50 | global_hybrid p95 | global_fill p50 | global_fill p95 |
|---|---:|---:|---:|---:|
| Eligible vector rows | 273 (max 407) | | 273 (max 407) | |
| Vector loop: SQLite step, decode, dot product, per-source best | 1.6 ms | 1.8 ms | 1.6 ms | 4.8 ms |
| Vector stage: connection, identity, coverage, count, loop; four metered charges | 291 ms | 412 ms | 80 ms | 148 ms |
| Lexical stage (window 100 or 16 metered candidate loads) | 341 ms | 448 ms | 68 ms | 81 ms |
| Whole search | 745 ms | 985 ms | 258 ms | 342 ms |

Preparation time per attempt, development p50 / p95:

| Arm | p50 / p95 |
|---|---|
| lexical | 651 / 790 ms |
| hybrid | 2,856 / 3,762 ms |
| global_hybrid | 1,267 / 1,659 ms |
| global_fill | 840 / 1,015 ms |

Shipped hybrid is slower than `global_hybrid` with the same ranking. A likely cause, not separately measured: the shipped search verifies every inspected vector row against the store and writes a raw snapshot and a manifest to the sidecar, while the global search verifies only its 16 results. These histories have about 500 events, so none of this is an L1 measurement.

### Synthetic scale (measured, commit `9ca96cd`, benchmark binary `f337dd82…`)

Each sidecar holds one 512-dimension unit vector per synthetic source. Each row count ran five unleased searches with no lexical matches. One further search ran with the default episode limits (`EpisodeResources.developmentCaps`: 64 MiB of vector bytes and 100,000 metadata rows per episode).

| Vector rows | Vector loop p50 | Vector stage p50 | Whole search p50 | Default limits |
|---:|---:|---:|---:|---|
| 1,000 | 1.2 ms | 3.6 ms | 4.9 ms | admitted |
| 10,000 | 21 ms | 48 ms | 54 ms | admitted |
| 50,000 | 121 ms | 267 ms | 312 ms | refused: episode_budget_exceeded |
| 140,000 | 336 ms | 751 ms | 868 ms | refused: episode_budget_exceeded |

Whole-search time is close to linear, at about 6.2 microseconds per row beyond the first thousand. Vector stage minus loop is mostly the aggregate coverage query, which is also linear in sources.

### Extrapolation to 100,000 events (proposed estimate, not measured)

Basis: the development cohort averages about 492 events, 797 chunks and 282 vectors per history.

| Encoder coverage | Vector rows at 100,000 events | Unleased brute-force search | Vector bytes charged | Default episode budget |
|---|---:|---:|---:|---|
| Current English-only gate (0.57 vectors per event) | about 57,000 | about 0.35 s | about 117 MB | refused above about 32,750 rows, which is about 57,000 events |
| Every chunk vectorized (1.62 chunks per event) | about 162,000 | about 1.0 s | about 332 MB | refused |

In the leased path, the durable accounting seen at cohort scale (about 0.1 to 0.3 s per stage) comes on top of these figures. The shipped search at 100,000 events would inspect only the oldest 4,096 eligible chunks, about 7 percent of the vectors at the current yield, and report a partial index.

Against the gates: L1 has an interim target of 2 s and a release target of 0.5 s, both p95 over recent-only at 100,000 events. The vector stage alone would fit the interim target. At full coverage, it alone would exceed the release target before the lexical, read and accounting stages are added. Under the current per-episode vector budget, the global search fails closed (the Send fails with a budget error) beyond about 57,000 events. Deploying it would need a budget change, an index, or a smaller vector type. None of those is justified by the recall result.

## Recommendation (proposed)

1. **Turn semantic retrieval off the ordinary path.** Ordinary Send should use the lexical selection that the `lexical` arm measures: hybrid strategy, no semantic index. On both cohorts it is strictly better than the shipped fusion (+10 development cases, +1 regression case, 11/11 assistant recall against 6/11). It is never worse in any category, and it is about 2.2 s faster at p50 per preparation on these histories. This needs a product change outside this package: the GUI and coordinator wiring of `semanticIndex`. This package does not change the shipped default. (Adopted; see [Decision](#decision).)
2. **Do not adopt `global_hybrid`.** On cohort-size histories it is the shipped ranking. Its loss mechanism is the fusion itself, not the population.
3. **Do not adopt `global_fill`.** It can only match lexical (60/90, 9/12). It won no case in 114 attempts, adds about 0.2 s of search and an encoder call, and fails the default episode budget at about 57,000 events.
4. **Stop spending background maintenance budget on the semantic index for the ordinary path**, as step 4 directs when fusion does not raise R2. Keep `SemanticIndex` and its contracts for the explicit memory browser and later experiments.
5. **Step 5 (encoder).** Coverage holes from the English-only gate showed up clearly. About 96 percent of assistant bytes and 25 percent of human bytes have no vector, and they cause the measured fusion losses. But step 5's precondition is that step 4 shows semantic value. Step 4 did not: across 114 attempts, no semantic-only result produced a case that lexical missed. A full-coverage encoder would remove the coverage bias in fusion, but whether semantic recall would then add cases is unmeasured. That decision belongs to the plan owner.

The two fusion wins point at P2 step 3, wider windows and cost-aware packing, rather than at semantic recall. Four of the five recovered turns came from lexical primaries ranked 11 to 16, lost at the 16-slot expansion cap.

## Decision

**User decision, October 8, 2026.** The user accepted recommendations 1 and 4: semantic retrieval is off for ordinary Send, and the application no longer runs background semantic indexing. This section describes **implemented** code and **measured** confirmation; the earlier sections remain the evidence.

### What changed (implemented)

- **One named policy.** `SemanticRetrievalPolicy.ordinarySend` in `Sources/Boros/SemanticRetrievalPolicy.swift` is `.disabledByPolicy`. It governs both decisions below. Setting it to `.enabled` restores fused retrieval on ordinary Send and background semantic maintenance together.
- **Ordinary Send retrieves lexically.** Every ordinary user-answering path passes the policy:
  - selected-Qwen GUI Send (`AnswerAttemptCoordinator`, constructed in `BonsaiPlayground.sendSharedAttempt`);
  - native-profile GUI Send (`ChatContextPreparation.prepare` on the preparation queue);
  - the `--ui-self-test` observation of that native path, so the check sees what Send does.
  
  The coordinator and `ComponentContextPreparationOperation` drop the index when the policy withholds it, and `ChatContextPreparation` ignores any index it is still handed. Preparation is the `lexical` harness arm: the hybrid strategy with no semantic index, the any-term lexical query, primary completion and the v1/16 exchange expansion. No query embedding and no vector read occur.
- **Honest audits.** Under the policy, the retrieval audit records `"semantic_retrieval": "disabled_by_policy"` next to `"mode": "lexical"`. The audit is persisted with each invocation's admission record. Before this change, a missing index recorded only `"semantic_available": false`, and the status line said "Archive recall used lexical search; semantic recall is unavailable." Under the policy, that notice is no longer shown, because lexical selection is the intended path. The bounded-window notice ("Archive recall inspected a bounded lexical candidate window; additional evidence may remain.") still appears when it applies. `semantic_available: false` is kept for compatibility with existing consumers and remains true as a statement: no index was used. A preparation that receives no index without the policy (for example the `lexical` harness arm or the imported-chat lexical protocol) still reports "unavailable" as before.
- **No background semantic indexing.** At launch the application no longer constructs `SemanticIndex`. Constructing it ran the metered two-sentence encoder probe and took the sidecar owner lock. Startup and post-Send maintenance triggers no longer schedule semantic work; both go through `ApplicationSemanticMaintenance`. The Background Indexing Status sheet now says "Semantic indexing is turned off by policy. Ordinary Send searches original sources lexically, and no background encoder work is scheduled." It also says that sidecar files from earlier versions remain on disk unused. The durable allowance counters it shows are unchanged.
- **Harness arm `ordinary_send`.** This arm opens the history's real semantic index and passes it through `SemanticRetrievalPolicy.ordinarySend`, exactly as the GUI does. The report compares it with `lexical` on every history and checks three things: delivered ranges, traced candidates, and the recorded policy.
- **Contract checks.** Sixteen synthetic contracts in `Sources/Boros/SemanticRetrievalPolicyChecks.swift` run inside `--semantic-self-test`. They cover:
  - the policy value;
  - status wording that reports neither failure nor unavailability;
  - no sidecar, owner lock or probe charge when the application opens under the policy;
  - no scheduled semantic work: no encoder call and no ledger window;
  - lexical indexing continuing;
  - an explicit on-demand build still publishing vectors;
  - ordinary Send preparation running no semantic search and recording `disabled_by_policy`, with selection identical to the no-index lexical call;
  - native-profile preparation under the same policy;
  - the coordinator dropping the index for ordinary Send;
  - explicit evaluation hybrid still receiving the index, ranking with fusion and writing a manifest;
  - a missing index without the policy still reported as unavailable.

### What did not change

- `SemanticIndex.swift`, `GlobalSemanticSearch.swift`, the main store schema, the semantic sidecar schema and the background ledger are unchanged. Lexical FTS indexing is synchronous with capture and unaffected.
- Explicit paths still construct and use an index on demand with the `.enabled` default:
  - `AnswerEvaluationCommand` hybrid attempts;
  - the harness `hybrid`, `global_hybrid` and `global_fill` arms;
  - the imported-chat `hybrid_context` protocol;
  - `--semantic-self-test` and the background worker suites.
  
  `hybrid` still means fused retrieval. `AnswerEvaluationCommand`'s `ordinary-v1` preparation mode still builds an index for hybrid attempts, so its hybrid arm now measures the explicit fused configuration, not shipped Send.
- The native investigation route never used the semantic index and is unchanged.
- The Memory source browser uses lexical and literal search only and is unchanged.
- **Existing vectors are not deleted.** A store that earlier versions indexed keeps its `semantic/` sidecar on disk; the application neither opens nor removes it. Deletion requires its own contract (AGENTS.md). For scale, the cached harness stores hold LongMemEval public histories, not a user store. Across 242 cached histories of 409 to 608 events, the sidecar was 1.8 to 3.0 MB per history (median 2.2 MB). That is about 4.5 KB per event against about 22.7 KB per event for the main store. Each stored vector is 2,048 bytes (512 float32 values). A linear extrapolation to 100,000 events at the current English-only yield gives about 450 MB of sidecar. That figure is an estimate, not a measurement. Backups already exclude the sidecar. A restore therefore no longer rebuilds one in the background under the policy.

### Cost that stops (from existing records)

- **At every launch:** one reserved and armed background work item, the two-sentence public encoder probe (2 encoder calls, 65 input bytes), and opening the sidecar database.
- **After every Send and at launch:** a scheduled worker slice of up to 128 chunks (`maximumChunksPerRun`). Each chunk is one Apple encoder call over up to 1,024 bytes, a source read and seal under the logical-work recipe, and a vector publication. All of it was charged against the daily allowance in [BACKGROUND-INDEX-BUDGET.md](BACKGROUND-INDEX-BUDGET.md): 4,096 encoder calls, 16 MiB encoder input, 512 MiB logical source work, 32 MiB vector publication, 100,000 metadata rows and 4,096 new source jobs per 24-hour window.
- **Wall time:** building an index for one roughly 500-event history took 19.2 s (development) and 17.1 s (regression) at p50 in the P1 harness ([RETRIEVAL-HARNESS.md](RETRIEVAL-HARNESS.md)). This is the closest recorded proxy for background work per 500 events.
- **Not recorded:** energy and physical disk I/O.
- **Per Send:** hybrid preparation took 2.9 s against 0.65 s for lexical (development p50, above). That difference included one query embedding and the sidecar search, manifest and raw-snapshot writes.

### Measured confirmation

Regression cohort, one replicate, three workers. The run used this change's working tree on top of `dd389da` (the report records `working_tree_modified: true`). Harness binary SHA-256 `994bf9fc…`, build digest `72f31f6a…`, ingestion digest `925bba6e…`. Private report: `.build/evaluation/semantic-off-regression.json`. Editing the harness source changed the store cache key, so all 14 stores were rebuilt; no cache was reused. There were zero preparation failures, zero runner starts and zero refused generation requests.

| Arm | R1 | R2 | Turns whole | Preparation p50 / p95 |
|---|---:|---:|---:|---|
| lexical | 9/12 | 9/12 | 15/18 | 626 / 1,016 ms |
| ordinary_send (GUI configuration, real index withheld by policy) | 9/12 | 9/12 | 15/18 | 629 / 2,497 ms |
| hybrid (explicit fused retrieval) | 8/12 | 8/12 | 14/18 | 3,013 / 5,136 ms |

`lexical` 9/12 and `hybrid` 8/12 reproduce the earlier records. In all 14 histories, `ordinary_send` matched `lexical` on three counts:
- the same recent sources and delivered byte ranges;
- the same traced candidates, with no trace omitted in either arm;
- a preparation that received no semantic index and recorded `disabled_by_policy` with `mode: lexical`.

The development cohort was not rerun. Its ordinary Send figure, 60/90, is the `lexical` measurement above, and this equivalence is what carries that figure over. The `ordinary_send` p95 includes one slower attempt under three concurrent workers; its median matches `lexical`. Semantic index construction for these stores took 21.0 s at p50 and 25.6 s at p95 per history, 11,180 chunks published in total. That cost is now confined to explicit builds. `python3 scripts/check.py` passes with 4,420 checks. These include the 16 policy contracts and 25 recall-floor comparisons; the floor now holds `ordinary_send` at the lexical figures, 9/12 and 15/18.

## Limits

- One replicate. Selection is deterministic; latency was measured under three concurrent harness workers.
- LongMemEval positive-turn annotations are a proxy for sufficient spans, as in P1.
- **Store reuse.** The cached P1 stores were reused. Adding arms changed the harness source, and with it the store cache key. The ingestion code (`ensureCache` and every ingestion source) is byte-identical, so the cached directories were cloned to the new key rather than rebuilt. The unchanged arms reproduce the P1 numbers exactly, which confirms the reuse.
- **Delivery audit size.** Development delivery audits sit close to their 32 KiB cap. A first run that also recorded per-result identities and ranks in the global audit dropped the selection trace from all 100 attempts of each global arm. Selection and R2 were identical in that run. The committed audit keeps only the parameter digest, the row count and timings. Even so, `global_fill` dropped its trace in 5 of 100 development attempts. R1 for those five is scored from delivered evidence. R2 is unaffected, and evidence containment was checked on all 114 attempts.
- **Unrecorded semantic ranks.** The shipped manifest records the 16 fused results only. Semantic ranks of turns outside them, as in `4baee567` and `1a1907b4`, are not recorded.
- **Synthetic scale.** The scale run uses synthetic one-chunk sources and random vectors with a warm page cache. The 100,000-event figures are linear extrapolations from it and from cohort chunk yields, not measurements of a 100,000-event archive.

## Reproducing

```bash
python3 scripts/retrieval_harness.py --cohort development --workers 3 --output .build/evaluation/<new>.json
python3 scripts/semantic_decision_diagnosis.py --cohort development --report .build/evaluation/<new>.json --output .build/evaluation/<new>-diagnosis.json
python3 scripts/global_semantic_scale.py --rows 1000 10000 50000 140000 --repeats 5 --output .build/evaluation/<new>-scale.json
```
