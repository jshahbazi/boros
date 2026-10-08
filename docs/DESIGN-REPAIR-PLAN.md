# Design repair plan

Written October 7, 2026 in response to the [design and test assessment](reviews/DESIGN-AND-TEST-ASSESSMENT-20261007.md). This is proposed design. Nothing in it is implemented or measured unless the linked record says so. It keeps the product decision in [the plan](../tracechat-plan.md): preserve accepted history, retrieve relevant evidence, make limits visible. It changes the order of work and what counts as progress.

## Principles

1. **Quality evidence precedes architecture.** No new schema, authority, service, deletion or tree work until the retrieval and answering gates below have a measured value on a registered cohort.
2. **Measure stages separately.** Candidate recall, delivered recall, reader success on sufficient packs, end-to-end acceptance, latency and cost are six numbers. A change is judged by the stage it targets.
3. **Retrieval is evaluated without a model.** Required-span recall is computable offline from annotations in seconds. Iterate retrieval there, and spend model and judge calls only on configurations that already clear the offline gate.
4. **Check counts are not progress.** Contract checks stay as regression protection. Status documents report the six stage numbers and their cohort sizes.
5. **Reuse what already works.** The investigation engine's full-index, rarity-weighted exchange search found all four missing turns on the local repeat. Port its selection into the ordinary path rather than tuning the eight-term query.

## Gates

These restate the plan's targets with the stage split and realistic interim thresholds. Interim values are decision points for the next step, not release criteria.

| Gate | Measure | Interim target | Release target (plan) |
|---|---|---|---|
| R1 candidate recall | Fraction of annotated positive turns present in the ranked candidate set before packing | 95 percent | 95 percent (Gate 2) |
| R2 delivered recall | Fraction of annotated positive turns delivered whole after packing and token fitting | 90 percent | 95 percent (Gate 2) |
| A1 reader on sufficient packs | Independently accepted answers when every required turn is delivered | 80 percent | Set from A1 measurement |
| A2 end to end | Independently accepted answers over all declared questions, abstentions included | Better than recent-only with a 95 percent lower bound above zero | Plan Gate 4 and 5 terms |
| L1 memory latency | Added memory-path p95 over recent-only at 100,000 events | 2 seconds | 500 milliseconds (Gate 6) |
| L2 turn cost | Model calls and input tokens per turn over recent-only | At most 3 calls and 40,000 tokens | Declared with the workload |

Cohort: at least 100 answer-blind, category-stratified LongMemEval histories with opaque identities, three replicates for any model-involved result, abstentions retained in the denominator. The 51 previously used question identities stay out of every new cohort.

## Work packages

Dependency order. Each package names its exit evidence. Packages P1 to P3 require no model calls and no spending.

### P0 Consolidate branches

Merge `codex/boros-foundation` into `main`, commit or discard the uncommitted working tree in the original checkout, rebase `codex/native-investigation` onto the result, and make `main` the only development branch. Record which experimental defaults are on (`v1/16` ordinary selection, investigation off). Exit: one branch, clean status, `scripts/check.py` passes on it, STATUS.md describes files that exist.

### P1 Offline retrieval harness

Build a model-free harness over the pinned LongMemEval S file that ingests each selected history into a temporary store, runs the actual native selection path through the existing CLI projection, and scores R1 and R2 against the scorer-only annotations. It must run all 100 cohort histories in minutes, report per category, retain every failure, and never expose annotations to the selector. Reuse the existing answer-blind selection, opaque-identity projection and v8 provenance pins. Exit: R1 and R2 for the current `v1/16` default on the 100-history cohort, recorded with cohort manifest hash. This number becomes the baseline every retrieval change is compared against.

### P2 Retrieval repair

Implement in the ordinary native path, each measured on P1 before the next:

