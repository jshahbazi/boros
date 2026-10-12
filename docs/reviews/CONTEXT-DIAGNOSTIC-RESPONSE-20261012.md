# Response to the OptChat long-history diagnostic

Review date: October 12, 2026. This review reads the completed 20-question BEAM comparison (`docs/evaluation/beam-expanded-memory-results.md`), its source-coverage diagnosis (`optchat-boros-quality-diagnosis.md`) and the six-question context diagnostic with its confirmation (`boros-context-diagnostic-results.md`), all recorded in the OptChat repository against Boros revision `f28584bb621e0900563f57b768846d9f06f875fd`. It maps each measured failure to the Boros code that produced it, records what has changed in Boros since that revision, and proposes the next work in order. No model call, runtime change or default change was made for this review. Questions, answers, references and original conversation text remain private; the question labels below are the SHA-256 prefixes the diagnosis uses.

Each section states whether it describes implemented behavior, measured results or proposed design.

## Judgment

The comparison does not show that OptChat's architecture answers better. It shows three separable Boros weaknesses and one property of the shared local model:

1. **Retrieval coverage** is the largest and the only one with a measured fix already in the tree. Boros delivered 17 of 83 author-resolved gold sources across the 20 questions, and 8 of its 14 misses had no or almost no gold source in the request. The P2 `exchange_packed` policy, opt-in since October 8 and backed by a persistent index since October 12, replaces every mechanism the diagnosis names. It lacks answer-quality evidence because no answering runner can select it yet.
2. **Context use** failed on one knowledge-update question where the updated fact was in the request. Two unrelated 20-token and 3,400-token changes to the request each fixed it on all three repeats. This is a presentation effect that needs a controlled comparison across more questions before anything is promoted.
3. **Contradiction resolution** failed under every one of nine conditions, including an oracle source pack of under 1,000 tokens. That is a reader limit under this request style, not a retrieval or framing problem, and belongs to the reader decision (P5), not to retrieval work.
4. **Generation instability** at temperature zero flipped one verdict between byte-identical requests. Single-replicate differences of one or two questions, including part of the four-question gap in the 20-question comparison, are inside this noise.

OptChat's own failures (four aborted runs from an exhausted tool-result window and three wrong answers taken from the summary overview without reading a source) argue for keeping Boros's single-call bounded assembly and improving what goes into it, not for adopting a navigation loop.

## What the comparison and diagnostic established (measured)

### The 20-question comparison

| Arm | Correct | Answer failures | Answer calls | Gold sources delivered / complete / resolvable |
|---|---:|---:|---:|---:|
| OptChat | 10/20 | 4 | 141 | 34 / 12 / 83 |
| Boros ordinary Send | 6/20 | 0 | 20 | 17 / 16 / 83 |
| Recent control | 3/20 | 0 | 20 | 0 / 0 / 83 |

Paired: both correct 6, OptChat only 4, Boros only 0, neither 6, excluded for an OptChat failure 4. Boros's 20 requests used 11,521 to 15,580 prompt tokens (median 13,280) of the 29,696 the 32K envelope permits after the 2,048 output and 1,024 safety reserves.

The per-question public metadata separates Boros's 14 misses by what the request contained:

| Miss class | Questions | Category (gold delivered / resolvable) | OptChat on the same question |
|---|---:|---|---|
| Gold sources absent or nearly absent | 8 | event ordering `99c47ce2` (0/6) and `dd324d29` (0/9); information extraction `0e87bafe` (0/2) and `b5dc14dd` (0/1); multi-session `aa5aa5ee` (0/2) and `c396433f` (2/7); summarization `58e347d9` (0/26) and `feefc644` (2/15) | Correct on `c396433f` only; aborted on four; wrong on three |
| Every resolvable gold source delivered complete | 5 | contradiction `ab844202` and `cfe976a3` (2/2 each); instruction following `9cd27fcb` (2/2); knowledge update `cf558e11` (2/2); temporal `470fe812` (2/2) | Correct on `cfe976a3`, `9cd27fcb`, `cf558e11`; wrong on the other two |
| Abstention | 1 | `293323bf` (no resolvable source) | Wrong; the recent control was correct |

