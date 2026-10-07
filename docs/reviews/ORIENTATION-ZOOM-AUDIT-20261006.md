# Orientation and inspection correctness audit

The October 6, 2026 audit examined committed code and existing private captures without running the experiment, its continuation, or any provider call. The user explicitly prohibited another run until they authorize it. Restored credits alone do not authorize resumption.

The recorded source projections, request/response provenance and aggregate arithmetic reproduce correctly. The experiment has a material blinding defect. Its earlier 11/13 headline must not be treated as clean accuracy evidence. Mechanical verification did not establish experimental validity.

## Identifier leakage

[The projection](../../scripts/evaluate_orientation_zoom.py#L86) constructs every event ID from the benchmark question ID. All five abstention question IDs end in `_abs`; every source event in those histories therefore exposes that suffix. Existing receipts confirm exposure in all fifteen abstention final-answer requests, twenty planner requests and five overview requests. The reader can infer an answerability cue without inspecting the requested facts.

Original session IDs are also copied into model-visible records. Ten distinct session IDs across the abstention histories contain `_abs`, affecting 118 records. Another 24 records in answerable histories contain the same marker. Removing the constructed event-ID suffix alone would not close the metadata boundary.

The five abstentions cannot support blinded accuracy claims. A future authorized comparison needs opaque event and session IDs in every model-visible field, with private mappings back to original provenance and scorer annotations. Blinding tests must inspect derived metadata as well as forbidden field names. The v1 continuation preserves the same cue and cannot repair this experiment by reusing its requests.

## Summary and receipt limitations

[Overview validation](../../scripts/orientation_zoom.py#L374) checks region coverage, the 240-character summary bound and valid links within the correct session. It establishes structural coverage. It does not establish factual summary accuracy, meaningful retention of relevant details, or support of the summary by its cited originals. The flat overview tests one restrictive implementation of orientation; its result cannot reject the general orientation/zoom idea.

Tool receipts are saved before [actual token fitting](../../scripts/evaluate_orientation_zoom.py#L324). Offline reconstruction found additional older-block trimming in fifteen of twenty-eight tools. No newly returned records were lost, and none were missing from the sixteen subsequent planner requests. This does not invalidate the observed annotated-turn counts, but token-fit evictions are reconstructed from count traces rather than enumerated in the saved tool receipt. Future receipts should bind the final fitted pack and every eviction.

The original report's paired QA counters convert unknown to not-yes. Its nineteen both-not-yes rows include seventeen unresolved comparisons and two matched rejections. Public matched-subset tables were computed separately and reproduce correctly. The raw all-thirty counters do not establish paired quality outcomes.

## What the existing observations establish

Independent checks reproduce all thirty questions and original question dates, all 14,652 original records across 1,407 sessions, and every whole-history overview input against the pinned dataset. No source-content corruption was found. The report retains all ninety rows: forty-three answers completed, and thirteen histories have valid QA in all three arms.

After separating the five contaminated abstention cases, the matched answerable subset contains eight histories:

| Existing answerable observations | Lexical exchange | Inspection | Orientation and inspection |
|---|---:|---:|---:|
| Model QA accepted | 6/8 | 6/8 | 6/8 |
| Full annotated turns delivered | 17/23 | 20/23 | 18/23 |

These observations show no orientation answer gain. They cover knowledge updates and multi-session questions only. Four other answerable categories remain unjudged; same-family model judgments are uncalibrated. The experiment uses standalone lexical complete-exchange retrieval and a Sol reader, bypassing native Boros retrieval and its selected-Qwen path. It cannot determine production Boros quality or explain all prior retrieval failures.

## Spending and stop behavior

All 1,066 operation receipts reproduce the report's usage totals. The standard-rate observed estimate is $14.436816, including $8.247586 for whole-history overview creation. It applies no cached-input discount and excludes unknown usage; it is not an invoice. The input/output reservation caps were explicit, but there was no user-specified dollar ceiling.

The original runner did not stop dispatching other stages after a provider HTTP 429. Sixty-seven generation requests failed with that status. This was poor fail-fast behavior. The later continuation controller stops new work on the first count or generation HTTP 429, but that safeguard does not change what the original run did or remove its identifier leakage.

The prior sixty-one synthetic contracts remain mechanical evidence for their tested implementation boundaries. This audit did not rerun them or any model work. No experiment/evaluator/continuation process is running. Original report SHA-256 remains `81cc1582829969ee22cc01c53d4e63d594b10bc03dac14173079cd334122041c`; the earlier verification remains unchanged. Original captures and findings are preserved separately.

## Current decision

Hold all paid and local-model experiment execution until the user explicitly authorizes it. Do not automatically resume v1 after credits become available. A future proposal should first close identifier leakage, distinguish structural coverage from semantic fidelity, publish final fitted-pack receipts, separate unknown paired outcomes, and declare a dollar ceiling and stop conditions. Its corrected requests require a new experiment identity; earlier receipts remain evidence of what actually happened.

The user later authorized a separate [local JevK5 QA pass over saved answers](../JEVK5-SAVED-QA.md). That pass makes no new answers or retrieval attempts and does not lift the experiment hold. Its second-model judgments agree with Sol on the eight matched answerable cases; they do not repair the original identifier leakage or establish summary fidelity.