1. **Exchange units.** Index and retrieve complete human/assistant rounds as the ranking unit, delivering whole units. This removes the directional neighbor defect that caused three of four misses. The investigation engine already has the exchange index; make it a persistent, incrementally maintained store structure rather than a per-turn rebuild.
2. **Full-question query.** Replace the eight-term prompt-order selector with the investigation engine's rarity-weighted content-term search over the whole question, keeping quoted anchors as mandatory terms. Keep OR semantics but rank by weighted term coverage and unit byte cost.
3. **Wider candidate window, cost-aware packing.** Retrieve more candidates than will fit, then pack by relevance per token under the 12,000-token evidence cap, rather than rank order followed by geometric prefix removal. Protect mandatory units; make every omission an explicit receipt.
4. **Global vector search.** Replace the chronological 4,096-chunk population with a search over every eligible chunk. At the current corpus scale a brute-force cosine pass over all vectors is cheap enough to measure before building an index. Measure on P1 whether semantic fusion raises R1 over lexical alone; if it does not, keep semantic off the ordinary path and stop spending maintenance budget on it.
5. **Encoder decision.** If step 4 shows semantic value but coverage holes from the English-only gate limit it, evaluate one locally runnable multilingual code-tolerant encoder on the same offline harness. Do not change encoders on reach arguments alone.

Exit: R1 at or above 95 percent and R2 at or above 90 percent on the 100-history cohort, with the 100,000-event standalone latency profile rerun.

### P3 Latency and cost of the investigation route

The investigation loop meets quality on three cases and misses L1 and L2 by an order of magnitude. Reduce it before any broader quality run:

1. Build the map and exchange index once per store and maintain them incrementally under the existing background budget. Rebuilding per turn is the first cost to remove.
2. Reduce the loop to one planner call and one final call by default. Keep the extraction stage and additional actions behind a setting until A1 shows they add accepted answers.
3. Reuse prompt prefixes across private stages so mlx-serve's cache applies; measure with the provider's usage receipts.
4. Set the turn deadline to the L1 target and report every deadline failure.

Exit: investigation p95 added latency and token cost on the three-case repeat recorded against L1 and L2; a decision on whether the route can become the ordinary path or stays an explicit mode.

### P4 Judge calibration

Before any model-involved quality claim:

1. Assemble a blinded calibration set of at least 50 saved answers across accepted, rejected, abstention, incomplete evidence and correct-plus-unsupported cases, adjudicated by a person against the reference and the delivered evidence.
2. Measure false-accept and false-reject rates for JevK5, Qwen-as-judge and Sol-as-judge against that adjudication, per category.
3. Select the judge or ensemble with the lowest error, record the rates, and report every later acceptance with those rates attached.
4. Keep answerability cues out of every model-visible identifier; the v8 opaque projection is the required baseline for all cohorts.

Exit: recorded judge error rates; the LongMemEval local labels from earlier waves annotated with the measured rate of their judge.

### P5 Reader decision

With P2 delivering sufficient packs, measure A1 on identical delivered evidence for the selected Qwen, at least one larger locally runnable model, and Sol as an upper reference. Compare direct answering with the investigation route's quote-extraction step. Decide the default reader on A1, latency and the remote-processing boundary. A remote default requires the plan's egress and disclosure contracts first; this package only produces the measurement that would justify that work.

Exit: A1 per reader on the 100-history cohort, three replicates.

### P6 Registered comparison

Freeze the configuration from P2, P3 and P5, register a fresh held-out cohort disjoint from everything used so far, and run the plan's arm comparison for recent-only, ordinary hybrid and investigation. Report all six gate numbers with intervals. This is the first result that may be described as product quality.

### P7 Resume deferred architecture

Only after P6: authority lifecycle, deletion and restore fencing, service and MCP boundary, and the tree decision under the plan's Gate 4. Each remains gated on the registered baseline it is compared against.

## Testing changes

- Add the P1 harness to `scripts/check.py` with an R1 and R2 floor set from the last accepted result. A build that lowers recall fails the check, in the same way a broken ledger does today.
- Move `*Checks.swift` out of the shipped binary into a separate test executable sharing the sources. The product bundle should not carry 7,500 lines of fixtures.
- Report in STATUS.md one table of the six gate numbers with cohort size, replicates, judge error rate and source capture hash. Retire check-count headlines.
- Require every quality document to state which stage it measures. A delivered-turn number is not an answer number, and an accepted-answer number without a judge error rate is a model opinion.

## What this plan does not do

It does not promise that the local Qwen model can meet A1; P5 decides that. It does not adopt a summary tree; P7 keeps it gated. It does not enable remote processing; P5 produces only the measurement. It does not resume the held paid experiments; P4 and P6 require their own authorization and spending caps. It does not rewrite the storage, episode or backup layers, which pass their contracts and are not the cause of the failures.
