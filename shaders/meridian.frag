#version 440
// Meridian, the focused orb (task 85ff482a, decision 49f5d444): a ceramic time globe
// inside Vessel's thick glass shell. Every uniform comes from plugin/focus/meridian.js
// (globe() and the spin state); nothing here moves on its own: there is no time uniform,
// so a settled globe draws the same pixels until its record or the hand changes it.
//   longitude = time (now at lon 0 faces you, past west, log scale; marksA/B are 1m..1d),
//   latitude  = record lane, plaques = record text from the atlas (Meridian.qml) at
//   (lon, lat) with trust as brightness (bright*), lease = lit arc east of now on the
//   equator, sun = liveness, bead on the now meridian = heartbeat fuse.
// The camera and rotation match meridian.js (ray, hit, toObj, throughLoupe) line for line.
// Compiled to plugin/shaders/meridian.frag.qsb.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float yaw;       // globe orientation: world = Rx(pitch) Ry(yaw) obj
    float pitch;
    float px;        // pixels per globe radius (antialiasing)
    float land;      // 0..1 fly progress: the loupe and the lease light up as it lands
    float leaseLon;  // lit arc end, radians east of now; 0 = no live claim
    float hbFuse;    // explicit heartbeat fuse 0..1 (1 fresh); < 0 none
    float light;     // liveness light
    float lost;      // 1 lost: red now meridian
    float dorm;      // 1 dormant: cold moonlight
    float ended;     // 1 ended: eclipse
    float nPlq;      // plaques in use (<= 8)
    float dimOut;    // plaque text brightness outside the loupe, a share of inside (meridian.js LOUPE.dim)
    vec4 loupe;      // x, y, radius (globe radii, screen space, y up), magnification
    vec4 sun;        // sun direction (world)
    vec4 marksA;     // time meridians (lon): 1m 5m 15m 1h
    vec4 marksB;     // 6h 1d
    vec4 plq0; vec4 plq1; vec4 plq2; vec4 plq3;   // lon, lat, half width, half height (radians of arc)
    vec4 plq4; vec4 plq5; vec4 plq6; vec4 plq7;
    vec4 brightA;    // plaques 0..3 trust brightness; 0 = slot unused
    vec4 brightB;    // plaques 4..7
    vec4 atm;        // rim light (role tint)
    vec4 leaseCol;
};
layout(binding = 1) uniform sampler2D atlas;   // 4 x 2 plaque slots (Meridian.qml)

const float PI = 3.14159265;
const float E = 1.3;          // item half extent in globe radii
const float CAMZ = 5.0;
const float SHELL = 1.06;     // Vessel's glass shell around the globe
const float KLOUPE = 0.12;
const float LEASE_HALF = 0.035;

