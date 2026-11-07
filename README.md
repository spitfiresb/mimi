# Mimi

**耳 (mimi)** — *noun*, Japanese

> 1. ear
> 2. hearing; ability to hear
> 3. edge; crust; rim

---

Mimi is a lightweight, on-device speech-to-text app for the Mac.

Everything runs locally. Nothing leaves your machine.

Hold **Fn / 🌐**, wait for **“Speak now”**, then dictate. Release to finish and
paste. For hands-free dictation, **double-press Fn**, wait for **“Speak now”**,
then speak without holding anything. **Press Fn again** to finish and paste.
The overlay appears only when recording is ready. Hands-free mode shows a lock
icon without an instruction line. Short first taps remain invisible.

A double press means two presses within half a second, with a short first tap
(under 0.3 seconds). A single short tap cancels without pasting. Holding Fn starts
the microphone immediately; releasing stops it immediately unless hands-free is
locked. Sleep cancels either mode. The mic stays off while idle, including after
wake; there is no background pre-roll. Fn combined with another key cancels an
unlocked recording so ordinary Fn keyboard shortcuts can pass through.
Releasing a hold before “Speak now” cancels without pasting.
If macOS also handles Fn, set **System Settings → Keyboard → Press 🌐 key to →
Do Nothing** to avoid competing actions.

Cold microphone startup takes a moment. If startup cannot finish within eight
seconds, Mimi stops capture and lets you retry. A recording ends automatically
after two minutes of readiness. Speech models may remain loaded between presses.

On release, a lightweight silence gate skips final transcription and pasting when
there is no sustained signal. It measures 20 ms audio frames and requires 60 ms
in a row above an RMS level of 0.002 (about −54 dBFS), after removing DC bias.
This rejects silence, very low background levels, and isolated clicks without
another model. It is not speech/noise classification: louder noise can still pass,
and very quiet or distant speech below the threshold can be skipped. Gate metrics
are recorded locally to support tuning with real microphones.

Cleanup is off by default for faster pasting. Enable **Clean Up Dictation** in
Mimi's menu if you want the optional language-model pass; existing saved choices
are preserved. A successful Parakeet result pastes without waiting for Apple's
final transcript. Apple still provides live preview and fallback recognition.

## Overlay appearance

The overlay is stock macOS 26 Liquid Glass: an `NSGlassEffectView` in the
`.regular` style, the same material as Notification Center's pills. WindowServer
blurs and composites the live backdrop, so **Screen Recording is not required**
and Mimi never receives screen pixels. Text uses system label colors, which
adapt to light and dark backdrops, and Reduce Transparency is honored by the
system.

Stock glass in Mimi's panel freezes on a snapshot of what was behind it, so
windows dragged underneath never show through. `LiveGlassView` keeps two
undocumented switches on: the backdrop layer's `windowServerAware` (sample
other apps' windows through WindowServer) and the window's flattening off
(`shouldAutoFlattenLayerTree`). AppKit turns `windowServerAware` off during
layout and replaces the backdrop layer on resize; correcting it afterwards on a
timer made the backdrop stutter. While the pill is visible, a main run-loop
observer just ahead of Core Animation's commit switches on any new or reset
backdrop layer, and KVO reverts resets made during the commit itself, so no
frame renders with it off. Selectors are checked first, so a macOS
without them falls back to stock glass. Set `MIMI_GLASS_DEBUG=1` to log each
correction.

The panel starts at 350×52 and grows with the transcript, anchored at the
bottom center. It never becomes key, joins all Spaces and applications
(including eligible full-screen Spaces), and stays put in Mission Control.

### Native glass preview

Run `bash scripts/preview-native-glass.sh` to launch **Mimi Glass Preview**, which
builds the same `OverlayPanel.swift` as the app without the microphone, speech
models, or hotkeys. Use **Glass Preview** in the menu bar to show the listening
state, short or long text, or **Play Dictation** (the full listening → partials →
transcribing → settle → hide sequence). Launch flags: `--listening`, `--long`,
`--play`. This does not rebuild or restart the running dictation app.
To check the backdrop stays live, run a second copy as the background:
`"build/Mimi Glass Preview.app/Contents/MacOS/MimiGlassPreview" --moving-window --bg-only &`
then the preview; `--dump` prints the backdrop layer's state.

### Legacy browser studio

Run `python3 tools/overlay-preview/serve.py`, then open
[localhost:8769](http://localhost:8769) to explore every overlay state and edit
its appearance live. No Swift build, microphone, or speech models are needed.
Browser settings save locally and can be exported as a design JSON file.
The browser retains an earlier frosted-glass approximation; designs are applied to native Mimi
separately. See [the preview guide](tools/overlay-preview/README.md).
