# Native investigation local repeat

Recorded October 7, 2026. **All six declared local Qwen attempts completed. JevK5 accepted 3/3 native investigation answers and 0/3 recent-only answers.** Native investigation delivered all four annotated evidence turns; recent-only delivered zero. This is the first completed native investigation quality comparison.

The user explicitly authorized getting the timeout working and running the local Qwen/JevK5 comparison. The [preceding failed trial](NATIVE-INVESTIGATION-LOCAL-TRIAL.md) remains intact. The paid orientation experiment and its legacy continuation were not run.

## Scope and execution

The repeat retained the existing three-case, answer-blind selection: `1b9b7252`, `4baee567`, and `gpt4_70e84552`. These are two single-session-assistant questions and one temporal-reasoning question, reused from the fourteen-history development cohort. The three histories contain 1,447 original events and 1,444,411 UTF-8 source bytes. Source projections, exact question bytes, dates, separate scorer annotations, output cap, arm order and QA protocol stayed pinned.

The optimized build includes the committed calibration timeout repair. A new private declaration froze its binary, source/test inventory, inputs, controller, QA protocol and connector executable before execution. The one-shot controller ran recent-only and native investigation for each case, with a maximum of six answer attempts and twelve judge decisions, no retries, and stop on the first operational failure. No operational stop occurred. Every declared arm remains in the denominator.

Answering used local `ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit` at the configured loopback endpoint, with thinking off and a 1,024-token final output cap. Judging used `JevK5-4B-v0.3-Q8_0` through the supplied mcpme MCP slot `87576cb2-cc02-4225-a13d-42fa684f99fb`. No remote-provider request occurred.

## Results

| Case | Recent-only acceptance | Investigation acceptance | Complete annotated turns delivered, recent / investigation | Whole-turn time, recent / investigation |
|---|---:|---:|---:|---:|
| `1b9b7252` | Rejected | Accepted | 0/1 / 1/1 | 11.84 s / 101.49 s |
| `4baee567` | Rejected | Accepted | 0/1 / 1/1 | 1.99 s / 57.87 s |
| `gpt4_70e84552` | Rejected | Accepted | 0/2 / 2/2 | 5.25 s / 75.01 s |
| Total | 0/3 | 3/3 | 0/4 / 4/4 | Median 5.25 s / 75.01 s |

All six answers have complete capture, completed episodes and healthy accounting receipts. Original-source delivery validation passes. Native investigation used 6, 3 and 4 navigation actions and 8, 5 and 6 private stages respectively, followed by one final visible answer per attempt. All three loops report finished with zero unresolved facts. Each final request contained original evidence; derived notes stayed outside final input. This verifies actual invocation of the orientation, deliberate navigation and reading path.

JevK5 passed all six public controls and graded all six completed answers. All twelve decisions were cache misses. The live runtime count increased from 56 to 68 decisions, with cache hits unchanged at three and errors unchanged at zero. Backend/engine identity and generation 32 stayed stable. The manager reports 73 successful MCP tool requests and zero failures. These are runtime/manager observations; the GUI was not visually rechecked.

## Timeout and resource evidence

The repaired optimized app passes 4,053 application checks, including the delayed-calibration transport fixture, plus seven controller tests and strict deep signature verification. All 164 captured source/test hashes still match after execution.

All 25 live calibration requests completed; the slowest took 1.40 seconds. The first recent-only calibration took 1.24 seconds. The live repeat establishes working calibration and answering with the current local server. These warm responses did not require the extended 90-second ceiling; the synthetic delayed-response fixture establishes that the client accepts calibration beyond the former 15-second limit. The earlier approximately 68.8-second server interval remains an incompletely attributed historical observation.

| Charged episode resource | Recent-only, three attempts | Native investigation, three attempts |
|---|---:|---:|
| Model calls, including calibration | 6 | 44 |
| HTTP attempts | 36 | 264 |
| Input tokens | 10,492 | 229,804 |
| Output tokens | 414 | 3,797 |
| Logical source bytes | 13,239,932 | 26,060,007 |

All held resource totals are zero at completion. Logical source-work charges describe accounted source passes, not physical disk I/O. The extra model work and 58–101-second native turn times are substantial; this path is not ready for default promotion on latency evidence.

## Interpretation and limits

The retrieval and reference-based QA results agree on these cases: native investigation recovered the annotated original evidence and produced accepted answers. This is direct evidence that the implemented whole-history orientation followed by deliberate search and reading can succeed on the two assistant-recall cases and the temporal case tested here.

The sample has three reused development histories, two categories, one replicate and no abstentions. The control is recent-only. There is no matched ordinary-hybrid arm, and investigation has a larger original allowance. These results cannot isolate orientation from full-snapshot lexical search, establish broad performance across the fourteen-history cohort, or validate JevK5's semantic accuracy and source-support calibration. No production-readiness claim follows.

The next performance work should reduce repeated private model work and compare investigation with ordinary hybrid across more categories. Both quality and latency need measurement before enabling the route by default. Additional runs need a separate frozen declaration; this repeat is terminal and cannot be resumed.

## Receipts

Private captures remain ignored by Git in the isolated worktree's `.build/evaluation/native-local-trial-v2-20261007`. The optimized bundle and synthetic verification live in `.build/calibration-timeout-repair-optimized-v3`. No prompts, answers, provider bodies, credentials or imported history are included here.

| Artifact | SHA-256 |
|---|---|
| Frozen declaration | `2a9109deb21aa7df98d5ba07a4a864c2c0ca2e6112944009eb8cda2119ed813d` |
| Terminal report | `6a216ea2364d8491d03627996a9e94e066ead3129470abe899fde1822f4150c3` |
| Post-run metadata audit | `45770cdecc62cfba259c5a738c7f5e976d07d9ad6dc62e0980cf8f87713edf89` |
| Live counter audit | `972447e1bc50b45f0dddb415bd961bfd352ea72c70ee6616f8d5ee4201a66b1e` |
| Optimized binary | `9366ba25e5503202941b1cdb392daad068722e031dad424fd1f291025433749d` |
| Optimized verification | `16e482034781fe1f8a182ac5184f80a8822d7f8b05233b05e686a3abf5f580ee` |
