# Adversarial review of judging and retrieval

Review date: October 6, 2026. Reviewed implementation: `b64cd85`, before the next application amendment. Scope: the seven-case LongMemEval development comparisons, six complete-source controls, fourteen-case independent development comparison, shared local judge, and actual native retrieval path. This review made no model calls and changed no application or evaluator code. Original questions, answers, hypotheses, source text and dates remain private.

## Finding

The latest evidence supports specific failures in candidate selection and exchange expansion. It does not support attributing every low answering score to retrieval.

The independent comparison has 18/19 gold-session hits, 14/18 complete annotated turns delivered, and local acceptance of 9/12 answerable hybrid answers. These measure different properties. Three rejected answerable cases omit small original turns before assembly. All fourteen hybrid attempts have zero evidence byte, token, envelope or reduction exclusions. Increasing the model context limit or output cap would not recover those missing turns.

The concrete application defect is an expansion contract that reserves no slots for later primary results and looks in only one direction: a human primary adds its following assistant; an assistant primary adds its preceding human. Useful preceding assistant and following human messages remain unreachable through those anchors. Greedy expansion spends the same sixteen slots used by ranked primaries. Across fourteen attempts it drops 97 of the 224 initially selected primary spans. That is an established selection behavior, not proof that all 97 dropped spans were useful.

The judge plumbing reproduced correctly. Correctness of its real-answer labels remains uncalibrated. No observed parsing, category mapping or denominator error explains the latest score.

## Evidence audited

The review reconstructed the independent adapter from the pinned source, validated the answer bundle and native-build linkage, regenerated all 28 exact grading requests, compared private request and raw-response hashes, reparsed every judgment, and recomputed summaries. All 28 requests and labels matched; every judgment was strict yes/no, with zero unknown results. Private capture files had mode `0600`. These checks establish input and scoring integrity, not semantic correctness.

| Local artifact | SHA-256 |
|---|---|
| `.build/evaluation/longmemeval-independent-v1-20261006.json` | `0a89e02a330cd80dedb5157694ee60180d7a22c60df919cb45c60d67d720cfbe` |
| `.build/evaluation/local-qa-independent-v1-20261006/report.json` | `553a3b2199a4ef1b62bd54828bb0271e76613be1b27c84d92fbac67a35957e73` |
| `.build/evaluation/longmemeval-adjacent-v1-20261006.json` | `706563fb98bb87cc707018d28e2c7867294b50cf794f33149db6fdf2f16e49e6` |
| Pinned upstream `src/evaluation/evaluate_qa.py` | `ecce9c4c79dc89d99534ac17b383a5cbb5b9f0c69ee98adaf0684742e3d95251` |

The independent native reviewer separately corroborated missing-target attribution and exact lexical replay. This review also repeated an in-memory contentless FTS5 reconstruction for the three rejected answerable cases, preserving all original events, the accepted dated question, recent exclusions, selected token indices, query digest and `bm25`/descending-sequence order. No new source-bearing artifact was published.

## What judging establishes

`scripts/local_longmemeval_qa.py:152` executes the hash-pinned upstream prompt function. The category and abstention mapping preserve the source task types; independent abstention IDs use the upstream abstention branch. The independent grader (`scripts/local_longmemeval_independent_qa.py:267`) verifies ordered exports, exact original projections, annotations, metadata, native source inventories and build proof. It grades every operationally complete answer regardless of recall coverage. Failures and unknown judgments retain declared denominators. Pre- and post-call checks bind source, report, exports, controls and grader dependencies.

The upstream evaluator checks for a yes substring. Boros additionally requires the entire normalized judgment to be `yes` or `no`, a normal stop and the expected model string (`scripts/local_longmemeval_qa.py:395`). All 28 actual responses satisfied that restriction. Ambiguous prose containing yes cannot explain these scores.

There are material limits:

