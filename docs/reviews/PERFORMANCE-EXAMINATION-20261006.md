# Boros performance examination and repair direction

October 6, 2026. This examination compares the original Optchat design, current Boros execution paths, retained retrieval experiments, cross-model controls and primary research. Independent agents reviewed design provenance, retrieval code and evaluation defects. Private questions, answers and histories are excluded.

## Assessment

Boros has a durable evidence store, but its current memory strategy is weak. It performs one retrieval pass, ranks isolated message excerpts and packs them by position. It lacks the whole-history orientation and interactive zoom that motivate Optchat. A separately identified SQL planning defect caused impractical large-history latency; this examination repairs it and measures a large improvement in the standalone native path.

The evidence supports pursuing better memory behavior. It does not support promising reliable recall from the current implementation. Development hybrid answering already outperforms recent-only under the existing local judge; clean evidence improves two known retrieval failures, and Sol performs better than Qwen on the five curated controls. Those observations justify focused improvements. The uncalibrated judge and small reused cohorts prevent a representative accuracy claim.

Implementation effort has concentrated on accounting, source integrity and recovery before establishing strong retrieval and reading. Further policy, service or release work will not resolve these failures. The next development slice should improve what evidence the model receives and how it uses that evidence.

## What the original idea supplies

The supplied Optchat specification describes a bounded whole-history view formed from recent detailed nodes and older summaries, with exact expansion through zoom. It estimates its proposed 128,000-byte view at roughly 64,000 tokens; Boros's selected total context is 32,768 tokens. That estimate does not establish a count under Boros's tokenizer. Its reported cache overlap and anecdotal summary-size results are useful design evidence; the specification supplies no reproducible comparative answer-quality experiment. The source lineage is recorded in [GUI-ORIGIN.md](../GUI-ORIGIN.md).

