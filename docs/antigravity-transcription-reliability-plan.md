# Antigravity transcription reliability plan

Research date: September 17, 2026. Implementation branch: `fix/antigravity-transcription-reliability`. Changes are in the working tree; the installed app has not been replaced.

## Parallel chunk follow-up

On September 18, resumed T3 thread `043b3a66-658e-4bc1-a774-8ee266d7e00e`, backed by Codex thread `01a0b292-9c0e-74b0-9a51-3e3e769df08d`. The user requested concurrent chunks within the existing maximum AI session setting. The previous agent implemented the scheduler and five regression tests before stopping at a usage limit.

Each lecture queues a bounded number of unfinished chunks. Every chunk acquires the existing shared session permit, so a setting of three caps active requests across chunks, other lectures, and study-material generation together. The scheduler reads the current limit when refilling work; the pool enforces the current limit before starting each session. Reducing the setting lets existing requests finish before admitting more.

Results and checkpoints retain their original chunk indices. Each accepted result is saved before its task returns, including results that finish out of order. Only a complete set is merged, in recording order using the existing overlap rules. A failed chunk cancels its siblings; explicit cancellation does the same. Resume skips accepted checkpoints, and each unfinished chunk keeps its own single-retry budget. Progress counts accepted parts and serializes asynchronous callbacks so an older count cannot replace a newer one.

Regression fixtures cover ten chunks with a limit of three and reversed completion order, sequential processing at a limit of one, two lectures sharing the limit with generation, failure after an out-of-order checkpoint, and cancellation followed by resume. The first cancellation run timed out on a signal-handler marker. A rerun and 100 repeated concurrency cases passed. The final test checks that child PIDs have exited, since closing stdin can also terminate a completed fixture without running its signal handler.

Final verification on September 18: the full Xcode suite passed with 296 tests passing and two opt-in live tests skipped, across 205 XCTest cases and 93 Swift Testing cases. This includes all five concurrency tests with the process-exit assertion. Result bundle: `.build/reliability/Logs/Test/Test-Lectern-2026.09.18_00-14-57--0400.xcresult`. `git diff --check` passed. Changes remain uncommitted and unpushed; the installed app is unchanged.

Live-provider speedup and long-recording quality under concurrent load have not been measured. The earlier sequential live checks below do not establish those results.

## Implementation and verification

Recovered the interrupted implementation from T3 thread `3a4408dc-5d4a-429b-812a-07a15684b5e2`, backed by Codex thread `01a0b26c-b58d-7e43-83e2-a25339389069`. The prior agent stopped at a usage limit while finishing the resume regression test.

Implemented:

- The managed transcription connection applies its policy before the ACP initialization handshake. It denies permissions, rejects client tool/input requests, stops on tool notifications, bounds transcript and protocol output, and requires successful completion. Generation keeps its existing default policy.
- Each request still contains the complete transcription skill and native audio. Model, thinking level, audio encoding, chunk boundaries and overlap, and session concurrency retain their existing selection rules.
- Accepted chunks use separate atomic files with integrity digests. Resume checks a streaming audio digest, source identity, job and connection identity, settings, skill text, runtime version, and preparation/parser/prompt versions. Saved ranges allow completed audio exports to be skipped. Missing or corrupt data is recomputed. A storage failure keeps the in-memory transcript and reports a resume warning.
- Explicit retry reuses accepted chunks. Retranscribing a completed lecture creates a fresh job. Cancellation retains checkpoints without scheduling a restart. Lecture deletion waits for the cancelled job's writes before removing its checkpoints. Other abandoned caches expire after 30 days, with cleanup bounded to the checkpoint directory and at most once per hour during use.
- Recoverable process failures and timeouts allow one fresh-session retry per unfinished part. The outer engine cannot multiply that budget. Off-task activity, invalid output, authentication failure, and cancellation do not trigger automatic chunk retry. Existing fallback and upload-consent rules remain in force.
- The deadline is three times the chunk duration, clamped to 15–120 minutes, starting after the shared session permit is acquired. This is a conservative initial bound, not a calibrated latency prediction. Shutdown retains the originating error and signals only the owned process group, including a child that ignores termination after its parent exits.
- The lecture view shows percentage based on accepted chunks, completed/total parts, retry state, elapsed time, and a progress bar. Token streaming does not write the job history. Failure summaries contain the part, attempt, elapsed time, and failure category without prompts, audio, credentials, commands, or thought text.

