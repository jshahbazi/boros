# Experimental memory investigation

Implemented October 6, 2026. The new standalone path gives the reader a history map, deliberate search and zoom, protected complete exchanges, and a source-bound extraction step before answering. It preserves the frozen orientation pilot. Ordinary native GUI Send still uses its existing one-pass selection.

The implementation has synthetic verification only. No new model answers, retrieval benchmark, judge calls, paid API work, or quality/latency measurement ran. The user's experiment hold remains in effect. A future execution requires explicit authorization and a spending limit; CLI flags do not provide that authorization.

## History map and original evidence

[history_navigation.py](../scripts/history_navigation.py) validates the original record allowlist, order and complete status. It retains original content, roles and chronology. Before rendering any model input, it replaces event and session identities with ordinal opaque IDs and strips source-time locators and other imported metadata. The host can resolve opaque event IDs back to originals. This closes the identifier route that exposed answerability labels in v1; it cannot remove clues already present in original message text.

The question-blind map has an aggregate header spanning every original record, grouped chronological regions, and pageable session/exchange detail. Topic and entity cues are literal terms selected from originals, weighted by frequency and rarity, with supporting source/block links. They describe navigation, without claiming semantic entity extraction or faithful model summaries. Available original dates, unknown-date counts, sample-link coverage and continuations are explicit. No paid summarization call constructs this map.

The map and original full-text indexes are reusable within a `NavigationHistory` instance. Initialization builds them from the supplied snapshot; incremental native maintenance and cross-run index reuse are unimplemented. The reused v1 validator retains its per-session initialization cost. Large-corpus startup time, memory and sustained query latency remain unmeasured.

Search covers every indexed original message and every complete exchange. It considers content terms throughout the query, ranks by term rarity and relevance relative to exchange byte cost, and returns bounded pages. It supports at most 256 distinct content terms in a 16 KiB query. An initial question exceeding that term bound reaches the planner for reformulation rather than silently searching its prefix. Search remains lexical: paraphrase and semantic recall quality are unestablished.

Zoom reaches grouped regions, sessions or individual exchanges. Authenticated cursors bind the snapshot, operation, query/filter and source exclusions. Cursors permit continuation through all candidate pages. A reached candidate can fail delivery admission; these are separate receipt fields. Oversized exchanges stay identifiable for further inspection but cannot be split by this whole-exchange implementation.

Optional date filters use supported literal original civil dates, with an explicit choice about unknown dates. They retain entire exchanges when a constituent record matches. They do not establish UTC ordering or interpret natural-language temporal constraints automatically.

## Investigation and reading

[memory_investigation.py](../scripts/memory_investigation.py) accepts a provider with exact counting and bounded generation methods. It performs these stages:

1. Select bounded recent originals and an initial full-index search pack; present the history map to the planner.
2. Allow up to six deliberate search, zoom or overview actions. Each decision names missing facts and the already delivered exchanges to pin. Pins reserve whole exchanges atomically; failure to fit is explicit.
3. Extract relevant facts with exact quotes from every cited delivered source. Reject invented, altered, unselected or unquoted source references before final answering.
4. Answer from original records plus clearly identified derived notes. Carry unresolved facts, incomplete search and the termination reason into the final reader.

Repeated ineffective actions stop with a no-progress reason. Exhausted actions remain visible to the reader. A finish decision with gaps remains a finish with gaps. None of these states proves a fact absent from the archive.

Recent selection prioritizes newest complete exchanges and can skip an oversized exchange. Geometric token reduction can underfill its allocation; the result need not be a contiguous suffix. Historical selection packs complete units in relevance/cost order. The complete rendered stage is counted again after component admission; fitting removes whole unpinned units. Sources cited by extracted notes become protected for the final request.

Each model-stage receipt binds its exact prepared source IDs, exchange IDs and original-record digest. Host candidate/packing receipts do not claim model delivery. Private tool history preserves query/filter descriptors so a stateless planner can follow a cursor. The host replays the cursor's original exclusions if recent context later changes.

