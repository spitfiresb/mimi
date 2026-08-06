# Mimi — Requirements & Roadmap

Local speech-to-text for the Mac. Push a key, talk, text appears where your cursor is.

---

## The press release

*Written 2026-08-06, before the product it describes. Amazon-style: this is what
must be true when we're done, and every stage below exists to make a clause of it
true.*

> **Mimi runs its own speech model on the Mac's Neural Engine — and proves it.**
>
> Mimi ported a streaming speech model (NVIDIA Parakeet-TDT) to Core ML with int8
> quantization, running inference on the Apple Neural Engine at under 0.2× real
> time. Audio reaches the model through a lock-free ring buffer gated by on-device
> voice activity detection, and every claim is backed by a benchmark harness that
> scores the model against Apple's own SpeechAnalyzer across the app's full log of
> real dictations — word error rate, latency, and power, measured, not assumed.

The two sentences that go on the resume, verbatim targets:

1. *Ported a streaming speech model to Core ML with int8 quantization, running
   inference on the Apple Neural Engine at under 0.2× real time* — the RTF is a
   placeholder until measured.
2. *Fed it from a lock-free audio ring buffer with on-device VAD, benchmarked
   against Apple's SpeechAnalyzer across 1,000 logged utterances* — the count is
   whatever `transcripts.jsonl` holds at print time (42 today).

**No clause ships to the resume before it ships to `main`.**

---

## Principles

1. **Nothing leaves the machine.** Not audio, not text, not telemetry. This is
   architectural, not a setting. *(Unchanged — the pivot strengthens it: our own
   weights on our own silicon is the strongest form of the claim.)*
2. **Prove, don't assume.** Every performance claim carries its measurement: RTF
   from the harness, ANE residency from `powermetrics`, WER from scored logs. A
   number without a methodology is marketing.
3. **The harness decides.** Apple's SpeechAnalyzer stays wired in as the baseline
   and the fallback. Parakeet earns the default slot only by beating it in the
   harness — and if it never does, the harness result *is* the deliverable.
4. **Fast enough to feel instant.** Release the key, text is there.

### What changed 2026-08-06, and why

The old roadmap said *small, no bundled weights, the model is a commodity, no
Parakeet*. That produced a real product — but a 520KB app built entirely on system
frameworks caps out at "user of Apple's APIs." The project's actual job is to be
the hardest engineering story Zain can truthfully tell, so the direction inverts:
**deploy, optimize, and evaluate our own model on the Neural Engine.** The old
non-goals are retired, not repudiated — the system-framework path stays in the app
as the baseline arm of the benchmark, which is exactly where a commodity belongs.

---

## Constraints

| | |
|---|---|
| **OS** | macOS 26.0+ only |
| **Hardware** | Apple Silicon only |
| **Language** | Swift / SwiftUI (Python permitted in `tools/` for model conversion only) |
| **ASR — baseline** | Apple `SpeechTranscriber` (system framework, zero bundled weights) |
| **ASR — challenger** | Parakeet-TDT converted to Core ML, int8, ANE-pinned |
| **Formatting** | Apple Foundation Models (on-device LLM, zero bundled weights) |
| **Sandbox** | Off — required for Accessibility APIs |
| **Distribution** | Developer ID direct download. Not the Mac App Store. |

### Non-goals

- **No cloud anything.** No API calls, no accounts, no sync.
- **No Mac App Store.** Sandboxing blocks the Accessibility APIs this needs.
- **No Electron / Tauri.** Native or bust.
- **No Intel support.**
- **No training or fine-tuning.** We deploy and evaluate; we don't train. (Aqua
  Voice trained a custom model and tied with free Parakeet — see Notes.)

*Retired 2026-08-06:* "No Parakeet / whisper.cpp fallback" and "no bundled model
weights" — both reversed by the press release. Whisper stays out on the merits:
it's chunk-based and can't stream, and streaming is the product.

---

## Milestone log

Dates are when the work landed on `main`.

| Date | Milestone |
|---|---|
| 2026-07-31 | Project named and scoped — README, principles, non-goals |
| 2026-08-02 | **Stage 0 — walking skeleton.** End-to-end dictation: hold ⌃⌥Space, talk, text appears at the cursor |
| 2026-08-02 | Live transcription overlay — a floating non-activating panel showing text as you speak |
| 2026-08-03 | **Stage 1 — transcript logging.** Every dictation appended locally as JSONL; launch at login |
| 2026-08-03 | **Stage 2 first cut — formatting layer live.** Foundation Models pass with invention-ratio guard, verbatim toggle, prewarm |
| 2026-08-04..05 | Overlay redesign, sleep/wake survival, press/release race fix, hot-mic pre-roll, streaming cleanup, instrumentation |
| 2026-08-06 | PR #1 merged — Stages 1–2 on `main`. **Press-release pivot:** this roadmap rewritten around the Core ML / ANE / benchmark direction |

**Current state:** MVP on system frameworks, genuinely usable, 42 logged
dictations. Act II begins.

---

## Act I — the system-framework MVP ✅