Gold delivery counts source presence, not factual sufficiency, and the two summarization questions need 26 and 15 sources, which no 12,000-token evidence component can hold whole. With that caveat, more than half of Boros's misses on this history are retrieval misses, and all four OptChat-only wins came with Boros holding the complete gold sources for three of them.

### The six-question diagnostic

Thirty-six first-wave answers, eight confirmation answers and the saved originals, all graded by the same frozen local grader:

| Case | Category | Native (saved, repeat 1, repeat 2, then two confirmation repeats for `cf558e11`) | Citation aligned | Review sentence (one answer; three for `cf558e11`) | Recent quotes removed (one answer; three for `cf558e11`) | Oracle pack | Oracle pack tokens |
|---|---|---|---|---|---|---|---:|
| `ab844202` | contradiction | 0, 0, 0 | 0 | 0 | 0 | 0 | 819 |
| `cfe976a3` | contradiction | 0, 0, 0 | 0 | 0 | 0 | 0 (and 0, 0 with the 35,577-byte OptChat overview added) | 892 |
| `9cd27fcb` | instruction | 0, 1, 0 | 0 | 0 | 0 | 1 | 619 |
| `cf558e11` | knowledge update | 0, 0, 0, 0, 0 | 0 | 1, 1, 1 | 1, 1, 1 | 1 | 967 |
| `c396433f` | multi-session | 0, 0, 0 | 0 | 0 | 0 | 1 | 4,668 |
| `d8952867` | preference | 1, 1, 1 | 1 | 1 | 1 | 1 | 579 |

Three facts matter for what to build:

- The knowledge-update request held the updated fact and failed five times natively. Appending one sentence to the system message (14,730 tokens) or removing the eight quoted recent messages (11,288 tokens) each recovered it three of three times. No evidence was added in either condition.
- The multi-session oracle pack is 4,668 tokens. Boros's native request for that question was 15,580 tokens with zero exclusions from any token limit. Budget was not the constraint; candidate selection was.
- Both contradiction cases failed with complete sources alone in under 900 tokens. More context (the overview, 25,585 tokens) did not help either.

Two of the six first-wave native pairs differed in answer bytes; one of those changed its verdict. All confirmation pairs were byte-identical within a condition. mlx-serve at temperature zero with a fixed seed is therefore not reproducible enough to read a one-question change as an effect.

## Mechanisms in the evaluated revision (implemented)

The diagnosis's code citations are to `f28584b`; the same code is still the ordinary Send path at `HEAD`, because the P2 policies are opt-in. Line numbers are at `HEAD`.