float h3(vec3 p) { p = fract(p * 0.3183099 + 0.1); p *= 17.0; return fract(p.x * p.y * p.z * (p.x + p.y + p.z)); }
float n3(vec3 x) {
    vec3 i = floor(x), f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix(h3(i), h3(i + vec3(1, 0, 0)), f.x), mix(h3(i + vec3(0, 1, 0)), h3(i + vec3(1, 1, 0)), f.x), f.y),
               mix(mix(h3(i + vec3(0, 0, 1)), h3(i + vec3(1, 0, 1)), f.x), mix(h3(i + vec3(0, 1, 1)), h3(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}
float fbm(vec3 p) { float s = 0.0, a = 0.5; for (int i = 0; i < 3; i++) { s += a * n3(p); p = p * 2.03 + vec3(1.7, 9.2, 3.1); a *= 0.5; } return s; }
vec2 sph(vec3 ro, vec3 rd, float r) {
    float b = dot(ro, rd), c = dot(ro, ro) - r * r, h = b * b - c;
    if (h < 0.0) return vec2(-1.0);
    h = sqrt(h);
    return vec2(-b - h, -b + h);
}
vec3 camRay(vec2 p) { return normalize(vec3(p * (CAMZ / sqrt(CAMZ * CAMZ - 1.0)), CAMZ)); }
vec3 toObj(vec3 w) {
    float c = cos(-pitch), s = sin(-pitch);
    vec3 a = vec3(w.x, w.y * c - w.z * s, w.y * s + w.z * c);
    c = cos(-yaw); s = sin(-yaw);
    return vec3(a.x * c + a.z * s, a.y, -a.x * s + a.z * c);
}
float wrapA(float a) { return a - 2.0 * PI * floor((a + PI) / (2.0 * PI)); }
float lum(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }
// Plaque, brightness and time-mark uniforms by index. No arrays here: Qt hands GLSL
// "100 es" to some drivers (NVIDIA), and array constructors are not GLSL ES 1.00
// (task 3432bf5a; tools/check-gles.sh keeps them out of every shipped .qsb).
vec4 plq(int i) {
    if (i == 0) return plq0; if (i == 1) return plq1; if (i == 2) return plq2; if (i == 3) return plq3;
    if (i == 4) return plq4; if (i == 5) return plq5; if (i == 6) return plq6; return plq7;
}
float bright(int i) {
    if (i == 0) return brightA.x; if (i == 1) return brightA.y; if (i == 2) return brightA.z; if (i == 3) return brightA.w;
    if (i == 4) return brightB.x; if (i == 5) return brightB.y; if (i == 6) return brightB.z; return brightB.w;
}
float mark(int i) {
    if (i == 0) return marksA.x; if (i == 1) return marksA.y; if (i == 2) return marksA.z; if (i == 3) return marksA.w;
    if (i == 4) return marksB.x; return marksB.y;
}
// Vessel's studio: an overhead softbox, a warm side light and a cool fill.
vec3 studio(vec3 d) {
    float top = smoothstep(0.25, 0.95, d.y) * smoothstep(0.9, 0.2, abs(d.x));
    float side = smoothstep(0.55, 0.95, d.x) * smoothstep(0.6, 0.0, abs(d.y - 0.15));
    float side2 = smoothstep(0.75, 0.98, -d.x) * smoothstep(0.5, 0.0, abs(d.y - 0.35)) * 0.5;
    return vec3(0.012, 0.016, 0.024) + vec3(0.85, 0.9, 1.0) * top * 1.3 + vec3(1.0, 0.86, 0.66) * side * 0.8
         + vec3(0.6, 0.8, 1.0) * side2 + vec3(0.05, 0.06, 0.08) * smoothstep(-0.2, 0.6, d.y);
}

void main() {
    vec2 p = vec2(qt_TexCoord0.x * 2.0 - 1.0, 1.0 - qt_TexCoord0.y * 2.0) * E;
    float r = length(p);
    if (r > E) { fragColor = vec4(0.0); return; }
    float aa = 1.5 / max(px, 1.0);
    vec3 ro = vec3(0.0, 0.0, -CAMZ);

    // The loupe: a fixed lens over the globe that magnifies and flattens what it covers.
    vec2 lc = loupe.xy;
    float lr = loupe.z, ld = length(p - lc), lq = ld / lr;
    bool inL = lq < 1.0 && land > 0.5;
    vec2 pp = inL ? lc + (p - lc) / loupe.w * (1.0 + KLOUPE * lq * lq) : p;
    float aaG = inL ? aa / loupe.w : aa;

    vec3 col = vec3(0.0);
    float a = 0.0;
    vec3 rd = camRay(pp);
    vec2 h = sph(ro, rd, 1.0);
    if (h.x > 0.0) {
        vec3 Pw = ro + rd * h.x;
        vec3 N = normalize(Pw);
        vec3 n = toObj(N);
        float lat = asin(clamp(n.y, -1.0, 1.0)), lon = atan(n.x, -n.z);
        float cl = max(cos(lat), 0.05);
        vec3 alb = mix(vec3(0.055, 0.065, 0.08), vec3(0.10, 0.11, 0.13), fbm(n * 6.0));
        vec3 em = vec3(0.0);
        // Graticule: latitude every 15 degrees; time meridians at 1m, 5m, 15m, 1h, 6h, 1d ago.
        float g = abs(fract(lat / (PI / 12.0) + 0.5) - 0.5) * (PI / 12.0);
        em += vec3(0.55, 0.6, 0.68) * smoothstep(aaG * 1.2, 0.0, g) * 0.10;
        for (int i = 0; i < 6; i++) em += vec3(0.55, 0.6, 0.68) * smoothstep(aaG * 1.4, 0.0, abs(wrapA(lon - mark(i))) * cl) * 0.22;
        // Now meridian (lon 0): cream; red once the promised heartbeat stopped (lost).
        float nowd = abs(wrapA(lon)) * cl;
        em += mix(vec3(0.95, 0.9, 0.8), vec3(1.0, 0.25, 0.12), lost) * smoothstep(aaG * 2.5, 0.0, nowd) * 0.65;
        // Heartbeat bead: the explicit heartbeat's fuse, north = fresh, south = about to go lost.
        if (hbFuse >= 0.0) {
            float hy = mix(-1.15, 1.15, hbFuse);
            em += vec3(0.75, 0.95, 1.0) * smoothstep(0.034, 0.022, length(vec2(nowd, lat - hy))) * 1.3;
        }
        // The lease: a lit arc on the equator from now east to the claim's expiry.
        if (leaseLon > 0.0) {
            float dl = wrapA(lon);
            float on = smoothstep(-aaG, 0.0, dl) * smoothstep(leaseLon + aaG, leaseLon, dl);
            float band = smoothstep(LEASE_HALF + aaG, LEASE_HALF, abs(lat));
            float tick = 0.75 + 0.25 * step(0.5, fract(dl * 12.0));
            em += leaseCol.rgb * on * band * tick * 1.25 * land;
            em += leaseCol.rgb * smoothstep(0.05, 0.03, length(vec2((dl - leaseLon) * cl, lat))) * 1.4 * land;
        }
        // Plaques: the record's text (atlas slot i), brightness = trust. Every plaque is drawn; the
        // loupe's rim cuts one like real glass: magnified inside, unmagnified and dimmed outside.
        float plqL = inL ? 1.0 : mix(1.0, dimOut, land);
        for (int i = 0; i < 8; i++) {
            if (float(i) >= nPlq) break;
            vec4 q = plq(i);
            float b = bright(i);
            vec2 lp = vec2(wrapA(lon - q.x) * cl, lat - q.y);
            vec2 uv = lp / (2.0 * q.zw) + 0.5;
            if (b > 0.0 && uv.x > 0.0 && uv.x < 1.0 && uv.y > 0.0 && uv.y < 1.0) {
                float fi = float(i);
                vec2 o = vec2(mod(fi, 4.0) * 0.25, floor(fi / 4.0) * 0.5);
                vec4 tx = texture(atlas, o + vec2(uv.x, 1.0 - uv.y) * vec2(0.25, 0.5));
                alb = mix(alb, alb * 0.35, tx.a * 0.7);
                em += tx.rgb * b * 1.15 * plqL;
            }
        }
        // Sun = liveness: day, dusk, night, moonlight, eclipse.
        vec3 sunD = normalize(sun.xyz);
        float wrapL = max((dot(N, sunD) + 0.3) / 1.3, 0.0);
        float spec = pow(max(dot(reflect(rd, N), sunD), 0.0), 40.0) * 0.35;
        vec3 sunC = mix(vec3(1.0, 0.94, 0.84), vec3(0.55, 0.62, 0.8), dorm);
        col = alb * (sunC * wrapL * 2.2 * light + vec3(0.04, 0.05, 0.07)) + sunC * spec * light;
        float night = 1.0 - smoothstep(-0.1, 0.3, dot(N, sunD));
        col += em * (0.75 + 0.6 * night) * mix(1.0, 0.55, ended);
        col += atm.rgb * pow(1.0 - max(dot(-rd, N), 0.0), 3.0) * 0.45 * light;
        // Antialiased silhouette (in screen space, outside the loupe).
        a = inL ? 1.0 : smoothstep(1.0, 1.0 - aa, r);
    }

    // Vessel's glass shell: fresnel reflection of the studio, a softbox window, a thick rim.
    vec3 rd0 = camRay(p);
    vec2 hs = sph(ro, rd0, SHELL);
    float rS = sqrt(CAMZ * CAMZ - 1.0) * SHELL / sqrt(CAMZ * CAMZ - SHELL * SHELL);   // shell silhouette radius in p
    if (hs.x > 0.0) {
        vec3 Ns = normalize(ro + rd0 * hs.x);
        float cosI = max(dot(-rd0, Ns), 0.0);
        float fres = 0.04 + 0.96 * pow(1.0 - cosI, 5.0);
        vec3 R = reflect(rd0, Ns);
        vec3 Lw = normalize(vec3(-0.45, 0.72, -0.52));
        vec3 wu = normalize(cross(Lw, vec3(0.0, 0.0, 1.0))), wv = cross(Lw, wu);
        float win = step(0.0, dot(R, Lw)) * smoothstep(0.22, 0.16, abs(dot(R, wu))) * smoothstep(0.12, 0.08, abs(dot(R, wv)));
        win *= 1.0 - smoothstep(0.008, 0.0, abs(dot(R, wu))) * 0.7;
        vec3 glass = studio(R) * fres + vec3(0.9, 0.95, 1.0) * win * fres * 4.0
                   + vec3(1.0, 0.95, 0.9) * pow(max(dot(R, normalize(vec3(0.8, 0.55, -0.25))), 0.0), 300.0) * 1.2;
        float edge = smoothstep(rS, rS - aa, r);
        col = col * (1.0 - fres) * mix(1.0, 0.6, smoothstep(0.86, 0.99, r / rS) * a) + glass * edge;
        a = max(a, clamp(lum(glass) * 1.4 + fres * 0.6, 0.0, 1.0) * edge);
    }

    // The loupe's glass, once the orb has landed: rim band, a bright edge, a glint.
    if (land > 0.0) {
        float rim = smoothstep(0.86, 1.0, lq) * step(lq, 1.0);
        col = col * (1.0 - rim * 0.55 * land);
        float ring = smoothstep(aa * 1.5 / lr, 0.0, abs(lq - 1.0)) * land;
        col += vec3(0.9, 0.95, 1.0) * ring * 0.7;
        col += vec3(1.0) * pow(max(0.0, 1.0 - length((p - lc) / lr - vec2(-0.45, 0.5)) * 2.2), 3.0) * 0.22 * land * step(lq, 1.0);
        a = max(a, ring * 0.9);
    }

    // Halo: atmosphere by the light, red when lost.
    float out1 = max(r - rS, 0.0);
    vec3 halo = (atm.rgb * (1.0 - lost) * 0.30 * light + vec3(1.0, 0.3, 0.15) * lost * 0.45) * exp(-out1 * 9.0) * step(rS, r);
    col += halo;
    a = max(a, clamp(lum(halo) * 1.5, 0.0, 1.0));
    col = mix(col, vec3(lum(col)), dorm * 0.45 + ended * 0.8);
    col = col / (1.0 + col * 0.15);
    fragColor = vec4(col, a) * qt_Opacity;
}