Stages 0–2 of the old roadmap: walking skeleton, transcript logging, formatting
layer. All shipped; details live in git history and the notes below. What Act I
leaves behind that Act II builds on:

- `transcripts.jsonl` — every real dictation, growing daily. Becomes the eval set.
- `SpeechTranscriber` fully wired — becomes the baseline arm of every benchmark.
- The formatting layer — engine-agnostic; whatever ASR wins feeds it unchanged.
- The hot `AVAudioEngine` + 0.5s pre-roll — the thing the ring buffer replaces.

---

## Act II — own the model

Ordering principle: **the harness first, because it validates everything after
it.** A converted model without a harness is a demo; with one it's a result.

### Stage 3 — The eval harness 🟡 *(started 2026-08-06)*

The XCTest target the project has never had, and the stage every later claim
depends on. Eval set decision (2026-08-06): **LibriSpeech test-clean from
OpenSLR**, not audio sidecars on the transcript log — human-verified references,
2,620 utterances, comparable to published figures. Own-voice sidecars demoted to
a supplement (wishlist) rather than a prerequisite.

- [x] `MimiTests` target in `Package.swift` — pins `Formatter`'s deterministic
      halves (routing, sentence split, invention guard) and the WER scorer
- [x] `EvalKit` library + `mimi-eval` CLI — run a LibriSpeech-format directory
      through any `EvalEngine`, capture transcript + timings
- [x] WER scorer — token-level Levenshtein with error-kind backtrace, corpus
      aggregation, case/punctuation-free normalization (no ITN denorm — both
      engines face the same charge, so A/B stays fair; absolutes read high)
- [x] `scripts/fetch-librispeech.sh` — test-clean into `datasets/` (gitignored)
- [x] Metrics per run: WER (sub/ins/del), RTF; per-utterance JSON report
- [ ] First-partial latency and peak RAM metrics (needs a streaming-aware
      engine interface — arrives with ParakeetEngine, which actually streams)
