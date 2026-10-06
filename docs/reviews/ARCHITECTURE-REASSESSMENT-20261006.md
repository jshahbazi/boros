# Architecture and answering reassessment

Assessment date: October 6, 2026. This assessment follows the [adversarial judging/retrieval review](JUDGING-RETRIEVAL-ADVERSARIAL-20261006.md) and its completed matched neighborhood experiment. Three independent agent investigations reviewed architecture, evidence selection and documentation. No new provider calls or runtime amendment were made for this assessment. Original questions, answers, histories and date literals remain private.

## Judgment

The current answering pipeline has not established reliable long-history memory. Its retrieval strategy is too limited to justify that claim. We do not yet know whether the selected local answerer can meet the intended quality target when given sufficient evidence under the intended budget.

Complete original storage, exact source paging, counted context and durable request evidence provide useful foundations. Their passing contract checks establish implementation properties. They do not establish that search finds the necessary material, that packing preserves its relationships, or that the model answers correctly.

We have devoted substantial implementation effort to accounting, custody and audit mechanics before demonstrating a strong answering baseline. The next decision should concern answering feasibility and evidence selection. Additional service, authority or tree architecture will not answer that question.

## What the matched experiment showed

The baseline and experiment use the same fourteen development histories, original question projections, 1,024-token output setting and local grading protocol. Each wave contains 28 recent-only/hybrid attempts. All attempts complete operationally. The new implementation increases the maximum expanded assembly to 48 spans, protects at most sixteen primary spans, adds both immediate opposite-role neighbors and retains the original 12,000-token evidence allocation.

| Measurement | Baseline v1 | Experimental v2 |
|---|---:|---:|
| Answerable gold sessions with any hybrid-delivered range | 18/19 | 19/19 |
| Hybrid complete annotated positive turns | 14/18 | 14/18 |
| Answerable cases with every positive turn delivered | 8/12 | 8/12 |
| Locally accepted hybrid answers, including abstention | 10/14 | 8/14 |
| Locally accepted answerable hybrid answers | 9/12 | 7/12 |
| Locally accepted recent-only answers | 2/14 | 3/14 |

The four missing annotated turns remain missing, with zero gained or lost complete positive turns. All fourteen experimental hybrid contexts undergo token reduction, removing 13–21 spans. None undergo byte, envelope or audit-size exclusion.

Independent reconstruction places three needed turns among the new neighbors at zero-based candidate positions 30 or 31, beyond the delivered prefix. Reconstruction matches all fourteen delivered prefixes and initial-count equations. Full native initial-trace bodies were omitted from exported metadata and the temporary stores were removed; this attribution is consistent replay evidence, not independent authentication of every native initial candidate. The fourth missing target is outside reconstructed candidate reach.

Two newly rejected hybrid answers receive every annotated positive turn. Their failure could involve missing unannotated relationships, distractor sensitivity, answering ability or incorrect judgment. The unchanged recent-only arm also changes labels. One replicate and fourteen cases do not establish a statistically reliable regression or determinism. The experiment supplies no evidence for promoting the wider policy.

The working-tree default was consequently restored to exact v1/16. Explicit v2 remains experimental. The 3,887-check app and model reports describe the frozen experimental implementation before that gating edit. The gating edit and its new contract checks require a fresh native build; those earlier checks must not be attributed to the edited source tree.

## Why it is failing

### Search has limited understanding and reach

`HistoricalQueryFormulation.swift:76` selects at most eight unique non-stopword terms, prioritizing quoted anchors and then prompt order. It does not decompose the question, prioritize rare entities or distinguish recall of a person's words from recall of an assistant's response. Topical lexical similarity can rank distractors above an answer-bearing turn that uses different words.

The Apple encoder rejects code-like, non-ASCII-letter and uncertain English inputs (`SemanticIndex.swift:34`). The independent histories have incomplete semantic coverage, and three queries receive no vector inspection because of ambiguous language. Exact semantic support for each missing target remains unknown.

Semantic search ranks a bounded chronological population rather than querying a global nearest-neighbor index. The default examines at most 4,096 eligible chunks, ordered by source sequence and offset before similarity ranking (`SemanticIndex.swift:648`). A continuation exists, but ordinary answering performs one search pass (`ChatContextPreparation.swift:189`). In larger archives, sources beyond that population cannot win that pass's semantic ranking. This is a structural reach limit; it is not established as the cause of these four cohort misses.

### Packing does not estimate answer value

Fusion collapses to one range per source and retains sixteen primary results (`SemanticIndex.swift:675`). The original expansion interleaves neighbors and can discard later primary hits. The experimental expansion preserves primary spans before every optional companion (`BoundedNeighborhoodExpansion.swift:113`), then removes neighbor suffixes geometrically when tokens overflow (`ContextAssembler.swift:310`).

Both rules allocate context by mechanical rank and position. A highly ranked anchor can consume space while the short adjacent turn containing its answer is dropped. We rank isolated messages, but many questions need complete exchanges, antecedents, corrections or evidence from several sessions. Expanding candidate count without selecting evidence by relevance, relationship and token cost cannot solve that reliably.

There is no ordinary model-driven search/read loop that notices an evidence gap and tries a different query or source page. Adding such a loop is a proposed option with additional latency and cost; it needs its own matched evidence.

### Retrieval is only one source of answering failure

Earlier DevGPT sufficient-evidence controls deliver all nine curated packs, yet the model passes five tasks. Earlier six-case LongMemEval source controls complete five answers, all locally accepted, with one output-limited failure retained. These controls use different workloads and rubrics and do not establish an unbiased model ceiling. They show why delivery and answering must be measured separately.

