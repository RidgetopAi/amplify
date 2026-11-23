#version 440
// Lease vessel (task a40d7440): a glass vial hung on a tether from the orb
// that holds a claim. Liquid level = lease left, (claimExpiresAt - now) /
// lease length, re-read on the client clock each tick; colour = the task's
// lane. An expired or released claim leaves an empty vial on a dashed tether.
// Compiled to plugin/shaders/orbvessel.frag.qsb.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float time;    // client clock seconds (meniscus motion only)
    float level;   // lease left 0..1
    float held;    // 1 = claim live, 0 = expired
    float wPx;     // item width in pixels
    float hPx;     // item height in pixels
    float tether;  // tether length in pixels at the top of the item
    vec4 liquid;   // lane colour of the held task
    vec4 glass;    // holder's role tint
};

float sdBox(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void main() {
    vec2 p = vec2(qt_TexCoord0.x - 0.5, qt_TexCoord0.y) * vec2(wPx, hPx);  // px, y down from top
    vec3 col = vec3(0.0);
    float al = 0.0;

    // Tether from the orb's knot to the vial's neck.
    float neckTop = tether;
    if (p.y < neckTop) {
        float dash = held > 0.5 ? 1.0 : step(0.5, fract(p.y / 5.0));
        float line = exp(-p.x * p.x / 0.5) * dash;
        col += glass.rgb * line * 0.7;
        al = max(al, line * 0.7);
    }

    // Vial: a short neck and a rounded body.
    float bodyTop = neckTop + hPx * 0.12;
    float bw = wPx * 0.36, bh = (hPx - bodyTop - 2.0) * 0.5;
    vec2 bc = vec2(0.0, bodyTop + bh);
    float sd = min(sdBox(p - bc, vec2(bw, bh), bw * 0.9),
                   sdBox(p - vec2(0.0, neckTop + (bodyTop - neckTop) * 0.5), vec2(bw * 0.42, (bodyTop - neckTop) * 0.5 + 1.0), 1.5));
    float dash = held > 0.5 ? 1.0 : step(0.45, fract(atan(p.y - bc.y, p.x) * 3.0));
    float rim = exp(-sd * sd / 0.7) * dash;
    // Liquid fills the body from the bottom up to the lease left.
    float inner = bh * 2.0 - 3.0;
    float surface = bc.y + bh - 1.5 - inner * clamp(level, 0.0, 1.0);
    float wave = sin(p.x * 0.35 + time * 1.7) * 0.9 * step(0.02, level);
    float inside = smoothstep(0.5, -1.0, sd + 1.5);
    float wet = inside * smoothstep(surface + wave - 0.6, surface + wave + 0.6, p.y) * held;
    float depth = clamp((p.y - surface) / max(inner, 1.0), 0.0, 1.0);
    vec3 liq = liquid.rgb * (0.55 + 0.45 * (1.0 - depth));
    float menis = exp(-pow(p.y - surface - wave, 2.0) / 0.8) * inside * held * step(0.02, level);
    // Glass: faint body, brighter rim, one highlight down the left side.
    float sheen = inside * exp(-pow(p.x + bw * 0.55, 2.0) / 2.0) * 0.25;
    col += glass.rgb * (rim * 0.55 + inside * 0.04 + sheen);
    col = mix(col, liq, wet * 0.92) + liquid.rgb * menis * 0.9;
    al = max(al, max(rim * 0.6, max(inside * 0.08, wet * 0.9)));
    al = max(al, menis);
    al = clamp(al, 0.0, 1.0);
    fragColor = vec4(col * 1.0, al) * qt_Opacity;
}
