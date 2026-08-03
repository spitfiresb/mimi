# Mimi — Requirements & Roadmap

Local speech-to-text for the Mac. Push a key, talk, text appears where your cursor is.

---

## Principles

1. **Nothing leaves the machine.** Not audio, not text, not telemetry. This is architectural, not a setting.
2. **Small.** The app should be a few megabytes, not a few hundred. No bundled model weights.
3. **The model is a commodity.** The differentiation is everything that happens *after* transcription.
4. **Fast enough to feel instant.** Release the key, text is there.

---

## Constraints

| | |
|---|---|
| **OS** | macOS 26.0+ only |
| **Hardware** | Apple Silicon only |
| **Language** | Swift / SwiftUI |
| **ASR engine** | Apple `SpeechTranscriber` (system framework, zero bundled weights — but a one-time OS-level asset download on first use) |
| **Formatting** | Apple Foundation Models (on-device LLM, zero bundled weights) |
| **Sandbox** | Off — required for Accessibility APIs |
| **Distribution** | Developer ID direct download. Not the Mac App Store. |

### Non-goals

- **No Parakeet / whisper.cpp fallback.** One engine. macOS 26+ or nothing.
- **No cloud anything.** No API calls, no accounts, no sync.
- **No Mac App Store.** Sandboxing blocks the Accessibility APIs this needs; every competitor ships direct for the same reason.
- **No Electron / Tauri.** Native or bust.
- **No Intel support.**

---

## Milestone log

Dates are when the work landed on `main`.

| Date | Milestone |
|---|---|
| 2026-07-31 | Project named and scoped — README, principles, non-goals |
| 2026-08-02 | **Stage 0 — walking skeleton.** End-to-end dictation: hold ⌃⌥Space, talk, text appears at the cursor |
| 2026-08-02 | Live transcription overlay — a floating non-activating panel showing text as you speak (pulled forward from the wishlist) |
| 2026-08-03 | **Stage 1 begins — transcript logging.** Every dictation appended locally as JSONL. Reordered the roadmap: output quality ahead of ergonomics |
| 2026-08-03 | Launch at login via `SMAppService`, on by default — the app has to be running to log anything |
| 2026-08-03 | **Stage 2 first cut — the formatting layer is live.** Foundation Models pass with invention-ratio guard, verbatim toggle, prewarm. Disfluencies, ITN, and reconstruction all working in first tests |

**Current state: MVP.** The core loop works end to end and is genuinely usable.
Collecting data; formatting layer is next.

---

## Stages

Each stage should be independently shippable and independently useful.

**Ordering principle: output quality first, ergonomics last.** Everything that makes
the text better comes before anything that makes the app nicer to hold. A rough app
that writes what you meant beats a polished one that writes what you said.

### Stage 0 — Walking skeleton ✅ *(2026-08-02)*

The smallest thing that transcribes.

- [x] Menu bar app, no dock icon (`LSUIElement`)
- [x] Hardcoded push-to-talk hotkey (⌃⌥Space, hold to record)
- [x] `AVAudioEngine` capture, converted to the analyzer's requested format
- [x] `SpeechTranscriber` transcription
- [x] Insert via pasteboard + synthetic ⌘V, restore previous clipboard
- [x] Mic + Accessibility permission prompts
- [x] First-run asset download + locale reservation
- [x] Warm start via `modelRetention: .processLifetime` (pulled forward from Stage 5)
- [x] Live overlay showing the transcript as you speak (pulled forward from the wishlist)

**Verified:** transcribes accurately, feels instant, clipboard restores correctly, insertion works in
TextEdit, Terminal, and other apps.

Built as an SPM package; `./scripts/bundle.sh` assembles and ad-hoc signs `Mimi.app` (~220 KB).

---

### Stage 1 — Capture everything 🟡 *(started 2026-08-03)*

No ML. Just instrumentation, running before there's anything to instrument.

Moved ahead of everything else because this data can only be collected *forward*.
Every day of real use without it is a day of training data thrown away, and it's the
one asset here a competitor can't clone.

