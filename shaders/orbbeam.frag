#version 440
// Activity link between two orbs (task a40d7440): one beam per
// scene.links[] row whose sessions are both on the desktop. The item is laid
// from the `from` orb's limb to the `to` orb's limb; a light packet travels in
// the link's direction, and `alpha` fades with the link's age on the client
// clock. Compiled to plugin/shaders/orbbeam.frag.qsb.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float time;    // client clock seconds
    float alpha;   // 1 fresh link .. 0 at the end of the show window
    float lenPx;   // beam length in pixels
    float hPx;     // item height in pixels
    vec4 hueFrom;  // tint of the sending orb
    vec4 hueTo;    // tint of the receiving orb
};

void main() {
    float x = qt_TexCoord0.x;
    float y = (qt_TexCoord0.y - 0.5) * hPx;          // pixels from the axis
    float ends = smoothstep(0.0, 0.08, x) * smoothstep(1.0, 0.92, x);
    float d = abs(y);
    float core = exp(-d * d / 1.1);
    float glow = exp(-d * d / 40.0) * 0.22;
    // Packet: travels from -> to at 140 px/s, with a faint follower.
    float pos = fract(time * 140.0 / max(lenPx, 1.0));
    float along = (x - pos) * lenPx;
    float packet = exp(-along * along / 220.0) * exp(-d * d / 6.0) * 1.6;
    float pos2 = fract(pos + 0.5);
    float along2 = (x - pos2) * lenPx;
    float packet2 = exp(-along2 * along2 / 120.0) * exp(-d * d / 4.0) * 0.5;
    vec3 c = mix(hueFrom.rgb, hueTo.rgb, x);
    float a = (core * 0.55 + glow + packet + packet2) * ends * alpha;
    a = clamp(a, 0.0, 1.0);
    fragColor = vec4(c * a, a) * qt_Opacity;
}
