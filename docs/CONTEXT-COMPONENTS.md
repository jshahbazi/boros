# Exact context component limits

The original component allocation was implemented, verified and pushed October 5, 2026 at `9cf4d11`. That configuration passed 1,297 combined checks, 97 coordinator/proof fixtures, independent rendering and identity review, strict app signature verification and two live mlx-serve turns. Counts overlap. Registered measurement adoption remains pending.

The working-tree ordinary selected-Qwen default remains exact `selected-model-context-components-v1`, with 16 spans, 8,000 recent tokens and 12,000 evidence tokens. Explicit experimental v2 protects at most 16 primaries before adding neighbors, with 48 total spans and unchanged token/byte allowances. The [bounded neighborhood contract](BOUNDED-NEIGHBORHOOD.md) describes its reductions, provenance and audit fitting. The frozen experimental app passed 3,887 checks and genuine old-writer archive replay. Its matched repeat recovered no additional positive turns and locally accepted hybrid 8/14 versus 10/14; it did not earn promotion. The subsequent v1-default restoration requires a fresh build. Historical v1 records retain their exact allocation and JSON. Registered settings remain unchanged.

## Exact counting

The verified Qwen renderer will return the complete rendered prompt and attributed recent/evidence text from one implementation. Host-owned component assignments identify message provenance; role alone cannot distinguish recent human content, historical evidence and the mandatory request.

| Component | Selected-tokenizer input |
|---|---|
| Recent | Actual rendered recent-message blocks, in delivery order, including role delimiters, capture labels and assistant-history framing |
| Historical evidence | Actual rendered evidence block, including introduction, source IDs, status, timestamps, digests, offsets and quoted spans |
| Complete request | Existing full provider rendering, including mandatory system/current input and the generation prefix |

Apply the provider's actual ASCII trimming and think-tag normalization. Exact component tokenization is not an additive attribution of whole-request usage. Whole-request admission still counts the full rendered prompt independently; no sum or difference of component counts substitutes for it.

Count with the verified selected-model `/tokenize` binding. Empty components count zero without a request. Counts consume HTTP attempts and elapsed time under the original episode; they are not additional generative input charges. Calibration and answering retain their full prompt/model/output charges.

An immutable count receipt binds text digest, token count, tokenizer-work ID, episode, adapter identity and renderer version. Tokenizer work retains the exact rendered-text request and its committed count evidence. All receipts share the original verified session's boot domain and continuous-clock timestamp; component calls do not extend its 30-second validity. A failure to read the original lease clock rejects handoff. The final admitted context binds the final source snapshot, canonical body, frozen component policy, component receipts and whole-request receipt. Dispatch rejects changed body, text, source selection, scope, policy, observed model metadata, template or thinking state.

## Preparation and reduction

1. Preserve the accepted request and mandatory host/current messages. Verify the adapter once through a cancellable counting/admission session.
2. Count mandatory-only input early; fail intact if it cannot fit with unchanged output and safety reservations.
3. Select bounded whole recent messages. Count their rendered component; if it exceeds its cap, remove the oldest half, rounding up, and recount. Retain a contiguous suffix.
4. Retrieve historical evidence using the final retained recent IDs as exclusions. A source removed from recent context becomes eligible for retrieval.
5. Validate original spans and frame the evidence. Ordinary v1 removes half the evidence spans on overflow, rounding up, and recounts. Explicit v2 first removes half the optional neighbor suffix, then primaries if needed. Preserve order and whole spans.
6. Count the complete canonical candidate. On envelope overflow, reduce evidence first and then oldest recent messages under the same rules. Recount every changed component and complete request.
7. Explicit v2 additionally fits the actual proof-bearing delivery audit before freezing selection work. Audit-size exclusions remove one suffix span at a time, neighbors first; recount changed evidence and the whole prompt under the original lease. Reconcile the authoritative terminal receipt before successful publication.

