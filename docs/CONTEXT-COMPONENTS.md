# Exact context component limits

Status: implementation contract for the next answering wave, October 4, 2026. Current answering enforces exact whole-request admission and aggregate episode allowances. Recent/evidence selection still has byte allocation guards. The matched component-token configuration remains incomplete.

Use `selected-model-context-components-v1` with 8,000 recent tokens and 12,000 historical-evidence tokens. Freeze counting, reduction and independent byte/row guards together before registered measurement. The original decision sheet and preregistration remain unchanged; the next development amendment will identify this configuration after implementation stabilizes.

## Exact counting

The verified Qwen renderer will return the complete rendered prompt and attributed recent/evidence text from one implementation. Host-owned component assignments identify message provenance; role alone cannot distinguish recent human content, historical evidence and the mandatory request.

| Component | Selected-tokenizer input |
|---|---|
| Recent | Actual rendered recent-message blocks, in delivery order, including role delimiters, capture labels and assistant-history framing |
| Historical evidence | Actual rendered evidence block, including introduction, source IDs, status, timestamps, digests, offsets and quoted spans |
| Complete request | Existing full provider rendering, including mandatory system/current input and the generation prefix |

Apply the provider's actual ASCII trimming and think-tag normalization. Exact component tokenization is not an additive attribution of whole-request usage. Whole-request admission still counts the full rendered prompt independently; no sum or difference of component counts substitutes for it.

Count with the verified selected-model `/tokenize` binding. Empty components count zero without a request. Counts consume HTTP attempts and elapsed time under the original episode; they are not additional generative input charges. Calibration and answering retain their full prompt/model/output charges.

An immutable count receipt binds text digest, token count, tokenizer-work ID, episode, adapter identity and renderer version. The final admitted context binds the final source snapshot, canonical body, frozen component policy, component receipts and whole-request receipt. Dispatch rejects changed body, text, source selection, scope, policy, model epoch, template or thinking state.

## Preparation and reduction

1. Preserve the accepted request and mandatory host/current messages. Verify the adapter once through a cancellable counting/admission session.
2. Count mandatory-only input early; fail intact if it cannot fit with unchanged output and safety reservations.
3. Select bounded whole recent messages. Count their rendered component; if it exceeds its cap, remove the oldest half, rounding up, and recount. Retain a contiguous suffix.
4. Retrieve historical evidence using the final retained recent IDs as exclusions. A source removed from recent context becomes eligible for retrieval.
5. Validate original spans and frame the evidence. If its count exceeds the cap, remove the last half of selected spans, rounding up, and recount. Preserve order and whole spans.
6. Count the complete canonical candidate. On envelope overflow, reduce evidence first and then oldest recent messages under the same rules. Recount every changed component and complete request.
7. Reconcile the authoritative terminal receipt before successful publication.

This geometric reduction bounds calls and can underfill an allocation. It is a declared selection rule, rather than maximal packing. Do not assume token-count monotonicity after deleting text; termination follows from decreasing source count. All counts, reductions, retrieval passes and calibration use the same episode and preserve previous charges. Output headroom and the complete current request remain fixed.

## Session and allocation guards

Refactor provider admission into one verified session for component counts and final body admission. Reuse an unchanged count only under its identical verified binding and original validity period. Identity drift or expiry requires rejection or re-verification within remaining allowances. No unsupported batch endpoint, offline tokenizer or cross-episode cache is assumed.

The current 24,000 recent bytes, 12,000 evidence bytes and 65,536 total serialized bytes often bind before token caps. The next baseline should enlarge independent allocation guards within bounded recent candidates, at most 16 historical spans of 4,096 bytes, a fixed recent candidate count and the existing 2 MiB HTTP envelope limit. Freeze exact byte/row values after synthetic boundary checks. These guards bound materialization and do not estimate tokens. Report byte-limited exclusion separately from token-limited exclusion.

Persist an optional component policy in episode limits; old journals decode it as absent and unverified. Retain original excerpt offsets, source/delivered digests and the final retained subset in the delivery audit. Record counting/reduction versions, rendered digests, source-order digests and exclusion causes within a bounded durable representation.

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
