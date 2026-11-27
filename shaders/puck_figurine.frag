#version 440
// Puck, figurine (task 23a62966): the Puck shown in focus, ported from the orb-lab
// "Puck A" (context 01e8ede7). A raymarched toy with a cosmic glaze, a long droopy nose,
// eyes that follow the glance, lids that blink and the raised finger. Changes from the
// lab: the glaze, stars, arm sway and bob are held (no time uniform: nothing moves unless
// a uniform does), raised brows, and a mouth groove that never frowns. Same uniform block
// as puck_cel.frag (Puck.qml). Compiled to plugin/shaders/puck_figurine.frag.qsb.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float lookX;
    float lookY;
    float blink;
    float raise;
    float mouth;
    float mouthHalf;
    float brow;
    float sizePx;
    vec4 colA;
    vec4 colB;
    vec4 colC;
};

float hash13(vec3 p3) { p3 = fract(p3 * 0.1031); p3 += dot(p3, p3.zyx + 31.32); return fract((p3.x + p3.y) * p3.z); }
vec3 hash33(vec3 p3) { p3 = fract(p3 * vec3(0.1031, 0.1030, 0.0973)); p3 += dot(p3, p3.yxz + 33.33); return fract((p3.xxy + p3.yxx) * p3.zyx); }
float vnoise(vec3 x) {
    vec3 i = floor(x), f = fract(x); f = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix(hash13(i), hash13(i + vec3(1, 0, 0)), f.x), mix(hash13(i + vec3(0, 1, 0)), hash13(i + vec3(1, 1, 0)), f.x), f.y),
               mix(mix(hash13(i + vec3(0, 0, 1)), hash13(i + vec3(1, 0, 1)), f.x), mix(hash13(i + vec3(0, 1, 1)), hash13(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}
float fbm(vec3 p) { float a = 0.5, s = 0.0; for (int i = 0; i < 4; i++) { s += a * vnoise(p); p = p * 2.03 + vec3(1.7, 9.2, 3.1); a *= 0.5; } return s; }
float smin(float a, float b, float k) { float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0); return mix(b, a, h) - k * h * (1.0 - h); }
float sdCap(vec3 p, vec3 a, vec3 b, float r) { vec3 pa = p - a, ba = b - a; float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0); return length(pa - ba * h) - r; }
float sdEll(vec3 p, vec3 r) { float k0 = length(p / r); float k1 = length(p / (r * r)); return k0 * (k0 - 1.0) / k1; }
vec3 rotZ(vec3 p, vec3 c, float a) { p -= c; float s = sin(a), co = cos(a); return vec3(co * p.x - s * p.y, s * p.x + co * p.y, p.z) + c; }

const vec3 EL = vec3(-0.29, 0.30, -0.74), ER = vec3(0.29, 0.30, -0.74);

vec2 mapP(vec3 p) {
    // The head turns toward the glance.
    // (GLSL mat2 is column-major: these rotate the sample point, so the head turns toward +look.)
    float ay = lookX * 0.32, ax = -lookY * 0.18;
    float sy = sin(ay), cy = cos(ay); p.xz = mat2(cy, -sy, sy, cy) * p.xz;
    float sx = sin(ax), cx = cos(ax); p.yz = mat2(cx, -sx, sx, cx) * p.yz;
    float body = sdEll(p, vec3(1.0, 1.08, 0.92));
    // Mouth groove, y = mouth * x^2: corners up.
    vec2 m = p.xy - vec2(0.0, -0.40);
    float fx = clamp(m.x, -mouthHalf - 0.03, mouthHalf + 0.03);
    float d2 = length(vec2(m.x - fx, m.y - mouth * fx * fx)) * 0.9;
    body = max(body, -max(d2 - 0.03, p.z + 0.55));
    // Brow ridges, raised.
    float bl = 0.05 * brow;
    float brows = min(sdCap(p, EL + vec3(-0.15, 0.27 + bl, 0.02), EL + vec3(0.13, 0.33 + bl, 0.0), 0.035),
                      sdCap(p, ER + vec3(0.15, 0.27 + bl, 0.02), ER + vec3(-0.13, 0.33 + bl, 0.0), 0.035));
    body = smin(body, brows, 0.03);
    // Nose: long, droopy.
    float nose = sdCap(p, vec3(0.0, 0.36, -0.84), vec3(0.0, -0.02, -1.06), 0.075);
    nose = smin(nose, length(p - vec3(0.0, -0.03, -1.04)) - 0.095, 0.06);
    float d = smin(body, nose, 0.06);
    // Right arm and the raised finger: raise 1 points it straight up, lower values tip it out.
    vec3 S = vec3(0.82, 0.28, 0.0);
    float ang = -(1.0 - raise) * 0.9;
    vec3 H = rotZ(vec3(1.08, 1.28, 0.0), S, ang);
    float arm = sdCap(p, S, H, 0.085);
    vec3 fp = rotZ(p, H, -ang);
    float hand = length((fp - H) / vec3(1.1, 1.0, 1.0)) - 0.15;
    float fing = sdCap(fp, H + vec3(-0.02, 0.08, -0.02), H + vec3(-0.02, 0.42, -0.02), 0.048);
    float thumb = sdCap(fp, H + vec3(-0.10, -0.02, -0.11), H + vec3(0.04, 0.01, -0.14), 0.045);
    float knuck = sdCap(fp, H + vec3(-0.06, 0.02, -0.06), H + vec3(0.08, 0.0, -0.07), 0.075);
    hand = smin(hand, knuck, 0.04);
    d = smin(d, arm, 0.07);
    d = smin(d, smin(hand, min(fing, thumb), 0.03), 0.05);
    // Hanging arm.
    vec3 S2 = vec3(-0.84, 0.02, 0.0), H2 = vec3(-1.02, -0.78, -0.04);
    d = smin(d, sdCap(p, S2, H2, 0.082), 0.07);
    d = smin(d, length(p - H2 - vec3(0.0, -0.08, -0.02)) - 0.12, 0.04);
    // Legs and feet.
    float lg = min(sdCap(p, vec3(-0.32, -0.9, 0.0), vec3(-0.34, -1.62, 0.0), 0.1), sdCap(p, vec3(0.32, -0.9, 0.0), vec3(0.34, -1.62, 0.0), 0.1));
    float ft = min(sdEll(p - vec3(-0.36, -1.7, -0.07), vec3(0.16, 0.08, 0.21)), sdEll(p - vec3(0.36, -1.7, -0.07), vec3(0.16, 0.08, 0.21)));
    d = smin(d, smin(lg, ft, 0.06), 0.06);
    vec2 res = vec2(d, 1.0);
    // Eyes and lids.
    float e = min(length(p - EL) - 0.2, length(p - ER) - 0.2);
    if (e < res.x) res = vec2(e, 2.0);
    float lidP = 0.21 - blink * 0.44;
    float lid = min(max(length(p - EL) - 0.215, -(p.y - EL.y - lidP)), max(length(p - ER) - 0.215, -(p.y - ER.y - lidP)));
    if (lid < res.x) res = vec2(lid, 1.0);
    return res;
}

