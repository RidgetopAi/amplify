#version 440
// Current river water and terrain (direction c755578f). Compiled to
// plugin/shaders/river.frag.qsb by tools/build-shaders.sh. River.qml renders it
// into a half-resolution layer. Its only motion is phase, which River.qml
// advances by the flow the scene model reports (recent task activity). The curve matches centerY/halfWidth in
// plugin/river/river.js; keep the two in sync.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float phase;   // design px the current has travelled (advected by flow)
    float light;   // 0..1, from live sessions
    float flow;    // 0..1, from recent task activity
    vec2 size;     // design size (1080 * aspect, 1080)
    vec4 g0;       // gate x: draft, ready, claimed, verifying
    vec4 g1;       // gate x: evidence, merged, trunk, unused
};

float h21(vec2 p) { p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
float n2(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(h21(i), h21(i + vec2(1, 0)), f.x), mix(h21(i + vec2(0, 1)), h21(i + vec2(1, 1)), f.x), f.y);
}
float fbm(vec2 p) {
    float s = 0.0, a = 0.5;
    for (int i = 0; i < 3; i++) { s += a * n2(p); p = p * 2.02 + vec2(1.7, 9.2); a *= 0.5; }
    return s;
}
float ry(float x) { float u = x / size.x; return 548.0 + 46.0 * sin(u * 5.568 + 0.4) + 22.0 * sin(u * 13.632 + 1.7); }
float rw(float x) { float u = x / size.x; return 74.0 + 18.0 * sin(u * 7.68 + 2.0); }

// Stage hue along the river, blended across each gate (colours = river.js COLORS).
vec3 stageCol(float x) {
    vec3 c = vec3(0.42, 0.47, 0.55);
    c = mix(c, vec3(0.50, 0.65, 0.85), smoothstep(g0.y - 80.0, g0.y + 80.0, x));
    c = mix(c, vec3(0.57, 0.62, 0.97), smoothstep(g0.z - 80.0, g0.z + 80.0, x));
    c = mix(c, vec3(0.72, 0.63, 0.96), smoothstep(g0.w - 80.0, g0.w + 80.0, x));
    c = mix(c, vec3(0.91, 0.77, 0.49), smoothstep(g1.x - 80.0, g1.x + 80.0, x));
    c = mix(c, vec3(0.95, 0.90, 0.82), smoothstep(g1.y - 80.0, g1.y + 80.0, x));
    c = mix(c, vec3(0.97, 0.95, 0.91), smoothstep(g1.z - 60.0, g1.z + 60.0, x));
    return c;
}

void main() {
    vec2 p = qt_TexCoord0 * size;
    vec3 col = mix(vec3(0.034, 0.046, 0.064), vec3(0.016, 0.022, 0.030), p.y / size.y);
    col += vec3(0.025, 0.03, 0.05) * exp(-pow((p.y - ry(p.x)) / 300.0, 2.0));

    // Terrain contours are still: only data moves on this layer.
    float h = fbm(p * 0.0019);
    float cl = abs(fract(h * 12.0) - 0.5);
    col += vec3(0.55, 0.60, 0.72) * (1.0 - smoothstep(0.0, 0.045, cl)) * 0.035;

    // The current: streaks advected by phase, brighter with light, faster with flow.
    float yc = ry(p.x), w = rw(p.x);
    float d = (p.y - yc) / w, ad = abs(d);
    vec3 sc = stageCol(p.x);
    float inside = smoothstep(1.03, 0.93, ad);
    float u = p.x - phase;
    float warp = fbm(vec2(u * 0.0045, d * 1.4 + phase * 0.0004));
    float s1 = n2(vec2(u * 0.011, d * 5.0 + warp * 2.6));
    float s2 = n2(vec2(u * 0.026 + 3.0, d * 12.0 + warp * 3.4));
    float streak = pow(s1, 3.0) * 1.25 + pow(s2, 5.0) * (0.7 + 0.6 * flow);
    float depth = 1.0 - ad * ad;
    vec3 water = vec3(0.030, 0.052, 0.088) * (0.55 + 0.7 * depth) + sc * streak * 0.24 * light * (0.3 + depth);
    water += sc * 0.085 * light * exp(-d * d * 3.2);
    float bank = exp(-pow((ad - 1.0) * 13.0, 2.0));
    col = mix(col, water, inside);
    col += sc * bank * 0.17 * light;
    col += sc * 0.045 * light * exp(-max(ad - 1.0, 0.0) * 2.2) * (1.0 - inside);

    // The mouth opens into the trunk: a soft widening glow past the last gate.
    float mouth = smoothstep(g1.z - 40.0, size.x, p.x);
    col += vec3(0.97, 0.95, 0.91) * mouth * exp(-pow((p.y - yc) / (w * 2.4), 2.0)) * 0.05 * light;

    vec2 vv = p / size - 0.5;
    col *= 1.0 - 0.55 * dot(vv, vv);
    fragColor = vec4(col, 1.0) * qt_Opacity;
}
