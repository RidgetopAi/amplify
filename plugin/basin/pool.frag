#version 440
// Needs-you basin pool: a calm warm pool of light under the basin rows.
// Warm is reserved for human-needed items (decision 23973614), so this is the
// only warm field on the desktop. Compile with:
//   qsb --glsl "100es,120,150,300es" --hlsl 50 --msl 12 -o plugin/basin/pool.frag.qsb plugin/basin/pool.frag

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float time;      // seconds, client clock
    float fill;      // 0 empty .. 1 several items waiting
    float alarm;     // 0 .. 1 when the most urgent item is a lost session
    float aspect;    // width / height
    vec4 warm;       // basin coral
    vec4 lost;       // muted red for lost sessions
};

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}

void main() {
    // Ellipse centred low-right, as if light pools where the pointer rests.
    // The ellipse stays inside the quad so its rim never meets a hard edge.
    vec2 p = (qt_TexCoord0 - vec2(0.52, 0.56)) / vec2(0.44, 0.40);
    float r = length(p);
    float pool = smoothstep(1.0, 0.35, r);

    // Slow concentric ripples, warped so they never read as a radar sweep.
    float w = noise(p * vec2(2.2 * aspect, 2.2) + vec2(time * 0.05, -time * 0.04));
    float rip = 0.5 + 0.5 * sin(r * 26.0 - time * 0.55 + w * 1.8);
    rip *= rip;
    float caustic = pow(noise(p * vec2(7.0 * aspect, 7.0) + vec2(time * 0.11, time * 0.07) + w * 1.5), 4.0);

    vec3 tint = mix(warm.rgb, lost.rgb, alarm * 0.6);
    float level = 0.18 + 0.82 * fill;
    vec3 col = tint * pool * level * (0.09 + 0.05 * rip + 0.12 * caustic);
    // Faint meniscus where the pool meets the desktop.
    col += tint * exp(-pow((r - 0.92) * 14.0, 2.0)) * 0.05 * level;
    float a = clamp(max(col.r, max(col.g, col.b)) * 1.6, 0.0, 1.0);
    fragColor = vec4(col, a) * qt_Opacity;
}
