# Answer presentation defects

Status, October 9, 2026:

- **Implemented (diagnosis):** `scripts/answer_presentation_defects.py`, an offline diagnostic, and `scripts/test_answer_presentation_defects.py`, run by `scripts/check.py`.
- **Implemented (fixes A, D and G):** the `context-source-snapshot-v4` framing, now the default. See [Implementation of fixes A, D and G](#implementation-of-fixes-a-d-and-g).
- **Implemented (fix E):** rendered Markdown and inline math in the GUI answer display. Display only. See [Fix E](#fix-e-rendered-answer-display).
- **Not implemented:** fixes B, C and F.
- **Measured (diagnosis):** pattern counts over the seven flagged calibration answers and over all 192 saved Qwen and Sol answers with retained text. Also measured: a source comparison of the frozen run builds with `main` (`03f4196`).
- **Measured (replay):** one local Qwen generation per question under V3 and under V4 for the 7 questions with copied headers, 14 generations in total. V3 copied the header in 3 of 7 answers; V4 did so in 0 of 7. See [Replay](#replay-v3-versus-v4-on-the-seven-echo-questions).
- **Measured (fix G replay):** one local Qwen generation per question under V3 and under V4 on the recent-only arm of all 21 distinct questions, 42 generations in total. AI or memory disclaimers: V3 3 of 3 on the disclaimer questions (4 of 21 overall), V4 0 of 21. V4 declined on all 21; recent-only delivered no gold evidence for any question, so the declines match the evidence, but this cohort cannot detect a false decline. See [the recent-only replay](#replay-v3-versus-v4-on-the-recent-only-arm-of-all-21-questions).
- **Measured (fix G with retrieval on):** the 54026fce V4 decline in the seven-question replay is a false decline; its gold turn was delivered whole ([finding](#the-54026fce-decline-in-the-seven-question-replay)). A paired V3 against V4 replay of the same 21 questions on the recorded hybrid arm (not ordinary Send's lexical selection, which the runner cannot select): 42 local generations, judged by the default judge (126 Vertex verdict requests, $0.13). V4 declined 1 of 12 answerable questions whose gold turns were delivered whole (54026fce again). Judge accepts: V3 15 of 21, V4 16 of 21; 11 of 12 under each arm where gold was delivered whole. See [the retrieval-on replay](#replay-v3-versus-v4-with-past-conversation-retrieval-on-all-21-questions).

The diagnosis sections below describe the V3 framing as it was. This document contains no answer, question, evidence or history text. It quotes only host-authored code strings and describes answers by structure.

## The seven flagged answers

The user's 50-item adjudication ([JUDGE-CALIBRATION.md](JUDGE-CALIBRATION.md#answer-presentation-defects)) flagged seven Qwen answers. The note topics below come from a keyword match over the private notes, without printing them. Counts come from the raw saved answer, which the private key resolves to its run, arm and question.

| Item | Run | Arm | Note topic | Patterns found (occurrences) |
|---|---|---|---|---|
| item-024 | independent-v1 | hybrid | formatting, metadata | Envelope header echo at answer start (1). Raw event IDs (2). Markdown bold (6) and list items (5). Ends with a follow-up question. |
| item-028 | source-controls-v1 | hybrid | formatting, dollar signs | Inline `$...$` arithmetic (3 spans, 6 `$`). Raw event IDs (2), cited inline as `event_id: <id>` (2). Markdown bold (3) and list items (4). |
| item-030 | independent-v1 | recent only | prose | "As an AI" style disclaimer (1). Abstention question, no historical evidence delivered. |
| item-032 | natural-v5 | recent only | other | AI or memory disclaimer (1). Numbered list (3). Abstention question, no historical evidence delivered. |
| item-037 | neighborhood-v1 | recent only | formatting, metadata | Envelope header echo at answer start (1). Raw event ID (1). Markdown bold (16) and list items (12). Ends with a follow-up question. |
| item-039 | natural-v5 | hybrid | formatting, metadata, repeats the question | Envelope header echo at answer start, with `"role":"human"` (1). The question repeated verbatim after the header. Ends with a question. |
| item-049 | independent-v1 | hybrid | formatting, metadata, "Original message text" | Envelope header echo at answer start (1). Raw event IDs (2). Markdown bold (1). |

Totals over the seven answers (answers with the pattern, total occurrences):

| Pattern | Answers | Occurrences |
|---|---:|---:|
| Envelope header echo (`Recent source metadata (host): {json}` then `Original message text:`) | 4 | 4 |
| Echoed header naming the human role | 1 | 1 |
| Raw benchmark event IDs (`<question>-sNNNN-mNNNN`) | 5 | 8 |
| 64-hex digest (all inside echoed headers) | 4 | 4 |
| Inline `$...$` math | 1 | 3 |
| Markdown bold | 4 | 26 |
| Markdown list items | 4 | 24 |
| Ends with a question | 3 | 3 |
| Question repeated verbatim | 1 | 1 |
| AI or memory disclaimer | 2 | 2 |
| `<think>` tags, chat-template tokens, reasoning scaffold phrases, role-label lines, `Question:` lines | 0 | 0 |

The four answers whose notes mention metadata or "Original message text" are exactly the four that open with an echoed envelope header. The note about dollar signs matches the only answer with `$...$` math. The prose notes fall on the two recent-only abstention answers that carry an AI or memory disclaimer.

## Prevalence across all saved answers

The diagnostic reads the same captures as `judge_calibration.py inventory`. Those are the primary checkout's `.build/evaluation` and the `codex/native-investigation` worktree's evaluation directory. It measures every answer with retained text: 144 Qwen and 48 Sol. The cell format is answers with the pattern, then total occurrences in parentheses when they differ.

| Run | Arm | Answerer | Answers | Envelope header echo | Raw event ID | 64-hex digest | Inline `$...$` math | Markdown bold | Markdown list | Ends with a question | "As an AI" disclaimer | Talks about the context |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| adjacent-v1 | hybrid | Qwen | 5 | 0 | 5 (11) | 0 | 0 | 5 (20) | 3 (7) | 0 | 0 | 0 |
| adjacent-v1 | recent only | Qwen | 6 | 0 | 1 | 0 | 0 | 1 (2) | 0 | 0 | 1 | 0 |
| independent-v1 | hybrid | Qwen | 14 | 2 | 13 (24) | 2 | 0 | 10 (50) | 6 (29) | 1 | 0 | 5 (6) |
| independent-v1 | recent only | Qwen | 14 | 0 | 3 (11) | 0 | 0 | 6 (34) | 6 (42) | 1 | 2 | 2 |
| native-hundred-v1 | native investigation | Qwen | 7 | 0 | 0 | 7 (14) | 0 | 7 (23) | 3 (8) | 0 | 0 | 0 |
| native-local-trial-v2 | native investigation | Qwen | 3 | 0 | 2 (3) | 0 | 0 | 3 (12) | 1 (6) | 0 | 0 | 0 |
| native-local-trial-v2 | recent only | Qwen | 3 | 0 | 1 (2) | 0 | 0 | 1 (5) | 1 (4) | 0 | 0 | 0 |
| natural-v2 | hybrid | Qwen | 6 | 0 | 1 | 0 | 0 | 1 (2) | 0 | 0 | 0 | 6 (12) |
| natural-v2 | recent only | Qwen | 7 | 1 | 1 | 1 | 0 | 1 (5) | 1 (3) | 0 | 1 | 1 |
| natural-v3 | hybrid | Qwen | 7 | 2 | 7 (16) | 2 | 0 | 5 (36) | 4 (26) | 1 | 0 | 4 |
| natural-v3 | recent only | Qwen | 7 | 1 | 1 | 1 | 0 | 0 | 0 | 1 | 1 | 2 |
| natural-v4 | hybrid | Qwen | 7 | 2 | 6 (16) | 2 | 0 | 5 (34) | 4 (19) | 1 | 0 | 5 |
| natural-v4 | recent only | Qwen | 7 | 1 | 1 | 1 | 0 | 0 | 1 (3) | 1 | 1 | 1 |
| natural-v5 | hybrid | Qwen | 6 | 1 | 6 (11) | 1 | 0 | 5 (28) | 4 (11) | 1 | 0 | 3 (4) |
| natural-v5 | recent only | Qwen | 7 | 1 | 1 | 1 | 0 | 0 | 1 (3) | 1 | 1 | 2 |
| neighborhood-v1 | hybrid | Qwen | 14 | 3 | 14 (27) | 3 | 0 | 11 (33) | 6 (15) | 1 | 0 | 6 (7) |
| neighborhood-v1 | recent only | Qwen | 14 | 1 | 4 (8) | 1 | 0 | 4 (39) | 4 (31) | 2 | 2 | 3 |
| openai-controls-v2 | clean pack | Sol | 5 | 0 | 5 (15) | 0 | 0 | 5 (11) | 1 (3) | 0 | 0 | 1 |
| openai-controls-v2 | clean pack | Qwen | 5 | 0 | 5 (23) | 0 | 0 | 4 (24) | 2 (18) | 0 | 0 | 4 (5) |
| orientation-zoom-v1 | inspection | Sol | 13 | 0 | 13 (24) | 0 | 0 | 10 (26) | 3 (11) | 0 | 0 | 5 |
| orientation-zoom-v1 | lexical exchange | Sol | 17 | 0 | 17 (27) | 0 | 0 | 14 (25) | 4 (12) | 0 | 0 | 6 |
| orientation-zoom-v1 | orientation inspection | Sol | 13 | 0 | 13 (24) | 0 | 0 | 11 (24) | 3 (10) | 0 | 0 | 6 |
| source-controls-v1 | hybrid | Qwen | 5 | 1 | 4 (8) | 1 | 1 (3) | 5 (11) | 2 (6) | 0 | 0 | 2 (4) |

By prompt family:

| Prompt family | Answerer | Answers | Envelope header echo | Raw event ID | 64-hex digest | Inline `$...$` math | Markdown bold | Markdown list | Ends with a question | "As an AI" disclaimer |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Boros selected-Qwen envelope (native LongMemEval runs) | Qwen | 126 | 16 | 68 (138) | 16 | 1 (3) | 59 (294) | 42 (195) | 11 | 9 |
| Clean-pack controls (identical prompt for both models) | Qwen | 5 | 0 | 5 (23) | 0 | 0 | 4 (24) | 2 (18) | 0 | 0 |
| Clean-pack controls (identical prompt for both models) | Sol | 5 | 0 | 5 (15) | 0 | 0 | 5 (11) | 1 (3) | 0 | 0 |
| Native investigation (JSON records) | Qwen | 13 | 0 | 3 (5) | 7 (14) | 0 | 11 (40) | 5 (18) | 0 | 0 |
| Orientation pilot | Sol | 43 | 0 | 43 (75) | 0 | 0 | 35 (75) | 10 (33) | 0 | 0 |

Zero in all 192 answers: `<think>` or `</think>` tags, chat-template tokens, reasoning scaffold phrases, role-label lines (`User:`, `Assistant:`), `Question:` or `Question Date:` lines, historical-source block markers or field lines, the incomplete-capture notice, the clean-pack records label, Markdown tables, `$$` or `\(`-style math, and LaTeX commands.

Reading the counts:

- The runs are not independent. natural-v2 to v5, adjacent-v1 and source-controls-v1 reuse the same frozen seven questions. independent-v1 and neighborhood-v1 use the same 14. The 16 echoed headers fall on 7 of the 21 distinct questions, with 4, 4, 3, 2, 1, 1 and 1 echoes per question. They come from 11 of 64 hybrid answers and 5 of 62 recent-only answers.
- Sol never answered through the Boros envelope. Every Sol answer comes from the clean-pack or orientation prompts. "No Sol answer had these notes" therefore does not separate model from prompt. The one matched comparison is the clean-pack control, where both models receive the same prompt. There, Qwen shows no envelope echo, LaTeX or disclaimer. Both models cite raw event IDs in 5 of 5 answers and use Markdown bold in 4 and 5 of 5. With n = 5 per model, this is a small sample.
- Raw event IDs and Markdown appear in nearly every prompt family and in both models. Both are requested or tolerated by the prompts, and neither is specific to the flagged answers.
- "Talks about the context" is a loose phrase list ("excerpts", "the records", "provided context" and similar). It matches Sol as well, so it is a weak signal.
- The 7 native-hundred answers with 64-hex digests are a separate identifier exposure in the native investigation route. They have no envelope echo. Their cause was not investigated here.

## Root causes

### Envelope header echo: the model continues a demonstrated format

**Measured (16 of 126 envelope answers).** Every echo opens the answer. All 16 parse as JSON, and all 16 have exactly the current v3 recent-header key set (`capture_status`, `captured_utc`, `event_id`, `role`, `source_time`). In 14 of 16, the echoed `event_id` is the next message number after the last delivered recent message. The other 2 use another ID in the same format. All 16 IDs are absent from the history, so they are fabricated. 9 echoes claim the assistant role and 7 claim the human role. All 7 human-role echoes are followed by the current question verbatim; this is the "repeats the question" defect. In 9 of 16, the text after the header ends with a question mark. In every one of the 126 envelope answers, the last delivered recent message was an assistant message.

**Cause (source).** Every retained recent message, including each prior assistant turn, is sent under its original role. The message content begins with a host metadata header:

- `Sources/Boros/ContextAssembler.swift:756-761` (`message(_:)`): role `assistant` for assistant events, content = `recentPrefix(...) + event.text`.
- `Sources/Boros/ContextSourceFraming.swift:8` (`recentMetadataHeading = "Recent source metadata (host): "`) and `:45`, which append the sorted-key JSON metadata and `"\nOriginal message text:\n"`.
- `Sources/Boros/ContextAssembler.swift:399-401` (`historyFraming`), appended to the System text by `mandatoryMessages` at `:411-413`. It says "Recent messages carry host source metadata before the original message text" and "cite their event IDs".
- The current question carries no header (`ContextAssembler.swift:413`; evaluation prompt `AnswerEvaluationCommand.swift:258-261`, `Question Date: ...\nQuestion: ...`).

As a result, the prompt contains many assistant turns that all begin `Recent source metadata (host): {...}\nOriginal message text:\n`. For a chat model, the likeliest start of the next assistant turn is the same prefix, with the event number advanced by one. Sometimes the model continues the transcript as the next human turn instead. The model is copying the envelope from in-context examples: the key set and next-ID arithmetic match the host header, not anything in the evidence text. This is not thinking leakage.

**Product impact beyond evaluation (inferred from source, not measured live).** The GUI Send path uses the same `ComponentContextPreparation` and `ContextAssembler.message(_:)` (see [IMPLEMENTATION.md](IMPLEMENTATION.md)). Accepted answers are stored verbatim. An echoed header stored in one answer is then sent on the next turn after a real header, as part of that assistant turn's "original message text". That adds a second demonstration to the context. Whether this raises the echo rate in a live chat is unmeasured.

### Raw event IDs and `event_id:` citations: requested by the prompt

**Measured.** Envelope answers: 68 of 126 with 138 raw IDs. Clean pack: 5 of 5 for both models. Orientation (Sol): 43 of 43. In the blinded form, these IDs appear as `E<n>` or `[source]` labels, which reads as visible metadata.

**Cause.** `ContextAssembler.swift:400` tells the model to "cite their event IDs when they support the answer". Historical excerpts expose `event_id: <id>` lines (`ContextSourceFraming.swift:69-80`). Recent headers expose `"event_id"` (`:30`). The clean-pack prompt (`scripts/evaluate_answerer_controls.py:33-36`) also says "Cite source event IDs". The IDs are therefore the requested behavior, and Sol does the same. item-028 additionally writes them inline as `(event_id: <id>)`, mirroring the `event_id:` field-line form.

### Dollar signs: Qwen writes arithmetic as LaTeX, and nothing renders it

**Measured.** One answer of 192 (item-028, source-controls-v1 hybrid): 3 inline `$...$` arithmetic spans. No delivered context of any measured answer contains inline `$...$` math, so the answer did not copy the style from evidence. Sol: 0 of 48.

**Cause.** Model style for arithmetic. The GUI appends answers as plain monospaced text (`Sources/Boros/BonsaiPlayground.swift:1122-1127`, `:1265-1276`, `NSAttributedString(string:)`), and the adjudication form uses `textContent` with `white-space: pre-wrap` (`scripts/judge_calibration.py:803`, `:879`). Neither renders Markdown or LaTeX, so `$`, `**` and `1.` show literally. This is rare and model-specific in the saved set. The cause is a model habit plus raw display, not envelope copying.

### Markdown formatting: shown raw

**Measured.** Bold in 59 of 126 envelope answers (294 spans), 4 of 5 clean-pack Qwen, 5 of 5 clean-pack Sol and 35 of 43 orientation Sol. Lists are similar. No headings appear except in one answer, and no tables appear.

**Cause.** No prompt asks for plain text or for Markdown. Both models default to Markdown, and both display surfaces show it raw (references above). Markdown alone does not explain why only Qwen was flagged. In the flagged items it co-occurs with the envelope echo.

### AI or memory disclaimers in recent-only abstention answers

**Measured.** 9 of 62 recent-only envelope answers and 0 of 64 hybrid answers. Several are the same question repeated across runs. Sol: 0 of 48, but Sol never answered a recent-only arm.

**Cause (probable, not proven).** The recent-only arm delivers no historical evidence. `historyFraming` says "A missing excerpt is not proof that the archive lacks a fact" but gives no wording for an unsupported answer. Qwen falls back to a generic assistant disclaimer about lacking memory or personal access. A live comparison would be needed to establish this cause.

### Thinking or scaffold leakage: not observed

**Measured.** 0 of 192 answers contain think tags, chat-template tokens or reasoning scaffold phrases. All envelope runs used `thinking: false`. The selected-Qwen HTTP path excludes `reasoning_content` deltas from the visible answer (`Sources/Boros/EndpointRunner.swift:121`). Thinking-on output was not measured.

## Does current `main` still produce these conditions?

**Measured: yes, for every cause above.** Each run report pins the SHA-256 of its source files. All eight native LongMemEval reports pin a `ContextSourceFraming.swift` hash identical to current `main` (`03f4196`). Those reports are natural-v2 to v5, adjacent-v1, independent-v1, neighborhood-v1 and source-controls-v1. `ContextAssembler.swift` differs: the frozen builds match commits `7894907` and `64ccef2`. A block comparison shows its prompt-bearing parts are byte-identical to `main`: `historyFraming`, `mandatoryMessages`, `evidenceMessage` and `message(_:)`. The later changes are audit and provenance fields only. `ModelProfiles.swift` is identical. No current code removes or rewrites an echoed header in model output: `Recent source metadata` and `Original message text` appear only in framing code and checks. The GUI still renders plain text.

`python3 scripts/answer_presentation_defects.py envelope` reads the framing literals from current Swift source and renders a synthetic hybrid turn in `ContextAssembler` order. The result is: System text, then framed recent user and assistant messages, then the historical excerpts message, then the unframed question. The rendered literals are:

- Recent message prefix: `Recent source metadata (host): ` + sorted-key JSON (`capture_status`, `captured_utc`, `event_id`, `role`, `source_time`) + `\nOriginal message text:\n`.
- Historical block: `Historical source excerpts for reference:` then, per span, `BEGIN HISTORICAL SOURCE`, `event_id:`, `conversation_id:`, `role:`, `capture_status:`, `captured_utc:`, `source_time:`, `source_sha256:`, `excerpt_utf8_offset:`, `source_total_bytes:`, `quoted_excerpt:`, the excerpt, `END HISTORICAL SOURCE`.
- System suffix: the `historyFraming` paragraph quoted in the cause section, including "cite their event IDs when they support the answer".

A synthetic contract checks the extracted literals against the exact prefix asserted in `RecentSourceFramingChecks.swift:76`. If the framing changes, the rendering follows it.

**Not established offline.** Whether the current build's Qwen still echoes at the measured rate needs a live generation. The minimal test: replay the 7 echo-producing question-arm cases with the pinned model, `thinking: false`, temperature 0 and the same seed. Run them on current `main`, then repeat on a build carrying one proposed fix. Count `envelope_header_at_answer_start` with this script. That is 7 to 14 local generations, and it needs the user's authorization.

## Proposed fixes

This was the proposal at diagnosis time. A, D and G are now implemented as one framing version (next section). E is implemented separately (last section). B, C and F are not implemented.

| Fix | Would fix | Would not fix | Cost and risk |
|---|---|---|---|
| **A. Stop presenting framed text as the assistant's own prior output.** Send the recent transcript as one host-labelled user (or system) block of quoted messages. Prior answers would then not be assistant turns that begin with a header. Alternatively, keep the roles but move the metadata into a separate host-labelled index message, leaving each assistant turn's content as the original text only. | The in-context demonstration that drives the header echo, the fabricated next IDs and the human-role impersonation. This is the root cause for 4 of the 7 flagged items. | Raw ID citations, LaTeX, Markdown and disclaimers. | Changes the delivered body. That requires a new `context-source-snapshot` version, matching `ContextComponentJournal` validation, archive compatibility for v1 to v3, and new token counts. It may change answer quality, so it needs a live A/B. |
| **B. Less echoable labels and an explicit output instruction.** Replace `Recent source metadata (host):` and `Original message text:` with clearly non-conversational delimiters, for example XML-style `<source id=... role=...>` ... `</source>` tags. Add to the System framing: "Write only your reply. Never begin with source metadata, a header or a message label." | Probably reduces the echo rate. Gives a post-processor a fixed tag to strip. | Does not remove the demonstration if assistant turns still start with the tag. The model may then copy the tag instead. | Same versioning cost as A for the label change. The instruction alone is cheap but unproven on Qwen. |
| **C. Output post-processing.** Detect an answer-initial header, using exactly `RE_ECHO` in the diagnostic, and strip it from the displayed and stored answer. | All 16 measured echoes, deterministically, including the header text in item-039. | The question restatement that follows a human-role header in 7 of 16 echoes. The answer still is not an answer. Raw IDs, LaTeX, Markdown. | Conflicts with the rule to preserve complete accepted chat content. It would need a separately stored display projection or an explicit, recorded transformation, plus capture and archive contract changes. It treats the symptom only. |
| **D. Citation wording.** Replace "cite their event IDs" with a user-facing convention: no inline IDs, or short bracketed ordinals that the host maps to sources. | The visible metadata from raw IDs in 68 of 126 envelope answers, and the `event_id:` inline form. | The header echo, LaTeX and Markdown. | Changes the citation contract that the evaluation and support judges rely on. Needs a host-side mapping to keep provenance. |
| **E. Render Markdown and math in the GUI**, with a raw-text toggle. Use `AttributedString(markdown:)` for inline styles and lists, and a math renderer for `$...$` or plain-text substitution. | Raw `**`, list markers and `$` arithmetic as seen by a GUI user. | Anything in the adjudication form, the envelope echo, raw IDs and disclaimers. Rendering an echoed header makes it no less wrong. | GUI-only. Must keep the stored bytes unchanged. Markdown parsing of untrusted model output needs link and attachment restrictions. |
| **F. Plain-text style instruction** in the System framing: "Answer in plain prose; do not use Markdown or LaTeX." | Markdown and LaTeX at the source, for both display surfaces. | The echo, IDs and disclaimers. | Unproven adherence. Conflicts with E if both are adopted, so choose one. |
| **G. Insufficient-evidence wording** in the System framing: "If the supplied messages do not answer the question, say the saved conversation does not show it; do not describe yourself as an AI." | Probably the recent-only disclaimers (item-030, item-032). | Everything else. | Prompt-only. Unproven on Qwen. |

Recommended order, as a proposal: A (or B with an output instruction) first, because it addresses the only defect specific to the Boros envelope and the one behind most of the flagged items. Then D, or E or F, for presentation. C only as a temporary guard with an explicit display-projection contract.

## Implementation of fixes A, D and G

**Implemented, October 9, 2026.** One new framing version, `context-source-snapshot-v4`, carries all three fixes. It is the default for ordinary Send (selected-Qwen and native profiles) and for `--answer-evaluation` runs that do not pin a framing. V3 stays selectable and validates unchanged. [IMPLEMENTATION.md](IMPLEMENTATION.md) and [CONTEXT-COMPONENTS.md](CONTEXT-COMPONENTS.md#quoted-source-framing-v4) describe the contract.

### Fix A: variant chosen

Fix A had two variants. **Variant 1** quotes the recent conversation in non-assistant messages. **Variant 2** keeps the original roles and moves the metadata into a separate index message. V4 implements variant 1, with one quoted user message per recent source instead of one combined block. Reasons:

- **It removes the demonstration completely.** No assistant-role turn precedes the answer, so there is no assistant turn whose opening the model can continue. Under variant 2 the prior assistant turns would remain. Any stored answer that already opens with an echoed header would still appear as an assistant turn beginning with header text, the compounding case noted under "Product impact".
- **It keeps source identity local.** Each quoted message carries its own label and metadata. Variant 2 would link turn *k* to index entry *k* by position only, which the model must infer.
- **It reuses a format with no measured echoes.** The quoted, field-line style already used for historical excerpts appeared 0 times in all 192 saved answers. The JSON header in assistant turns was echoed 16 times.
- **It keeps the accounting and proof structure.** One message per source preserves whole-source reduction, per-message prefix validation, component token assignment and the journal's `messages.count == recent + 2 (+1)` shape. A single combined block would have needed new reduction, count and journal code. The original text still runs to the end of its message, so the chat-template boundary terminates it and source text cannot forge the end of a block.

Cost of the choice: the request now holds consecutive user turns, and prior human messages are presented as quoted evidence rather than user turns. Whether this changes answer quality beyond the replayed cases is unmeasured.

### Fix D: citation labels

Each delivered source gets a host label `E1`, `E2`, ... in delivery order: recent sources oldest first, then historical spans in delivered rank. This matches the `E<n>` style of the blinded calibration evidence. The model sees `[E<n>]` on the recent heading and on the historical `BEGIN` and `END` lines. Model-visible text no longer contains event IDs: the historical `event_id:` line is removed, and recent metadata has no ID. `conversation_id` and `source_sha256` remain visible, because they serve grouping and provenance rather than citation. The selection snapshot journals the map as `citation_labels` (label, kind, event ID and, for excerpts, offset and byte length), and journal validation recomputes it. The System framing says: "When a quoted source supports the answer, cite its label in square brackets, for example [E2]; do not cite event IDs or other identifiers."

### Fix G: insufficient-evidence wording

The V4 System framing adds: "If the quoted sources contain the answer, answer directly. If they do not contain the requested information, say plainly that the conversation history provided here does not show it, and mention any partially relevant information you found; do not guess, and do not say that you are an AI or that you lack memory or access." It keeps "A missing excerpt is not proof that the archive lacks a fact." The wording asks for a plain decline only when the sources lack the answer, and it forbids guessing.

**Status of G (measured October 9, 2026, 42 local generations):** on the recent-only arm, V4 removed the AI or memory disclaimers (V3 4 of 21, including all 3 disclaimer questions; V4 0 of 21). It also turned every recent-only answer into a plain decline (21 of 21, including all 3 abstention questions). No recent-only delivery contained gold evidence, so those declines match the evidence. See [the recent-only replay](#replay-v3-versus-v4-on-the-recent-only-arm-of-all-21-questions).

**Status of G with retrieval on (measured October 9, 2026, 42 local generations plus default-judge verdicts):** on the hybrid arm, V4 declined 1 of 12 answerable questions whose gold turns were delivered whole (54026fce, also the false decline of the seven-question replay), and answered the other 11, all accepted by the judge. Judged accuracy on answerable questions was the same under V3 and V4 (13 of 18). All 3 abstention answers became accepted declines (V3: 2 of 3 accepted). G therefore does not decline wholesale when evidence is present, but it produced one reproducible false decline. Its cause is unexamined, and answers under ordinary Send's lexical selection are unmeasured. See [the retrieval-on replay](#replay-v3-versus-v4-with-past-conversation-retrieval-on-all-21-questions).

### Why one version

A, D and G all change the same fixed framing: the System literal, the recent prefix and the historical header. Each change already requires a new snapshot version, digests and validation. Three versions would create two intermediate framings that no default path uses, and the replay budget (7 + 7) allows only one fix arm. The cost is attribution: the replay measures A, D and G together and cannot separate their effects.

### Guarantees kept

- Original text is delivered byte-exact. Validation checks the exact prefix for the source's delivery position, plus the remainder's byte count and digest.
- Source identity, provenance and dates: each source shows its label, role, capture status, captured UTC and source time, and historical spans keep conversation, digest and range. The label map ties each label to an event ID.
- Trust boundary: host text and quoted content stay separated. Incomplete fragments keep their marker. Quoted sources are declared evidence without authority.
- Token accounting and admission are unchanged in kind: one component message per recent source, and the same byte caps, token caps and reductions.
- Journal records of the original input: the selection snapshot, the mandatory-message binding and the original-input proof all bind V4 bytes. The proof strips the System framing of the journaled version.
- Retrieval selection is unchanged. The experimental exchange-packing estimate keeps V3 header bytes so that V4 does not reorder it.

### Contract evidence (synthetic)

- `RecentSourceFramingChecks` holds 82 checks, including 27 for V4. They verify no assistant-role turn and no V3 header in V4 and exact original bytes for every source. Labels must be unique, sequential and stable across identical selections, and the map must be recorded and absent from V3. No event ID may appear in model-visible text, and the D and G wording must be present. They also cover re-labelling on recent reduction, historical labels continuing after recent ones, and rejection of a fabricated label, an assistant role, changed bytes and either binding paired with the other version's body. V3 recent prefix, evidence header and footer bytes and the V3 System framing digest are pinned to the pre-V4 source.
- `ComponentPreparationChecks` runs the coordinator end to end under both framings. `.pipeline` runs V3; the new `.quotedPipeline` and the default fixtures run V4. Each goes through admission, the original-input proof, journal validation, archive creation and verification, and restore. The journal corruption suite runs against both. A new `reboundCitationLabelMap` mutation is refused for v1, v2, v3 and v4.
- `scripts/test_answer_presentation_defects.py` has 14 contracts. They cover the V4 rendering, V4 header detection, label resolution, fabricated IDs, plain decline versus disclaimer, and the reference and addressing checks.
- `python3 scripts/answer_presentation_defects.py envelope` renders both framings from the Swift literals. It reports `assistant_turns_starting_with_host_text`: V3 1, V4 0.

## Replay: V3 versus V4 on the seven echo questions

**Measured, October 9, 2026, with the user's authorization ("implement fix A and replay the 7 questions"). The coordinator extended the fix arm to A+D+G.** One local generation per question and framing, 14 in total. No remote call was made.

### Declaration

Written before any generation, at `.build/answer-presentation-replay-20261009/declaration.json` (private, 0600):

- **Inputs.** Each case uses the frozen runner input of the run whose saved answer copied the header. All 7 were rebuilt from the pinned dataset and match the runner-input SHA-256 recorded by that run. Each run executes only the declared attempt (`--attempt`).
- **Binary.** Both arms ran the same binary: SHA-256 `39a5b25e…`, built from commit `87f70ea`. The only difference between arms is `--context-framing`: `context-source-snapshot-v3`, the framing of `main` (`0badf7e`, with no `Sources/` change since `088d92f`), against `context-source-snapshot-v4`.
- **Model and settings.** Model `ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit`, temperature 0, thinking off, seed 104202601, the frozen 32,768 context limit and the frozen output caps (512 for runner documents 4 and 5, 1,024 for 7). The live server's `/v1/models` listed the model.
- **Limits and detector.** Generation limit 14. Detector: `answer_presentation_defects.py` (`answer-presentation-defects-v2`), with the measures defined below.

| Question | Run where the header was copied | Arm | Component policy |
|---|---|---|---|
| 001be529 | natural-v4 | hybrid | v1 |
| 06878be2 | natural-v5 | recent only | v1 |
| 0e5e2d1a | natural-v5 | hybrid | v1 |
| 1192316e | neighborhood-v1 | hybrid | v2, bounded neighborhood (pinned with `--component-policy`) |
| 1a1907b4 | independent-v1 (it also echoed in neighborhood-v1) | hybrid | v1 |
| 1faac195 | independent-v1 | hybrid | v1 |
| 54026fce | neighborhood-v1 | hybrid | v2 (pinned) |

**Operational record.** The first two attempts at the first case failed in admission before any answer invocation, so no answer was generated. The first failed with `provider_admission_unavailable`: the 1-token calibration request timed out while the server was loading the model. The second failed with `provider_adapter_unverified`: the server's `max_safe_context` was below 32,768 and drifting while `check.py` compiles loaded the host. Two further runs were stopped during setup, before any server request. After the host's memory recovered (`max_safe_context` about 120,000 and stable), all 14 declared runs completed. The ledger records 14 answer generations and 4 runs without an answer invocation. One V3 answer (06878be2) ended at the 512-token cap (`incomplete_result`).

**Only the framing differs.** For every question, the two arms delivered identical source sets: the same recent IDs and the same historical event and range lists. For 5 of 7 questions, those sets also equal the ones the original run recorded. For 001be529 and 0e5e2d1a (natural-v4 and natural-v5), current retrieval delivers a different set than those older builds did. On the recent-only case, where no conversation UUID enters the prompt, the V3 prompt token count equals the original run's exactly (5,073). V4 prompts were 169 to 300 tokens shorter on the hybrid cases and 17 tokens longer on the recent-only case.

### Results

Definitions:

- **Header:** the answer opens with a V3 or V4 host header or block marker.
- **Fabricated:** distinct raw or JSON event IDs in the answer that are absent from the history.
- **Repeated question:** the question appears verbatim.
- **Raw IDs:** benchmark event IDs in the answer.
- **LaTeX:** inline, display or command math.
- **Addresses:** non-empty, no header at the start, question not repeated.
- **Has reference:** the normalized reference answer is a substring of the normalized answer. This is a string check, not a judge.
- **Labels:** cited `[E<n>]` labels, and how many resolve to a delivered source in the journaled map.

| Question | Arm | Header | Fabricated IDs | Repeated question | Raw IDs | AI disclaimer | Plain decline | LaTeX | Words | Addresses | Has reference | Labels cited (resolved) |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---:|
| 001be529 | V3 | 0 | 0 | 0 | 1 | 0 | 0 | 0 | 48 | yes | yes | 0 |
| 001be529 | V4 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 20 | yes | yes | 1 (1) |
| 06878be2 | V3 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 348 (cap) | yes | no | 0 |
| 06878be2 | V4 | 0 | 0 | 0 | 0 | 0 | 1 | 0 | 66 | yes | no | 0 |
| 0e5e2d1a | V3 | **1** | 1 | 0 | 2 | 0 | 0 | 0 | 35 | no | yes | 0 |
| 0e5e2d1a | V4 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 31 | yes | yes | 1 (1) |
| 1192316e | V3 | 0 | 0 | 0 | 2 | 0 | 0 | 0 | 61 | yes | no | 0 |
| 1192316e | V4 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 55 | yes | no | 2 (2) |
| 1a1907b4 | V3 | **1** | 1 | 0 | 1 | 0 | 0 | 0 | 233 | no | no | 0 |
| 1a1907b4 | V4 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 196 | yes | no | 6 (6) |
| 1faac195 | V3 | 0 | 0 | 0 | 1 | 0 | 0 | 0 | 12 | yes | yes | 0 |
| 1faac195 | V4 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 12 | yes | yes | 1 (1) |
| 54026fce | V3 | **1** | 1 | 0 | 1 | 0 | 0 | 0 | 162 | no | no | 0 |
| 54026fce | V4 | 0 | 0 | 0 | 0 | 0 | 1 | 0 | 179 | yes | no | 0 |

| Arm | Answers | Header | Fabricated IDs | Repeated question | Raw IDs | AI disclaimer | Plain decline | LaTeX | Addresses | Has reference | Labels cited (unresolved) | Ends with a question | Markdown bold | Median words |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| V3 (main) | 7 | 3 | 3 | 0 | 8 | 0 | 0 | 0 | 4 | 3 | 0 (0) | 1 | 38 | 61 |
| V4 (A+D+G) | 7 | 0 | 0 | 0 | 0 | 0 | 2 | 0 | 7 | 3 | 11 (0) | 0 | 20 | 55 |

Reading the results:

- **Current main still copies the header.** V3 opened 3 of 7 answers with a copied header, each with a fabricated event ID (0e5e2d1a, 1a1907b4 and 54026fce). The original runs had 16 echoes in 126 envelope answers, all 16 on these 7 questions. At temperature 0 with fixed inputs, 3 of 7 is a reproduction on a small sample, not a rate.
- **V4 removed the header copy on every question:** 0 of 7, with no fabricated IDs and no raw event IDs. It cited 11 labels, and all 11 resolve to delivered sources.
- **Accuracy did not change on the string check.** The reference string appears in the same 3 answers under both arms. V4 did not lose the three answers V3 had right, and the string check found no new correct answer.
- **The question was not repeated verbatim in either arm.** The human-role echo with a repeated question did not recur under V3 in this replay, so this replay does not test that pattern.
- **G needs review.** V4 opened 2 answers with a plain decline (06878be2 recent only, 54026fce hybrid). Both questions are answerable, not abstention items. Under V3, the first hit the output cap and the second copied the header; neither contained the reference under either arm. Whether these declines are faithful (the delivered evidence lacks the answer) or wrong (a decline on answerable evidence) needs adjudication against the delivered evidence. This replay does not settle it, and it is the main risk to check before relying on G. **Settled later:** 06878be2 had no gold delivered (justified), and 54026fce had its gold turn delivered whole (a false decline); see [the 54026fce finding](#the-54026fce-decline-in-the-seven-question-replay).
- **The V4 answers carry less Markdown bold** (20 against 38 spans), and none ends with a question. These were not targets of A, D or G, and n = 7.

### What G would need

The disclaimers that motivated G occur in 9 saved recent-only answers on 3 distinct questions:

- 031748ae_abs: natural-v2 to v5 and adjacent-v1 (item-032)
- 0862e8bf_abs: independent-v1 and neighborhood-v1 (item-030)
- 1192316e: independent-v1 and neighborhood-v1; answerable

This replay included no recent-only attempt on these questions; 1192316e was replayed on its hybrid arm only. A paired V3 against V4 replay of those three recent-only attempts would take 6 generations. Checking that G does not cause declines on answerable questions needs the recent-only arm of the other answerable questions too: up to 21 distinct questions, or 42 paired generations. Both need the user's authorization.

**Update:** the user authorized the 42-generation recent-only replay, and it has run. See [Replay: V3 versus V4 on the recent-only arm of all 21 questions](#replay-v3-versus-v4-on-the-recent-only-arm-of-all-21-questions). It also shows that recent-only delivered no gold evidence turn for 06878be2, so that question's V4 recent-only decline above matches the delivered evidence. The 54026fce decline was on the hybrid arm, which the recent-only replay does not cover.

### Reproduction

```sh
python3 scripts/answer_presentation_replay.py declare --output <new .build directory> --dataset <pinned longmemeval_s_cleaned.json> --binary <Boros binary>
python3 scripts/answer_presentation_replay.py run --output <same directory> --binary <same binary>
python3 scripts/answer_presentation_replay.py measure --output <same directory> --dataset <pinned dataset>
```

`measure` prints counts, identifiers and booleans only. Answers, inputs and native reports stay in the private directory.

## Replay: V3 versus V4 on the recent-only arm of all 21 questions

**Measured, October 9, 2026, with the user's authorization:** up to 42 local generations on the local model server only, as a paired V3 against V4 (default) replay of the recent-only arm on the 21 distinct questions. The replay used 42 answer generations: one per question and framing, with no retry and no run that failed before its answer invocation. No remote or paid call was made. Its purpose is fix G, the insufficient-evidence wording in the default `context-source-snapshot-v4` framing.

### Declaration

The declaration was written at 12:08 UTC, before any generation, to `.build/answer-presentation-recent-only-20261009/declaration.json` (private, 0600, SHA-256 `9817cd6d…`). The first generation started at 12:28 UTC, after the coordinator's offline retrieval harness had exited. The server's `max_safe_context` was about 193,000 when the run started, and no `check.py` or compile ran during the generations.

- **Cohort** (`answer_presentation_replay.py declare --cohort recent-only-21`). The recent-only arm of all 21 distinct questions in the saved native runs. The 7 frozen pilot questions use the natural-v5 runner input (document 5, 512 output tokens): 001be529, 00ca467f, 01493427, 031748ae_abs, 06878be2, 08f4fc43 and 0e5e2d1a. The 14 independent questions use the independent-v1 runner input (document 7, 1,024 output tokens, default component policy v1): 0862e8bf_abs, 1192316e, 1a1907b4, 1b9b7252, 1faac195, 3f1e9474, 4baee567, 51c32626, 54026fce, 7a87bd0c, a1eacc2a, f685340e_abs, gpt4_2655b836 and gpt4_70e84552. All 21 inputs were rebuilt from the pinned dataset and match the runner-input SHA-256 recorded by their original run. Each run executes only the recent-only attempt (`--attempt 0`).
- **Classes.** 3 abstention questions (`_abs`): 031748ae_abs, 0862e8bf_abs and f685340e_abs. 18 answerable questions. The 3 disclaimer questions are 031748ae_abs, 0862e8bf_abs and 1192316e.
- **Arms.** `v3-pinned` passes `--context-framing context-source-snapshot-v3`. `v4-default` passes no framing flag, so it runs the binary's default; measurement verified that all 21 reports and selections record `context-source-snapshot-v4`. Run order: question order as listed, V3 then V4 for each question.
- **Binary.** Both arms ran the same binary: SHA-256 `e60b6bbf…`, built from `main` at `f28584b`. The declaration records commit `f54ec7a`, which adds only the driver cohort and leaves `Sources/` unchanged. Its framing and assembler sources have the same SHA-256 as the binary of the seven-question replay.
- **Model and settings.** These match the seven-question replay: model `ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit` (listed by the live server's `/v1/models`), temperature 0, thinking off, seed 104202601, the frozen 32,768 context limit, 256 safety tokens and the frozen output caps (512 for runner document 5, 1,024 for 7).
- **Limit and retry rule.** Generation limit 42. A run whose answer invocation never started could be retried at most twice without counting. Any run that started an answer invocation counted. A finished run with an unknown invocation state stops the driver.
- **Detector.** `answer_presentation_defects.py` (`answer-presentation-defects-v2`), the same measures as the seven-question replay, plus three additions:
  - **Outcome:** `decline` if a plain-decline phrase from the detector's list starts within the first 200 characters, `partial_decline` if one appears only later, and `answer` otherwise.
  - **Abstention flag.**
  - **Delivered gold evidence:** the delivered recent sources whose benchmark turn is marked `has_answer`, or that come from a gold answer session. This is computed from labels and delivered IDs and reads no text.

**Only the framing differs.** For all 42 runs, the delivered recent source IDs equal those recorded by the original run. Every V3 prompt token count equals the original run's. V4 prompts were 61 tokens shorter to 98 tokens longer.

**Recent-only delivered no gold evidence.** For all 21 questions and both arms, no delivered recent source is a gold `has_answer` turn or comes from a gold answer session. A content-free check found the normalized reference string in the delivered recent text for 1 of 21 questions: 00ca467f, whose reference is a single token.

### Results

Outcome and Has reference are lexical string checks, not a judge. Header is a copied V3 or V4 host header at the start of the answer. Raw IDs are benchmark event IDs in the answer.

| Question | Class | V3 outcome | V3 disclaimer | V3 header (raw IDs) | V4 outcome | V4 disclaimer | V4 header (raw IDs) | Has reference V3 / V4 | Words V3 / V4 |
|---|---|---|---:|---|---|---:|---|---|---|
| 001be529 | answerable | decline | 0 | 0 (0) | decline | 0 | 0 (0) | no / no | 67 / 35 |
| 00ca467f | answerable | decline | 0 | 0 (6) | decline | 0 | 0 (0) | yes / no | 47 / 32 |
| 01493427 | answerable | answer | 0 | 0 (0) | decline | 0 | 0 (0) | no / no | 43 / 30 |
| 031748ae_abs | abstention, disclaimer question | answer | **1** | 0 (0) | decline | 0 | 0 (0) | no / no | 89 / 37 |
| 06878be2 | answerable | answer | 0 | **1** (1, fabricated; question repeated) | decline | 0 | 0 (0) | no / no | 22 / 65 |
| 08f4fc43 | answerable | decline | 0 | 0 (0) | decline | 0 | 0 (0) | no / no | 58 / 40 |
| 0e5e2d1a | answerable | answer | 0 | 0 (1) | decline | 0 | 0 (0) | no / no | 169 / 49 |
| 0862e8bf_abs | abstention, disclaimer question | answer | **1** | 0 (0) | decline | 0 | 0 (0) | no / no | 19 / 34 |
| 1192316e | answerable, disclaimer question | answer | **1** | 0 (0) | decline | 0 | 0 (0) | no / no | 73 / 46 |
| 1a1907b4 | answerable | answer | 0 | **1** (1, fabricated) | decline | 0 | 0 (0) | no / no | 426 / 357 |
| 1b9b7252 | answerable | answer | 0 | 0 (1) | decline | 0 | 0 (0) | no / no | 134 / 44 |
| 1faac195 | answerable | answer | 0 | 0 (0) | decline | 0 | 0 (0) | no / no | 38 / 37 |
| 3f1e9474 | answerable | decline | 0 | 0 (0) | decline | 0 | 0 (0) | no / no | 51 / 39 |
| 4baee567 | answerable | decline | 0 | 0 (2) | decline | 0 | 0 (0) | no / no | 60 / 31 |
| 51c32626 | answerable | decline | 0 | 0 (0) | decline | 0 | 0 (0) | no / no | 31 / 30 |
| 54026fce | answerable | answer | 0 | 0 (0) | decline | 0 | 0 (0) | no / no | 377 / 142 |
| 7a87bd0c | answerable | answer | 0 | 0 (0) | decline | 0 | 0 (0) | no / no | 59 / 36 |
| a1eacc2a | answerable | answer | 0 | 0 (3) | decline | 0 | 0 (0) | no / no | 51 / 40 |
| f685340e_abs | abstention | answer | 0 | 0 (0) | decline | 0 | 0 (0) | no / no | 50 / 42 |
| gpt4_2655b836 | answerable | answer | **1** | 0 (0) | decline | 0 | 0 (0) | no / no | 72 / 35 |
| gpt4_70e84552 | answerable | decline | 0 | 0 (2) | decline | 0 | 0 (0) | no / no | 50 / 35 |

| Arm | Answers | AI disclaimer | Disclaimer on the 3 disclaimer questions | Decline: answerable | Decline: abstention | Copied header (fabricated IDs) | Answers with raw IDs (IDs) | Repeated question | Has reference | Cited labels | Ends with a question | Markdown bold | Median words |
|---|---:|---:|---:|---:|---:|---|---|---:|---:|---:|---:|---:|---:|
| V3 (pinned) | 21 | 4 | 3 of 3 | 7 of 18 | 0 of 3 | 2 (2) | 8 (17) | 1 | 1 | 0 | 2 | 46 | 58 |
| V4 (default) | 21 | 0 | 0 of 3 | 18 of 18 | 3 of 3 | 0 (0) | 0 (0) | 0 | 0 | 0 | 1 | 15 | 37 |

No answer in either arm hit its output cap, and none had a `partial_decline` outcome, LaTeX or an unresolved label.

### Reading the results

Measured:

- **G removed the disclaimers on the disclaimer questions.** V3 reproduced an AI or memory disclaimer on all 3 (031748ae_abs, 0862e8bf_abs and 1192316e), plus 1 on gpt4_2655b836, which had none in the saved runs. V4 had 0 of 21. At temperature 0 with fixed inputs this is one paired sample per question, not a rate.
- **V4 declined on every recent-only question:** 21 of 21, against 7 of 21 under V3. All 3 abstention questions got a lexical decline under V4, against 0 of 3 under V3. Under V3, 2 of those 3 carried a disclaimer, and the third (f685340e_abs) had no decline phrase.
- **The 18 answerable declines are consistent with the delivered evidence.** Recent-only delivered no gold evidence turn and no gold-session source for any of the 18, so a decline is what G asks for here. This replay therefore cannot show a false decline: it contains no recent-only case where the evidence held the answer. The previous replay's V4 recent-only decline on 06878be2 falls in the same class.
- **One string-check hit was lost.** The only reference-containing answer was V3 on 00ca467f. That answer also opened with a decline phrase. The reference is a single token that also appears in the delivered, non-gold recent text, so the hit is weak evidence of a correct answer. V4 declined that question.
- **V4 again removed the header copies and raw IDs.** V3 opened 2 of 21 recent-only answers with a copied header, each with a fabricated event ID: 06878be2 and 1a1907b4. The 06878be2 answer also repeated the question verbatim, the human-role echo pattern that the seven-question replay did not reproduce. V3 also wrote 17 raw event IDs in 8 answers. V4 had 0 headers, 0 fabricated IDs and 0 raw IDs. V4 cited no labels, which is consistent with declining.
- **V4 answers are shorter** (median 37 against 58 words) and carry less Markdown bold (15 against 46 spans). These were not targets of G.

Inferred, not measured:

- Uniform declines on evidence without gold turns show that G produces the requested wording. They do not show that the model judges evidence sufficiency correctly. A model that declines whenever the evidence is thin would give the same table. The test that matters is whether V4 still answers when the delivered evidence holds the answer. In the seven-question replay, V4 kept all 3 hybrid answers that contained the reference, and that is the only evidence on this question so far. The hybrid V4 decline on 54026fce is still unadjudicated against its delivered evidence. **Update:** it was a false decline (gold delivered whole), and [the retrieval-on replay](#replay-v3-versus-v4-with-past-conversation-retrieval-on-all-21-questions) tests this question directly.
- The V3 "answer" outcomes on answerable questions had no gold evidence. Most are therefore guesses or answers from general knowledge. 0 of 11 contained the reference. G's "do not guess" wording removes them, which a user would see as a decline rather than a wrong answer. This is a reading of the counts; the answers were not judged.

### Reproduction

```sh
python3 scripts/answer_presentation_replay.py declare --cohort recent-only-21 --output <new .build directory> --dataset <pinned longmemeval_s_cleaned.json> --binary <Boros binary>
python3 scripts/answer_presentation_replay.py run --output <same directory> --binary <same binary>
python3 scripts/answer_presentation_replay.py measure --output <same directory> --dataset <pinned dataset>
```

The `measure` output for this run is saved privately as `measure.json` in the run directory.

## The 54026fce decline in the seven-question replay

**Measured offline, October 9, 2026, with no model call.** The seven-question replay's V4 answer on 54026fce (hybrid arm, neighborhood-v1 runner input, component policy v2) opened with a plain decline. The question is answerable and has one annotated gold turn (`has_answer`) in one gold session.

Method: the attempt's own `delivered_ranges` from the runner report (historical excerpts by byte offset and length, plus whole recent sources), scored with `retrieval_harness.coverage`, the function behind the harness's R2. The new `gold_delivery` in `answer_presentation_replay.py` does exactly this. Only IDs, counts and labels were read.

| Attempt | Delivered recent | Delivered ranges | Gold turn | Gold delivery | Lexical outcome | Labels cited |
|---|---:|---:|---|---|---|---:|
| V3 (`main-v3`) | 12 | 34 | historical excerpt, not recent | whole | answer (opened with a copied header) | 0 |
| V4 (`fix-v4`) | 12 | 34 | historical excerpt, label `E14` of 34 | whole | decline | 0 |

- **The V4 decline is a false decline** by the annotation proxy: the single gold turn was delivered whole, as source `E14`. The answer cited no label.
- **V3 received the same evidence.** Both arms delivered the identical range set (same order-independent digest), which is also the set recorded by the original neighborhood-v1 run. The independent-v1 run, under component policy v1, delivered a different set of 28 ranges, also with the gold turn whole. V3's answer had no decline phrase, but it opened with a copied header, and neither answer contained the reference string.
- **The annotation is a proxy.** LongMemEval's gold turns approximate sufficient evidence; the human adjudication agreed with this proxy on 34 of 37 answerable calibration items. Whether the delivered turn states the answer plainly was not checked, because that needs the text.
- Over the whole seven-question replay, gold delivery was whole on 5 of 7 questions and none on 2 (06878be2, recent only, and 1a1907b4, hybrid). The V4 06878be2 decline is justified by this measure.

## Replay: V3 versus V4 with past-conversation retrieval on, all 21 questions

**Measured, October 9, 2026, with the user's authorization:** up to 42 local generations on the local model server only, as a paired V3 against V4 replay of the same 21 questions as the recent-only replay, with past-conversation retrieval on; then verdicts on all 42 answers from the default judge (Vertex Sonnet 5.5), paid, capped at $1.00. The replay used 42 answer generations, one per question and framing, with no retry and no run that failed before its answer invocation.

### Arm used: hybrid, not lexical

Ordinary Send has used the `lexical` selection since October 8, 2026 ([P2-SEMANTIC-DECISION.md](P2-SEMANTIC-DECISION.md#decision)). **The answer-evaluation runner cannot select it.** For a recorded `hybrid` attempt it always builds the history's semantic index and passes it to the coordinator with the default `.enabled` policy (`AnswerEvaluationCommand.swift`, `PreparationMode.constructsSemanticIndex`), and it has no flag that withholds the index. This replay therefore ran the recorded **`hybrid` attempt**: explicit fused lexical and semantic retrieval, the retrieval harness's `hybrid` arm. All 42 reports record retrieval mode `hybrid` with the index built and no construction failure. Selection differs from ordinary Send. On the harness regression cohort, which holds the 14 independent questions here, hybrid delivers every gold turn on 8 of 12 answerable cases and lexical on 9 of 12. The difference is 51c32626, which lexical delivers whole and hybrid only partly; it is one of this replay's partial-gold questions. Answers under lexical selection were not measured.

### Declaration

Written at 13:29 UTC, before any generation, to `.build/answer-presentation-retrieval-on-20261009/declaration.json` in this worktree (private, 0600, SHA-256 `e0eeb892…933b`). Generations ran from 13:30 to 13:50 UTC. No `check.py` or compile ran during them.

- **Cohort** (`answer_presentation_replay.py declare --cohort retrieval-on-21`). The same 21 questions, runner inputs and component policy (v1) as `recent-only-21`, with `--attempt 1`, the recorded hybrid attempt. The 7 pilot questions use the natural-v5 runner input (document 5, 512 output tokens), and the 14 independent questions use independent-v1 (document 7, 1,024 output tokens). All 21 inputs were rebuilt from the pinned dataset and matched their recorded runner-input SHA-256.
- **Arms.** `v3-pinned` passes `--context-framing context-source-snapshot-v3`. `v4-default` passes no framing flag; all 21 V4 reports and selections record `context-source-snapshot-v4`. Run order: question order, V3 then V4.
- **Binary.** The same binary as the recent-only replay, SHA-256 `e60b6bbf…2a95`, built at `f54ec7a`. Its `Sources/` equal those of `05f1f55` and of the declaration commit `96392ab`, which adds only the driver cohort and scoring. The declaration's `build_commit` field records the checkout commit at declaration time (`96392ab`), not the binary's build commit.
- **Model and settings.** Unchanged from the earlier replays: model `ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit`, listed by the live server's `/v1/models`; temperature 0; thinking off; seed 104202601; the frozen 32,768 context limit with 256 safety tokens; and the frozen output caps.
- **Limit and retry rule.** Generation limit 42. A run that never started an answer invocation could be retried twice without counting, but none needed a retry.
- **Detector.** The recent-only replay's measures, plus **gold delivery**. The annotated gold turns (`has_answer`) are scored against the attempt's own `delivered_ranges` with `retrieval_harness.coverage`, as the harness scores R2. `whole` means every gold turn was covered, `partial` means some gold bytes were delivered but not every turn whole, and `none` means no gold byte was delivered. A decline (or partial decline) on an answerable question is a **false decline** when gold delivery is whole, a **justified decline** when it is none, and a **decline with partial gold** otherwise.

**Only the framing differs.** For all 21 questions the two arms delivered the identical recent sources and historical ranges. 18 of 21 delivered range sets equal those of the recorded run. The 3 that differ are 001be529, 06878be2 and 0e5e2d1a, all natural-v5 inputs; the seven-question replay saw the same drift for 001be529 and 0e5e2d1a. V3 prompt token counts differ slightly from the recorded runs' (by 2 to 40 tokens where delivery matches). The probable cause, not checked here, is that historical excerpts carry conversation IDs, which are new with each ingestion. V4 prompts were 64 to 317 tokens shorter than V3.

### Results

Gold delivery was the same under both arms. Answerable questions: whole on 12 (001be529, 00ca467f, 01493427, 0e5e2d1a, 1192316e, 1faac195, 3f1e9474, 54026fce, 7a87bd0c, a1eacc2a, gpt4_2655b836, gpt4_70e84552), partial on 3 (06878be2, 08f4fc43, 51c32626) and none on 3 (1a1907b4, 1b9b7252, 4baee567). The 3 abstention questions have no annotated gold turns.

Outcome and Has reference are lexical string checks. Verdict is the default judge's majority of three. All 42 items were unanimous, 3 to 0.

| Question | Class | Gold | V3 outcome | V3 verdict | V4 outcome | V4 verdict | Has reference V3 / V4 |
|---|---|---|---|---|---|---|---|
| 001be529 | answerable | whole | answer | accept | answer | accept | yes / yes |
| 00ca467f | answerable | whole | answer | accept | answer | accept | yes / yes |
| 01493427 | answerable | whole | answer | accept | answer | accept | yes / yes |
| 031748ae_abs | abstention | none annotated | answer | reject | decline | accept | no / no |
| 06878be2 | answerable | partial | answer (512-token cap) | accept | decline | accept | no / no |
| 08f4fc43 | answerable | partial | decline | reject | answer | reject | no / no |
| 0e5e2d1a | answerable | whole | answer (copied header, question repeated) | reject | answer | accept | no / yes |
| 0862e8bf_abs | abstention | none annotated | partial decline (AI disclaimer) | accept | decline | accept | no / no |
| 1192316e | answerable | whole | answer | accept | answer | accept | no / no |
| 1a1907b4 | answerable | none | answer | accept | answer | accept | no / no |
| 1b9b7252 | answerable | none | answer | reject | decline (justified) | reject | no / no |
| 1faac195 | answerable | whole | answer (copied header) | accept | answer | accept | yes / yes |
| 3f1e9474 | answerable | whole | answer | accept | answer | accept | yes / yes |
| 4baee567 | answerable | none | decline (justified) | reject | decline (justified) | reject | no / no |
| 51c32626 | answerable | partial | partial decline | reject | decline | reject | no / no |
| **54026fce** | answerable | **whole** | answer (copied header) | accept | **decline (false)** | **reject** | no / no |
| 7a87bd0c | answerable | whole | answer | accept | answer | accept | yes / yes |
| a1eacc2a | answerable | whole | answer | accept | answer | accept | no / no |
| f685340e_abs | abstention | none annotated | answer | accept | decline | accept | no / no |
| gpt4_2655b836 | answerable | whole | answer | accept | answer | accept | no / no |
| gpt4_70e84552 | answerable | whole | answer | accept | answer | accept | yes / yes |

Lexical measures:

| Arm | Answers | Decline (plus partial) | False decline | Justified decline | Decline with partial gold | Abstention decline | AI disclaimer | Copied header (fabricated IDs) | Answers with raw IDs (IDs) | Repeated question | Has reference | Cited labels (unresolved) | Markdown bold | Median words |
|---|---:|---:|---:|---:|---:|---:|---:|---|---|---:|---:|---|---:|---:|
| V3 (pinned) | 21 | 2 (+2) | 0 | 1 | 2 | 1 | 1 | 3 (3) | 20 (43) | 1 | 7 | 0 (0) | 83 | 66 |
| V4 (default) | 21 | 8 (+0) | 1 | 2 | 2 | 3 | 0 | 0 (0) | 0 (0) | 0 | 8 | 34 (0) | 59 | 52 |

One V3 answer (06878be2) stopped at the 512-token cap (`incomplete_result`). No V4 answer did. Neither arm contained LaTeX. Each arm had 1 answer ending with a question.

### Judged results (default judge)

Default judge exactly as configured in [JUDGE-CALIBRATION.md](JUDGE-CALIBRATION.md#default-judge-user-decision-october-9-2026). The configuration is Vertex `claude-sonnet-5-5` in `llm-train-482420`, location `global`, with declaration version 3, prompt set `boros-judge-calibration-prompts-v3`, thinking `between_tools`, instructed JSON replies, the verdict task only and three replicates. A majority of three decides, and a tie or unparseable majority is `unknown`. The answers are Qwen-authored, so self-preference does not apply.

- **Items.** `judge-set` built 42 blinded items (set `jr-d978990efd3d8096`, items SHA-256 `9262cfea…7c51`) with the calibration item builder: dataset question, date, type, reference and abstention flag, no evidence, and the same identifier scrub (46 substitutions, all in V3 answers). The judge saw no arm, run or question ID, and the item order interleaves the arms by a seeded hash.
- **Declaration.** It was frozen before the first Vertex call (`judge-declaration-vertex-sonnet-v3.json`, file SHA-256 `bb0bbd43…03ed`, canonical `e0b0041d…401f`). It is the version 3 template with `stages_per_item` set to `["verdict"]`. It declares $2 and $10 per million tokens, a $1.00 cap, 126 generations and 42 counts, and `check-declaration` reported no problem.
- **Access.** One standalone empty-body probe before the run, then the runner's own probe: both `reachable` (HTTP 400).
- **Run.** 126 of 126 replies parsed: all `end_turn`, all bare JSON, 0 thinking tokens. Labels SHA-256 `2c83aba7…de78`.
- **Cost.** Observed $0.128274 (56,742 input and 1,479 output tokens), reserved $0.758856 against the $1.00 cap. The briefing's $0.04 estimate was low: a verdict request here averages about 450 input tokens, like the calibration run's verdict requests ($0.15 for 150).

Accepted answers, with the judge's calibrated rates against the revised 50-item adjudication: error 2/50, 4% (1-13%); false reject 1/30, 3% (1-17%); false accept 1/20, 5% (1-24%).

| Subset | Answers per arm | V3 accept | V4 accept | Unknown |
|---|---:|---:|---:|---:|
| Answerable, gold delivered whole | 12 | 11 | 11 | 0 |
| Answerable, gold not whole (3 partial, 3 none) | 6 | 2 | 2 | 0 |
| Abstention | 3 | 2 | 3 | 0 |
| All | 21 | 15 | 16 | 0 |

The questions that changed verdict between arms: 0e5e2d1a (V3 reject with a copied header, V4 accept), 031748ae_abs (V3 reject, V4 accept on a decline) and 54026fce (V3 accept, V4 reject on a false decline). The other 18 questions got the same verdict under both arms. The two accepts without whole gold are 06878be2 (partial gold, both arms) and 1a1907b4 (no gold, both arms; the harness notes it was accepted without its annotated turn before).

### Reading the results

Measured:

- **G declined once when the gold evidence was delivered.** V4 declined 1 of 12 answerable questions with every gold turn delivered whole: 54026fce, which the judge rejected. It is the same question as the seven-question replay's false decline, now under component policy v1 with 28 delivered ranges instead of v2 with 34. On the other 11, V4 answered and the judge accepted all 11.
- **Judged correctness did not change on answerable questions:** 13 of 18 accepted under each arm, 11 of 12 where gold was delivered whole. V4 gained one gold-whole question (0e5e2d1a, where V3 copied the header and repeated the question) and lost one (54026fce).
- **G turned the abstention answers into declines, and the judge accepted all 3** (V3: 2 of 3, rejecting 031748ae_abs, which V3 answered).
- **V4 declined more with retrieval on than V3, but far less than without retrieval:** 8 of 21 lexical declines against 4 of 21 for V3, compared with 21 of 21 in the recent-only replay. Of V4's 5 answerable declines, 2 are justified (no gold), 2 had partial gold and 1 is false.
- **A lexical decline is not a reject.** The judge accepted 4 of V4's 8 declines: the 3 abstention questions and 06878be2, a decline phrase within the first 200 characters on a question with partial gold. The lexical outcome flags wording, not correctness.
- **Presentation fixes held with retrieval on.** V4 had 0 copied headers, 0 fabricated IDs, 0 raw IDs and 0 disclaimers, against 3, 3, 43 (in 20 answers) and 1 under V3. All 34 V4 labels resolve to delivered sources.

Inferred, not measured:

- One false decline in 12 gold-whole cases is not a rate. At temperature 0 with fixed inputs, the two 54026fce declines are the same case under two component policies, not independent samples. Why V4 declines there was not examined, because that needs the answer and evidence text. The cause could be the G wording, the quoted framing, or how the gold turn states the fact.
- The judge is reference-only and calibrated on 50 items. With a false-accept interval reaching 24 percent, some of the 16 or 15 accepts may be wrong. The arm difference (16 against 15) rests on three questions and is within that uncertainty.
- Ordinary Send's lexical selection would change delivery on at least 51c32626, which has partial gold here. Whether V4 answers it with gold delivered whole is unmeasured.

### Reproduction

```sh
python3 scripts/answer_presentation_replay.py declare --cohort retrieval-on-21 --output <new .build directory> --dataset <pinned longmemeval_s_cleaned.json> --binary <Boros binary>
python3 scripts/answer_presentation_replay.py run --output <same directory> --binary <same binary>
python3 scripts/answer_presentation_replay.py measure --output <same directory> --dataset <pinned dataset>
python3 scripts/answer_presentation_replay.py judge-set --output <same directory> --dataset <pinned dataset>
# fill a copy of vertex-sonnet.v3.template.json with stages_per_item ["verdict"], then:
python3 scripts/judge_calibration_run.py --set <dir>/judge-set --declaration <filled> --output <dir>/<run> --protocol <evaluate_qa.py> [--execute]
python3 scripts/answer_presentation_replay.py judge-summary --output <same directory> --dataset <pinned dataset> --labels <labels path>
```

`measure.json` and `judge-summary.json` are saved privately in the run directory. Both carry IDs, classes and counts only.

`scripts/test_answer_presentation_replay.py` holds 8 synthetic contracts, run by `scripts/check.py`. They cover:

- the cohort definition;
- gold delivery against the harness coverage, including overlapping excerpts, gaps, empty ranges and UTF-8 sizes;
- the decline classes and the range digest;
- the majority of three, where ties and unparseable votes are `unknown`;
- blinded judge items: no evidence, no arm, run or question ID, the calibration scrub, and deterministic order;
- a judge set written privately, loaded by the unchanged runner and planned as verdict-only requests;
- the label join by run index, with refusal of a mismatched set or row order.

## Reproducing the measurements

```sh
python3 scripts/answer_presentation_defects.py measure \
  --evaluation-root /Users/johnshahbazian/development/boros/.build/evaluation \
  --evaluation-root /Users/johnshahbazian/.codex/worktrees/native-investigation/boros/.build/evaluation \
  --dataset /Users/johnshahbazian/development/boros/.build/datasets/longmemeval-98d7416c24c778c2fee6e6f3006e7a073259d48f/longmemeval_s_cleaned.json \
  --calibration-set <private set-v1-20261008 directory> \
  --item item-024 --item item-028 --item item-030 --item item-032 --item item-037 --item item-039 --item item-049
python3 scripts/answer_presentation_defects.py envelope
python3 scripts/test_answer_presentation_defects.py
```

`measure` prints counts, pattern names, run, arm and family identifiers and item IDs only. `envelope` prints code literals and synthetic text only.

## Limits

- Pattern detection is lexical. "Talks about the context" and the disclaimer list are phrase lists with unknown precision. The envelope, ID, digest and LaTeX patterns are exact or near-exact.
- The 126 envelope answers cover 21 distinct questions, at temperature 0 with one seed, so repeated runs largely repeat the same behavior. Per-run rates are not independent estimates.
- Echo rates under the GUI's saved System text, with thinking on, or in multi-turn live chats where stored echoes compound, are unmeasured.
- Item note topics were derived by keyword match. One note (item-032) matched no presentation keyword.

## Fix E: rendered answer display

**Implemented October 9, 2026, with the user's authorization.** Fixes A, D and G are implemented separately, in the V4 framing described above. B, C and F are not implemented. Fix E changes the display only. It changes no prompt, stored text, export, backup or model request. It does not fix the envelope echo, raw IDs or disclaimers. An echoed header that is rendered is still wrong. The private adjudication form in `scripts/judge_calibration.py` is unchanged.

### What it does

- `Sources/Boros/AnswerRendering.swift` renders assistant messages in the GUI conversation transcript: restored history, the streamed answer and the completed answer. Human messages appear exactly as typed, in the proportional font, and are never parsed. The memory browser still shows paged exact source bytes. It is a source inspector, and a page boundary can split Markdown.
- **View > Show Original Text** (Option-Command-U) switches the whole transcript between the rendered view and the previous plain monospaced display of the stored bytes. The same toggle is in the transcript's context menu, which also offers **Copy Original Message**.
- Copy and drag write plain text only, mapped back to the stored text. Every rendered character carries the original UTF-16 span that produced it. Every message carries its complete stored text. If a selection reaches a message's first or last rendered character, it extends to that message's start or end. Selecting a whole message therefore copies its exact bytes, including fences, markers and line endings. A selection inside a message copies the source span it covers. For example, selecting the rendered words "Step one" copies `Step** one`.
- Rendering only reads stored text. The store, the history sent to the model, backups and the shared-answer capture are untouched. The shared-answer UI integration check now compares the stored answer with the original text behind the display, not with the rendered string.
- While an answer streams, committed deltas are appended as plain text. The in-progress answer is re-rendered at most every 0.25 s. For long answers, the interval grows to ten times the last render time. On completion, the renderer formats exactly the text already shown.

### Parser and frameworks

Foundation's `AttributedString(markdown:)` handles inline syntax only, resolves reference definitions and gives no source positions. Instead, a small bounded parser was written. It uses only AppKit text classes: `NSAttributedString`, `NSParagraphStyle`, `NSTextBlock` and `NSTextTable` in a TextKit 1 `NSTextView`. No third-party dependency was added. The repository has no `Package.swift`. `scripts/build.py` compiles every `Sources/Boros/*.swift` file with `swiftc` and links only system frameworks.

| Construct | Rendered |
|---|---|
| `**bold**`, `*italic*`, `_italic_`, `***both***`, `~~strike~~` | Font traits and strikethrough. Delimiters follow the CommonMark flanking rules, including intraword `_` and the rule of three. A single `~` stays literal, so `~5` is not struck. |
| `` `code` `` | Monospaced, with a background. Contents are literal. |
| Fenced code blocks (backtick or tilde) and indented code blocks | Monospaced lines in a full-width shaded block. Info strings are hidden. As in CommonMark, an unclosed fence runs to the end of the answer. |
| ATX headings `#` to `######` | Bold, at 20, 17, 15 or 13 pt. Setext headings are not supported, so `---` under text is a rule. |
| Unordered and ordered lists, including nested lists | Bullets (`•`, `◦`, `▪` by depth) with hanging indents. Ordered lists keep the source numbers. A child marker indented less than the parent's content column still nests. An ordered item can interrupt a paragraph only if it starts with `1`. |
| Block quotes, including nested quotes | Secondary text color, with a left bar. |
| GitHub tables | `NSTextTable`, with a bold shaded header row and column alignment. Up to 24 columns; wider tables stay plain text. |
| Thematic breaks | A thin full-width rule. |
| Line breaks inside a paragraph | Kept as line breaks rather than joined into spaces, so chat text keeps its shape. |

These stay literal text: raw HTML, images (`![...](...)`; nothing loads), reference definitions and reference links, footnotes, task-list checkboxes, setext headings, bare URLs and emoji shortcodes.

### Links

Only inline links `[text](url)` and angle-bracket autolinks `<url>` become clickable. The URL must be absolute `http` or `https`, with a host and no embedded user name or password. With any other destination (`javascript:`, `file:`, `data:`, `mailto:`, relative or scheme-relative), the whole construct stays literal. Links use a private attribute instead of AppKit's `.link`, so AppKit's link handling and link previews never engage. A link opens with `NSWorkspace` only on a single unmodified click that does not drag a selection. Its tooltip shows the full URL. Automatic link and data detection are off. No rendered message has a `.link` or `.attachment` attribute, so nothing loads remotely.

### Citation labels

Host labels such as `[E1]`, from the parallel fix D work, render as plain text. Reference links are not supported, so `[E1]`, `[E1][E2]`, `[E1, E2]`, `[E1] (see above)` and `[E1]: https://...` stay literal. Link-shaped forms whose bracket text contains only citation labels, such as `[E1](https://...)` or `[E1, E2](...)`, also stay literal and are never linked.

### Math heuristic

Math spans use Times New Roman, with letters in italic and other characters upright. Unicode replaces `\times`, `\cdot`, `\div`, `\pm`, comparison and arrow commands, set and logic symbols, Greek letters and common function names. `\frac{a}{b}` becomes `a/b`. A part that is not a single number or a single word gets parentheses, as in `(a+1)/(2b)`. `\sqrt{x}` becomes `√x` or `√(x+1)`. `\binom{n}{k}` becomes `C(n, k)`. `\text{...}` and similar commands become upright text. `^` and `_` arguments use a smaller font with a baseline offset. `\left`, `\right` and sizing commands are dropped. Unknown commands stay literal. This is not TeX layout: there are no stacked fractions, matrices or alignment.

Recognized delimiters are `$$...$$`, `\(...\)` and `\[...\]`. `$$...$$` spans can be up to 4,000 UTF-16 units and are centered when they make up the whole paragraph. Single-dollar `$...$` counts as math only when all of these hold:

1. The opening `$` is unescaped and not part of `$$`. It is not preceded by an ASCII letter or digit, as in `US$5`. It is followed by a non-whitespace character.
2. The closing `$` is the next unescaped `$`, on the same line and within 400 UTF-16 units. It is preceded by a non-whitespace character and is not followed by a digit or another `$`. If that next `$` fails these tests, the opening `$` is literal.
3. The content is not prose. Outside TeX command names and `\text{...}`-style arguments, it has fewer than two words of three or more ASCII letters.
4. If the content starts with a digit and contains whitespace, it must also contain an operator or TeX command (`\ ^ _ = + - * / < > ( ) × · −`). Otherwise it reads as money.

An escaped `\$` is always a literal dollar, and code spans are never math. The synthetic contracts check that these stay unchanged: `$20 and $30`, `It costs $5, $10, and $15.`, `US$5 or US$7`, `$1,000-$2,000`, `$5 per month, i.e. 60$ per year`, `Between $20 and $30 or 5$`, `Pay $20 (about $25) today`, `Cost: $ 5$`, `Totals $12.50/$13.75` and `$$ is slang`. Known limits: `price $5$` renders `5` as math. As in CommonMark, `2*3*4` italicizes the `3`; spaced arithmetic such as `2 * 3 * 4` is unaffected.

### Untrusted input and performance

The parser works line by line, and every scan has a limit: link labels up to 1,000 units, destinations up to 2,048 and inline math up to 400. Containers nest at most 8 levels deep; deeper content appears as plain lines. Unmatched delimiters stay literal. Answers over 400,000 UTF-16 units appear as plain text without parsing. Malformed input never throws. The affected construct falls back to literal text.

Measured on this development Mac with `Boros --answer-rendering-benchmark`. These are synthetic answers with one run each, not a controlled benchmark:

| Synthetic answer (UTF-16 units) | Parse and render | TextKit 1 layout, 800 pt wide |
|---|---:|---:|
| 2,360 (10 sections) | 0.032 s | 0.003 s |
| 24,411 (100 sections) | 0.015 s | 0.017 s |
| 214,911 (850 sections) | 0.132 s | 0.152 s |
| 400,224 (over the limit, plain-text fallback) | 0.001 s | not measured |

The first row includes one-time font setup. Each section holds a heading, bold, italic, code, math, dollar amounts, a citation label, nested lists, a quote, a fenced block and a table.

The contracts set these bounds: a synthetic answer of more than 200,000 UTF-16 units, with every construct in each section, renders in under 2 s. An adversarial 300,000-unit delimiter string also renders in under 2 s. The plain-text fallback renders in under 1 s.

### Verification

- `--answer-rendering-self-test` has 61 checks in `Sources/Boros/AnswerRenderingChecks.swift`, run by `scripts/check.py`. They cover:
  - each construct;
  - links and unsafe schemes;
  - images and HTML;
  - citation labels;
  - math rendering and the dollar heuristic;
  - exact original-text recovery for whole and partial selections, including CRLF, combining marks and emoji;
  - copy through the transcript view to a private pasteboard;
  - 300 seeded random inputs plus hand-written malformed and pathological inputs;
  - the absence of remote-capable attributes;
  - full-width block layout;
  - the performance bounds.
- `--ui-self-test` gains 11 GUI checks. They cover:
  - rendered assistant text and literal human text;
  - the exact original text behind the transcript;
  - copy;
  - the Show Original Text toggle and menu item;
  - rendering of a streamed answer from committed deltas;
  - the absence of `.link` and `.attachment` attributes;
  - unchanged stored events.
- Visual check. A synthetic OpenAI-style chat was imported with `scripts/import_chat.py` into a scratch store, and the built app was launched on that store. `screencapture` lacked permission, so a temporary hook captured the window offscreen with AppKit's `cacheDisplay`. The hook was removed before commit. No model was called.
  - Rendered mode showed every construct in the table above, inline and display math, and a clickable `https` link. `$20 and $30` was unchanged and `[E1] and [E2][E3]` appeared as plain text. HTML, image and `javascript:` link text stayed literal.
  - Original mode reproduced the previous monospaced display of the stored bytes.
  - The first capture exposed a defect: AppKit text blocks without a set width shrank to one glyph per line. Blocks and tables now fill the available width. A layout contract fails if this regresses; disabling the fix makes it fail.