- [x] Append-only local JSONL at `~/Library/Application Support/Mimi/transcripts.jsonl`
- [x] Log raw transcript, duration, locale, frontmost app, timestamp
- [x] Inspectable and purgeable — "Show Transcript Log…" in the menu, one file to delete
- [x] Failures swallowed; logging can never take dictation down with it
- [x] Launch at login (`SMAppService`), on by default — an app that isn't running logs nothing. Ergonomics normally waits for Stage 5; this one is a data-collection prerequisite, so it jumped.
- [ ] Fill `formatted` once Stage 2 exists
- [ ] Detect user edits to inserted text (short window after insertion) → fill `corrected`
- [ ] Simple review UI — see your own corrections
- [ ] Retention policy — decide whether the log is capped, rotated, or kept forever

**Done when:** every dictation produces a complete `(raw, formatted, corrected)` triple.

---

### Stage 2 — The formatting layer

Where the actual product is. Takes the transcript and makes it into what you meant to type.

**Early signal (2026-08-03, n=3 — confirm with real volume):** the premise this
stage was written on is partly wrong. `SpeechTranscriber` already punctuates and
capitalizes — the first logged utterances came out as *"Okay, so the current system
seems to be live now. I'm going to start using it pretty much for everything."* Not a
lowercase run-on. So punctuation and casing may be mostly free, and the real remaining
value is disfluency removal, reconstruction, and ITN. Re-scope this stage once
there's a week of log data rather than three lines.

- [x] Foundation Models pass over raw transcript *(2026-08-03)*
- [x] Disfluency removal, ITN, sentence reconstruction — all handled by one prompt; the warm-up test got *"um so basically I think we should uh push the release to like thursday no wait friday"* → *"We should push the release to Friday."* and *"three thirty"* → *"3:30"* unprompted
- [x] **Over-edit guard** — invention ratio, not edit distance: deletions are the job, invented words are the failure. >40% of output words absent from the raw → discard the rewrite, insert raw
- [x] Toggle to disable ("Clean Up Dictation" in the menu), for when you want verbatim
- [x] Skip the pass on very short utterances (< 3 words)
- [x] Prewarm at bootstrap — cold ~3s, warm ~0.5–0.7s (measured 2026-08-03, M-series)
- [ ] Feed confidence + alternatives into the prompt (needs the richer transcriber init)
- [ ] Tune the prompt against a week of real log data — n is still tiny
- [ ] Latency: ~0.5–0.7s added per dictation. Acceptable? Watch it in real use.

#### Approach: one model pass, one mechanical guard — not a rulebook

Rules don't scale here. ITN alone is thousands of cases, every rule is a rule you
maintain forever, and no rule reconstructs *"send it to Bob, no wait, Sarah."* But the
inverse — trusting a 3B model with free rein over your text — is how you get invented
words. The split: **the model makes judgments, deterministic code enforces safety.**

**Feed it acoustic uncertainty, not just text.** Verified in the macOS 26.5 SDK,
`SpeechTranscriber.init(locale:transcriptionOptions:reportingOptions:attributeOptions:)`
opts into more than the presets expose:

| Option | Gives |
|---|---|
| `.alternativeTranscriptions` | `Result.alternatives: [AttributedString]` — n-best |
| `.transcriptionConfidence` | per-run `Double` confidence |
| `.audioTimeRange` | per-run timing, so pauses are visible |

That's the acoustically-derived information a text-only model would otherwise lose —
without touching the audio or bundling a multimodal model.

**Gate edits on confidence.** High-confidence spans are locked; the model may only
rewrite what the recognizer was unsure of. This makes hallucination *structurally*
hard rather than prompt-hard, which is the only kind of hard that survives contact
with a small model.

**Guard mechanically.** Token-level edit distance between raw and output; past a
threshold, discard the rewrite and insert the raw text. One deterministic rule, not a
rulebook.

**Apple Foundation Models is the engine.** `FoundationModels.framework` ships in the
26.5 SDK: `LanguageModelSession.respond(to:generating:)` with `@Generable` gives
schema-constrained decoding, so the output shape is guaranteed rather than parsed.
Zero bundled weights, which keeps the size principle intact.

