# Frozen exact-answer diagnostic rubrics

`scripts/answer_rubrics.py` implements the scorer-only protocol `boros-public-exact-answer-v1`. It scores exact reproduction, ordered composition of quoted facts, replacement of an obsolete literal value, and explicit abstention for absent information. This module freezes a diagnostic scoring contract; it does not establish that a public corpus supplies suitable correction or absence cases, representative questions, or independent annotations.

The response must be one JSON object with exactly three fields: `answer`, `citations`, and `abstain`. `answer` is a string except for `cross_message_quotes`, where it is an ordered array of strings. `citations` is an array of event-ID strings. `abstain` is a JSON boolean. Duplicate or additional fields, Markdown fences, trailing text, nonfinite numbers, invalid UTF-8, unpaired Unicode surrogates, and responses above 1 MiB fail closed. Outer JSON whitespace is accepted. Byte-exact Unicode spelling matters; the scorer applies no case folding or normalization.

A scorer-only oracle contains exactly these fields:

| Field | Contract |
|---|---|
| `rubric_version` | `boros-public-exact-answer-v1` |
| `kind` | `exact_quote`, `cross_message_quotes`, `correction`, or `absence` |
| `expected_answers` | Frozen exact strings in the requested order |
| `required_source_ids` | Distinct event IDs providing the frozen evidence |
| `forbidden_answers` | Distinct obsolete literal strings for correction; empty otherwise |
| `answerable` | Boolean consistent with the selected kind |

`exact_quote` requires one expected answer and at least one required source. `cross_message_quotes` requires at least two expected answers and two distinct source IDs. `correction` requires one current expected answer, required sources, and at least one forbidden obsolete literal. The expected answer cannot contain a forbidden literal. `absence` requires `answerable: false` and empty expected, required, and forbidden arrays. These consistency checks reject an invalid oracle before scoring.

The host calls `score_response(response, oracle, operational_complete=..., delivered_source_ids=...)`. It must validate gold byte offsets, UTF-8 boundaries, and digests against the frozen corpus. It must also validate delivered ranges or recent-message bytes and supply only event IDs whose relevant evidence was actually delivered. The scorer cannot derive these attestations from an ID alone. Oracle answers, obsolete values, gold ranges and required IDs remain outside provider input; the provider sees only the ordinary request and selected source context.

An answerable response succeeds only when `abstain` is false and its answer equals the expected string or ordered array. Exact equality rejects explanatory additions, negation, stale values and extra answers. Correction additionally rejects any forbidden literal anywhere in the answer. An absence response requires `answer: ""`, `citations: []`, and `abstain: true`.

Citation correctness is recorded separately from answer correctness. Citations must contain precisely the required source-ID set, with no duplicates, and every required source must have been delivered. Citation order has no effect. A correct quoted value with missing, extra, duplicate, or undelivered citations receives zero overall score. The caller's source-delivery checks remain essential: matching IDs alone cannot prove that the necessary bytes reached the model.

The content-free result contains the frozen rubric version and kind, overall integer `score`, booleans for operational completion, response validity, answer correctness, citation correctness and abstention correctness, and required/delivered/cited source counts. `failure_code` is null for success or one fixed code: `invocation_incomplete`, `response_invalid`, `abstention_mismatch`, `answer_mismatch`, or `citation_mismatch`. Partial or failed invocations receive zero without parsing or rewarding their retained output. Invalid oracle or host-evidence types raise `RubricError` containing only a fixed host-authored code. Results never include answer text, expected text, citations, or source IDs.

This protocol measures compliance with a constrained exact-answer request. It does not evaluate unrestricted prose, paraphrases, entailment, citation sufficiency independent of host attestations, or general conversational usefulness. A successful absence case only measures the declared question and frozen corpus; it does not prove that the requested fact is absent from other histories or external knowledge. No quality, latency, economic, summary-tree, or release threshold is established by the scorer itself.

The N4 additive diagnostic `boros-response-diagnostic-v1` preserves every v1 scoring decision and `failure_code`. Results add `response_diagnostic_version` and `response_error_code`. Invalid responses report one fixed structural code for size, UTF-8, host input type, JSON syntax, duplicate keys, nonfinite numbers, top-level shape, key set, abstention/citation shape, or string/array answer shape. Validation order determines the first failure. Valid and incomplete responses have a null structural code; incomplete invocations are not parsed. These codes contain no supplied text, parser error, path, citation or source ID. Discarded prior responses cannot be retroactively classified.

The synthetic contract suite runs with:

```sh
python3 scripts/test_answer_rubrics.py
```

It verifies exact and ordered success, negation, obsolete answers, abstention, citation set and delivery checks, terminal failure accounting, malformed JSON and UTF-8, strict types, oracle consistency, and content-free results.