vec3 studio(vec3 d) { return vec3(0.02, 0.02, 0.03) + vec3(0.9, 0.92, 1.0) * smoothstep(0.3, 0.95, d.y) * 1.2 + vec3(1.0, 0.85, 0.7) * smoothstep(0.6, 0.98, d.x) * 0.6; }

void main() {
    vec2 p = (qt_TexCoord0 - 0.5) * vec2(2.5, -2.5);
    vec2 cp = p * 2.05;
    float sh = exp(-pow(length((cp - vec2(0.0, -1.79)) * vec2(1.0, 5.0)), 2.0) * 1.6) * 0.55;
    if (abs(cp.x) > 1.75 || cp.y > 2.15 || cp.y < -2.05) { fragColor = vec4(0.0, 0.0, 0.0, sh) * qt_Opacity; return; }
    vec3 ro = vec3(0.0, 0.0, -7.0);
    vec3 rd = normalize(vec3(cp, 0.0) - ro);
    float t = 4.5; vec2 hm = vec2(0.0); bool hit = false;
    for (int i = 0; i < 96; i++) { hm = mapP(ro + rd * t); if (hm.x < 0.001) { hit = true; break; } t += hm.x * 0.9; if (t > 9.5) break; }
    if (!hit) { fragColor = vec4(0.0, 0.0, 0.0, sh) * qt_Opacity; return; }
    vec3 x = ro + rd * t; const vec2 k = vec2(1, -1); float ep = 0.002;
    vec3 N = normalize(k.xyy * mapP(x + k.xyy * ep).x + k.yyx * mapP(x + k.yyx * ep).x + k.yxy * mapP(x + k.yxy * ep).x + k.xxx * mapP(x + k.xxx * ep).x);
    vec3 L = normalize(vec3(-0.5, 0.75, -0.65));
    float wrap = max((dot(N, L) + 0.4) / 1.4, 0.0);
    vec3 R = reflect(rd, N);
    float fr = 0.04 + 0.96 * pow(1.0 - max(dot(-rd, N), 0.0), 5.0);
    vec3 col;
    if (hm.y == 2.0) {
        // Eyeball: the pupil follows the glance.
        vec3 g = normalize(vec3(lookX * 0.55, lookY * 0.45, -1.0));
        float pd = dot(N, g);
        float pup = smoothstep(0.90, 0.915, pd), iris = smoothstep(0.86, 0.875, pd);
        col = vec3(0.93, 0.93, 0.95) * (0.25 + 0.85 * wrap);
        col = mix(col, vec3(0.08, 0.07, 0.09), iris * 0.35);
        col = mix(col, vec3(0.01), pup);
        col += studio(R) * fr * 1.2 + vec3(1.0) * pow(max(dot(R, L), 0.0), 90.0) * 1.5;
    } else {
        vec3 q = x * 1.3;
        float n1 = fbm(q * 1.4), n2 = fbm(q * 3.1 - 3.0);
        vec3 base = mix(colA.rgb, colB.rgb, smoothstep(0.3, 0.75, n1));
        base += colC.rgb * pow(smoothstep(0.42, 0.85, n2), 2.0) * 1.4;
        base += vec3(1.0, 0.55, 0.85) * pow(smoothstep(0.55, 0.95, fbm(q * 5.0 + 7.0)), 3.0) * 0.6;
        vec3 cell = floor(q * 30.0);
        float st = step(0.93, hash13(cell));
        float sd = length(fract(q * 26.0) - 0.5 - 0.3 * (hash33(cell) - 0.5));
        vec3 stars = vec3(1.0, 0.95, 0.9) * st * smoothstep(0.12, 0.0, sd) * (0.6 + 0.4 * hash13(cell + 3.0)) * 2.0;
        col = base * (0.18 + wrap) + stars + studio(R) * fr * 0.9 + vec3(1.0) * pow(max(dot(R, L), 0.0), 60.0) * 0.7
            + colC.rgb * pow(1.0 - max(dot(-rd, N), 0.0), 3.0) * 0.35;
    }
    col = col / (1.0 + col * 0.12);
    fragColor = vec4(col, 1.0) * qt_Opacity;
}