**It is text-only.** No audio or image input anywhere in the API surface. True
audio→LLM would mean a third-party multimodal model via MLX — gigabytes of weights,
which breaks the second principle outright. Revisit only if the confidence-and-
alternatives channel proves insufficient.

**Done when:** the output reads like something you typed, not something you dictated.

**Watch:** this adds ~200–500ms. Budget it.

---

### Stage 3 — Context awareness

The same sentence should land differently in different apps.

- [x] Detect the frontmost app *(landed with Stage 1 logging)*
- [ ] Per-app formatting profiles (code editor vs Slack vs email vs docs)
- [ ] Code context: identifiers, no prose punctuation, camelCase/snake_case awareness
- [ ] Chat context: shorter, looser, no terminal period
- [ ] User-editable profiles

---

### Stage 4 — Personalization

The moat. Nobody in this category does it — every product ships a static prompt and learns nothing.

- [ ] Build a per-user vocabulary from corrections (names, jargon, repos, coworkers)
- [ ] Feed it into the formatting prompt
- [ ] Investigate contextual biasing at the ASR layer (published gains: 30–48% relative rare-word recall — far more than any model swap)
- [ ] Learn per-user formatting habits, not just vocabulary
- [ ] Measure it: does WER on the user's own speech drop over time?

**Done when:** it's measurably better after a month of use than on day one.

---

### Stage 5 — Make it reliable

Deliberately late. Stage 0 works on the happy path; this makes it work every time.
None of it improves a single word of output, which is why it waits — but all of it
blocks shipping to anyone else.

- [ ] Fix the press/release race — releasing the key before the session finishes starting drops the utterance
- [ ] Handle input device switching, Bluetooth, sample rate changes
- [ ] Insertion fallback chain: ⌘V → AX direct set → leave on clipboard and notify
- [ ] Configurable hotkey instead of hardcoded ⌃⌥Space
- [ ] Stable self-signed cert so Accessibility survives rebuilds (currently reset each build by `bundle.sh`)
- [ ] Install to `/Applications` — the login item registers whatever path the bundle is at, and `build/` is deleted every build
- [ ] Recording indicator in the menu bar
- [ ] Graceful failure states (no mic permission, no Accessibility, engine unavailable)
- [ ] First-run onboarding for the two permission grants

**Done when:** it survives a day of real use without a manual restart.

**Pull forward if:** a bug starts costing you dictations often enough that you stop
reaching for the app. Broken tools don't generate training data.

---

### Stage 6 — Ship it