Quote validation establishes source membership and exact text. It does not validate the interpretation of a claim, the final answer's semantic support, or general answer accuracy. JevK5 saved-answer grading remains a separate tool; the new runner does not automatically judge results.

## Execution and resource limits

[run_memory_investigation.py](../scripts/run_memory_investigation.py) accepts one case with exactly `question`, `question_date`, and `sources`. There are no reference answers, categories, positive annotations or scorer inputs. Sources use the existing original-record allowlist. Input origins still need an independent check before a benchmark claim.

Default execution prepares a fresh private input, map preview, dependency capture and immutable declaration. It reads no credential and makes no provider call:

```sh
python3 scripts/run_memory_investigation.py \
  --input /absolute/path/case.json \
  --output "$PWD/.build/evaluation/memory-investigation-prepared"
```

Output must be a new directory below ignored `.build/evaluation`, with private directory/file permissions and no overwrite. Source/dependency pins are checked before every provider dispatch. Original identities, questions, records, intermediate output, final answers and traffic stay private. Public stdout contains counts and fixed error codes.

The optional standalone adapter targets the existing Sol Responses configuration. Future authorized execution additionally requires `--execute`, an explicit credential path and `--max-cost-usd`. No credential path is supplied by default. It provides no remote adapter in the native application.

| Limit | Default |
|---|---:|
| Search/zoom/overview actions | 6 |
| Generations, including planner, extraction and answer | 9 |
| Actual count requests | 128 |
| Input per generation | 24,576 tokens |
| Recent / historical evidence / map components | 8,000 / 12,000 / 4,000 tokens |
| Planner / extraction / answer output reservation | 1,024 / 2,048 / 1,024 tokens |
| Aggregate held input / output reservations | 150,000 / 16,384 tokens |
| Provider admission deadline | 300 seconds |
| Existing in-flight HTTP timeout | 120 seconds |

Reservations include the entire output allowance, including reasoning, and never decrease. A failed/unknown generation retains its reservation. The first provider, count, capture, pin or parsing failure fences further calls. There are no retries or automatic continuations. Interrupts and deadlines fence subsequent dispatch; an in-flight upstream request cannot be forcibly terminated by this runner.

The spending check uses frozen declared estimates of $2 per million input tokens and $10 per million output tokens, without cache discounts. The default aggregate reservation ceiling corresponds to $0.463840 per case at those rates. An explicitly lower cap may terminate before an answer. These are dispatch reservation estimates, not an invoice guarantee or a promise about future provider prices. Stage output limits and the deadline still need real-model feasibility validation.

## Verification and next decision

Seventy-nine new synthetic contracts cover navigation, scripted investigation and a mocked transport. Sixty-one existing orientation/judging/continuation contracts also pass, for 140 checks. These include full-index reach beyond record 4,096, late rare anchors, cross-session updates, identity blinding, date/unknown handling, pagination after recent eviction, atomic pins, whole-request fitting, exact per-stage source binding, malformed extraction, spend/usage holds, HTTP 429, interruption, deadlines, tampering and no-clobber capture. No check uses a live model or private evaluation corpus.

The original v1 report and declaration hashes remain unchanged. The prior native working-tree changes and verified app bundle are preserved.

Next quality work requires an explicitly authorized small comparison with a spending cap, frozen original inputs, an independently checked blind projection, manual source/judgment checks, and separate baseline/investigation results. Record candidate reach, packing loss and source-supported answer quality separately. These implementation checks provide no new answer-quality result.

Native integration requires a reusable stage admission helper, a new counted component session for each planner/extractor request under the original episode lease, bound derived-content framing, private intermediate capture, and one visible final invocation. Existing final-answer count proofs cannot authorize different planner bodies. The new path stays experimental until comparison supports promotion; further policy/service expansion remains deferred.
