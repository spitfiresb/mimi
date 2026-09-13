# Overlay studio

This browser studio retains the earlier frosted HUD approximation and does not
render the native app's current Liquid Glass material.

Run from the repository root:

```sh
python3 tools/overlay-preview/serve.py
```

Open <http://localhost:8769>. Use `--port 8770` if the default port is occupied.
Stop the server with Ctrl-C. Only this preview directory is served, on loopback.

Select any phase in the left sidebar or play a hands-free sequence. Change the
background, opacity, blur, edge highlight, shadow, radius, spacing, width and text
appearance in the right sidebar. Try light and dark backdrops and long sample
dictations. Settings save automatically to this browser's local storage; Export
design downloads a JSON file for implementing the selected appearance in AppKit.
Edits to HTML/CSS/JS files appear on browser refresh. There is no build step.

The baseline follows the previous frosted overlay: 220–460 point width,
14 point corners, 16/12 point horizontal/vertical padding, 14 point medium system
type, waveform/lock glyph, and dim unconfirmed words. Startup is invisible;
hands-free uses a lock icon without an instruction line. The browser's background blur, shadows and glyphs approximate AppKit's
dark `NSVisualEffectView` HUD material and SF Symbols; they are not pixel-identical.
The preview caps long text with scrolling to keep controls usable. Native Mimi's
panel instead grows up to its screen-height limit.

This is a design sandbox, not a replacement renderer or a live connection to
Mimi. Exported values are not automatically applied to the native app. No speech
models, microphone, Accessibility grant, third-party assets, package installation
or Swift rebuild are needed. Playback stops when the tab is hidden and does not
loop. Idle server requests do no transcription or audio work.