- [ ] Developer ID Application certificate
- [ ] Hardened Runtime, entitlements: sandbox off, `device.audio-input`, `network.client`
- [ ] `NSMicrophoneUsageDescription` (Accessibility and Input Monitoring have no usage-description keys — they're pure runtime TCC consent)
- [ ] Notarize + staple
- [ ] Sparkle 2.9.x for updates
- [ ] DMG with a real installer experience
- [ ] Landing page

---

### Stage 7 — The benchmark

The credential. Nobody publishes on-device dictation numbers, and the hardware everyone else lacks is the hardware you have.

- [ ] Eval harness: WER × latency × RAM × battery on Apple Silicon
- [ ] Formatting benchmark — punctuation, casing, ITN, disfluency, reconstruction. Measured separately from acoustic WER, because it's ~3× the effect size on clean audio.
- [ ] Run across engines and Mac models
- [ ] Publish: harness, methodology, results
- [ ] Consider submitting a *model* to the Open ASR Leaderboard (documented path, ~$3–6/run). Not a dataset — zero community datasets have ever been merged.

---

## Wishlist

Unscheduled. Pull forward if something proves important.

- Voice commands — "new paragraph", "scratch that", "delete that"
- Streaming insertion — text lands in the *target app* as you speak. The live overlay (done 2026-08-02) covers the preview half of this; inline insertion is the part left, and it conflicts with the Stage 2 formatting pass, which needs the whole utterance before it can rewrite anything.
- Configurable hotkey; double-tap-modifier support
- Multiple profiles / modes (dictation, code, command)
- Transcript history window
- Auto-stop on silence via `SpeechDetector`
- Custom vocabulary UI (manual entry, ahead of Stage 4 learning it)
- Multi-language
- Per-app enable/disable
- Sound or haptic on start/stop
- Menu bar waveform
- CLI for scripting

---

## Open questions

1. **Does `SpeechTranscriber` honor custom vocabulary?** Partly resolved by reading the SDK: `contextualStrings` lives on `AnalysisContext`, which `SpeechAnalyzer.init(…analysisContext:)` accepts for *any* module — so it is **not** restricted to `DictationTranscriber` as the docs imply. The API path is open. Whether `SpeechTranscriber` actually acts on it is still an empirical test, and it gates Stage 4's biasing work. Cheap to answer — worth doing early, because a "no" changes how personalization reaches the ASR layer at all. Further confirmed in the 26.5 SDK: `contextualStrings` is keyed by a `ContextualStringsTag` (`.general` provided), and `SpeechAnalyzer.setContext(_:)` updates it *mid-session* — so learned vocabulary can be pushed in without tearing down the analyzer. The plumbing is better than expected; only the behaviour is unproven.
2. **How much latency will users tolerate** for the formatting pass before wanting it off?
3. **What's the right correction-detection window** in Stage 1 before edits stop being "corrections" and start being ordinary editing?

---

## Notes worth keeping

- **Formatting > acoustics.** Removing punctuation changes WER by 2.0–4.1% absolute; total acoustic error on clean audio is ~0.92%. The formatting layer is roughly 3× the effect size of the model choice.
- **The ASR field is saturated on clean speech.** SOTA on LibriSpeech test-clean is 0.92%; professional human transcribers beat Whisper by a fraction of a point. There's nothing acoustic left to win on near-field dictation audio.
- **Aqua Voice's own proprietary model scores ~5.2 average WER** — statistically tied with free Parakeet. A dictation company trained a custom model and gained nothing measurable. Don't repeat that experiment.
- **Argmax is the template**: open-source WhisperKit → became the reference implementation for on-device ASR on Apple Silicon → commercial SDK. They never topped a leaderboard.
- **Never `codesign --deep`.** Sign inside-out. `--deep` is fine for verification only.

### Implementation gotchas already hit

- **Physical modifiers merge with synthesized ones.** On release the user is often still holding ⌃⌥, which turns a synthesized ⌘V into ⌃⌥⌘V and pastes nothing. `TextInserter` waits for modifiers to clear first.
- **Ad-hoc signing invalidates Accessibility silently.** TCC keys approval to the code hash, which changes every build — so a previously-granted toggle still reads "on" while being invalid. `bundle.sh` runs `tccutil reset Accessibility` to force a clean re-grant. No sudo needed.
- **`CGEventTap` gets disabled by the system on timeout**, silently. Must handle `.tapDisabledByTimeout` and re-enable, or the hotkey just stops working.
- **Stamp synthesized events** with `CGEventSource.userData` and ignore them in the tap, so the app can't retrigger itself.
- **`AVAudioEngine` input format ≠ analyzer format.** Ask `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` and convert; don't assume 16kHz.
- **Live preview needs two transcriber modules, not one filtered on `isFinal`.** A module emitting volatile results is not required to reissue them as final if finalization didn't change them — so filtering one progressive module silently drops text. Run a `.progressiveTranscription` module for the preview and a separate `.transcription` module for the authoritative transcript. The progressive preset also carries `fastResults` ("faster but less accurate") — fine to show, wrong to insert.
- **The preview overlay must never become key or main.** If it takes focus, the synthesized ⌘V lands in the overlay instead of the user's app.
- **A dead menu bar app is indistinguishable from a broken hotkey.** `LSUIElement` means no dock icon and no window, so when `bundle.sh` quit the running copy and didn't relaunch it, the only symptom was ⌃⌥Space doing nothing. The script now relaunches if a copy was up. Suspect "is it even running?" before debugging the event tap.
- **The login item registers the bundle's current path.** `SMAppService.mainApp` points at wherever `Mimi.app` sits right now — today that's `build/`, which `bundle.sh` deletes and recreates every run. Fine for development, wrong for real use: the app needs to live in `/Applications` before launch-at-login can be trusted.