- The judge sees the question, reference and hypothesis. It does not receive delivered evidence. It can accept a lucky guess, a generic response or a correct answer with unsupported additional claims. It cannot establish citation support, grounding, source sufficiency or retrieval quality.
- The upstream preference rubric deliberately accepts correct use of personal information without every rubric point. The temporal rubric deliberately tolerates off-by-one duration answers. These are benchmark semantics, not implementation bugs. They need separate product-grounding measurements.
- The answering and judging model share the same model identifier. Correlated omissions and self-preference are plausible; their magnitude and direction are unknown. There is no independent real-answer adjudication set or measured false-accept/false-reject rate.
- Fourteen simple synthetic controls contain seven positive/negative pairs. They establish basic task routing and obvious correctness discrimination. They do not test mixed correct/incorrect claims, incomplete real multi-session answers, plausible unsupported inference, citation errors, contradictory evidence or instructions embedded in generated answers. Perfect controls do not calibrate real-answer judgments.
- The grader fingerprints source code, templates, controls and model settings. The provider model string is checked. Weights and live runtime identity remain unpinned. Reusing an older controls report cannot establish unchanged model behavior. Judge settings use temperature zero but omit a seed; the answering seed is not a judge seed (`scripts/local_longmemeval_qa.py:133`). Temperature zero alone is not a determinism guarantee.

No independent semantic ground-truth adjudication of the 28 private answers was completed by this review. The labels below remain model judgments. Mechanical agreement with those labels must not be described as correctness verification.

## Exact current retrieval attribution

The selector returns sixteen fused primary results before expansion. `primary_completion.decisions` preserves their IDs and order; the later `selection_trace.candidates` records the expanded list. All three rejected answerable targets are absent from the original sixteen and absent from delivered ranges. Their lengths are below the existing 4,096-byte page limit.

| Case | Missing original positive | Established behavior | Remaining uncertainty |
|---|---|---|---|
| `51c32626`, multi-session | `51c32626-s0047-m0008`, human, 135 bytes | No lexical match under the actual query. An adjacent assistant `m0007` is an original primary and is promoted into the delivered list. Expansion considers its preceding human, not the following human target; promoted assistants exit expansion early. Both gold sessions are hit despite the missing positive. | Per-source semantic eligibility and complete fused ranks are unavailable. Delivering the target might fix the answer; that generation experiment has not run. |
| `1b9b7252`, assistant recall | `1b9b7252-s0023-m0003`, assistant, 927 bytes | Exact lexical replay places the target at raw lexical index 22; the recorded sixteen fused primaries omit it. Following human `m0004` is original primary index 10 and is discarded after earlier neighbors fill all sixteen slots. Even retaining that human under the existing one-direction contract would retrieve its following assistant, not this preceding target. | Its exact native semantic rank/support is unknown. A higher lexical window alone does not fix a target already inside the inspected 100-candidate raw window. |
| `4baee567`, assistant recall | `4baee567-s0037-m0011`, assistant, 452 bytes | No lexical match under the actual query. Following human `m0012` is original primary index 10 and is discarded. Preceding human `m0010` appears in the raw lexical population below the fused sixteen. Either adjacent anchor could recover the target with the appropriate direction. | Native semantic support and ranks of omitted sources were not retained. Which alternative anchor would win under a revised bounded policy requires execution. |
| `1a1907b4`, preference, locally accepted | `1a1907b4-s0005-m0002`, human, 258 bytes | The annotated turn is absent from primary, expanded and delivered lists, yet the judge accepts the answer. | Other delivered turns may supply equivalent information, the rubric may allow a partial response, or the judge may falsely accept. Current labels cannot distinguish these explanations. |

For the three rejected answerable cases, every one of the sixteen final candidates has assembly disposition `included`. Evidence token totals are 9,610, 9,272 and 9,314 respectively; there are no later context exclusions. These are selection misses, not retained snippets clipped by admission. The missing turns are small, but small size alone does not prove the full revised evidence set fits. Primary indices in this review are zero-based; the independently replayed assistant target is raw lexical index 22, or rank 23 when counting from one.

The rejected hybrid abstention `f685340e_abs` is a separate generation/grounding problem. There is no gold target to retrieve. Recent-only is locally accepted and hybrid is rejected after receiving historical material. The exact unsupported claim and judge correctness need independent private adjudication; more recall cannot by itself guarantee better abstention.

