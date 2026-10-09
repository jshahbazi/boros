# Answer presentation defects

Status, October 9, 2026:

- **Implemented:** `scripts/answer_presentation_defects.py`, an offline diagnostic, and `scripts/test_answer_presentation_defects.py` with 8 synthetic contracts, run by `scripts/check.py`. No product code changed.
- **Measured:** pattern counts over the seven flagged calibration answers and over all 192 saved Qwen and Sol answers with retained text. Also measured: a source comparison of the frozen run builds with current `main` (`03f4196`).
- **Proposed:** the fixes listed under [Proposed fixes](#proposed-fixes). None is implemented. None has been tested against a model.

No model server, local or remote, was called. No answer was generated. This document contains no answer, question, evidence or history text. It quotes only host-authored code strings and describes answers by structure.

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

None is implemented. Each needs its own contract, tests and a live check before claims are made.

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