- **Query.** [HistoricalQueryFormulation.swift:79](../../Sources/Boros/HistoricalQueryFormulation.swift) keeps at most eight terms, quoted spans first and then prompt-order prose, so a multi-topic question loses every term after the eighth. [MemoryStore.swift:1226](../../Sources/Boros/MemoryStore.swift) joins them with `OR` under the `anyTerm` mode and [line 1235](../../Sources/Boros/MemoryStore.swift) ranks single messages by `bm25`, then newest first. A single message that happens to hold one common question term competes equally with the exchange that holds the answer. The earlier [source-selection trace](../STATUS.md#historical-source-selection-trace) showed the same limit from the other side: on the DevGPT probes the eight retained tokens came from the question's formatting instructions, before its source anchor.
- **Candidate window.** [ChatContextPreparation.swift:163](../../Sources/Boros/ChatContextPreparation.swift) asks for 16 primaries. [MeteredExchangeExpansion.swift:15](../../Sources/Boros/MeteredExchangeExpansion.swift) then expands preceding-human and following-assistant neighbors inside the same 16-candidate cap, in rank order. A neighbor added for a high-ranked primary consumes a slot that a lower-ranked primary needed; the audit records the evicted primary as `candidate_limit` ([lines 112 to 114 and 133 to 135](../../Sources/Boros/MeteredExchangeExpansion.swift)). For `c396433f` the expansion dropped five primaries this way, including the one whose preceding human turn was a referenced source. [ContextAssembler.swift:528](../../Sources/Boros/ContextAssembler.swift) admits at most 16 spans. The 12,000-token evidence cap in [EpisodeBudget.swift:114 to 125](../../Sources/Boros/EpisodeBudget.swift) is reached only after that, which is why the evidence component is usually half empty.
- **Presentation.** Under the V4 framing, every recent source is rendered as a separate `user` message with a host heading and a citation label ([ContextSourceFraming.swift:84](../../Sources/Boros/ContextSourceFraming.swift)); historical excerpts follow in one `user` message; the question is the last message ([ContextAssembler.swift:856](../../Sources/Boros/ContextAssembler.swift)). In the BEAM history the whole 796-message conversation is one conversation, so the eight recent messages are the tail of a long chat and are unrelated to most questions; they cost 3,421 tokens in the knowledge-update request. The same shape arises in the application whenever a user asks about something far back in a long chat. Boros's own records already name this block as competing evidence: the offline [diagnosis of the 54026fce false decline](../ANSWER-PRESENTATION-DEFECTS.md#diagnosis-of-the-54026fce-false-decline-offline-no-generation) finds the V4 answer applying the framing's "not shown" test to the unrelated 12-message recent conversation instead of the historical excerpts. No replay has shortened, moved or merged the recent block.
- **Default.** [EpisodeBudget.swift:163](../../Sources/Boros/EpisodeBudget.swift) sets `currentSelectedQwen = selectedQwen` (v1/16). The coordinator freezes it into every episode ([AnswerAttemptCoordinator.swift:151](../../Sources/Boros/AnswerAttemptCoordinator.swift)).

## What changed since the evaluated revision (implemented and measured)

Fifty commits separate `f28584b` from `HEAD`. The ones that bear on this diagnostic are the P2 retrieval repair records: [steps 1 and 2](../P2-EXCHANGE-QUERY.md), [step 3](../P2-PACKING.md), [step 4](../P2-SEMANTIC-DECISION.md) and the [persistent exchange index](../P2-EXCHANGE-INDEX.md).

`exchange_packed` (`selected-model-context-components-v3-exchange-packed`) replaces each mechanism above: every content term of the question ranks human-led exchange blocks by IDF-weighted coverage; the candidate window is 32 blocks plus their neighbors instead of 16 messages; packing is by value per estimated token under the full 12,000-token cap with a receipt for every omitted unit; quoted anchors are mandatory. On the P1 offline harness it delivers every annotated positive turn in 69 of 90 development cases (76.7 percent) against 60 for lexical and 50 for the ordinary Send configuration measured in the BEAM comparison, with no category below the lexical arm, and 11 of 12 on the regression set. With the persistent index it selects on 9 of 9 probes at 100,000 events with an added p95 of 0.41 s warm and 0.68 s after restart. Its prompts are about 17,100 tokens at the median on the development cohort, still well inside the 29,696-token allowance. Of its 28 remaining missed turns, 16 are outside the candidate window (mostly multi-session) and 12 are candidates skipped by the token budget.

It is not the default for three stated reasons: R2 is below the plan's 90 percent interim target, there is no answer-quality evidence, and the plan requires answer-quality checks before a default change. The second reason has a concrete cause. The answering runner's `--component-policy` option accepts only the v1 and v2 policies ([AnswerEvaluationCommand.swift:343](../../Sources/Boros/AnswerEvaluationCommand.swift)), and the OptChat driver that produced the 20 Boros requests pins revision `f28584b` and three arms (`optchat/scripts/boros-context-driver.ts:4`, `boros-context-driver.swift:90`). The offline delivery harness already accepts the arm and can write the exact answer request body it would dispatch ([DeliveryHarness.swift:91 and 348](../../Tests/Evaluation/DeliveryHarness.swift)), and the coordinator already routes the policy through `ExchangeBlockQuery` under a lease ([ComponentContextPreparation.swift:193](../../Sources/Boros/ComponentContextPreparation.swift)), so the missing piece is evaluation plumbing, not runtime work.

## What OptChat's failures mean for Boros (measured, with an inference)

OptChat's ten misses split into four runs that exhausted the 32K window on accumulated tool results before answering, three answers taken from the summary overview with no search or source read, two unsuccessful retrievals, and one failed abstention. Its wins used 8 to 13 generation calls each; its 141 answer calls against Boros's 20 bought 34 delivered gold sources against 17, with fewer of them complete.

The inference: the reach came from reformulating queries across rounds, and the failures came from the lack of a bounded evidence workspace. Boros already has the bounded workspace (counted components, a safety reserve, duplicate-source receipts, zero failures in 64 answer calls across the comparison and diagnostic) and lacks the reach. The P2 policies add reach inside one call. A single-call policy with better selection is the right next step; a navigation loop is not, and the existing investigation route (about 15 calls and 77,000 tokens per turn) should stay an explicit mode under P3.

## Recommendations (proposed)

In dependency order. Each item names its gate and what it would not establish.

### R1. Produce answer-quality evidence for `exchange_packed`, then decide the default on it

This is the strongest implementation target the diagnostic names, and the policy exists.

1. **Let the answering runners select the policy.** Add the three exchange policies to the `--component-policy` list in `AnswerEvaluationCommand`, with the same option checks the ordinary Send arm has. Add an `exchange_packed` arm to the OptChat driver (`limits.componentPolicy = .selectedQwenExchangePacked`, as `DeliveryHarness.exchangeLimits` does) and move its `BOROS_REVISION` pin to a current `main` commit. Both are evaluation-only changes; ordinary Send is untouched.
2. **Rerun the 20 BEAM questions** as a labelled development comparison with the `exchange_packed` arm beside the frozen ordinary Send requests, three repeats each, under the OptChat harness's existing local grader. This covers event ordering, information extraction, summarization and abstention, which the P1 cohorts do not, and it spends nothing. About 60 answers and 60 grades.
3. **Replay the 94 step 3 inputs** (retrieval-on 21, preference 27, temporal 25, recent-only 21) under `exchange_packed` with local Qwen, three replicates, graded by the default judge (Gemini 3.8 Flash, prompt set v4) interleaved with the existing V4 lexical answers. The `reader_comparison.py capture` step already writes byte-exact request bodies for a harness arm; it needs a local-Qwen sender beside the hosted readers, or the replay can go through the evaluation command once step 1 lands (`answer_presentation_replay.py` also lists only `ordinary_send`). Cost: local generation plus about $1 of judging at the calibration run's rate. Principle 3 of the repair plan reserves generation and judge spending for configurations that clear the offline gate, and `exchange_packed` is at R2 76.7 percent against the 90 percent interim target, so this step needs the user's explicit exception; step 2 does not, because its grader is local.
4. **Gate.** Promote `currentSelectedQwen` to `exchange_packed` if the accepted rate is not below the lexical default on either cohort with the lower bound of the paired difference above minus two points (the plan's regression envelope), and no category falls. Promotion is a one-line policy change plus the first-use index build, maintenance cost of 0.25 to 0.6 ms per appended event, and the GUI notice for the fallback period.
5. **Keep R2 as a separate number.** The 90 percent interim target is a retrieval gate. Between two selectors where the candidate already dominates the incumbent on R2 in every category, the default should be decided on answer quality; the R2 gap is reported beside it, not used to block the decision.

What this would not establish: representative quality (one BEAM history and the reused development cohort), or anything about the 16 multi-session turns that no lexical ranking reaches.

### R2. Run the controlled presentation comparison before changing framing or recent history

The knowledge-update effect replicated, but on one question. None of the three interventions has been tested in Boros: no framing variant asks the model to compare conflicting or updated statements (V5's "check every quoted source" clause was only ever bundled with its other changes, and V4-ordered orders the answer, not the evidence), the message order has been constant in every arm, and no replay has shortened the recent block. Test the two interventions and their combination on every question before implementing either:

1. On the OptChat side, the diagnostic harness already transforms frozen request bytes. Extend it to all 20 BEAM questions with four conditions (native, review sentence, recent quotes removed, both), two or three repeats each: at most 240 answers and 240 grades, all local.
2. On the Boros side, add a `context-source-snapshot-v4-review` framing that appends the diagnostic's sentence to the V4 system framing, and replay it on the framing cohorts with the existing `framing_v4_variants_replay.py` pattern, three replicates, default judge. The earlier V4-advice, V4-ordered and V5 replays are the template and the prior: none of the three earned adoption, and their effects were the size of V4's own run-to-run variation.
3. Only if removing recent history helps across questions, add a versioned policy with a smaller recent allowance (for example 2,000 tokens) and measure it the same way. Note that the P1 and framing cohorts place the question in the last session's conversation, so their recent suffix is shorter and more relevant than BEAM's; the BEAM result is the one that resembles a long single chat in the application.
4. Two structural variants are untested and cheap to add to the OptChat-side comparison as transformed bytes before any Boros implementation: quoting recent sources after the historical excerpts (chronological order) and quoting all sources in one block instead of nine consecutive `user` messages. Neither changes original source storage or role authority.

Gate: adopt a presentation change only if it is at least neutral on every cohort and category with three replicates. What this would not establish: the mechanism (length, position or instruction), which the diagnostic already notes is confounded.

### R3. Treat generation instability as the evaluation noise floor

Every answer-quality claim in R1 and R2 needs three replicates, as the repair plan already requires, and should report the fraction of byte-identical repeats. Boros's own framing replays measured the same thing at larger scale: only 17 of 69 V4 answers were byte-identical between two runs with identical request bytes and delivered ranges, and the decline status changed on 4 questions ([FRAMING-V4-VARIANTS.md](../FRAMING-V4-VARIANTS.md)). The 20-question comparison's four-question margin is a single replicate from a backend that produced two different answers from identical bytes in 2 of 6 pairs; it should be cited as a direction, not a size. Checking whether mlx-serve honors the `seed` Boros sends ([ProviderAdmission.swift:318](../../Sources/Boros/ProviderAdmission.swift)) is worth one small probe, but nothing in Boros can make the server deterministic.

### R4. Route the full-evidence failures to the reader decision, not to retrieval

Five Boros misses had every resolvable gold source complete in the request, and the two contradiction questions failed with complete sources alone. The [reader comparison](../READER-COMPARISON.md) measured Sonnet 5.5 at 67.1 percent and Gemini 3.8 Flash at 60.2 percent against local Qwen at 56.9 percent on identical Boros requests. On the answers whose every gold turn was delivered, the accept rates were Sonnet 90 percent, Gemini 82, Qwen 80 and Haiku 73; with partial gold they fell to 55, 24, 41 and 21. The reader record's own inference is that retrieval, not the reader, limits the end-to-end score, which is consistent with the miss classes above and with R1's priority. P5's plan (a larger locally runnable model on sufficient packs, with the hosted models as the upper reference) is the right place for the contradiction and temporal cases. A conflict-specific instruction is not promising: the review sentence, which names conflicting and updated statements, did not move either contradiction case.

### R5. Measure a larger evidence allowance offline before using it

Under `exchange_packed` the token budget is the binding constraint (4,073 `T` receipts across 100 attempts; 12 of 28 missed turns were candidates skipped for tokens), and prompts sit at about 17,000 tokens against a 29,696 allowance. A variant with `evidenceTokens` at 16,000 costs nothing to measure on the P1 harness (no model calls, about 35 minutes). It should go to answer-quality only after R2, because the knowledge-update case shows that added context can cost accuracy.

### R6. Harness hygiene

- The BEAM comparison's base instruction asks for original source identifiers while the V4 framing forbids them. Citation alignment recovered nothing, so this did not change the score, but the next BEAM run should align the base instruction to the host labels.
- The OptChat driver compiles a source closure at a pinned revision. Any Boros rerun must bump the pin and record the new revision, or it measures the old selector again.
- Consider importing the BEAM history and its 83 author-resolved references as a second regression set for the P1 harness, so retrieval changes are measured on event-ordering, extraction and summarization questions offline before any model run. The references are private OptChat data; only hashes and counts would be published.
- Two status statements are stale: [STATUS.md](../STATUS.md) section 6 still says P2 to P7 are proposed and unimplemented, and the repair plan's remote-provider paragraph still names Sonnet as the default judge, which changed to Gemini 3.8 Flash on October 11.

### What not to do

- Do not add a tool-navigation loop to ordinary Send. OptChat's four aborts and three summary-only wrong answers are the measured cost of that design under a 32K window.
- Do not patch the v1 selector (for example raising `maximumCandidates` so neighbors stop evicting primaries) instead of measuring `exchange_packed`. The bounded-neighborhood experiment already showed that widening v1 without changing the packer recovered no annotated turn and lowered local acceptance.
- Do not promote the review sentence or drop recent history on one question's evidence, and do not raise the evidence allowance on the budget headroom alone.

## Sequence and cost (proposed)

| Step | Work | Model calls | Blocks |
|---|---|---:|---|
| 1 | Evaluation plumbing for `exchange_packed` (R1.1) and the BEAM-side presentation harness extension (R2.1) | 0 | Nothing |
| 2 | BEAM 20-question presentation comparison (R2.1) and `exchange_packed` arm (R1.2), together | about 300 local answers and 300 local grades | Step 1 |
| 3 | 94-input `exchange_packed` replay with the default judge (R1.3) | 282 local answers, about $1 of judging; needs the user's principle 3 exception | Step 1 |
| 4 | Default decision on `exchange_packed` (R1.4) | 0 | Steps 2 and 3 |
| 5 | V4-review framing replay if step 2 supports it (R2.2) | 282 local answers, about $1 of judging | Step 2 |
| 6 | Evidence-allowance variant on P1, then answer quality (R5) | 0, then as step 3 | Step 4 |

Steps 2 and 3 can run in parallel on the local server. None of them changes a default; step 4 is the first decision, and it is the user's.

## Evidence locations

- OptChat repository: `docs/evaluation/beam-expanded-memory-result.json` (per-question outcomes and gold delivery counts used above), `boros-context-diagnostic-result.json`, `boros-diagnostic-confirmation-result.json`, and their validation files. Requests, answers and references are in that repository's private storage.
- Boros: [P2-PACKING.md](../P2-PACKING.md) and [P2-EXCHANGE-INDEX.md](../P2-EXCHANGE-INDEX.md) for the `exchange_packed` measurements; [READER-COMPARISON.md](../READER-COMPARISON.md) for the reader numbers; [DESIGN-REPAIR-PLAN.md](../DESIGN-REPAIR-PLAN.md) for the gates cited; [ANSWER-PRESENTATION-DEFECTS.md](../ANSWER-PRESENTATION-DEFECTS.md), [FRAMING-V4-VARIANTS.md](../FRAMING-V4-VARIANTS.md) and [FRAMING-V5.md](../FRAMING-V5.md) for the framing replay pattern R2 reuses.
