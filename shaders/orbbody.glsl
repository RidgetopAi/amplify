// Shared body of the desktop orbs (task a40d7440). Included by
// orb_coord.frag (ROLE 0), orb_worker.frag (ROLE 1) and orb_critic.frag (ROLE 2):
// one compiled program per role, never one program with role branches
// (decision 23973614). Every uniform below comes from the scene model
// (plugin/orbs/orbs.js orbProps); `time` and `angle` only move the surface.
//
// Space: v is the item square mapped to [-E, E] with y up; the orb body has
// radius 1. Output is premultiplied.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float time;    // client clock seconds; surface motion only
    float angle;   // spin phase, advanced at the liveness spin rate
    float sat;     // liveness saturation
    float light;   // liveness light
    float energy;  // write recency, exp(-write age / 10 min)
    float form;    // forming: connect age / 10 min (1 = formed)
    float dorm;    // dormant: hollow shell
    float lost;    // lost: muted red broken ring
    float ended;   // ended: collapse progress toward an ember
    float need;    // lost while holding a live claim: warm needs-you ring
    float fuse;    // heartbeat time left before lost, 0..1; < 0 = never heartbeat
    float pulse;   // last heartbeat age / pulse window; 1 = no pulse
    float seed;    // per-session phase from the session id
    float mono;    // 1 = flat silhouette (shape proof, no colour)
    float px;      // pixels per orb radius, for antialiasing
    vec4 hue;      // role tint (theme-derived, cool)
    vec4 alarm;    // lost ring
    vec4 warm;     // needs-you, reserved for human-needed items
};

const float E = 1.9;
const float TAU = 6.2831853;

