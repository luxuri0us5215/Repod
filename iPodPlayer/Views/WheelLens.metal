#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

/// 3.1.8 — the click wheel's touch indicator: a refractive arc.
///
/// 3.1.5 swelled a round spot of glass under the thumb. The wheel is a ring, so the
/// lens now has the ring's shape: it fills the whole band, from the centre key's
/// edge out to the rim, and runs along the ring as an arc centred on the thumb's
/// angle. It is worked out in polar coordinates around the disc centre:
///
///   · along the ring, pixels are sampled from an angle nearer the thumb, so what
///     the arc covers is stretched along the curve (a label passing through bends
///     round with the wheel);
///   · across the ring, pixels are sampled from a radius nearer the ring's
///     mid-line, like a curved glass rod laid in the track.
///
/// Both weights reach zero *with zero slope* at their edges — `(1 − v²)²` at the
/// arc's two ends, `(1 − u⁴)²` (flat over most of the band) at the inner and outer
/// edges — so there is no rim, no outline and no seam: the arc fades into the disc.
/// The arc also opens out from the thumb as it appears (its length follows
/// `strength`), and keeps the faint dispersion and the light gathered along its
/// middle that made the round lens read as glass.
///
/// `strength` 0 is the identity; 1 is the full arc.
[[ stitchable ]] half4 wheelArcRefraction(float2 position, SwiftUI::Layer layer,
                                          float2 center, float innerRadius, float outerRadius,
                                          float angle, float halfArc, float strength) {
    if (strength <= 0.0 || outerRadius <= innerRadius || halfArc <= 0.0) {
        return layer.sample(position);
    }

    float2 d = position - center;
    float r = length(d);
    float midR = 0.5 * (innerRadius + outerRadius);
    float halfW = 0.5 * (outerRadius - innerRadius);
    float u = (r - midR) / halfW;                     // −1 inner edge … 0 mid-line … 1 rim
    if (abs(u) >= 1.0) {
        return layer.sample(position);
    }

    float amount = clamp(strength, 0.0, 1.0);
    float arc = halfArc * (0.55 + 0.45 * amount);     // opens out from the thumb
    float theta = atan2(d.y, d.x);
    float dTheta = theta - angle;
    dTheta -= 2.0 * M_PI_F * rint(dTheta / (2.0 * M_PI_F)); // −π … π
    float v = dTheta / arc;                           // −1 … 0 at the thumb … 1
    if (abs(v) >= 1.0) {
        return layer.sample(position);
    }

    float u4 = u * u * u * u;
    float across = (1.0 - u4) * (1.0 - u4);           // flat across the band, 0 at both edges
    float along = 1.0 - v * v;
    along *= along;                                   // 1 at the thumb → 0 at the ends
    float bump = across * along;

    // Magnification: along the curve more than across the narrow band.
    float kAlong = 0.30 * amount * bump;
    float kAcross = 0.20 * amount * bump;

    // One sample point per channel; red bends a little less than blue.
    float2 p[3];
    float spread[3] = { 0.94, 1.0, 1.06 };
    for (int i = 0; i < 3; i++) {
        float th = angle + dTheta * (1.0 - kAlong * spread[i]);
        float rr = midR + (r - midR) * (1.0 - kAcross * spread[i]);
        p[i] = center + float2(cos(th), sin(th)) * rr;
    }
    half4 cr = layer.sample(p[0]);
    half4 cg = layer.sample(p[1]);
    half4 cb = layer.sample(p[2]);
    half4 c = half4(cr.r, cg.g, cb.b, cg.a);

    // Light: carried along the whole arc (not pooled in a spot under the thumb), a
    // touch lost on its shoulders, where the stretch turns into compression. Both
    // fade to nothing at every edge.
    float gather = 0.045 * amount * bump;
    float shoulder = 0.05 * amount * (4.0 * v * v * along) * across;
    c.rgb = c.rgb * half(1.0 - shoulder) + half3(half(gather)) * c.a;

    return c;
}
