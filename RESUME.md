# Mimi — resume bullet bank

Everything this project can truthfully claim, grouped by the discipline a job ad
is asking about. Pick 2–4 per application.

**House rules**

- Historical draft from 2026-08-13, first committed with the September 13 work.
  Some bullets describe superseded implementations or old counts; revalidate
  before using them. Current capture and battery status live in `ROADMAP.md`.
  Aspirational claims live in the last section, quarantined.
- Bullets run 16–24 words to match the existing entry's rhythm.
- Numbers: `1.92%` / `2.34%` WER, `0.008×` / `0.028×` RTF, `2,620` utterances,
  `5.4h` audio, `36ms` vs `2.2s`, `~65×`, `151` logged dictations, `~5,000` lines.
- Never claim Parakeet "streams" — it batch-decodes at key release today.

## The measured results

| | Parakeet-int8 (ours, on ANE) | Apple SpeechTranscriber (baseline) |
|---|---|---|
| Word error rate | **1.92%** | 2.34% |
| Real-time factor | **0.008×** | 0.028× |
| 5.4h of audio in | 2.6 min | 9.1 min |
| Errors | 805 sub / 91 ins / 113 del | 950 sub / 115 ins / 166 del |

Corpus: LibriSpeech test-clean, all 2,620 utterances, 52,576 reference words.
Identical scoring for both engines. Reproduced by one command.

---

## Header / tech-stack lines

Pick the one that matches the job. Keep the project name and "(Personal)".

- **On-Device Speech Recognition (Personal)** | Swift 6, Core ML, Apple Neural Engine, PyTorch, coremltools
- **On-Device AI Dictation (Personal)** | Swift, AppKit, Core ML, SpeechAnalyzer, Apple Foundation Models
- **ASR Model Deployment & Benchmarking (Personal)** | Python, PyTorch, NeMo, coremltools, Swift, Accelerate
- **Mimi — Local Speech-to-Text for macOS (Personal)** | Swift 6, Core ML, AVFoundation, CoreAudio, XCTest

---

## A. On-device ML / model deployment

The core story. Lead with these for MLE, applied ML, and on-device AI roles.

- Ported NVIDIA Parakeet-TDT-0.6b to Core ML with int8 quantization, running inference on the Apple Neural Engine
- Beat Apple's production SpeechTranscriber on accuracy and speed: 1.92% vs 2.34% WER, 0.008× vs 0.028× real time
- Deployed a 600M-parameter transducer end to end on-device — no cloud inference, no network calls, no accounts
- Hand-wrote the token-and-duration transducer decode loop in Swift; Core ML only executes the three exported networks
- Split the model into encoder, prediction, and joint networks, exported separately because each runs at a different cadence
- Cut real-time factor to 0.008×, transcribing 5.4 hours of audio in 2.6 minutes on a consumer laptop

## B. Model conversion & numerical parity

For anyone who asks "have you actually shipped a model."

- Exported a NeMo PyTorch checkpoint to Core ML in fp16 and int8, gated on 95% token agreement with the reference
- Built a parity harness comparing Core ML output against native PyTorch inference per utterance before trusting quantization
- Applied per-channel linear-symmetric int8 weight quantization and re-verified accuracy on the eval set, not by eyeballing samples
- Patched coremltools' TorchScript frontend to fix a constant-folding crash on scalarized casts under NumPy 1.25+
- Traced a second-call NaN to MLMultiArray's uninitialized memory feeding garbage LSTM state — first call passed on zeroed pages
- Found Core ML's async prediction overload returning silently wrong results on fp16 models, and pinned the synchronous path

## C. DSP / signal processing

Strong for embedded, audio, and anything numerical.

- Reimplemented NeMo's log-mel frontend on Accelerate/vDSP — preemphasis, Hann window, 512-point FFT, 128 Slaney mel bins
- Pinned the Swift mel frontend against spectrograms dumped from PyTorch, catching window-symmetry and pad-mode mismatches worth real WER
- Reverse-engineered a preprocessor's exact frame accounting — emitted vs valid frames, masked tails, per-feature normalization over the valid region
- Chose recompute-over-incremental for mel extraction after measuring vDSP at milliseconds across a full 60-second buffer

## D. Neural Engine / performance engineering

The bullets nobody else has. Best differentiators in the whole bank.

