#version 440
// Puck, cel (task 23a62966): the desktop-size Puck as a die-cut sticker, ported from the
// orb-lab "Puck B" (context 01e8ede7). An inked marble with limbs, a paper border that
// reads on any wallpaper, and a face decal that rolls over the ball toward the pointer.
// Changes from the lab: no line boil, bob or twinkle (nothing moves unless a uniform
// does, so an idle Puck draws no frames), every edge antialiased to one pixel (the
// coordinator asked for a smooth outline), raised brows and a mouth that never frowns.
// Uniforms come from Puck.qml (puck.js maps them). Compiled to plugin/shaders/puck_cel.frag.qsb.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float lookX;     // glance, -1..1 (right)
    float lookY;     // glance, -1..1 (up)
    float blink;     // 0 open .. 1 shut
    float raise;     // right arm: 0.55 half raised .. 1 finger up
    float mouth;     // mouth bend, y = mouth * x^2 (> 0: corners up)
    float mouthHalf; // mouth half width, ball units
    float brow;      // brow lift, 0..1
    float sizePx;    // item size in pixels (antialiasing width)
    vec4 colA;       // light glaze
    vec4 colB;       // dark glaze
    vec4 colC;       // rim glow
};

float hash12(vec2 p) { vec3 p3 = fract(vec3(p.xyx) * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return fract((p3.x + p3.y) * p3.z); }
float sdSeg(vec2 p, vec2 a, vec2 b) { vec2 pa = p - a, ba = b - a; float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0); return length(pa - ba * h); }
float sdBez(vec2 p, vec2 a, vec2 b, vec2 c) {
    float d = 1e5; vec2 pr = a;
    for (int i = 1; i <= 12; i++) { float t = float(i) / 12.0; vec2 q = mix(mix(a, b, t), mix(b, c, t), t); d = min(d, sdSeg(p, pr, q)); pr = q; }
    return d;
}

float AA;   // one pixel in ball units
float cov(float d) { return clamp(0.5 - d / AA, 0.0, 1.0); }
vec4 over(vec4 acc, vec3 c, float a) { return vec4(c * a, a) + acc * (1.0 - a); }