Live checks used only synthetic speech and a disposable text fixture with the installed managed runtime and the existing Google subscription:

| Audio run | Seconds | Result |
| --- | ---: | --- |
| Restricted | 6.63 | Exact fixture transcript |
| Existing generation policy | 4.93 | Exact fixture transcript |
| Existing generation policy | 4.99 | Exact fixture transcript |
| Restricted | 5.27 | Exact fixture transcript |

The audio said: "Photosynthesis uses sunlight to help plants make food. This is a short lecture about biology." All four requests included the full transcription skill. The live file-reading probe stopped with the off-task outcome. That verifies detection and termination, not prevention of every native action before its notification.

Local checkpoint encoding, integrity hashing, and atomic writes measured 1.81 ms at p95 for 30 samples of a 300-segment result in a debug build. The short live comparison does not establish a zero-regression guarantee or long-recording accuracy. Long English-Hebrew and sparse-audio comparisons, peak memory measurements, and deadline calibration remain release checks before distributing an updated installed build.

Verification completed on September 17, 2026:

- Full Xcode suite: 290 tests passed, zero failures, two opt-in live tests skipped. Result bundle: `.build/reliability/Logs/Test/Test-Lectern-2026.09.17_23-45-19--0400.xcresult`.
- After the final completed-job recovery fix and checkpoint-key update, all 47 focused reliability, provider, queue, and concurrency tests passed, with two live tests skipped. Result bundle: `.build/reliability/Logs/Test/Test-Lectern-2026.09.17_23-48-54--0400.xcresult`.
- The live audio comparison and live tool-containment probe passed in separate opted-in runs. The tests verify native audio/skill delivery, detection and termination, and generation's existing policy. They do not establish an operating-system sandbox.
- Regression cases include cancellation followed by explicit resume through a new engine/store, exact chronological merge, fresh retranscription after completion, corrupt checkpoints, disk-write failure, early permissions during initialization, truncated/oversized output, invalid timestamps, bounded timeout retries, and a termination-resistant child process.
- `git diff --check` passed. No release, installation, commit, or push was performed.

Run the deterministic suite with:

```sh
xcodebuild -scheme Lectern -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/reliability test CODE_SIGNING_ALLOWED=NO
```

`TranscriptionReliabilityTests` also contains two opt-in live tests. To run them, set `TEST_RUNNER_LECTERN_LIVE_RELIABILITY_AUDIO` to a synthetic WAV and `TEST_RUNNER_LECTERN_LIVE_RELIABILITY_SKILL` to the repository's transcription `SKILL.md` when invoking `xcodebuild`. Ordinary tests skip both live probes and make no authenticated provider requests.

## Findings before implementation

The interrupted run completed four audio parts, then spent several minutes on unrelated tool work during part five. Its saved conversation includes filesystem searches, database queries, and binary inspection. The recording was supplied as native audio. A missing file on disk was not a reason to search the Mac for it.

Current Lectern behavior explains why that could continue:

- `ACPConnection.respondToPermissionRequest` automatically selects `allow_once` when offered. This policy is shared with generation.
- `handleSessionUpdate` consumes text messages and ignores tool events. The prompt path checks refusal but does not require a successful completion reason.
- Initialization already advertises client filesystem and terminal capabilities as false. These flags describe client-provided protocol methods; they do not disable the runtime's own tools.
- `AntigravityACPClient.run` serves transcription and generation. Each invocation owns a connection and acquires a permit from the shared `AISessionPool`. The configured concurrency default is five.
- The transcription adapter holds successful chunk results in memory until all chunks finish. Its audio preparation exports all chunks before the first request and deletes temporary audio on exit.
- `TranscriptionJobStore.persist` encodes and atomically rewrites the entire job history. Adding token-level updates or chunk transcripts to that file would create unnecessary work.
- Timestamp parsing currently repairs backward timestamps and clamps out-of-range timestamps. Validation must examine raw values before that repair. The parser accepts untimed text too, which remains necessary for the no-timestamps option.
- `sourceAudioHash` is currently a path, size, and modification-time identity, not a content hash. Resume must account for this and must also match processing settings.
- Existing engine retries wrap the whole provider attempt. Adding chunk retries without coordinating that layer could multiply requests.

Source scope: `ACPConnection.swift`, `AntigravityACPClient.swift`, `AntigravityACP.swift`, `AISessionPool.swift`, `ExternalTranscriptionEngine.swift`, `TranscriptionService.swift`, and `TranscriptionProviders.swift`. Graph coverage was checked; the recorded partial range in `TranscriptionService.swift` was read directly. Relevant existing tests cover native audio, splitting and overlap merging, concurrent lectures, independent cancellation, runtime cleanup, and Notes generation.