- Root-caused an Apple Neural Engine compiler crash on dynamic-shape exports, shipping fixed-shape encoder windows instead
- Moved the encoder from GPU to Neural Engine: 36ms per 15-second window versus 2.2 seconds, a ~65× speedup
- Cut resident memory 3× by collapsing three encoder variants into one always-warm window after measuring 65s eviction reloads
- Built a modification-date-invalidated Core ML compile cache after finding 38GB of orphaned artifacts left by the system compiler
- Fixed IOSurface buffer exhaustion in a long-running benchmark by scoping autorelease pools per chunk rather than per process
- Profiled per-network placement and left the decoder and joint off the Neural Engine, where dispatch overhead exceeds compute

## E. Evaluation / benchmarking / data science

For DS, ML eval, and research-engineering roles. Section E is your strongest
non-ML-infra material.

- Built a Swift evaluation harness scoring any speech engine on word error rate and real-time factor behind one protocol
- Implemented a token-level Levenshtein WER scorer with backtrace, separating substitutions, insertions, and deletions rather than reporting distance
- Aggregated corpus-level rather than averaging per-utterance rates, which overweights short clips and inflates the headline number
- Benchmarked two engines across 2,620 LibriSpeech test-clean utterances, 5.4 hours of audio and 52,576 reference words
- Documented every methodology choice — no ITN denormalization, decode time excluded from RTF, sequential runs to avoid accelerator contention
- Chose a human-verified public corpus over convenient self-recorded audio so results stayed comparable to published figures
- Ran error analysis on the residual: proper nouns and contraction expansions, the latter attributable to a deliberate scoring choice
- Established the incumbent's baseline before building the challenger, so the new model had a number to beat rather than a demo
- Isolated failures so one erroring utterance scores as deletions instead of aborting a five-hour benchmark run

## F. Concurrency / reliability / debugging

For senior, systems, and infra roles. These read as production experience.

- Diagnosed a two-day application freeze to a blocking CoreAudio call on the main thread during system wake
- Replaced a lying `isRunning` health check with a buffer-delivery heartbeat after zombie engines recorded silent dictations for eight minutes
- Designed a generation-based recovery state machine so a wedged retry can never publish stale state or block later attempts
- Built retries on a concurrent queue with exponential backoff, because a serial queue inherits the first hang forever
- Replaced a task-group timeout that waited on the work it had already abandoned — the deadline fired but the caller still blocked
- Wrote an Objective-C exception shim so AVFoundation's NSExceptions become catchable Swift errors instead of unwinding through async callers
- Threaded cooperative cancellation through an uninterruptible inference loop, checking per frame so deadlines bite within milliseconds
- Extracted a race-prone recovery state machine from its framework so its concurrency invariants are unit-testable without hardware
- Layered independent watchdogs across recording, session startup, finalization, and decode so no single hang can strand the UI

## G. macOS / systems programming

- Built a menu bar app with a global push-to-talk hotkey via CGEventTap, swallowing the chord before it reaches other apps
- Handled the system silently disabling event taps on timeout, synthesizing the dropped key-up that would otherwise wedge the app permanently
- Pinned the built-in microphone at the CoreAudio unit level rather than following the system default input device
- Traced silent capture failures to a stale cached format after device pinning, where the tap received zero callbacks indefinitely
- Stamped synthesized keyboard events with a source marker so the app's own event tap cannot retrigger it
- Survived sleep, wake, and audio route changes by rebuilding the capture engine off the main thread on a heartbeat

## H. UI / interaction design

Use for frontend or product-engineering applications. It is native AppKit, not web.

- Designed a floating non-activating overlay that renders committed text solid and provisional text dimmed as speech resolves
- Sized the panel to its content with animated growth, so text advancing reads as progress rather than a box jumping
- Fixed a black flash on every text update by isolating the label from vibrancy compositing during crossfades
- Kept the overlay from ever becoming key or main, so a synthesized paste lands in the user's document instead
- Inserted text via a pasteboard snapshot-and-restore, gated on change count so a user's own copy always wins
- Waited for physically held modifiers to clear before synthesizing a paste, preventing the hotkey chord from corrupting the keystroke

## I. LLM application engineering

For anyone hiring on "AI engineer" or LLM product work.

- Integrated Apple's on-device language model to clean dictated text, running fully offline with no bundled weights
- Constrained model output through guided decoding into a typed schema, making conversational preamble structurally impossible rather than prompt-discouraged
- Built a mechanical invention guard rejecting rewrites where over 40% of output words never appeared in the input
- Routed only sentences with evidence of disfluency to the model, using the recognizer's own per-word confidence scores as a signal
- Cut cold-start latency 6× by prewarming the model session at launch and again at keypress, off the critical path
- Enforced a hard latency budget on an uninterruptible generation call by abandoning the wait rather than cancelling it