## Why the earlier seven-case score looked worse

The latest seven-case adjacency run completes 11/14 operational attempts. Hybrid assistant recall and preference, plus recent-only preference, reach the unchanged 512-token output cap. Those attempts receive no judge call and remain failures in declared denominators. Hybrid's 3/7 accepted count therefore includes two output failures. Calling all four unaccepted hybrid attempts retrieval failures is incorrect.

The completed multi-session case `00ca467f` is rejected even though both complete positive turns are delivered. Possibilities include missing surrounding referents, distractor interference, generation failure or a judge false reject. The retained complete-turn metric does not resolve them. The later oracle-selected complete-source control is accepted, which demonstrates a usable diagnostic direction without proving a unique cause.

There is a direct earlier instance of greedy loss: `06878be2-s0035-m0000`, a 116-byte positive human turn, is original primary index 13 and is dropped by adjacency. A second preference positive and one temporal positive are absent from primary selection. The old assistant positive is fully delivered while its answer fails at the output cap. This separates candidate recall, expansion loss and output feasibility.

The independent fourteen-case run uses a 1,024-token output cap and different histories. Its 28/28 completion and 10/14 hybrid acceptance cannot establish that a retrieval change caused improvement over the seven-case run. There was no matched 512-versus-1,024 experiment on the same cohort.

## Retrieval weaknesses beyond these attributed misses

`HistoricalQueryFormulation.swift:76` takes at most eight unique non-stopword terms, prioritizing quoted anchors and then prompt order. It does not prioritize rare entities or infer assistant-recall intent. `MemoryStore.swift:1208` uses OR matching and BM25 with a descending-sequence tie break. That can select topical distractors and omit nonmatching answer turns. The three-case replay finds 50, 131 and 116 eligible lexical sources; native windows inspect 50, 100 and 100. A full candidate window is a censored ranking boundary, not complete archive search.

`SemanticIndex.swift:678` collapses vector chunks to one range per source. When a source already has a lexical candidate, semantic fusion increases its score and records cosine similarity while preserving the lexical range. `MemoryStore.swift:1869` centers excerpts on only the first occurrence of each query term; later denser occurrences can be missed. These are real range-selection limitations. They are not the demonstrated cause of the three latest missing targets, which never reach the primary list.

Three independent-cohort queries receive `ambiguousLanguage` and zero inspected vectors. All fourteen histories have incomplete semantic coverage, with 212–267 unsupported sources per attempt and one pending source. The pending source includes the newly accepted question; it is excluded from historical search and is not evidence that an answer-bearing source was unindexed. The Apple adapter rejects code markers, non-ASCII letters and sentences whose English probability falls below 0.90 (`SemanticIndex.swift:41`). A supported question does not prove its needed source was supported. The retained truncated coverage holes and cleaned temporary stores prevent exact per-target semantic attribution. No claim that Apple embedding failed a particular target is justified from these aggregate counts.

## Metric and experimental defects

Gold-session hit rate awards credit for any nonempty delivered range in an annotated session. The `51c32626` failure hits both sessions while missing a required annotated turn. Session hit rate overstates answer-evidence recall in that case.

Complete-positive-turn coverage requires every UTF-8 byte of each `has_answer` message (`scripts/evaluate_longmemeval.py:133`). It measures a conservative mechanical whole-message target. It can understate sufficient answer-span delivery when unrelated text is omitted, and it can overstate sufficiency when antecedents, relationships or other necessary turns are missing. It is not the published official retrieval score, which remains null. Neither source annotations nor this review prove that all annotated turns form a minimal sufficient pack.

The six complete-source controls supply oracle-selected original packs containing the positives and surrounding context. Five answers complete and all five are locally accepted; one preference answer hits the output cap. Reporting 5/5 only would hide the declared 5/6 success. These reused curated cases bypass ordinary candidate selection and omit abstention. They suggest that evidence presentation matters and that the model can solve these five controls. They do not establish general upper-bound feasibility, source sufficiency, unbiased judge performance or retrieval accuracy.

