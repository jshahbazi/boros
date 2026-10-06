# Public developer-history answering amendment

This N3 development amendment adds three content-addressed DevGPT histories to the shared selected-Qwen answering diagnostic. It preserves the original synthetic pilot projection and all earlier registered evaluation pins. It is an unregistered diagnostic, with one replicate and fixed recent-only/hybrid order. It cannot pass the product's five-category quality gate.

## Source and case freeze

The source is the public PR-linked sharing snapshot in [DevGPT](https://github.com/NAIST-SE/DevGPT), revision `685efd2509dede9a6e996b839ae4e20d33430648`, path `snapshot_20230727/20230727_195927_pr_sharings.json`. Its LFS payload is 21,495,241 bytes, SHA-256 `45798598c79dbf6b69b8aee81fc137df084a2359697bafb55e4461cb9b4f2912`. The loader requires both size and digest. It accepts no arbitrary chat corpus, private store, validation split or held-out input.

Public availability does not establish redistribution permission. Licensing/redistribution permission remains unverified. The source payload, derived messages, questions, oracles, stores and answers remain private local runtime files outside Git. Reports contain hashes, counts, fixed diagnostics and accounting metadata.

`scripts/devgpt_answer_cases.py` freezes these source array positions and complete oracle-free projections:

| History | `Sources` / `ChatgptSharing` index | Events | Serialized text bytes | Projection SHA-256 |
|---|---|---:|---:|---|
| `boros-devgpt-v1-h00` | 139 / 1 | 68 | 33,947 | `3ce6a107744a380f2b1f047bbfcacae380bb396cc14cc23c8108d8c240d1d091` |
| `boros-devgpt-v1-h01` | 90 / 1 | 42 | 24,513 | `9d2a765385191a91562e52312ad906338aba99c7cf46aa144497e7b7047fff41` |
| `boros-devgpt-v1-h02` | 143 / 0 | 28 | 16,761 | `0ac2f9963c690db4365792fbd2f0f82dfc0929baf15df535caa41f29bef9bd38` |

Sharing URL digests are distinct. Duplicate prompts, duplicate answers and prompt/answer collisions are rejected for these cases. Distinct sharing identities do not establish independent authors, independent projects or a representative sample. Cases were selected through structural inspection before model answering, including rejection of another candidate with duplicated text.

Each serialized `Prompt` becomes a human event and `Answer` an assistant event, without rewriting the text. `complete` describes retention of the serialized text; original generation completion is unknown. DevGPT code-block placeholders remain as serialized. `ListOfCode`, HTML, URLs, titles, repository metadata and conversation-level timestamps are excluded from searchable text. Source timestamps are ingestion times; this amendment makes no original temporal-order claim beyond recorded message sequence.

## Questions, rubrics and isolation

Each history declares four probes and both strategies: **24 attempts** in total. Three probes request an exact first nonempty assistant line, with one requiring an ordered pair from different exchanges. Source-derived user-line prefixes identify the exchanges. Prefixes must be unique within the history. Eligible assistant lines are 20–2,000 UTF-8 bytes and exclude code placeholders, code fences, HTML starts and role prefixes. Frozen selectors take the first, middle and last eligible exchanges. The later quote is labeled `later_source_quotes`; it does not establish an immediate follow-up test.

The fourth probe asks for a corpus-verified absent diagnostic identifier. The identifier is checked against every source before execution. This tests declared abstention on the frozen corpus. Retrieval omission alone cannot prove archive absence.

Questions request one strict JSON response. The [exact-answer rubric](ANSWER-RUBRICS.md) freezes exact reproduction, ordered answers, citations and explicit abstention. Answer correctness, citation correctness, response validity and abstention are reported separately. Overall success requires all applicable conditions. Partial, failed, missing and malformed attempts score zero and retain their declared denominators. The rubric also implements correction scoring with obsolete-value rejection, verified on synthetic contracts; these three public histories have no frozen correction cases. Scoped policy/task correctness remains unimplemented.

Gold strings, required event IDs, spans, digests, rubrics and expected values stay on the Python scorer side. Only the original events and ordinary questions enter `AnswerEvaluationCommand`. The native runner independently checks the complete projection against its allowlist. The scorer checks its oracle pin, source bytes and citation/gold-ID linkage before compilation or provider work, then validates durable delivered ranges before awarding citations. The initial N3 run had no model-visible recent IDs. The N4 development amendment exposes those IDs through host source metadata without changing the frozen source projections, questions, or oracles.

The same shared coordinator, original episode allowance, restored per-attempt overlays, background construction, token counts, admission, capture-before-display, Stop and terminal accounting used by the GUI/pilot execute these cases. Each history gets its own checkpoint and each attempt its own restore. Hybrid constructs the real Apple index before each attempt and leaves it quiescent during answering. No gold witness enters source selection.

## Frozen configuration and execution

The amendment uses the pilot's local Qwen identity, system instruction, temperature 0, seed `104202601`, thinking disabled, 32,768 context limit and 256 safety tokens. Its output reserve is **2,048 tokens**, declared before any model answers because exact line-pair reproduction can be longer than the pilot's marker response. This is a new diagnostic configuration; its scores, latency and spend must not be pooled with the 128-output-token pilot. A larger output reserve does not establish sufficient-evidence feasibility.

Place the exact pinned public payload in a private local file outside Git, then run:

```sh
python3 scripts/evaluate_developer_answers.py \
  --source .build/public-sources/devgpt-20230727-pr.json \
  --output .build/evaluation/devgpt-answer-diagnostic.json
```

The tool compiles an immutable copied source inventory, including scorer/case-loader scripts, and binds source/binary/compiler/configuration/corpus/oracle hashes into the report. It refuses existing report paths. Native stores live beneath the validated private output directory, inside the Python supervisor's temporary subtree. Native finalization removes stores; supervisor cleanup also removes stores after a native timeout or process death, plus answer IPC after scoring. If the supervisor itself dies, private temporary data can remain. A direct native CLI owner must remove its explicitly chosen output directory after child death. The explicitly supplied public source file remains at its original path. Provider stdout/stderr and compilation diagnostics are captured privately and never printed. A fixed host error replaces content-bearing failures.

## Remaining acceptance work

This amendment implements a small source-bound reproduction/citation/absence diagnostic. On October 5, 2026, the matching copied-source application passed 2,218 checks and strict deep signature verification. A separate 32-check public-source suite included 27 overlapping synthetic checks and five native checks covering all 24 attempts against controlled Qwen plus killed-child supervisor cleanup ownership. All 24 operationally completed with intentionally incorrect output and zero task credit; actual projection/input digests, overlay isolation, construction/accounting and content-free reports passed.

The live Qwen run at `987441e` completed all 24 attempts. All 138 original source events fit their respective recent contexts. No historical evidence excerpt was delivered; all 12 paired request and answer digests matched. Each arm scored 3/12 overall, entirely from the three absence cases. Three of six single quotes reproduced the exact text but failed citations; three differed from the expected text. All three cross-message responses per arm failed the strict response schema. Every required gold text span was delivered in all nine answerable probes per arm. These observations identify reproduction/formatting and recent citation-identity boundaries; they establish no historical-retrieval advantage. Discarded answers cannot be reclassified to determine a more specific malformed-response cause.

Each arm charged 68,434 known input tokens and 2,267 output tokens including calibration, with no input/output holds remaining. Recent-only used 24 foreground model calls; hybrid used 36 including twelve opaque query encodings. Hybrid's twelve real index builds are separately recorded. The report is `.build/evaluation/devgpt-answer-pilot-20261005.json`, SHA-256 `c1ff20c833bb9af27174a68aadba94e838895031523d122d17eaac0d28528d72`, 1,207,595 bytes. Captured source hashes matched the worktree at recording; runtime stores and answer IPC were discarded after scoring.

N4 passed 2,287 application checks and five additional controlled native checks, with matching frozen source and strict deep signature verification. The genuine synthetic v1 count/admission/archive/restore fixture preserves exact request bytes, receipts and charges. Before repeating these development cases, N4 freezes `recent-source-framing-v2-structural-diagnostics-v1`: recent source IDs use the [v2 context framing](CONTEXT-COMPONENTS.md), and strict response failures gain fixed content-free structural codes. The original rubric decisions, projections, oracles, ordinary questions, output reserve, strategy order and one-replicate configuration remain unchanged. New rendered input includes the labels and revised host attribution instructions; fresh provider counts and admission are required. Reusing these probes after a baseline fix is a development repeat, with uncontrolled caches, rather than an independent confirmation set. The original report remains unchanged.

The repeat at `d9c3e20` completed 24/24 attempts and scored 6/12 overall per arm, comprising the same three correct single quotes plus three absence cases. Five of six single quotes now have correct citations; two still contain incorrect quoted text. Cross-message failures are two JSON-syntax and one top-level-shape failure per arm. The added framing caused h00 to reduce from 68 recent events to a 34-event suffix; historical and cross-message gold fell outside it and hybrid delivered no excerpts for those probes. Gold coverage fell from 9/9 to 7/9 answerable probes per arm. Hybrid delivered 16 historical excerpts only for h00 absence. Eleven paired requests and twelve paired answers match. There is no observed retrieval benefit. The [status record](STATUS.md#recent-source-framing-development-repeat) retains resources, hashes and the selection boundary.

A separate feasibility witness must include human query anchors and exchange relationships as well as answer text and IDs. Token counting/admission measures provider fit; sufficiency requires a frozen annotation contract. The proposed measurement API and standalone witness journal validation remain unimplemented.

The subsequent `historical-selection-trace-v1` diagnostic exposes bounded returned-candidate/assembly metadata and query-token positions through the ordinary coordinator. It preserves the existing query algorithm, source projections, questions, oracles, reserves and scoring. A read-only reconstruction of all nine answerable queries matches their retained lexical query digests and the original query-source hash. All eight selected words precede the first source anchor. The two h00 missing-evidence probes inspected zero lexical and vector candidates; the retained semantic disposition is `codeLike`. The failure occurs before evidence assembly or token reduction. The current trace does not establish how all pre-ranking candidates compare, or whether an alternative query/exchange pack is sufficient. Original reports remain immutable.

The fresh traced run completed 23/24 attempts and retained all twelve hybrid selection traces. Both arms remained 6/12, with the same h00 pre-assembly failure. The first recent-only attempt failed provider admission before history reads and retained its calibration charge plus one unknown output-token hold. Source/configuration/oracle pins matched; the original report remains unchanged. See [the traced run](STATUS.md#historical-source-selection-trace).

N3 remains incomplete until larger/cross-session histories and independently annotated natural developer questions/correction cases are frozen, and provider-rendered sufficient-gold-evidence feasibility is measured through its separate contract. A sufficient witness for the complete citation task must include identity as well as answer text. Original chronology, scoped lifecycle and code reconstruction need their own adapters. Three histories and one replicate cannot establish generalization, representative accuracy, power, latency, economics or tree benefit.