This geometric reduction bounds calls and can underfill an allocation. It is a declared selection rule, rather than maximal packing. Do not assume token-count monotonicity after deleting text; termination follows from decreasing source count. All counts, reductions, retrieval passes and calibration use the same episode and preserve previous charges. Output headroom and the complete current request remain fixed.

## Session and allocation guards

Refactor provider admission into one verified session for component counts and final body admission. Reuse an unchanged count only under its identical verified binding and original validity period. Identity drift or expiry requires rejection or re-verification within remaining allowances. No unsupported batch endpoint, offline tokenizer or cross-episode cache is assumed.

The component allocation freezes these independent materialization guards with `qwen38-attributed-text-v1`. Explicit experimental v2 uses `primary-first-neighbor-geometric-v1`; the v1 default retains `whole-source-geometric-v1`:

| Guard | Limit |
|---|---|
| Serialized recent-message array | 180,000 bytes |
| Recent candidate rows | 256 |
| Historical primary candidates | 16 |
| Historical spans | 16 in default v1; 48 in explicit experimental v2 |
| Individual historical excerpt | 4,096 UTF-8 bytes |
| Serialized framed evidence-message array | 131,072 bytes |
| Complete serialized message array | 1,900,000 bytes |
| Complete HTTP request body | 2 MiB |

These guards bound materialization and do not estimate tokens. Byte/row exclusions and token/envelope reductions are recorded separately. Exact UTF-8 source-ID sets reach SQL filtering, metered retrieval, semantic fusion and replay before candidate limits; Swift's canonically equivalent string equality cannot collapse distinct stored IDs.

Selected-Qwen historical preparation also records an auxiliary `historical-selection-trace-v1` audit. It contains the lexical query digest, selected alphanumeric-token ordinals, up to 16 returned candidate IDs/ranges and their assembly decisions. The original trace wave retained `prefix-eight-nonfiller-v1`. Current `quoted-anchor-round-robin-v1` prioritizes complete double-quoted, curly-quoted and backtick spans, round robin across at most eight spans of at most 16 KiB each, then fills remaining slots from prompt prose. The original eight unique non-filler terms, 128-byte term and 1,024-byte query limits remain. Unmatched or oversized spans fall back to ordinary prose; apostrophe quotation is not recognized. Token ordinals retain Foundation alphanumeric splitting and refer to the original full prompt. This is literal prioritization, not question understanding. Evidence/recent reductions retain the original trace so diagnostics can compare assembly with final delivered ranges. The trace describes returned results; it does not enumerate every pre-ranking candidate or prove answer sufficiency. It contains no query terms, excerpts or response text. If adding it exceeds the 32 KiB delivery-audit ceiling, omit auxiliary selection/adjacency metadata and add fixed omission codes when that code also fits. Core provenance and request acceptance keep their existing limits.

Persist an optional component policy in episode limits; old journals decode it as absent and unverified. Its decoder rejects unknown fields and changed frozen limits. Retain original excerpt offsets, source/delivered digests and the final retained subset in the delivery audit. Record counting/reduction versions, rendered digests, source-order digests and exclusion causes within a bounded durable representation.

The full canonical selection document contains ordered recent source metadata, historical range references, message hashes, scope/current-request binding and selection audit. A completed `sourceRead` work record stores it in the existing bounded authoritative snapshot journal and charges one memory operation plus bounded metadata work. The small delivery audit links its work ID and digest. Invocation admission recomputes that digest and checks request bytes, source metadata and count-work evidence before commit, without rereading source payloads already verified by metered assembly. Offline journal/archive verification additionally compares each bounded historical range to its original source bytes. This validates internal linkage; it does not authenticate an archive against deliberate rewriting of all evidence.

The preceding identity-framing wave used `context-source-snapshot-v2`. Each recent message carries a host metadata line with JSON-escaped event ID, original role and capture status, followed by `Original message text:` and the original payload. Incomplete-capture notices remain first. Metadata and framing consume the same recent and whole-request budgets as the payload. Stored source bytes, digests and roles remain unchanged. Identifiers containing quotes, controls or Unicode line separators remain one metadata line and preserve exact UTF-8 identity. Payload text resembling metadata remains original payload; these delimiters do not establish model resistance to injected instructions.