- [x] Baseline report: SpeechAnalyzer scored across test-clean — the number
      Parakeet has to beat. **Measured 2026-08-06, full 2,620 utterances
      (5.4h audio): WER 2.34% (950 sub / 115 ins / 166 del over 52,576 words),
      RTF 0.028×** (5.4h transcribed in 9.1 min). Worst errors are proper
      nouns ("Stephanos Dedalos") and contraction expansions ("he's" → "He
      is") — the latter is the no-ITN-denorm charge, applied equally to every
      engine. Parakeet-TDT-0.6b's published test-clean WER is ~1.7% with a
      text normalizer; under this harness's stricter scoring, beating 2.34%
      is a real but plausible target.

**Done when:** one command produces a scored report for a named engine across
the eval set. ✅

### Stage 4 — Parakeet-TDT → Core ML

The risky stage. Conversion is where this dies if it dies.

- [ ] `tools/convert/` — Python: pull Parakeet-TDT-0.6b, export encoder/decoder/
      joint through `coremltools` to `.mlpackage`
- [ ] fp16 first — prove numerical parity against the PyTorch reference on a
      handful of logged utterances before touching quantization
- [ ] int8 quantization pass; re-verify parity (WER delta on the eval set, not
      eyeballing)
- [ ] Swift inference wrapper: `ParakeetEngine` conforming to the same interface
      `SpeechEngine` uses, streaming partials as it decodes
- [ ] TDT decode loop in Swift (token-and-duration transducer — the decoder is
      ours to write; Core ML only runs the networks)
- [ ] Wire into the harness as the second engine

**Done when:** the harness scores Parakeet on the same report as SpeechAnalyzer.

### Stage 5 — Neural Engine, proven

The clause everyone else fabricates. We measure it.

- [ ] `computeUnits = .cpuAndNeuralEngine`; verify no silent CPU fallback via
      Instruments' Core ML/ANE trace
- [ ] `powermetrics --samplers ane_power` capture during a harness run — ANE draw
      while decoding is the receipt
- [ ] Measure RTF on-ANE across the eval set; this number replaces the 0.2×
      placeholder in the press release
- [ ] Op-level audit: which layers fell off the ANE and why (the usual suspects:
      unsupported ops, dynamic shapes); fix what's fixable
- [ ] Power/thermal comparison: ANE vs CPU-only on the same workload

**Done when:** the resume bullet's every clause carries a measured number and a
command that reproduces it.

### Stage 6 — The audio path: ring buffer + VAD

Replace the pre-roll with a real systems structure.

- [ ] Single-producer single-consumer lock-free ring buffer (atomic head/tail,
      power-of-two capacity) — mic render thread writes, engine consumer reads,
      no locks on the audio thread ever
- [ ] Pre-roll becomes a property of the buffer (read pointer trails write by
      0.5s) instead of a separate copy path
- [ ] On-device VAD gating what reaches the model: start with energy +
      hangover, evaluate Silero-VAD-CoreML if energy proves too crude
- [ ] Harness gains a VAD metric: false-trigger rate and clipped-word rate
      against the logged set

**Done when:** the audio thread allocates nothing, locks nothing, and the model
never sees silence.

### Stage 7 — Publish the benchmark

The credential, unchanged from the old roadmap but now with our own entrant.

- [ ] Full matrix: SpeechAnalyzer vs Parakeet-fp16 vs Parakeet-int8 × WER × RTF ×
      RAM × power, on real dictation audio
- [ ] Publish harness, methodology, results
- [ ] The winner becomes Mimi's default engine — principle 3 settles it

---

## Act III — product hardening

Unchanged in substance from the old Stages 3–6; compressed here, expanded when
Act II lands.

- **Context awareness** — per-app formatting profiles (code vs chat vs email)
- **Personalization** — vocabulary from corrections; contextual biasing at the
  ASR layer (published gains: 30–48% relative rare-word recall)
- **Reliability** — device switching, insertion fallback chain, configurable
  hotkey, stable signing, `/Applications` install, graceful failure states
- **Ship it** — Developer ID, notarize + staple, Sparkle, DMG, GitHub Actions
  building/signing/notarizing on tag (CI becomes honest resume material here),
  landing page

---

## Wishlist

Unscheduled. Pull forward if something proves important.

- Voice commands — "new paragraph", "scratch that"
- Streaming insertion into the target app (conflicts with the formatting pass;
  the overlay covers the preview half)
- Multiple profiles / modes; per-app enable/disable
- Transcript history window; custom vocabulary UI
- Auto-stop on silence via `SpeechDetector` (partially superseded by Stage 6 VAD)
- Multi-language; sound/haptic on start/stop; menu bar waveform; CLI

---

## Open questions

1. **Does `SpeechTranscriber` honor `contextualStrings`?** Plumbing confirmed in
   the 26.5 SDK (`setContext` works mid-session); behaviour still unproven. Now
   also a harness question — measurable the day Stage 3 lands.
2. **Can the TDT decode loop hit streaming latency in Swift**, or does the
   joint-network round-trip per token need batching tricks? The conversion can
   succeed and the streaming still fail — this is Stage 4's real risk, not the
   export.
3. **Audio retention policy** — sidecar WAVs are ~1MB per 30s. Cap, rotate, or
   keep? (Supersedes the old text-log retention question; text is negligible.)
4. **What latency will users tolerate** for the formatting pass before wanting
   it off?

---

## Notes worth keeping

- **Formatting > acoustics.** Removing punctuation changes WER by 2.0–4.1%
  absolute; total acoustic error on clean audio is ~0.92%. The formatting layer
  is ~3× the effect size of the model choice. *(This is why the harness scores
  formatting separately — and why Parakeet losing on WER wouldn't sink the
  project. The deployment story is the deliverable.)*
- **The ASR field is saturated on clean speech.** SOTA on LibriSpeech test-clean
  is 0.92%; there's nothing acoustic left to win on near-field dictation audio.
- **Aqua Voice's proprietary model scores ~5.2 WER** — statistically tied with
  free Parakeet. Deploy, don't train.
- **Argmax is the template**: WhisperKit → reference implementation for on-device
  ASR on Apple Silicon → commercial SDK. They never topped a leaderboard; they
  owned the *deployment* story. That is precisely the Act II thesis.
- **Never `codesign --deep`.** Sign inside-out. `--deep` is for verification only.

### Implementation gotchas already hit

- **Physical modifiers merge with synthesized ones.** On release the user is often
  still holding ⌃⌥, turning a synthesized ⌘V into ⌃⌥⌘V. `TextInserter` waits for
  modifiers to clear first.
- **Ad-hoc signing invalidates Accessibility silently.** TCC keys approval to the
  code hash. `bundle.sh` runs `tccutil reset Accessibility` each build.
- **`CGEventTap` gets disabled by the system on timeout**, silently. Handle
  `.tapDisabledByTimeout` and re-enable.
- **Stamp synthesized events** with `CGEventSource.userData` and ignore them in
  the tap, so the app can't retrigger itself.
- **`AVAudioEngine` input format ≠ analyzer format.** Ask
  `bestAvailableAudioFormat(compatibleWith:)` and convert; don't assume 16kHz.
- **Live preview needs two transcriber modules, not one filtered on `isFinal`.**
  A volatile module isn't required to reissue unchanged results as final —
  filtering one module silently drops text. Progressive module for preview,
  `.transcription` module for the authoritative text.
- **The preview overlay must never become key or main**, or the synthesized ⌘V
  lands in the overlay.
- **A dead menu bar app is indistinguishable from a broken hotkey.** Suspect "is
  it even running?" before debugging the event tap.
- **On-demand mic start eats the head of the utterance** (~1s hardware spin-up).
  Engine runs from launch; idle audio goes to a 0.5s pre-roll flushed into the
  stream at keypress. *(Stage 6 rebuilds this as the ring buffer.)*
- **The login item registers the bundle's current path** — today `build/`, which
  `bundle.sh` recreates every run. The app needs `/Applications` before
  launch-at-login can be trusted.
