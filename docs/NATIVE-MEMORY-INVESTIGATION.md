# Experimental native memory investigation

Implemented October 6, 2026 on `codex/native-investigation`, in an isolated checkout of the committed foundation. Checkout: `/Users/johnshahbazian/.codex/worktrees/native-investigation/boros`. Prior uncommitted evaluation changes in the original checkout remain preserved. This is an opt-in preparation route through the native application's shared `AnswerAttemptCoordinator`.

The Settings panel exposes **Investigate memory (experimental)** for the verified local Qwen adapter. The option starts off, stays runtime-only, and is frozen when Send accepts a turn. It adds private planner and extraction calls before the one visible answer. No remote production adapter is enabled.

## Execution path

1. Accept the exact question and freeze one episode allowance.
2. Load and seal every original record in the accepted project at a fixed source frontier, excluding the newly accepted question. Validate authoritative payload length, digest, scope, status, original date evidence and scalar-safe pages before indexing.
3. Build a question-blind multiscale lexical history map and a full-snapshot exchange index. Present an aggregate over all originals plus bounded, pageable region detail. Topic cues are literal navigation terms; semantic summary fidelity is not claimed.
4. Select initial question matches and recent complete exchanges. Questions outside the lexical query contract still reach the planner with the map and recent evidence. Permit up to six deliberate search, zoom or overview actions, with bound cursors, explicit missing facts and whole-exchange pins.
5. Extract source-referenced facts. Every citation must name a delivered opaque source and supply an exact nonempty quote. Quoted membership is checked; claim interpretation is unvalidated. Referenced exchanges become protected for final selection.
6. Count and admit a final request containing the original question, normal host framing and selected original evidence. Derived extraction prose stays out of that request. Its existing version-3 original-input proof and visible invocation journal remain authoritative.

The final reader does not receive extracted claims or the planner's missing-fact list. The GUI notice reports unresolved facts when present; ordinary host framing says missing excerpts do not prove archive absence. A future derived-note reader requires a separate framing and provenance contract.

Model-facing private IDs are ordinal projections. Imported identity strings, date locators and date normalization metadata stay host-only; original date literals survive. Private stage bodies and streamed output are durably retained in private episode snapshots. Private output never reaches transcript callbacks. The final answer cites the ordinary original event IDs.

Each planner, extractor and final reader gets a fresh selected-model component session. Counts, calibration, private generation, reads and final generation consume the same original lease. The final invocation has exactly one accepted human and one visible assistant. A private failure prevents final dispatch. Stop and deadlines fence future handoffs; the host waits for owned private generation to drain before becoming ready. Client cancellation cannot prove immediate server compute cancellation. Unknown dispatched usage retains its original output hold.

## Fixed limits

| Limit | Native default |
|---|---:|
| Complete snapshot ceilings | 20,000 records / 32 MiB original UTF-8 |
| Search query | 16 KiB / 256 distinct content terms |
| Navigation actions | 6 |
| Delivered evidence | 16 scalar-safe spans, each at most 4,096 bytes; at most 48,000 original bytes |
| Selected-model evidence cap | 12,000 actual tokens |
| Planner / extraction output | 1,024 / 2,048 tokens |
| Final output | Accepted GUI output setting |
| Aggregate model input / output reservations | 1,000,000 / 64,000 tokens |
| Aggregate model calls / HTTP attempts | 32 / 160, including calibration |
| Memory operations / metadata rows | 20,000 / 200,000 |
| Funded raw source work | 512 MiB |
| Vector bytes / encoder bytes | 0 / 0 |
| Original turn deadline | 300 seconds |

An explicit caller allowance remains authoritative. The snapshot ceilings are upper bounds; another original resource limit may stop preparation earlier. Larger snapshots refuse before original payload access. Navigation and the index are rebuilt per accepted investigation turn. Startup cost, resident memory and corpus-scale latency are unmeasured.

Whole exchanges are atomic. Oversized or unpinned exchanges may be omitted; protected exchanges that cannot fit fail admission. A host-observed count overflow permits at most two reductions of whole unpinned units per stage, each under the original allowance. It never retries a dispatched generation. Ordinary individual-span reduction is disabled for the preselected final snapshot. Search candidates, selected originals and actual counted delivery remain distinct evidence.

This native route uses lexical search and no query embedding. Paraphrase recall, planner behavior, semantic extraction accuracy, abstention quality and answer improvement require real workload evidence.

## Synthetic verification

Run a fresh build without launching an ordinary model-connected session:

```sh
python3 scripts/build.py --output .build/native-investigation-final
python3 scripts/check.py --app .build/native-investigation-final/Boros.app
```

The default checker includes pure navigation/admission contracts and a loopback fixture exercising the actual coordinator, selected-model counts, private endpoint stages, final input proof, capture and backup restore. Fixtures use fixed public synthetic text and scripted responses. They cover complete correcting exchanges, protected fitting, opaque private IDs, default-off behavior, Stop/deadline barriers, malformed planner output, invented quotes, missing private usage and suppression of late private output. Outputs contain only names, booleans and counts.

The optimized build passes **4,024 application checks**, including 53 pure native navigation/admission checks, 248 actual-coordinator loopback checks and 119 GUI checks. All 164 captured source/test files match; strict deep signature verification passes. Standalone investigation unit tests pass 79/79. Legacy orientation tests pass 60 with one private-upstream runtime fingerprint check skipped in this isolated checkout. The final verification receipt and source manifest live in ignored `.build/native-investigation-final`. The earlier failed integration attempts remain retained separately. These checks establish implementation mechanics. No live model answer, retrieval benchmark, judge call or paid provider call is part of this wave. The user's experiment hold remains in effect. Quality comparison and promotion require explicit authorization; enabling the checkbox is not recorded experimental evidence.

## Authorized local trial

On October 7 the user authorized a small local trial through the supplied JevK5-4B connector. An explicit `--investigate-memory` amendment to the pinned version-7 answering CLI exercises recent-only and native investigation arms with separate mode receipts, private retained stores and failure-driven termination. The one-shot controller freezes three source-blind ranked development histories and all six denominator rows before dispatch. Its public judging controls pass 6/6, but the first Qwen calibration fails before retrieval or any investigation dispatch. Zero answers complete; five arms remain unrun. [The trial record](NATIVE-INVESTIGATION-LOCAL-TRIAL.md) preserves evidence, limits and the bounded transport repair. This yielded no answer-quality measurement. The prior paid experiment remains held, and this trial has not been rerun.