## What ACP can enforce

[ACP tool-call documentation](https://agentclientprotocol.com/protocol/v1/tool-calls) defines permission replies and tool notifications. Permission requests are optional for agents. A notification can describe an action already executing. Therefore rejecting permission requests and cancelling on tool events is useful containment, but cannot prove that no native tool ran.

[ACP initialization documentation](https://agentclientprotocol.com/protocol/v1/initialization) defines client filesystem and terminal capabilities. Those switches do not constitute a process sandbox.

The upstream [T3 Antigravity text helper](https://github.com/pingdotgg/t3code/blob/53510d44ea7b4a44c10c122dd9245194f2f14d09/apps/server/src/textGeneration/AntigravityTextGeneration.ts) already uses the relevant pattern: reject tool/permission requests, abort on tool activity, use a temporary working directory, check for global hooks/MCP configuration, and impose a timeout. Its [provider documentation](https://github.com/pingdotgg/t3code/blob/53510d44ea7b4a44c10c122dd9245194f2f14d09/docs/internals/providers.md) explicitly says these controls are not a native sandbox. Its short-helper timeout is not an appropriate transcription timeout to copy blindly.

I did not establish a supported tools-disabled switch for Google's managed ACP 1.1.1 runtime. Settings documented for the ordinary Antigravity CLI are not evidence that the managed ACP runtime accepts them. No authenticated live prompt or audio upload was run during this research.

## Proposed implementation order

### 1. Add a policy specifically for transcription

Add an explicit operation policy passed from `AntigravityTranscriptionAdapter` through `AntigravityACPClient` into its owned `ACPConnection`. Generation retains its current default. Install the policy before session creation so early requests cannot slip through.

For transcription:

- Select the runtime's advertised supervised/default mode with checked error handling. Do not use the existing best-effort `setMode` for a required policy, or change the shared profile's settings globally.
- Reject permission requests, client filesystem/terminal requests, and unexpected extension requests. Preserve protocol-valid cancellation replies.
- Stop the owned request on `tool_call` or `tool_call_update`, including unsolicited calls that never requested permission. Discard that attempt's text and record a distinct off-task error.
- Reject unexpected user-input requests. Do not mistake thought-text streaming for tool execution.
- Check the managed profile's known hooks/MCP configuration before launch. Read only those bounded configuration files; do not scan the user's directories or erase settings.
- Retain native audio, the selected model and thinking level, language instructions, timestamps, and speaker options. Replace the `@filename` task phrasing with a clear reference to attached audio and explain that the supplied instructions are complete. The prompt is supporting guidance, not the enforcement mechanism.

First validate the pinned runtime with disposable fixtures. Determine which read/search actions bypass approval, what events they emit, and whether an advertised runtime restriction actually prevents them. If strict prevention cannot be verified, describe the result as early termination on detected tool use. A stronger guarantee would need a supported runtime restriction or separately evaluated process isolation; do not invent undocumented flags or silently switch providers, authentication, or billing.

### 2. Persist each accepted chunk and resume it safely

Introduce a small checkpoint store owned by the transcription workflow. Store a versioned manifest and individual normalized chunk results outside the all-jobs JSON file. Write one result atomically after acceptance; avoid repeated copies of the full accumulated transcript.

The manifest records source identity, exact core/export ranges and overlaps, provider/connection, model and thinking level, language, speaker/timestamp settings, and prompt/parser/preparation versions. On resume, verify compatibility before reusing results. A changed recording or setting invalidates incompatible checkpoints. Strengthen source identity using a streaming digest off the main thread if required; measure the cost and reuse it rather than hashing per chunk.

Separate audio planning from exporting enough to reuse saved ranges and export only unfinished parts on resume. Preserve the current codec, split boundaries, overlap, and normal-run export strategy. Save text and ranges rather than retaining all prepared audio indefinitely.

Merge accepted parts exactly once in chronological order with the existing overlap rules. Publish the final transcript only after every part succeeds. Explicit retry resumes; explicit retranscription starts fresh. Cancellation retains checkpoints but never automatically restarts a cancelled lecture. A fallback provider does not silently inherit another provider's partial text.

Handle corrupt/missing checkpoints by recomputing the affected part. Report checkpoint-write failure clearly without losing a successful in-memory result. Bound retention and remove checkpoints when their lecture is deleted or they expire. Cleanup uses the checkpoint store's own directory and does not run per token.

### 3. Bound failures without interrupting healthy work

Expose typed outcomes for user cancellation, off-task activity, timeout, output limit, authentication, and process exit. Preserve the originating failure while shutting down, rather than replacing it with a generic connection-closed error.

Use a per-chunk deadline based on chunk duration and measured healthy runs, with generous allowance for high reasoning and server latency. A lack of final text alone is not evidence of a stall. Do not copy a fixed three-minute text-helper timeout into transcription.

Use one coordinated retry budget. Permit at most one fresh-session retry for a recoverable chunk failure, reusing earlier checkpoints. Avoid nested engine retries that replay the whole lecture. Backoff occurs outside the shared session permit; every exit path releases the permit. Existing paid-fallback and upload-consent rules continue to apply. User cancellation never triggers retry or fallback.

Verify process ownership and child cleanup. Current `shutdown` sends termination to its direct process; it does not by itself prove descendant cleanup. Any escalation must target only the owned process group, never broad name-based searches that could stop generation or another lecture.

### 4. Validate cheaply and expose progress

Use one local validation pass, with no second model call:

- Require a successful ACP completion reason; reject cancelled, refused, or limit-truncated output.
- Reject empty output and gross format violations. Check raw timestamp order and duration bounds with rounding tolerance before normalization.
- Preserve support for no timestamps, quiet endings, sparse speech, Hebrew/Aramaic text, and student questions. Do not require the final timestamp to equal the recording duration.
- Avoid broad word blacklists for commentary: a lecturer can say those words. Ambiguous text-quality findings should be warnings unless supported by protocol evidence or a clear format failure.

Show part number, accepted parts, elapsed time, and retry state. Keep progress in memory, coalesce UI updates to at most twice per second, and persist only significant transitions. Retain a bounded diagnostic summary of event types, tool categories, timing, stop reason, and exit status. Do not record audio/base64 payloads, credentials, full thought streams, or every token. Do not open the runtime's conversation database during normal transcription.

## Performance and quality release gates

These are acceptance criteria to measure, not a claim of zero overhead before implementation.

- Preserve normal-run model, thinking level, audio encoding, chunk sizes/overlap, and configured concurrency. Add no model validation calls, extra audio uploads, or extra agent processes on successful runs.
- Keep policy checks in the existing event handler. Use sleeping deadlines, not periodic process or filesystem polling. Keep checkpoint encoding, hashing, and writes off the main actor.
- Proposed local checkpoint-plus-validation budget: p95 under 100 ms per completed chunk on the target Mac. Investigate any repeatable app CPU, memory, or responsiveness regression rather than dismissing it as network noise.
- Compare repeated deterministic before/after fixtures for dispatch overhead, time to first prompt, UI responsiveness, peak memory, and disk bytes. Include a large existing job history so whole-history write amplification cannot hide.
- Run interleaved live comparisons with identical audio and model settings for short, long, mixed English/Hebrew, and sparse recordings. Compare transcription coverage and accuracy as well as latency and false-abort/retry rate. Provider variability means one faster run is not proof.
- Exercise Notes, Flashcards, cleanup, Quiz, and chat concurrently with transcription. Confirm no policy leakage, added requests, lost permits, changed generation output handling, or cancellation of unrelated work.
- Resume test: cancel during part five, relaunch, and verify parts one through four are not uploaded or transcribed again. Compare final merge with an uninterrupted run.
- Protocol fixtures must cover permission rejection, a native tool notification without permission, late events, missing session IDs, malformed messages, cancellation/completion races, a hung child process, and output limits.

Use the existing Xcode `Lectern` scheme and focused Antigravity/concurrency/provider tests, then the full relevant suite. Live runtime enforcement and performance checks are required before enabling the new path in an installed build. Mock tests alone do not establish native runtime behavior.

## Scope and rollout

Implement as reviewable stages: transcription policy and event handling; checkpoints and resume; bounded recovery, validation, and UI; performance/quality verification. New checkpoint storage must be additive and versioned, leaving existing job JSON readable. Keep generation's behavior explicitly covered by regression tests throughout.

Do not combine this work with a model downgrade, runtime upgrade, broader generation restrictions, or a move to a paid API. The user subsequently authorized parallel chunks within the existing shared session limit, as described above; the global concurrency mechanism and setting remain the same.