The public [OptMem implementation](https://github.com/VictorTaelin/OptMem) exposes a bounded `wake` view, exact regex `recall`, and `zoom` into tree children. An agent decides when to invoke those tools. OptMem records agent-authored short memories; Boros preserves complete accepted messages. OptMem's reported 0.03-second view construction at a million memories excludes model answering and summary creation. Its implementation and README do not establish Optchat benchmark accuracy.

| Capability | Original design / public prior art | Current Boros |
|---|---|---|
| Whole-history orientation | Bounded view covers older regions through summaries | Recent messages plus selected historical excerpts; no whole-history overview |
| Recovery of an omitted detail | Agent can search or zoom and read again | Ordinary answering performs one historical search pass |
| Retrieval unit | Addressable historical regions, expandable to original material | One selected range per message source, then optional adjacent prefixes |
| Summary construction | Optchat proposes background compaction; OptMem asks the agent to merge | No tree construction; complete original sources remain available |
| Context and maintenance cost | Large cached view and compression work | Smaller context, explicit recent/evidence caps; total economics unmeasured |

We should test the orientation-and-expansion behavior directly. Copying a tree without letting the model read its relevant leaves would leave the central retrieval problem unresolved. OptMem's architecture also cannot be credited for quality on raw chat archives merely from its view-rendering speed.

## Failure causes and confidence

| Layer | Evidence | Diagnosis | Required change |
|---|---|---|---|
| Query | `HistoricalQueryFormulation.swift` keeps eight non-stopword terms, quoted anchors first, then prompt order | A question's entities, requested relationship or time condition can lose priority; no decomposition | Preserve entity/literal anchors and formulate bounded question-specific searches |
| Candidate reach | Apple English support excludes some code, multilingual and ambiguous queries; vector search inspects the first chronological 4,096 eligible chunks | Later indexed material cannot win that pass; no global nearest-neighbor search | Evaluate a suitable dense retriever and search the full eligible index, with measured bounded execution |
| Ranking | Fusion collapses to one range per source; semantic ranks contribute without a calibrated relevance cutoff, and a fused lexical hit retains its lexical range | Topical matches and the wrong range can occupy scarce slots | Rank answer-relevant exchanges/windows, retain useful distinct ranges, and calibrate relevance on fresh cases |
| Packing | Wider neighborhoods recover no additional full positive turns; all fourteen contexts lose 13–21 spans to tokens | Increasing candidate count followed by prefix removal evicts useful companions | Select complete evidence units for relevance, requested-fact coverage and token cost before final counting |
| Reading | Two newly rejected experimental answers received all annotated positives; on clean packs Sol receives 4/5 acceptance and Qwen 2/5–3/5 | Delivered bytes alone do not establish useful reasoning; answerer capability and presentation matter | Compare readers on identical delivered packs; test extraction of relevant facts before final answering |
| Judging | Same-model baseline judge is source-blind; source-aware Qwen gives identical evidence contradictory sufficiency labels across candidates | Scores cannot reliably attribute every error or certify groundedness | Freeze source-only sufficiency and required facts before judging candidate answers; calibrate coverage and claim support separately |
| Latency | 100k legacy automatic-context p95 exceeded 111 seconds; isolated FTS-first SQL removes repeated matching | A join-plan defect dominates that measured search path | Repair completed: fresh native warm p95 is 0.621 seconds; full GUI/Qwen preparation remains unmeasured |

The semantic reach and fusion weaknesses are code-supported risks. They have not been established as the causes of the four specific missing turns. Missing-turn and token-eviction attribution is stronger: the matched neighborhood experiment recovers zero of those four turns, and replay places three needed companions beyond the retained prefix. See [the architecture reassessment](ARCHITECTURE-REASSESSMENT-20261006.md).

All ten clean-pack answers complete below the 1,024-token non-reasoning allowance, with observed usage between 50 and 695. Their source-ID citations resolve to supplied records. Hard output truncation and invalid source IDs are not the causes of these clean-pack failures; instructions favoring conciseness could still affect omissions. Citation existence and reference-word overlap cannot establish relational correctness. This is a content-free diagnostic assessment; independent semantic adjudication remains unfinished.

## Repair implemented during this examination

`MemoryStore.lexicalCandidateReferences` and `MemoryStore.search` now use `event_fts CROSS JOIN events` with the existing equality, scope, frontier, exclusions, BM25 ordering and limit. SQLite's [documented CROSS JOIN behavior](https://www.sqlite.org/optoverview.html#manual_control_of_query_plans_using_cross_join) fixes the outer-loop order. It prevents the event-project index from driving repeated FTS matching.

Seven focused contracts execute both actual native SQL projections through macOS system SQLite. They compare every ordered projected value with the prior JOIN shape and check mixed scope, exact identity, frontier/exclusions before limits, all/any terms, tied scores, Unicode, quoted terms, original bytes and metadata. Query-plan checks verify FTS matching precedes event primary-key lookup.

A fresh optimized native 100,000-event warm/restart diagnostic is recorded separately in [SCALING.md](../SCALING.md). Both profiles complete with unchanged required-span recovery. Lexical endpoint p95 falls from 3.635 to 0.0133 seconds warm, and legacy automatic-context memory p95 from 111.668 to 0.621 seconds; restart values are 0.0154 and 0.479 seconds. Literal scanning remains about three seconds. Its source capture includes the current working-tree dependencies, with other differences from the earlier wave, so the whole-path ratio is not a sole-change causal estimate. It validates the standalone Swift retrieval path; it does not rebuild or measure GUI Send, Qwen admission or answer generation. The earlier app's 3,887 checks remain attached to its original source capture.

## Next quality implementation

The user subsequently authorized moving whole-history orientation followed by deliberate search/zoom into the immediate experiment. The [early pilot](../ORIENTATION-ZOOM-PILOT.md) compares a standalone lexical complete-exchange control, the same control with bounded inspection, and inspection with a question-blind overview. This directly tests the original interaction model before further baseline tuning. It uses a fixed Sol final reader and original evidence only; native integration remains separate. The remaining repairs follow the pilot's failure attribution:

1. **Retrieve exchanges, then select evidence.** Preserve exact original messages and authorship. Form bounded conversational rounds/windows containing useful antecedents and replies. Search more candidates than will be delivered; rerank those units against the complete question, then choose useful units within the existing evidence allocation. Keep unrelated high-rank anchors from consuming space while their answer-bearing companions are removed.
2. **Improve query and index reach.** Compare sparse retrieval with a supported dense retriever that makes all eligible indexed chunks searchable within measured budgets; this need not scan every vector per turn. Add question-specific entity and time searches; preserve unknown dates and unresolved temporal scope. Fact or summary keys may help locate original rounds, but generated keys must never replace original evidence or enter scorer expectations.
3. **Let the reader request missing evidence.** Prototype a bounded search/read cycle that can issue a revised query or expand an identified region when a requested fact is missing. Start with at most one additional retrieval round. Count planner/reranker/reader calls against the same total budget, and retain the single-pass arm to measure whether the additional work earns its latency.
4. **Test structured reading and reader choice.** Compare direct answering with private extraction of relevant facts and source references before the final answer. Extracted notes can introduce errors; final claims must remain supported by original sources. Compare Qwen and Sol with identical evidence and output rules. This is a diagnostic model comparison; a remote application adapter requires its own integration work.
5. **Promoted immediate experiment: orientation and inspection.** Build an offline, bounded summary view for a fresh cohort, with source-linked regions and explicit expansion. Compare the same baseline with inspection alone and with orientation plus inspection. Measure summary creation as well as turn cost. A full asynchronous tree is unnecessary for this decision.

These changes follow evidence from [LongMemEval's primary study](https://arxiv.org/html/2410.10813v2): conversational-round granularity, fact-expanded retrieval keys, time-aware queries and extraction before reasoning improved the tested systems. Their gains are external results, not predictions for Boros. [The authors' code](https://github.com/xiaowu0162/LongMemEval) supplies sparse/dense retrieval and reading baselines that can provide a useful external control. RAPTOR also supports testing summary-assisted retrieval, but its clustered semantic tree differs from Optchat's chronological binary tree; [its results](https://arxiv.org/abs/2401.18059) do not establish that Boros needs the latter.

## Evaluation that decides whether the repair works

Use a small fresh cohort first: 30 histories selected without answer labels, stratified across the published question categories, with the existing known failures retained only as regressions. Freeze the selection and experimental configurations before inspecting new outputs. This pilot diagnoses effects; it will not justify representative product claims.

Separate the pipeline into candidate recall, delivered evidence, reading success with authenticated sufficient packs, end-to-end answering and stage latency. Record omitted required relationships as well as positive-turn delivery. Assess sufficiency once per pack without candidate answers, mapping required facts to original sources; unresolved packs remain unresolved rather than being silently dropped. Blinded assessment must distinguish incorrect facts, omissions, unsupported additions, correct abstention and ambiguous references.

Run the promoted orientation/inspection package comparison first, retaining its inspection-without-overview arm to measure the overview's contribution. Subsequent isolated comparisons cover native selection versus exchange selection using the same reader, and direct versus extraction-based reading on the same packs. Reuse authenticated unchanged captures where appropriate, retaining their original experiment identity. Compare both readers on the same delivered evidence when investigating reader capability. Keep scorer annotations out of every selector and generation request.

Freeze acceptable latency, model-call and token/cost ceilings with each pilot configuration before observing outputs. Retain the existing product targets of at most 500 ms added memory p95 and 10% added total-episode p95; explicitly report where experimental arms miss them. Advance when a fresh paired result improves supported answers and evidence recovery within its declared ceilings. Report per-category results, failures, model calls and total turn costs. Repeated matched runs and an independent confirmation set follow a promising pilot. Contract checks establish correctness of the implementation; they cannot replace this behavioral decision.

The immediate direction is better question-specific retrieval, complete evidence units and deliberate reading. The SQL repair addresses a measured bottleneck now. The orientation/zoom comparison gives the original Optchat idea a concrete test instead of assuming it will succeed or postponing it indefinitely.
