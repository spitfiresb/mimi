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

The overlay uses macOS 26's native `NSGlassEffectView`, with the clear lens
profile from the native experiment. `NativeGlassTuner` applies the filter inputs
through Core Animation's named key paths and verifies presentation values.
While visible, it disables automatic window-layer flattening and enables the
backdrop layer's `windowServerAware` setting to address the reported frozen
background. These private compositing settings are restored when hidden.
The panel starts at the reviewed 350×52 size and grows with the transcript;
text remains sharp above the lens with a small shadow for contrast.

**Screen Recording is not required.** The earlier ScreenCaptureKit renderer,
its geometry helpers, and its Metal shader are excluded from the Mimi target
and app bundle. No screen-access prompt or screen-access menu item is present.
The operating system composites the backdrop; Mimi does not receive its pixels.

The lens inputs are private macOS APIs. Unsupported filter layouts retain the
native material, and Objective-C exceptions are caught so tuning failures do
not break dictation. Reduce Transparency restores the native accessibility
appearance. Tuning polls only while the overlay is visible and stops on hide.
Automated tests check presentation updates, idle compositing settings, recovery
after settings are overwritten, resize, and cleanup. Live refraction while
scrolling during dictation was visually confirmed on macOS 26.3; behavior during
Space swipes still requires separate validation.

The nonactivating panel joins all Spaces and applications, including eligible
full-screen Spaces, and uses stationary window behavior for Mission Control.
Its position stays anchored at the bottom center as the text grows.

### Native glass preview

Run `bash scripts/preview-native-glass.sh` to launch **Mimi Glass Preview**.
It uses the same `OverlayPanel.swift` as the app, but builds separately without
screen capture, microphone, speech models, or hotkeys. The pill remains visible
so you can switch apps, swipe between Spaces, and enter Mission Control. Use
**Glass Preview** in the menu bar to show short or long text, hide it, or quit.
The preview opens the floating **Clear lens preview** over your normal windows.
Run with `--grid` to restore the 350×52, text-free reference comparison, or
`--live-grid` to start its background moving after three seconds. The left
outline is plain transparency; the right is the experimental native lens.
**Hide Grid (Keep Lens Unchanged)** removes the test background without changing
lens geometry, filter parameters, position, or text visibility. **Show / Hide
Text (Keep Lens Size)** isolates foreground visibility without resizing.

**Deep Lens Test** adjusts undocumented native filter inputs with blur and tint
removed. The reference has an inner-refraction height of 26 and amount of 15.6.
**Previous Edge Lens** retains Apple's refraction geometry with blur cleared;
**Original Native Glass** restores the unmodified material. The prototype comparison controls remain available for visual evaluation; the
reviewed lens profile is also integrated into the dictation app.

The preview compares model and presentation filter values while its background
changes. Earlier filter-object replacement could leave presentation values at
the opaque defaults despite the requested model values. Updates now use named
filter key paths on the layer inside a transaction with implicit animations
disabled, followed by a flush when values change. Matching values verify filter
propagation; they do not by themselves prove the desired optical appearance.
See [the native preview guide](tools/native-overlay-preview/README.md).
This does not rebuild or restart the running dictation app.

The previous custom Metal experiment remains in `DesktopGlassView.swift`,
`DesktopGlassCapture.swift`, and `Shaders/DesktopGlass.metal` for comparison,
but those files are excluded from the app build, along with their old tests. Its upstream attribution is in
[ThirdParty/KKarsyline-LiquidGlass/SOURCE.md](ThirdParty/KKarsyline-LiquidGlass/SOURCE.md).

### Legacy browser studio

Run `python3 tools/overlay-preview/serve.py`, then open
[localhost:8769](http://localhost:8769) to explore every overlay state and edit
its appearance live. No Swift build, microphone, or speech models are needed.
Browser settings save locally and can be exported as a design JSON file.
The browser retains the earlier frosted-glass approximation; designs are applied to native Mimi
separately. See [the preview guide](tools/overlay-preview/README.md).
