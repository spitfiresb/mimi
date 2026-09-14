// Adapted from KKarsyline/liquid-glass's LiquidGlassLens.metal.
// Exact upstream revision and unmodified reference: ThirdParty/KKarsyline-LiquidGlass.
// Upstream does not specify a license. Do not replace this attribution.
#include <metal_stdlib>
using namespace metal;

struct GlassUniforms {
    float2 size;
    float2 origin;
    float2 captureSize;
    float radius;
    float strength;
    float dispersion;
    float magnify;
    float rimWidth;
    float hasBackdrop;
};

struct GlassVertex { float4 position [[position]]; float2 uv; };

vertex GlassVertex glassVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return {float4(p * float2(2, -2) + float2(-1, 1), 0, 1), p};
}

half4 sampleBackdrop(texture2d<half> image, float2 point, constant GlassUniforms &u) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    return image.sample(linearSampler, (u.origin + point) / u.captureSize);
}

half4 sampleEdge(texture2d<half> image, float2 p, float blur, constant GlassUniforms &u) {
    // Original five-tap weights, confined to the edge so the center stays clear.
    float2 bx(blur, 0), by(0, blur);
    return sampleBackdrop(image, p, u) * 0.52h
        + sampleBackdrop(image, p + bx, u) * 0.12h
        + sampleBackdrop(image, p - bx, u) * 0.12h
        + sampleBackdrop(image, p + by, u) * 0.12h
        + sampleBackdrop(image, p - by, u) * 0.12h;
}

fragment half4 glassFragment(GlassVertex in [[stage_in]],
                             texture2d<half> image [[texture(0)]],
                             constant GlassUniforms &u [[buffer(0)]]) {
    float2 position = in.uv * u.size;
    float2 halfSize = u.size * 0.5;
    float radius = min(u.radius, min(halfSize.x, halfSize.y));
    float2 local = position - halfSize;
    float2 q = abs(local) - (halfSize - radius);
    float sd = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    float coverage = 1.0 - smoothstep(-0.6, 0.6, sd);
    if (coverage <= 0) return half4(0);

    // Extend the upstream circular radial field around a rounded rectangle.
    float2 delta = local - clamp(local, -halfSize + radius, halfSize - radius);
    float dist = length(delta);
    float2 dir = dist > 0.001 ? delta / dist : float2(0);
    float n = clamp(1.0 + sd / max(radius, 1.0), 0.0, 1.0);
    float t = smoothstep(1.0 - u.rimWidth, 1.0, n);
    float band = pow(t, 2.6);
    float edgeBend = u.strength * band;

    // Use uniform center magnification, fading toward the edge. Unlike the
    // orb's radial pull, this remains continuous across a wide pill's center.
    float bulge = 1.0 - n * n;
    float2 magPull = local * (u.magnify / (1.0 + u.magnify)) * bulge;
    float2 baseOffset = -magPull - dir * edgeBend;

    // Preserve the upstream RGB dispersion and its edge-only sampling blur.
    float chroma = u.dispersion * u.strength * 0.16 * band;
    float2 redOff = baseOffset + dir * chroma;
    float2 blueOff = baseOffset - dir * chroma;
    float blur = band * 2.0;
    half3 color;
    half alpha;
    if (u.hasBackdrop > 0.5) {
        color = half3(sampleEdge(image, position + redOff, blur, u).r,
                      sampleEdge(image, position + baseOffset, blur, u).g,
                      sampleEdge(image, position + blueOff, blur, u).b);
        alpha = 1;
    } else {
        // Permission denied / first frame pending: a translucent surface,
        // never a stale screenshot. Dictation does not depend on capture.
        color = half3(0.07, 0.08, 0.10);
        alpha = u.hasBackdrop < -0.5 ? 1.0 : 0.22;
    }
    half rim = half(smoothstep(0.90, 0.98, n) * (1.0 - smoothstep(0.995, 1.0, n)));
    color += rim * half3(0.12, 0.12, 0.11);
    half line = half(smoothstep(-1.1, -0.2, sd) * (1.0 - smoothstep(-0.2, 0.6, sd)));
    color += line * half3(0.24);
    alpha = max(alpha, line * 0.6h);
    return half4(color * alpha * half(coverage), alpha * half(coverage));
}