Stored `context-source-snapshot-v1` selections retain their exact old unlabelled framing. Validation dispatches from the coupled selection, binding and source-read adapter versions, rejecting unknown or mixed versions and mislabeled bodies. V1/V2 validate original payload length/digest and role. V1 count proofs and archived invocations are verified against their stored bodies; they are never upgraded in place. The v2 framing wave added no database schema migration or token-cap change.

Final admission rereads observed server/model/template metadata within the same lease. The descriptor records `mlx-serve-model-observation-v1` and explicitly sets model-instance identity to `unobservable`; it binds the selected model, owner, engine, architecture, model context/position limits, advertised capabilities/modalities, server version and template digest. Receipt and component proof retain the same validated canonical descriptor, and the adapter identity includes its digest. Legacy epoch slots are zero for new observations and have no identity meaning. Historical receipts without a descriptor retain their original decode and journal representation.

The pinned [mlx-serve model-list implementation](https://github.com/ddalcu/mlx-serve/blob/25e94c3381c7f8428c4b0e45e814d2554c4926be/src/server.zig#L6243-L6248) sets `created` from the response-time clock. It is excluded from identity comparison. Calibration is scoped to one preparation operation or component session; independent sessions cannot reuse a calibration because the provider exposes no stable load generation.

mlx-serve offers no atomic identity lease spanning observation and answer dispatch. An unload/reload, weight replacement or restart preserving all advertised metadata remains unobservable. The supported count contract is conditional on the verified rendering/tokenizer/calibration observations and terminal model/usage checks. It does not attest model weights or the server binary. Observed model/count mismatch and quarantine remain authoritative for detected drift.

Exact support initially covers the verified Qwen/mlx-serve text adapter. Native paths retain unknown component counts in development mode and fail strict unsupported admission. Apple encoder input tokens remain a separate opaque inference. Browser reads need no answering-token admission. Retrieval-only evaluation keeps token feasibility unknown until a declared tokenized-selection/answering protocol accounts for verification, calibration and costs.

## Verification and ownership

Required fixtures cover exact cap boundaries; intact mandatory overflow with unchanged output/safety; role/capture/source labels and Unicode normalization; attributed rendering equal to the complete production renderer; deterministic suffix/span reductions and audits; dropped-recent eligibility; changed-proof rejection; Stop/deadline/HTTP exhaustion without quota renewal; unknown calibration and quarantine; historical policy decoding; unsupported native counts; and deadline crossing final publication.

| Owner | Surface |
|---|---|
| Context | Attributed source selection, staged recent/evidence preparation, deterministic reductions and final span audit |
| Provider | Attributed renderer, verified counting session and immutable receipts |
| Ledger | Optional frozen component policy and legacy validation |
| Coordinator | GUI/CLI canonical-body handoff and composition |
| Evaluation | New development configuration/source freeze and decision-sheet version after adoption |

Held-out execution remains gated on the complete baseline, credible workload/power design and frozen comparison configuration.

### Bounded following-assistant evidence

This section records the expansion retained by ordinary v1. Explicit experimental v2 uses the [bounded neighborhood contract](BOUNDED-NEIGHBORHOOD.md); legacy byte-only preparation also keeps this earlier path.

Ordinary historical selection can add the immediate next published assistant event in a matching human event's conversation. `following-assistant-prefix-v2` validates the scoped original anchor, reads one indexed same-conversation metadata row within the search's original source frontier, and applies current/recent exclusions before any neighbor payload read. A human boundary, absent row, excluded source or empty assistant yields no added excerpt. It never skips a boundary or infers relationships from event IDs, timestamps or importer pair labels. Publication adjacency is not an authoritative reply/turn link; late assistant publication can make this heuristic inappropriate.

The added excerpt is the scalar-safe first 4,096 UTF-8 bytes, with its original source digest, length, role, status and offset. Partial capture and prefix truncation remain explicit. Complete original content stays in the store. Human anchors retain selection order; an adjacent assistant prefix follows each eligible anchor. A complete existing primary prefix can be promoted to that position, retaining its exact span and avoiding another payload read. Distinct primary spans from one source remain available. Prefixes are suppressed only when an actually retained span covers the desired prefix range. A short or nonzero-offset span from that source does not establish coverage; the paid prefix is added. Promotion prevents a future complete primary span being dropped by the candidate cap after suppressing the prefix. Exact duplicate spans are deduplicated. Final selection has at most 16 candidates; interleaving can displace lower-ranked primary hits, and the metadata audit records retained/dropped/promoted counts and fixed decisions.

Metadata validation and source paging are prefunded under the same lease and existing caps. Page reads charge two logical passes; the assembler separately charges source revalidation. Exhaustion refuses the preparation; no allowance is renewed. Recent-only skips query/neighbor selection entirely. The original semantic manifest records primary search results; `exchange_expansion` records the additional adjacency step, and the selection receipt/final source ranges bind actual delivered excerpts. Later token/envelope reductions can remove them. Auxiliary audit overflow preserves the core source/count/body proofs.

### Preceding human evidence

This section records the ordinary v1 component path and its earlier measurements.

The shared selected-Qwen component path also expands selected assistant sources to the immediately preceding published human source in that same conversation. `adjacent-exchange-prefix-v3` retains the original human-to-following-assistant behavior and adds this reverse direction. The direct legacy preparation path and default standalone expansion keep the preceding contract. The matching app passed 3,555 checks, including 36 new reverse-expansion contracts and a counted pair fixture through invocation/archive/restore. The unchanged-input comparison recovers one complete positive turn (8/11 total), with 11/14 operational completions and local-judge acceptance of hybrid 3/7. It establishes no answer-quality improvement; see [STATUS.md](STATUS.md#preceding-human-sources).

The source lookup validates the exact original anchor and frozen frontier. It inspects one immediate publication; an assistant boundary, excluded human, missing row or empty source prevents expansion. It never searches farther back. Primary and promoted source metadata must retain the exact original date as well as scope, role, capture status, length and digest. Partial and cancelled sources remain marked. Prefixes use the same scalar-safe 4,096-byte page and prepaid two-pass read. Candidate order keeps the selected primary first and the neighbor next; at most one neighbor is added per original primary, with no recursive expansion.

Existing complete primary prefixes are promoted or reused without a second payload read; short fragments do not suppress a complete prefix. The final 16-candidate limit, geometric token/envelope reduction and original episode allowance remain in place. Interleaving can displace lower-ranked primaries. Audit decisions record `preceding_human` or `following_assistant`, fixed boundary/exclusion reasons and retained/dropped/promoted counts. The delivered source/body/count receipt validates the actual result. Publication adjacency remains a heuristic and does not establish an authoritative reply link or semantic sufficiency.

### Declared original-source diagnostic

An optional internal `evidenceSourceIDs` selection supplies original sources through the same coordinator and component preparation. It requires hybrid strategy and the accepted request's funded lease. The bounded unique IDs are resolved against one frozen project frontier; every scoped reference is validated before any selected payload is read. Each original must fit the existing 4,096-byte page and the declaration has at most 16 sources. Current input, foreign scope, missing/empty/oversized originals and invalid IDs are refused.

Complete scalar-safe payloads retain their original role, status, date and digest. Already retained recent sources contribute to the complete union without duplicate historical evidence. Historical assembly rereads and verifies the original ranges under existing funding and token/envelope caps. The path performs no ranking, query embedding or neighbor expansion. `declared-original-sources-v1` records selected IDs by ordered digest, counts, original bytes and frontier; later reductions can remove declared sources.

This is a separate diagnostic hook. Native version 6 pins six complete LongMemEval histories/questions and their original-source packs. Post-terminal inspection validates actual source/body/count linkage and full declared coverage independently of answer completion; offline inspection is outside episode accounting. Source delivery does not establish semantic sufficiency. See [the complete-source control contract](LONGMEMEVAL-SOURCE-CONTROLS.md).

## Original date delivery

`context-source-snapshot-v3` and v4 selections include host `captured_utc` and exact `source_time` object/null with recent messages and historical excerpts. Original payload bytes remain unchanged. The actual framing participates in serialized and provider token caps; funded source validation reads the bounded date field from the existing metadata row. Source selection and original-input receipts bind it, including unknown dates. V1/v2 use their stored framing, metadata hashes and SQL projections, including archives that lack the schema-10 column. Source dates retain their precision and explicit or unknown timezone; civil-day filtering and original date delivery do not establish temporal answer accuracy. See [source-time evidence](SOURCE-TIME.md).

## Quoted source framing (v4)

`context-source-snapshot-v4` is the default for new selections (October 9, 2026). The component counts, caps and reductions are unchanged. What changes is the rendering of the components:

- A recent component is one host-quoted **user** message per retained source, whatever its original role. The message opens with the quoted-source heading and its citation label, followed by `role:`, `capture_status:`, `captured_utc:`, `source_time:` and `quoted_text:` lines. The original text runs to the end of the message, so the chat-template message boundary still ends it. Validation checks the exact prefix for the source's delivery position and the exact original bytes, digest and byte count. It refuses an assistant role.
- Historical blocks carry `[E<n>]` labels on their `BEGIN` and `END` lines and no `event_id:` line. Labels continue after the recent sources.
- The selection document adds `citation_label_version` (`context-citation-labels-v1`) and `citation_labels`. Journal validation recomputes both from the recorded recent IDs and historical sources and requires exact equality. V1 to V3 documents must not carry them.
- The System framing for v4 is a separate fixed literal (`ContextAssembler.historyFraming(selectionVersion:)`). The mandatory-message binding hashes the framing actually delivered, and original-input proofs strip the framing of the journaled selection version.

Recent reduction removes the oldest half and re-frames the retained suffix from `E1`. Evidence reduction keeps the recent labels and re-renders the evidence block. V3 selections keep their exact bytes and validation path.

## V5 and the V4 no-G ablation (System framing only)

Implemented October 9, 2026, for measurement; not the default. Two further selection versions share the v4 rendering. `ContextSourceFraming.quotesSources` covers all three: the same quoted recent messages, labels, label map, historical blocks, journal shape, reductions and validation path. Only the fixed System framing differs. A contract derives both from the v4 literal, whose SHA-256 is pinned.

- **`context-source-snapshot-v5`**: v4 with the second fix G sentence replaced by the scoped rewording from [the 54026fce diagnosis](ANSWER-PRESENTATION-DEFECTS.md#proposed-mitigation-not-implemented). Before saying something is not shown, the model must check every quoted source, including the historical excerpts. Advice requests are tailored to user details from any quoted source, with labels cited. A decline is allowed only when a specific fact from the user's past is missing, and it names "the quoted sources". The no-disclaimer clause stays. The excerpt-block scope header that the diagnosis offered as an alternative is not added, so the System text is the only difference.
- **`context-source-snapshot-v4-no-g`**: v4 without both fix G sentences. It is evaluation-only. `ContextSourceFraming.permits` refuses it unless `GenerationSettings.evaluationOnlyFramingPermitted` is set. Only `--answer-evaluation --context-framing context-source-snapshot-v4-no-g` sets that flag. The coordinator checks it at acceptance, before any request is stored, so Send can never use the ablation.

Each version has its own mandatory-message binding. A v4 binding paired with a v5 or ablation body is refused, and so is the reverse. Selection digests differ, and the label map is byte-identical to v4's for the same delivery. See [FRAMING-V5.md](FRAMING-V5.md).
