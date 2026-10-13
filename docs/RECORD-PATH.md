# The record path: reading at save time, answering aggregation questions from the dated record

Record date: October 13, 2026. On the [BEAM cohort](BEAM-COHORT.md) today's ordinary Send answers about half of the questions; the weak categories (summarization 6.7 percent, event ordering 0, contradiction resolution 0, multi-session reasoning 30) need nearly every relevant message of a long history, and nothing that reads at question time has reached them: lexical search ranks about half of the needed messages at the 500K scale, and a question-time map over 320-character snippets recovered 30 to 45 percent of them ([MULTI-SOURCE-ANSWERS.md](MULTI-SOURCE-ANSWERS.md)). This record measures the alternative the user approved: read every exchange once, when it is stored, and answer the aggregation questions from the complete dated record. Each section states whether it reports implemented behavior, measured results, inferences or proposed design.

## Summary

(filled in after the runs)

## The design (implemented in the evaluation driver, `scripts/beam_record.py`; the application is unchanged)

The path is implemented in the evaluation driver only. Ordinary Send is unchanged, and so are the step 3 framing and the exchange packer.

1. **Extract, at write time.** One Gemini 3.8 Flash call per human-led exchange (the user's message and the reply, under headings, with the exchange date, session and turn numbers) writes the record of that exchange: compact atomic entries, one JSON object per line, each with `speaker` (user or assistant), `kind` (fact, event, decision, plan, preference, change, question, recommendation), `subject` (a short noun phrase), `entities` (names as written), `statement` (one self-contained sentence of at most 25 words with the names, numbers and dates stated) and `quote` (an exact copy of a span of at most 20 words from that speaker's message). The prompt asks for every fact, event, decision, plan, preference, change and correction in the user's message and only the substantive contributions of the reply (recommendations, options, names, figures, steps, conclusions); it forbids reconciling conflicting statements, adding anything from outside the exchange, and commentary. At most 24 entries per exchange; the reply holds nothing but the JSON lines or `NO ENTRIES`.
2. **Verify.** An entry is kept only when its quote is an exact substring of its speaker's message. A quote the extractor re-spaced, re-cased or re-quoted is located in the source after whitespace, quote-mark and case folding and replaced by the exact original span (counted as `recovered`); a quote that cannot be located is rejected and counted. Every kept entry carries its source message sequence (the harness event ID), the source date (the message's `source_time`), session, exchange and speaker. The original history stays the ground truth: nothing is compressed or overwritten, and every entry links to its source. This is not a rolling summary.
3. **Route.** The deterministic router of the multi-source driver (`beam_multi_source.route`, unchanged: summary, ordering, count-across, "ever" and change-across rules) sends a question to the record; every other question keeps today's single call.
4. **Select.** The selection is the hard part at the 500K scale, where the record holds thousands of entries. Three offline methods were measured first (BM25 over the entries' subject, entities, statement and quote; the same with the seeds' subjects and entities pulling in every entry under them; the same plus the rest of each chosen exchange). The pilot on 100K-1 (next section) showed that they cannot close the gap: the paid method is one selection call per 100,000 characters of the compact record listing (every entry's label `[R<n>]`, date, turn, speaker, kind and statement, in chronological order, no quotes; labels are global so a selection resolves across chunks) that lists the labels of every entry a later step must read, at most 120 per chunk; the 24 best lexical matches are added as a floor; at most 250 entries or 64,000 characters go forward, in chronological order. The selection runs once per question, not per replicate.
5. **Answer.** The ordinary `exchange_packed` request, exactly as captured for the baseline, receives one more host-labelled user message before the question: the selected entries, each as `[R<n>] date, turn, speaker, kind: statement Quote: "..."`, under a heading that names them as host-derived, says they cover the whole conversation in chronological order and that turn numbers increase with time, and one sentence appended to the System framing that gives them the standing of quoted sources and asks for their labels to be cited. A routed question whose selection is empty keeps its ordinary answer.

## Pilot on one 100K conversation (measured, October 13)

Extraction over the 94 exchanges of 100K conversation 1: 94 calls, no failure, $0.53 at the declared standard rate ($0.0028 per stored message, $0.0056 per exchange), median 3.4 s per call, 179,123 input and 34,564 output tokens; 395 verified entries (4.2 per exchange; 221 from user messages, 174 from replies), 393 quotes exact and 2 recovered, 17 rejected; no malformed line. 179 of the 188 messages have at least one entry. Extraction coverage of the gold messages of the conversation's 20 questions: 50 of 53 (94.3 percent; summarization 20 of 21, every other category with gold complete except information extraction and instruction following at 2 of 3).

Offline selection recall of the gold messages on the 7 routed questions, at most 250 entries per question:

| Method | Recall, routed | Summarization | Event ordering | Multi-session | Entries selected (median) |
|---|---:|---:|---:|---:|---:|
| Lexical (BM25) | 63.9 | 47.6 | 71.4 | 100 | 89 |
| Lexical with subject and entity expansion | 66.7 | 52.4 | 71.4 | 100 | 108 |
| The same plus the rest of each chosen exchange | 66.7 | 47.6 | 85.7 | 100 | 188 |

Why the offline methods stop there (inferred from content-free counts): 373 of the 383 distinct subjects name one entry, because the extractor sees one exchange at a time and writes a fresh subject for each statement, so subject expansion has nothing to expand; and every missed gold message has entries (one to four each) none of which contains a term of the question. The gap is paraphrase, not coverage. That is why the paid selection reads the statements: the listing of a 100K record is about 395 lines, of a 500K record about 1,700, which one to three Gemini calls cover.

## Declared before generation

(filled in from the declarations)

## Results (measured)

(filled in after the runs)

## Privacy and artifacts

Entries, listings, selections, request bodies, answers, grades and the declarations are in `.build/beam-record-20261013/` and `.build/beam-record-heldout-20261013/` of worktree `agent-a58874337b3759528` (0700 directories, 0600 files). This record contains no question, answer, entry, quote, reference or conversation text.
