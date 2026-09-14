# Native glass experiment

This builds the production `OverlayPanel` in a separate app. The preview does
not include Mimi's screen-capture renderer, microphone, or speech engines.
The dictation app now uses `NativeGlassTuner` for the reviewed lens profile.
This preview disables that controller and retains the comparison controls and
live diagnostic instrumentation used during the experiment.

## Reproduce the reference

```sh
bash scripts/preview-native-glass.sh --grid
```

The reference lens is 350×52 points, with hidden foreground text, radius 22,
inner-refraction height 26, amount 15.6, refraction opacity 1, zero blur bands,
and neutral face colors. Both comparison grids are drawn in a separate window
behind the overlays. The left outline is plain transparency.

## Test background updates

```sh
bash scripts/preview-native-glass.sh --live-grid
```

The grid stays still for three seconds, then changes its numbers every second
and scrolls continuously. The lens stays fixed. The menu can pause/resume it.
Reduce Motion suppresses smooth movement, while the number changes remain.

Watch whether numbers inside the right lens continue to follow the source,
and whether their distortion remains consistent. Startup-only screenshots or
matching model filter values cannot establish this.

Use **Hide Grid (Keep Lens Unchanged)** for an exact comparison over other
applications. This preserves size, position, filters, and hidden text.
**Show / Hide Text (Keep Lens Size)** changes only foreground visibility.
The ordinary short/long text actions intentionally restore content-driven size.

## Diagnostics

The preview writes `mimi-glass-live.txt` and `mimi-glass-diagnostics.txt` under
`NSTemporaryDirectory()`. The live file retains the last 90 samples, including
source ticks, layer dimensions, and model versus presentation filter values.
No screen images or desktop content are read or logged.

The initial filter-object replacement approach could leave the presentation
layer on the native defaults even while model values matched the requested
tuning. The current experiment sets named filter inputs through CALayer key
paths, disables implicit animations, and flushes changed transactions.
Presentation values now match during the moving-grid test; optical appearance
and behavior across Space transitions still require visual review.