float h3(vec3 p) { p = fract(p * 0.3183099 + 0.1); p *= 17.0; return fract(p.x * p.y * p.z * (p.x + p.y + p.z)); }
float n3(vec3 x) {
    vec3 i = floor(x), f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix(h3(i), h3(i + vec3(1, 0, 0)), f.x), mix(h3(i + vec3(0, 1, 0)), h3(i + vec3(1, 1, 0)), f.x), f.y),
               mix(mix(h3(i + vec3(0, 0, 1)), h3(i + vec3(1, 0, 1)), f.x), mix(h3(i + vec3(0, 1, 1)), h3(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}
float fb(vec3 p) { float s = 0.0, a = 0.5; for (int i = 0; i < 3; i++) { s += a * n3(p); p *= 2.07; a *= 0.5; } return s; }
mat3 rY(float a) { float c = cos(a), s = sin(a); return mat3(c, 0.0, -s, 0.0, 1.0, 0.0, s, 0.0, c); }
mat3 rX(float a) { float c = cos(a), s = sin(a); return mat3(1.0, 0.0, 0.0, 0.0, c, s, 0.0, -s, c); }
float band(float d, float k) { return exp(-d * d * k * k); }

void main() {
    vec2 v = vec2(qt_TexCoord0.x * 2.0 - 1.0, 1.0 - qt_TexCoord0.y * 2.0) * E;
    // Ended sessions collapse toward a small ember; everything below works in
    // body space w so the ember keeps its role silhouette in miniature.
    float shrink = mix(1.0, 0.36, ended);
    vec2 w = v / shrink;
    float r = length(w);
    float aa = 1.6 / max(px * shrink, 1.0);
    vec3 hu = hue.rgb;
    vec3 col = vec3(0.0);
    float al = 0.0;

    float spinA = angle + seed * TAU;
    if (r < 1.0 + aa) {
        vec2 vc = r > 1.0 ? w / r : w;
        vec3 n = vec3(vc, sqrt(max(0.0, 1.0 - dot(vc, vc))));
        mat3 R = rX(0.38) * rY(spinA);
        vec3 q = R * n;
        vec3 L = normalize(vec3(-0.5, 0.62, 0.6));
        float dif = max(dot(n, L), 0.0);
        float fres = pow(1.0 - n.z, 2.3);
        float spec = pow(max(dot(reflect(-L, n), vec3(0, 0, 1)), 0.0), 40.0);
        vec3 body;
#if ROLE == 0
        // COORD: a faceted lantern. Facets catch the light as it turns.
        {
            vec3 qf = normalize(floor(q * 2.3) + 0.5);
            vec3 nf = qf * R;
            float fd = max(dot(nf, L), 0.0);
            float g = fb(q * 3.2 + seed * 9.0);
            body = mix(vec3(0.07, 0.08, 0.11), hu, 0.26 + 0.74 * fd) * (0.62 + 0.38 * g);
            body += hu * pow(max(dot(reflect(-L, nf), vec3(0, 0, 1)), 0.0), 18.0) * 0.55;
            vec3 fq = fract(q * 2.3);
            vec3 ed = min(fq, 1.0 - fq);
            body += hu * (1.0 - smoothstep(0.0, 0.05, min(min(ed.x, ed.y), ed.z))) * 0.2;
        }
#elif ROLE == 1
        // WORKER: clear glass around a swirling core; the core brightens with writes.
        {
            float sw = fb(q * 2.4 + vec3(0.0, time * 0.1, seed * 5.0));
            float core = exp(-dot(w, w) * 2.4);
            body = mix(vec3(0.02, 0.04, 0.09), hu, 0.2 + 0.62 * sw) * (0.32 + 0.78 * dif);
            body += hu * core * (0.22 + 0.5 * energy);
            body += hu * band(q.y, 10.0) * 0.32;
        }
#else
        // CRITIC: obsidian with a lens; the iris fibres turn with the spin.
        {
            float g = fb(q * 4.0 + seed * 3.0);
            body = vec3(0.05, 0.045, 0.07) * (0.55 + 0.9 * dif) + hu * g * 0.07;
            float ir = length(w), an = atan(w.y, w.x);
            float iris = smoothstep(0.56, 0.5, ir) * smoothstep(0.17, 0.22, ir);
            float fib = n3(vec3(an * 4.0, ir * 9.0, time * 0.15));
            body += hu * iris * (0.18 + 0.35 * fib);
            body += hu * band(ir - 0.56, 34.0) * 0.9;
            body += hu * band(ir - 0.36, 44.0) * 0.35;
            float bl = abs(fract((an + spinA * 0.5) / TAU * 7.0) - 0.5);
            body *= 1.0 - 0.25 * smoothstep(0.46, 0.5, bl) * step(ir, 0.56);
            body = mix(body, vec3(0.0), smoothstep(0.2, 0.16, ir));
        }
#endif
        // Liveness material.
        float lum = dot(body, vec3(0.299, 0.587, 0.114));
        body = mix(vec3(lum), body, sat) * light;
        body += hu * fres * (0.3 + 0.6 * energy) * light * (1.0 - dorm * 0.6);
        body += vec3(1.0) * spec * 0.32 * light;
        // Dormant: not proven alive, so only the glass shell remains.
        body = mix(body, hu * fres * 0.55 + vec3(0.02, 0.025, 0.035), dorm * 0.85);
        // Forming: just connected, nothing written; fills from the core outward.
        float fm = smoothstep(form * 1.15 - 0.15, form * 1.15, r);
        body = mix(body, hu * fres * 0.5, fm * (1.0 - dorm) * step(form, 0.999));
        // Lost: the light stutters.
        body *= 1.0 - lost * 0.5 * step(0.6, h3(vec3(floor(time * 6.0), seed * 13.0, 1.0)));
        float m = smoothstep(1.0 + aa, 1.0 - aa, r);
        col = body * m;
        al = m * (1.0 - dorm * 0.55);
    }

    // Halo: brighter with recent writes, gone when dormant or ended.
    float hg = r > 1.0 ? exp(-(r - 1.0) * 4.2) : 0.0;
    col += hu * hg * 0.24 * light * (1.0 + energy * 1.4) * (1.0 - dorm * 0.7) * (1.0 - ended);

    // Role silhouettes outside the sphere, so roles read without colour.
    float sil = max(light, 0.3);
#if ROLE == 0
    // Coord: a tilted orbit ring with three beads, passing behind the lantern.
    {
        float ta = -0.3;
        vec2 u = vec2(cos(ta) * w.x - sin(ta) * w.y, sin(ta) * w.x + cos(ta) * w.y);
        float e = length(u / vec2(1.58, 0.40));
        float ring = band(e - 1.0, 30.0);
        float occ = (u.y > 0.0 && r < 1.0) ? 0.0 : 1.0;
        float bd = 0.0;
        for (int i = 0; i < 3; i++) {
            float th = angle * 0.7 + float(i) * 2.094;
            vec2 bp = vec2(1.58 * cos(th), 0.40 * sin(th));
            bd += exp(-dot(u - bp, u - bp) * 800.0) * ((sin(th) > 0.0 && r < 1.0) ? 0.0 : 1.0);
        }
        col = col * (1.0 - ring * occ * 0.6) + hu * (ring * 0.7 + bd * 1.5) * occ * sil;
        al = max(al, (ring + bd) * occ * 0.75);
    }
#elif ROLE == 1
    // Worker: the tether knot the lease vessel hangs from.
    {
        float kn = exp(-dot(w - vec2(0.0, -1.13), w - vec2(0.0, -1.13)) * 600.0);
        col += hu * kn * 0.9 * sil;
        al = max(al, kn * 0.85);
    }
#else
    // Critic: calipers closing on the lens from both sides.
    {
        float cr = band(r - 1.2, 26.0) * smoothstep(0.6, 0.85, abs(w.x) / max(r, 1e-3));
        col += hu * cr * 1.1 * sil;
        al = max(al, cr * 0.85);
    }
#endif

    // Heartbeat fuse: arc from twelve o'clock, clockwise, for the time left
    // before the session goes lost. A session that never heartbeat gets the
    // empty track and an empty socket instead.
    if (ended < 0.5) {
        float fa = fract(atan(w.x, w.y) / TAU);
        float track = band(r - 1.16, 70.0);
        vec2 sock = w - vec2(0.0, 1.16);
        if (fuse >= 0.0) {
            float burn = step(fa, fuse);
            vec2 head = vec2(sin(fuse * TAU), cos(fuse * TAU)) * 1.16;
            float pip = exp(-dot(w - head, w - head) * 900.0);
            col += hu * (track * (0.08 + 0.55 * burn) + pip * 1.2) * sil;
            al = max(al, track * (0.08 + 0.5 * burn) + pip);
        } else {
            float dots = smoothstep(0.25, 0.0, abs(fract(fa * 48.0) - 0.5) - 0.18);
            float socket = band(length(sock) - 0.07, 120.0);
            col += hu * (track * dots * 0.12 + socket * 0.5) * sil;
            al = max(al, track * dots * 0.1 + socket * 0.5);
        }
    }

    // Heartbeat pulse: a ring leaves the orb when an explicit heartbeat lands.
    if (pulse < 1.0) {
        float pr = band(r - (1.05 + 0.6 * pulse), 26.0) * pow(1.0 - pulse, 1.5);
        col += hu * pr * 0.7 * light;
        al = max(al, pr * 0.5);
    }

    // Lost: the broken heartbeat ring, muted red, never the warm needs-you hue.
    if (lost > 0.0) {
        float an = atan(w.y, w.x);
        float seg = step(0.5, fract(an / TAU * 10.0 + time * 0.05));
        float lr = band(r - 1.3, 22.0) * seg;
        col += alarm.rgb * lr * lost * (0.8 + 0.4 * sin(time * 3.0));
        al = max(al, lr * lost * 0.7);
    }

    // Dormant: a dotted outline around the hollow shell.
    if (dorm > 0.0) {
        float an = atan(w.y, w.x);
        float dt = smoothstep(0.3, 0.0, abs(fract(an / TAU * 36.0) - 0.5) - 0.2);
        float dr = band(r - 1.0, 50.0) * dt;
        col += hu * dr * 0.5 * dorm;
        al = max(al, dr * 0.5 * dorm);
    }

    // Ended: a closed, sealed ring around the ember.
    if (ended > 0.0) {
        float sr = band(r - 1.14, 26.0) * ended;
        col = col * (1.0 - 0.35 * ended) + vec3(0.62, 0.66, 0.74) * sr * 0.8;
        al = max(al, sr * 0.8);
    }

    // Needs you: a calm warm breathing ring (lost while still holding a claim).
    if (need > 0.0) {
        float b = 0.5 + 0.5 * sin(time * 1.9);
        float nr = band(r - 1.46 - 0.06 * b, 14.0);
        col += warm.rgb * nr * need * (0.4 + 0.4 * b);
        al = max(al, nr * need * 0.35);
    }

    al = clamp(al, 0.0, 1.0);
    // Shape proof: drop colour, keep form (luminance lifted so dark roles still read).
    float gl = dot(col, vec3(0.299, 0.587, 0.114));
    col = mix(col, vec3(min(gl * 1.6 + 0.12 * al, al)), mono);
    fragColor = vec4(col, al) * qt_Opacity;
}
