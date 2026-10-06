# Local LongMemEval QA diagnostic

`scripts/local_longmemeval_qa.py` grades the seven frozen LongMemEval development cases through the local Qwen server. It uses the unchanged upstream grading templates. It records local judgments; official GPT-4o grading and held-out judge calibration remain unrun.

## Inputs and execution

The protocol file is `src/evaluation/evaluate_qa.py` at upstream revision `9e0b455f4ef0e2ab8f2e582289761153549043fc`, SHA-256 `ecce9c4c79dc89d99534ac17b383a5cbb5b9f0c69ee98adaf0684742e3d95251`. The tool extracts only its pure prompt function through the Python AST. It does not import or execute the upstream CLI. Dataset bytes, source projections, questions, scorer annotations, dates, model configuration, answer-report hash and ordered hypothesis exports must match the [adapter contract](LONGMEMEVAL.md).

Execution requires `--execute`, an absolute fresh output directory, the pinned protocol file and a loopback HTTP endpoint. Redirects and environment proxies are disabled. Optional private capture uses a separate absolute fresh directory. Existing destinations, symlink ancestors and runtime destinations inside tracked repository paths outside `.build` are refused. Directories use `0700`; files use `0600`. Public reports contain counts, hashes and fixed statuses. Requests, benchmark questions, scorer answers and model responses belong only in private capture.

Run synthetic controls first, using fresh destinations:

```sh
python3 scripts/local_longmemeval_qa.py controls --execute \
  --protocol /absolute/path/pinned/evaluate_qa.py \
  --output-directory /absolute/path/new-controls \
  --private-directory /absolute/path/new-private-controls
```

QA requires a successful control report whose supplied SHA-256, grader implementation, template function, settings and 14 paired synthetic controls all match:

```sh
python3 scripts/local_longmemeval_qa.py qa --execute \
  --protocol /absolute/path/pinned/evaluate_qa.py \
  --source /absolute/path/longmemeval_s_cleaned.json \
  --answer-report /absolute/path/answer-report.json \
  --answer-report-sha256 EXACT_ANSWER_REPORT_SHA256 \
  --hypotheses-directory /absolute/path/private-hypotheses \
  --controls-report /absolute/path/controls/report.json \
  --controls-report-sha256 EXACT_CONTROLS_REPORT_SHA256 \
  --output-directory /absolute/path/new-qa-report \
  --private-directory /absolute/path/new-private-qa
```

The tool materializes all requests and publishes a declaration before calls. Each request has one user message, temperature zero, one completion, a ten-token output cap and thinking disabled. The selected local model is `ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit`. The default endpoint is `http://localhost:11234/v1/`. Protocol templates retain their category-specific update, temporal, preference and abstention grading rules. No scorer answer enters Boros's answering path.

## Response and denominator rules

Scoring requires the expected self-reported model identity, one assistant choice, an exact stripped case-insensitive `yes` or `no`, and a normal stop. The upstream yes-substring label is retained separately from strict format validity. Malformed JSON, duplicate fields, nonfinite values, truncation, inconsistent content and failed transport receive no score. Provider extension fields are permitted. Usage is recorded only when nonnegative integer counts sum correctly; missing or malformed usage remains unknown without invalidating an otherwise valid judgment. An observed completion count over ten makes the judgment unscored. Unknown usage never becomes an observed token total.

Incomplete answering attempts retain the official empty hypothesis placeholder. They remain in the declared QA denominator, receive no judge call and earn no credit. Reports separate accepted/declared fractions from accepted/scored fractions and distinguish failed answers from unknown judgments. Real-answer false-accept/reject rates are unknown because there are no independent truth labels for the local judge.

## Recorded evidence and limits

The 14 synthetic controls passed with no observed false accepts or false rejects. Local judgments accept hybrid 2/7 in v4, 4/7 in v5 and 3/7 in the preceding-human repeat; recent-only remains 1/7. The latest repeat scores 11/14 declared attempts; three output-limited answering failures receive no judge call or credit. Its 11 calls report 3,109 prompt tokens and 11 completion tokens. Across controls and all three comparisons, 52 calls report 13,734 prompt tokens and 52 completion tokens, outside Boros episode accounting. Exact regenerated requests, reparsed responses, labels, hashes, permissions and failed-response inventory are independently verified in `.build/evaluation/local-qa-adjacent-verification-20261006.json`; earlier result verification remains `.build/evaluation/local-qa-results-verification-20261006.json`. Detailed reports are listed in [STATUS.md](STATUS.md).

Twenty portable tests cover protocol extraction, input/export pins, strict responses, denominators, private publication, destination refusal and failure retention. They use synthetic temporary fixtures and require no downloaded benchmark or server. The historical local-QA-only checkpoint passed 3,502 checks, with source capture and binary reuse in `.build/evaluation/local-qa-verification-20261006.json`. The latest preceding-human app passes 3,555 checks and includes these 20 contracts.

Synthetic controls establish that this judge can follow these simple grading rules. They do not calibrate its decisions on held-out real answers. The answering and judging model is the same, allowing correlated errors. Model identity is self-reported; runtime and weights are unpinned. The subset has been reused for development. These results do not establish official benchmark accuracy, representative user quality or a completed product gate.
