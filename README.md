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

## Overlay design preview

Run `python3 tools/overlay-preview/serve.py`, then open
[localhost:8769](http://localhost:8769) to explore every overlay state and edit
its appearance live. No Swift build, microphone, or speech models are needed.
Browser settings save locally and can be exported as a design JSON file.
The browser approximates macOS materials; designs are applied to native Mimi
separately. See [the preview guide](tools/overlay-preview/README.md).