void main() {
    vec2 p = (qt_TexCoord0 - 0.5) * vec2(2.6, -2.6);   // y up
    vec2 bp = p * 2.0 + vec2(0.0, 0.05);               // ball radius 1
    AA = 5.2 / max(sizePx, 1.0);
    const float INK = 0.05, PAPER = 0.085;
    vec3 inkC = vec3(0.06, 0.04, 0.09), paper = vec3(0.96, 0.94, 0.89);

    // Limbs: two legs with feet, the left arm hanging, the right arm raised with its finger.
    float dLeg = 1e5;
    for (int i = 0; i < 2; i++) {
        float s = i == 0 ? -1.0 : 1.0;
        dLeg = min(dLeg, min(sdSeg(bp, vec2(s * 0.33, -0.85), vec2(s * 0.35, -1.60)) - 0.09,
                             (length((bp - vec2(s * 0.43, -1.68)) * vec2(1.0, 1.9)) - 0.17) / 1.9));
    }
    float dArmL = min(sdBez(bp, vec2(-0.88, 0.05), vec2(-1.14, -0.35), vec2(-1.06, -0.78)) - 0.085, length(bp - vec2(-1.06, -0.88)) - 0.13);
    vec2 S = vec2(0.86, 0.28);
    vec2 Hd = mix(vec2(1.22, -0.30), vec2(1.14, 1.22), raise);
    vec2 C = mix(vec2(1.30, 0.0), vec2(1.30, 0.62), raise);
    vec2 fd = vec2(0.0, 1.0);
    float dArmR = min(min(sdBez(bp, S, C, Hd) - 0.09, length((bp - Hd) * vec2(0.92, 1.0)) - 0.16),
                      min(sdSeg(bp, Hd + fd * 0.06, Hd + fd * (0.20 + 0.26 * raise)) - 0.055,
                          sdSeg(bp, Hd + vec2(-0.09, -0.02), Hd + vec2(0.07, -0.06)) - 0.05));
    float dBody = length(bp) - 1.0;
    float dLimb = min(dLeg, min(dArmL, dArmR));
    float dAll = min(dLimb, dBody);

    vec4 acc = vec4(0.0);
    // Ground shadow, then the sticker's soft drop shadow and paper border, then the ink line.
    acc = over(acc, vec3(0.0), smoothstep(0.55, 0.0, length((bp - vec2(0.0, -1.86)) * vec2(1.0, 5.0))) * 0.35);
    acc = over(acc, vec3(0.0), smoothstep(0.12, 0.0, dAll - INK - PAPER + 0.03) * 0.35);
    acc = over(acc, paper, cov(dAll - INK - PAPER));
    acc = over(acc, inkC, cov(dAll - INK));
    acc = over(acc, mix(colB.rgb, colA.rgb, 0.45), cov(dLimb));
    acc = over(acc, inkC, cov(dBody - INK));

    // The ball: three cel bands, a rim glow, a few fixed sparkles and the highlight.
    float r = length(bp);
    vec3 n = vec3(bp, -sqrt(max(1.0 - r * r, 0.0)));
    float dl = dot(n, normalize(vec3(-0.55, 0.65, -0.55)));
    float band = mix(0.34, mix(0.62, 1.0, smoothstep(0.54, 0.56, dl)), smoothstep(0.04, 0.06, dl));
    vec3 col = mix(colB.rgb, colA.rgb, band);
    col = mix(col, colC.rgb, smoothstep(0.75, 1.0, r) * 0.30);
    vec2 sc = floor(bp * 9.0);
    float sd = length(fract(bp * 9.0) - 0.5 - (vec2(hash12(sc), hash12(sc + 2.0)) - 0.5) * 0.5);
    col += vec3(1.0) * step(0.86, hash12(sc + 11.0)) * smoothstep(0.09, 0.0, sd) * (0.4 + 0.4 * hash12(sc + 5.0));
    col = mix(col, vec3(1.0), smoothstep(0.16, 0.10, length((bp - vec2(-0.45, 0.50)) * vec2(1.0, 1.5))) * 0.9);

    // Face decal on the ball, centred where the glance points; it foreshortens toward the rim.
    vec3 f = normalize(vec3(lookX * 0.55, lookY * 0.45 + 0.05, -1.0));
    vec3 t1 = normalize(cross(vec3(0.0, 1.0, 0.0), f)), t2 = cross(f, t1);
    float fz = dot(n, f);
    if (fz > 0.12 && r < 1.0) {
        vec2 u = vec2(-dot(n, t1), dot(n, t2));
        float fade = smoothstep(0.12, 0.32, fz);
        float ua = AA * 1.2;   // the decal is foreshortened: a slightly wider edge
        for (int i = 0; i < 2; i++) {
            float s = i == 0 ? -1.0 : 1.0;
            vec2 e = u - vec2(s * 0.28, 0.22);
            float eh = 0.19 * (1.0 - blink * 0.93) + 0.005;
            float de = (length(e / vec2(0.165, eh)) - 1.0) * min(0.165, eh);
            col = mix(col, inkC, clamp(0.5 - (de - INK * 0.8) / ua, 0.0, 1.0) * fade);
            col = mix(col, vec3(0.98, 0.97, 0.94), clamp(0.5 - de / ua, 0.0, 1.0) * fade);
            vec2 pc = e - vec2(lookX, lookY) * vec2(0.07, 0.06);
            float inEye = clamp(0.5 - de / ua, 0.0, 1.0);
            col = mix(col, vec3(0.03), clamp(0.5 - (length(pc + vec2(0.0, 0.01)) - 0.075 * (1.0 - blink)) / ua, 0.0, 1.0) * inEye * fade);
            col = mix(col, vec3(1.0), clamp(0.5 - (length(pc - vec2(-0.03, 0.03)) - 0.024) / ua, 0.0, 1.0) * inEye * (1.0 - blink) * fade);
            // Brows, raised and arched (the curious look); they ride up with `brow`.
            vec2 bo = vec2(0.0, 0.47 + 0.05 * brow);
            float db = sdBez(u, vec2(s * 0.13, bo.y - 0.04), vec2(s * 0.27, bo.y + 0.05 * brow + 0.02), vec2(s * 0.42, bo.y - 0.02)) - 0.022;
            col = mix(col, inkC, clamp(0.5 - db / ua, 0.0, 1.0) * fade);
        }
        // Nose: long and droopy, inked.
        float dn = sdSeg(u, vec2(0.0, 0.22), vec2(0.0, -0.12)) - mix(0.045, 0.085, smoothstep(0.22, -0.12, u.y));
        col = mix(col, inkC, clamp(0.5 - (dn - INK * 0.8) / ua, 0.0, 1.0) * fade);
        col = mix(col, mix(colB.rgb, colA.rgb, 0.8 + 0.2 * step(0.0, u.x + 0.03)), clamp(0.5 - dn / ua, 0.0, 1.0) * fade);
        // Mouth: y = mouth * x^2 under the nose; mouth > 0 turns the corners up.
        float fx = clamp(u.x, -mouthHalf, mouthHalf);
        float dm = length(vec2(u.x - fx, u.y - (-0.36 + mouth * fx * fx))) - 0.012;
        col = mix(col, inkC, clamp(0.5 - (dm - INK * 0.6) / ua, 0.0, 1.0) * fade);
    }
    acc = over(acc, col, cov(dBody));
    fragColor = acc * qt_Opacity;
}