The fourteen-case selector is answer-blind and verifies exact session-ID, complete session-payload and question disjointness. It does not establish independent authors, semantic disjointness or a representative deployment distribution. Two cases per task type and one replicate leave category findings highly fragile. Expanding this cohort is warranted after a concrete runtime amendment; reproducing a small reused score with more grader plumbing is not the immediate fix.

## Recommended application amendment

Reserve the sixteen original primary spans before adding optional neighbor evidence. Let every original primary inspect both immediate adjacent opposite-role sources within the same conversation and frozen frontier. Neighbor-only additions must not recurse. Keep source validation, scalar-safe 4,096-byte reads, original lease, prepaid work, 12,000 evidence tokens, 131,072 evidence bytes and whole-request admission bounds.

A separately bounded expanded list can have at most 48 spans before deduplication and existing admission: sixteen primaries and up to two neighbors per primary. A 32-span limit with greedy two-neighbor interleaving can still starve neighbors belonging to primary index 10. Increasing the limit alone also leaves the wrong directions and primary displacement intact. Optional neighbor removal should precede loss of protected primaries where feasible; oversized mandatory primary evidence must retain explicit reductions/failures rather than silently relaxing provider limits.

The new trace must distinguish original rank, expansion direction, promoted/neighbor-only origin, final rank and exact omission reason. Retain old trace/audit/archive grammars and fingerprints unchanged. Do not derive directions or priorities from scorer-only gold IDs. Generalize from original roles, adjacency and query input.

The existing passing checks explicitly assert primary displacement when neighbor expansion fills sixteen slots (`ExchangeExpansionChecks.swift:408` and `ExchangeExpansionChecks.swift:183`). They accurately enforce the old contract. They do not place necessary answer evidence on a later primary or on the other side of an adjacent source, so they cannot establish recall quality. A large application check count does not contradict the observed selection failure.

Required synthetic checks include late primary survival under neighbor saturation; following-human and preceding-assistant recovery; promoted-primary expansion in both supported directions; duplicate-range metadata disagreement; nonrecursive neighbor behavior; conversation/frontier/exclusion boundaries; Unicode/status/date preservation; prepaid exhaustion; byte/token reduction order; recent-only zero historical work; and original receipt/archive replay.

Then predeclare a matched repeat on the same fourteen histories and 1,024-token setting. Independently reconstruct delivered ranges and count proofs, preserve all attempts, and separately report candidate/turn recovery, answer completion, local labels and abstention. Include new independent cases containing distractors and both adjacency directions before claiming general quality. A positive delivery change is not an answer-quality result until generation is rerun.

The judging follow-up should be a small blinded real-answer calibration set adjudicated independently, including accepted answers, rejected answers, incomplete evidence, abstentions and correct-plus-unsupported claims. Report disagreement by failure type. Preserve unchanged upstream labels as a separate benchmark diagnostic. This calibration is necessary for trusted correctness claims; it should not delay the evidenced candidate-expansion fix.


## Follow-up: the wider candidate frontier did not earn promotion

The separately declared matched neighborhood experiment completed 28/28 answering attempts and 28 local judge calls. It corrected the candidate-frontier mechanics described above, but hybrid complete positive-turn delivery stayed 14/18 and all four missing targets remained missing. Gold-session hits rose 18/19 to 19/19. Local hybrid acceptance changed 10/14 to 8/14, with recent-only changing 2/14 to 3/14. These are one-replicate, uncalibrated judgments and do not establish a statistically reliable regression.

All fourteen experimental hybrid contexts removed optional spans for tokens. Independent replay places three needed neighbors beyond the retained prefix; native full initial-trace bodies were omitted from exports, limiting independent authentication of that attribution. Two newly rejected hybrid answers received every annotated positive turn. Candidate protection alone therefore did not establish adequate evidence selection or answering quality. The ordinary v1 default is restored in unbuilt working-tree source; the experimental implementation and frozen results remain retained.

The [architecture reassessment](ARCHITECTURE-REASSESSMENT-20261006.md) records the receipts and proposes five counted sufficient-source controls with independent correctness/grounding assessment before further retrieval implementation. This follow-up does not change the original reviewed snapshot or its findings.
