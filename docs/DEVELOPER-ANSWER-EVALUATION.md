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

Gold strings, required event IDs, spans, digests, rubrics and expected values stay on the Python scorer side. Only the original events and ordinary questions enter `AnswerEvaluationCommand`. The native runner independently checks the complete projection against its allowlist. The scorer checks its oracle pin, source bytes and citation/gold-ID linkage before compilation or provider work, then validates durable delivered ranges before awarding citations. Recent-context messages currently carry no visible event IDs; a strategy can reproduce the correct answer and fail citation scoring. That boundary remains explicit in reports.

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

This amendment implements a small source-bound reproduction/citation/absence diagnostic. On October 5, 2026, the matching copied-source application passed 2,218 checks and strict deep signature verification. A separate 32-check public-source suite included 27 overlapping synthetic checks and five native checks covering all 24 attempts against controlled Qwen plus killed-child supervisor cleanup ownership. All 24 operationally completed with intentionally incorrect output and zero task credit; actual projection/input digests, overlay isolation, construction/accounting and content-free reports passed. Live Qwen execution remains pending.

N3 remains incomplete until live execution is recorded, independently annotated natural developer questions and correction cases are frozen, and provider-rendered sufficient-gold-evidence feasibility is measured through its separate contract. Original chronology, scoped lifecycle and code reconstruction need their own adapters. Three histories and one replicate cannot establish generalization, representative accuracy, power, latency, economics or tree benefit.
