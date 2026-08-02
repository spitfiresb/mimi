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

## Stages

Each stage should be independently shippable and independently useful.

### Stage 0 — Walking skeleton ✅

The smallest thing that transcribes.

- [x] Menu bar app, no dock icon (`LSUIElement`)
- [x] Hardcoded push-to-talk hotkey (⌃⌥Space, hold to record)
- [x] `AVAudioEngine` capture, converted to the analyzer's requested format
- [x] `SpeechTranscriber` transcription
- [x] Insert via pasteboard + synthetic ⌘V, restore previous clipboard
- [x] Mic + Accessibility permission prompts
- [x] First-run asset download + locale reservation
- [x] Warm start via `modelRetention: .processLifetime` (pulled forward from Stage 1)

**Verified:** transcribes accurately, feels instant, clipboard restores correctly, insertion works in
TextEdit, Terminal, and other apps.

Built as an SPM package; `./scripts/bundle.sh` assembles and ad-hoc signs `Mimi.app` (~220 KB).

---

### Stage 1 — Make it reliable

Stage 0 works on the happy path. This makes it work every time.

- [ ] Handle input device switching, Bluetooth, sample rate changes
- [ ] Fix the press/release race — releasing the key before the session finishes starting drops the utterance
- [ ] Configurable hotkey instead of hardcoded ⌃⌥Space
- [ ] Stable self-signed cert so Accessibility survives rebuilds (currently reset each build by `bundle.sh`)
- [ ] Insertion fallback chain: ⌘V → AX direct set → leave on clipboard and notify
- [ ] Recording indicator in the menu bar
- [ ] Graceful failure states (no mic permission, no Accessibility, engine unavailable)
- [ ] First-run onboarding for the two permission grants

**Done when:** it survives a day of real use without a manual restart.

---

### Stage 2 — The formatting layer

Where the actual product is. ASR gives you a lowercase unpunctuated run-on; this makes it into what you meant to type.

- [ ] Foundation Models pass over raw transcript
- [ ] Disfluency removal (um, uh, like, false starts)
- [ ] Punctuation + casing
- [ ] Inverse text normalization — "three thirty" → 3:30, "twenty five dollars" → $25, "dot com" → .com
- [ ] Proper noun casing
- [ ] Sentence reconstruction — *"send it to Bob, no wait, Sarah"* → *"Send it to Sarah."*
- [ ] **Over-edit guard** — reject output that diverges too far from source. An invented word the user can't detect is worse than a transcription error.
- [ ] Toggle to disable, for when you want verbatim
- [ ] Skip the pass on very short utterances (latency not worth it)

**Done when:** the output reads like something you typed, not something you dictated.

**Watch:** this adds ~200–500ms. Budget it.

---

### Stage 3 — Context awareness

The same sentence should land differently in different apps.

- [ ] Detect the frontmost app
- [ ] Per-app formatting profiles (code editor vs Slack vs email vs docs)
- [ ] Code context: identifiers, no prose punctuation, camelCase/snake_case awareness
- [ ] Chat context: shorter, looser, no terminal period
- [ ] User-editable profiles

---

### Stage 4 — Correction capture

No ML yet. Just instrumentation. **Start logging early — this dataset is the only thing here a competitor can't clone.**

- [ ] Detect user edits to inserted text (short window after insertion)
- [ ] Store (raw transcript, formatted output, final text) triples locally
- [ ] Local-only, inspectable, easily purged
- [ ] Simple review UI — see your own corrections

---

### Stage 5 — Personalization

The moat. Nobody in this category does it — every product ships a static prompt and learns nothing.

- [ ] Build a per-user vocabulary from corrections (names, jargon, repos, coworkers)
- [ ] Feed it into the formatting prompt
- [ ] Investigate contextual biasing at the ASR layer (published gains: 30–48% relative rare-word recall — far more than any model swap)
- [ ] Learn per-user formatting habits, not just vocabulary
- [ ] Measure it: does WER on the user's own speech drop over time?

**Done when:** it's measurably better after a month of use than on day one.

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
- Streaming insertion using `volatileResults` (text appears as you speak)
- Configurable hotkey; double-tap-modifier support
- Multiple profiles / modes (dictation, code, command)
- Transcript history window
- Auto-stop on silence via `SpeechDetector`
- Custom vocabulary UI (manual entry, ahead of Stage 5 learning it)
- Multi-language
- Per-app enable/disable
- Sound or haptic on start/stop
- Menu bar waveform
- CLI for scripting

---

## Open questions

1. **Does `SpeechTranscriber` honor custom vocabulary?** Partly resolved by reading the SDK: `contextualStrings` lives on `AnalysisContext`, which `SpeechAnalyzer.init(…analysisContext:)` accepts for *any* module — so it is **not** restricted to `DictationTranscriber` as the docs imply. The API path is open. Whether `SpeechTranscriber` actually acts on it is still an empirical test, and it gates Stage 5's biasing work.
2. **How much latency will users tolerate** for the formatting pass before wanting it off?
3. **What's the right correction-detection window** in Stage 4 before edits stop being "corrections" and start being ordinary editing?

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