## J. Data engineering / instrumentation

- Designed a versioned append-only JSONL log capturing transcript, timing breakdown, capture health, and target application per dictation
- Instrumented the full latency path — finalize, format, settle, insert, decode, startup, first preview — to attribute user-visible delay
- Logged both engines' transcripts of the same audio, turning every real dictation into a free A/B comparison
- Recorded capture-side health so a silent dictation can be attributed to a dead microphone versus a failed engine
- Made logging failures silent by design, so a broken log can never take the product down with it

## K. Testing

- Wrote 36 unit tests across five suites covering the WER scorer, mel frontend, deadline primitives, recovery races, and text routing
- Pinned a numerical DSP port against reference output from the original framework, making the tolerance the contract
- Tested timeout primitives against deliberately uncancellable work, proving the deadline bounds the wait and not just the report

## L. Build & developer tooling

- Wrote a build script that assembles, signs, and relaunches the app, resetting TCC grants keyed to the changing ad-hoc code hash
- Verified process termination before relaunch after finding the launcher silently activating a stale binary, invalidating every test run since

## M. Judgment and process

Not resume bullets — talking points for cover letters and interviews.

- Wrote an Amazon-style working-backwards press release before building, with every stage mapped to one clause of it
- Held a standing rule that no claim reaches the resume before it reaches `main`, with placeholder numbers marked as placeholders
- Kept the incumbent engine wired as baseline and fallback; the challenger earned the default slot by winning the benchmark
- Built the evaluation harness before the model, on the principle that a converted model without one is a demo
- Structured the next arc to retire its accuracy risk on the harness, behind a numeric gate, before writing product code

---

## Do NOT claim yet

These appear in the roadmap as targets. They are not built.

| Claim | Reality |
|---|---|
| "lock-free audio ring buffer" | Not built. Stage 6, every box unchecked. Current path is a hot `AVAudioEngine` with a 0.5s pre-roll. |
| "on-device VAD" | Not built. Same stage. Chunking is a blind 29.4s cut today. |
| "streaming speech model" | Parakeet batch-decodes at key release. Streaming is planned in `STREAMING.md`, stage S0 not started. |
| "1,000 logged utterances" | The benchmark ran on LibriSpeech, not the dictation log. Say "2,620 LibriSpeech utterances." The log holds 151 dictations. |
| "measured ANE power draw" | `powermetrics` capture never taken. The 65× timing delta is the evidence; call it a speedup, not a power measurement. |
| "shipped / notarized / distributed" | Ad-hoc signed, runs from `build/`. No Developer ID, no notarization, no CI. |
| "first-partial latency" | Metric not implemented — blocked on the streaming session. |

There is **no backend** in this project — no server, no API, no database. For
backend applications, the transferable material is section F (concurrency,
timeouts, retry state machines), section E (the CLI and library API design), and
section J (schema design, structured logging). Frame it as systems work, not
web services.

---

## Interview backup

Three stories worth being able to tell in detail. Each maps to bullets above.

1. **The ANE crash.** Dynamic-shape Core ML exports crashed Apple's compiler in
   BNNS. Both `RangeDim` and `EnumeratedShapes` failed. Shipping single
   fixed-shape windows was the only thing that loaded — and it turned 2.2s of
   GPU time into 36ms. Then memory bit back: three window packages at ~570MB
   each thrashed an 8GB machine into 65-second reload stalls, so it collapsed to
   one always-warm 30-second window. Cost: 36ms of wasted padding on short
   utterances. (Section D.)

2. **The two-day freeze.** The menu bar went dead and stayed dead. Not a crash —
   the process was alive at 31% CPU with coreaudiod at 65% beside it. A wake
   handler had called `AVAudioEngine.inputNode` on the main thread while
   coreaudiod was still re-enumerating devices, and blocked in a mach_msg that
   never returned. Nothing about it was cancellable. The fix was structural:
   revival moved off the main thread entirely, health checks stopped asking
   AVFoundation anything, and a generation counter made overlapping recovery
   attempts safe. (Section F.)

3. **The deadline that wasn't.** A 59-second dictation spent 29.2 seconds
   decoding, blew its deadline, discarded the result, and pasted the fallback
   text. The timeout had fired exactly on schedule — but `withTaskGroup` waits
   for every child before returning, so the caller inherited the full duration
   anyway. The rewrite is a first-wins actor that abandons the loser instead of
   awaiting it. (Sections F and I.)