More context can introduce distractors. Complete annotated-turn delivery also does not prove that all necessary referents and relationships are present. Provenance authenticates input bytes; it does not validate the generated claims.

### The judge does not establish grounded correctness

The local judge receives the question, reference and generated answer. It does not receive delivered evidence. It uses the same model identifier as the answerer and has no measured error rate on real answers. Independent audits reproduce all request bytes, strict labels, summaries and denominators; that rules out several scoring-plumbing defects. Semantic calibration remains unrun.

Gold-session hits can rise without recovering the needed turn. Full positive-turn delivery is a useful conservative diagnostic, but can omit necessary surrounding context or count irrelevant bytes. Neither should be used as a substitute for independently assessed answer correctness and source support.

### Current scaling is impractical

The declared synthetic 100,000-event profiles record legacy automatic-context p95 above 111 seconds. Read-only system-SQLite attribution identifies repeated FTS matching caused by join planning. The faster isolated SQL alternative is not a measured native repair. This latency must be corrected and remeasured before adding repeated searches; it is separate from recall quality. See [scaling](../SCALING.md).

## Proposed decision before the OpenAI diagnostic

The following proposal preceded the subsequent authorized diagnostic recorded below. Its clean-pack comparison is now complete; independent semantic pack authentication and judge calibration remain pending.

Predeclare five diagnostic controls: the three rejected answerable cases with missing targets and the two newly rejected cases with all annotated positives delivered. For each, independently verify a small original exchange pack containing the facts, antecedents and chronology needed to answer. Use the existing counted original-source control path, the same evidence/output allowances and the same question. Preserve infeasible packs and incomplete answers as failures.

Generate five new answers and independently assess correctness and claim-level source support. Keep the existing same-model labels as a separate diagnostic. This uses known cases to diagnose feasibility; it cannot establish generalization and must never feed scorer annotations into production retrieval.

- If sufficient, feasible packs succeed, prioritize evidence selection: broader query-relevant retrieval, exchange grouping and relevance/token-aware packing. Then compare against the default on fresh cases and repeated matched runs.
- If verified sufficient packs fail, improve the answerer or its presentation before expecting a retrieval amendment to produce reliable answers.
- If the packs cannot fit the intended allocation, the product's budget/quality target needs revision backed by cost and latency evidence.

Do not add a summary tree to compensate for this uncertainty. A tree can provide orientation and help search choose regions; it introduces summary error and maintenance cost and still needs exact evidence selection. It remains gated on a demonstrated baseline benefit.

## Immutable receipts

| Artifact | SHA-256 |
|---|---|
| Experimental native verification, 3,887 checks | `dbf9b8b15e70153d7a3b9167384a6bff27e25869ded74d57617aeaeb9a76a038` |
| Matched input comparison | `abd9e876149b2599e68447a77cd3c3c375c4b8d5fffab43ca023286673c4f3fd` |
| Experimental generation report | `2b6c42e00a8c27aa60bfa2ecf9cbd6b35e8c93b92b4ce247cc9d5226b3223ad4` |
| Experimental original-source verification | `dc2da8b28aef66ebc8032fb76a89afab6ea91f0023aebf6b03bd5ee4463603e4` |
| Independent delivery-shift reconstruction | `f9f47fc7f40b98972e11ea8f215a578460a870d9fde6d1b29428d45225379f31` |
| Experimental local QA report | `0460b4dfd1853a67c0fe2b9961b3ebd0c0a6b709de476efd39f8367598a0946c` |
| Independently reconstructed final results | `2457c31a857d30b8903ccd2faf768cdf97bd2275891e359f5123eb111452c0dd` |
| Frozen experimental source-copy manifest | `5ea041d198d81f03c41c51b915f2665c5b8f7079af40e1fca84a565928253bdb` |

All artifacts remain under ignored private `.build/evaluation` paths. Frozen experimental sources are preserved separately from the later working-tree gating edit. No current gated-build, representative-quality or finished-architecture claim is made.

## Subsequent authorized OpenAI diagnostic

After this assessment, the user authorized GPT-6.1 Sol API testing. The [completed answerer controls](../OPENAI-ANSWERER-CONTROLS.md) use five frozen oracle-selected original-evidence packs through a standalone Python runner. They bypass native retrieval/admission; exact preceding native request bodies were unavailable. Every source/question/reference pin remains authenticated, but semantic pack sufficiency was unverified before generation.

Both source-aware judges accept Sol on 4/5 cases. Qwen receives 2/5 acceptance from itself and 3/5 from Sol. Both models succeed on two prior missing-target failures when given the curated packs. Sol also succeeds on the two cases with all annotated positives previously delivered. This supplies bounded evidence that answerer capability and evidence presentation matter alongside selection; it does not establish a representative model ceiling or isolate a native model replacement.

Five individual fields disagree between the judges. Qwen also gives the same pack opposite sufficiency labels depending on which answer it judges. Sol calls that pack insufficient in both assessments. The remaining failed case cannot be attributed to an answerer limit from verified sufficient evidence. A source-aware model rubric still requires independent semantic calibration; it has not become ground truth merely by including evidence.

The immediate priority remains authenticated complete-exchange selection and measured answering. Sol merits further comparison on fresh cases. Broader architecture and optional trees remain deferred. The diagnostic leaves remote application processing disabled and does not change the unbuilt default-gating boundary.
