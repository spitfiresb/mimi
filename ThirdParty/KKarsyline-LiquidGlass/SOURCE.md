# Upstream source

Repository: https://github.com/KKarsyline/liquid-glass
Commit: `a1424c7522e06c96854d9c70be57535c8246670d`
Original file: `Sources/LiquidGlassKit/Shaders/LiquidGlassLens.metal`

`LiquidGlassLens.upstream.metal` is the unmodified reference snapshot.
Mimi's adaptation is in `Sources/Mimi/Shaders/DesktopGlass.metal`: it retains
the edge-band power curve, RGB dispersion, five-tap edge sampling, and rim
highlight calculations. The circular geometry is replaced with a rounded
rectangle; magnification is continuous through its center; the background
comes from a ScreenCaptureKit texture rather than a SwiftUI background image.

The upstream repository contains no license file as of this snapshot. No MIT
or other license is asserted for this source. Upstream example images and
precompiled libraries are not included.
