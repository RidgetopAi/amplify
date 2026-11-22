#version 440
// Placeholder Meridian orb (Direction C "Current"). Compiled to
// plugin/shaders/orb.frag.qsb by tools/build-shaders.sh.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float time;     // seconds, client clock
    float energy;   // 0 idle .. 1 busy
    vec4 core;      // theme accent
    vec4 halo;      // theme foreground / warm channel
};

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

float noise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x),
               mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}

void main() {
    vec2 p = qt_TexCoord0 * 2.0 - 1.0;          // -1..1
    float r = length(p);

    // Body: a lit sphere of radius 0.5 with drifting surface noise.
    float R = 0.5;
    float z = sqrt(max(0.0, 1.0 - (r * r) / (R * R)));      // sphere depth
    // Seamless surface noise: sample by position, not angle (atan wraps at ±pi).
    vec2 q = p / R * 2.5;
    float n = noise(q + vec2(time * 0.2, z * 2.0 - time * (0.4 + energy)));
    float disc = smoothstep(R + 0.01, R - 0.01, r);
    float light = 0.35 + 0.65 * clamp(dot(normalize(vec3(p / R, z)), normalize(vec3(-0.4, -0.5, 0.75))), 0.0, 1.0);
    float body = disc * light * (0.7 + 0.3 * n);

    // Meridian: a slowly rotating great circle drawn on the sphere.
    float ang = time * 0.5;
    float m = abs((p.x * cos(ang) + p.y * sin(ang)) / R);
    float meridian = smoothstep(0.05, 0.0, m) * disc * z;

    // Pulse ring expanding outward from the limb; faster when busy.
    float ringR = R + fract(time * (0.25 + 0.5 * energy)) * 0.45;
    float ring = smoothstep(0.03, 0.0, abs(r - ringR)) * (1.0 - (ringR - R) / 0.45);

    // Halo falloff to the edge of the quad.
    float glow = exp(-r * r * 5.0) * 0.55;

    vec3 col = core.rgb * (body + glow) + halo.rgb * (meridian * 0.9 + ring * 0.6);
    float alpha = clamp(body + glow + meridian + ring * 0.6, 0.0, 1.0) * smoothstep(1.0, 0.85, r);
    fragColor = vec4(col * alpha, alpha) * qt_Opacity;   // premultiplied
}
