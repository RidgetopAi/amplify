.pragma library
// Meridian, the focused orb (task 85ff482a, decision 49f5d444; prototype in orb-lab
// context 01e8ede7). Pure: one session of the scene model (data/mandrel.js buildScene,
// ticked by tickScene) -> what the globe draws, and the hand-spin physics (drag,
// inertia, loupe detent). No timers, env reads or I/O; Meridian.qml passes the clock
// and the frame time in. Loaded by QML as a `.pragma library` and by node:test through
// plugin/focus/test/load.cjs.
//
// Mapping (viewer contract 22d73eeb), each from a named field:
//   longitude  time: now (scene time) faces you at lon 0; a record sits at the age of its
//              created_at (task: updated_at) west of now, on a log scale (lonOf);
//   latitude   record type: context and decision north, task and session activity south (LANES);
//   brightness trust: the record's trust band (TRUST; no band reads as unproven); hue is the kind only;
//   lit arc    the claim lease: (claim_expires_at - now) / the 45 min lease, east of now on the
//              equator up to LEASE_LON (a fresh claim), which no plaque reaches (LEASE_HALF < every
//              lane's plaque edge); its own linear scale, so it reads as how much is left;
//   sun        liveness: live day, quiet dusk, lost night (red now meridian), dormant moonlight, ended eclipse;
//   bead       the explicit heartbeat's age on the now meridian: north fresh, south near lost (10 min).
// Globe space: radius 1, y up; the camera sits at z = -CAM_Z looking +z, so p (screen, in globe
// radii from its centre) and the globe agree with shaders/meridian.frag line for line.

var TAU_SEC = 90;              // log time scale: lon = -KL * ln(1 + age / TAU_SEC)
var KL = 0.52;
var LANES = { context: 0.62, decision: 0.31, task: -0.31, activity: -0.62 };
var LANE_CAP = 3;              // newest plaques per lane
var MAX_PLAQUES = 8;           // atlas slots (Meridian.qml, meridian.frag)
var PLAQUE_HW = 0.2;           // plaque half extents, radians of arc
var PLAQUE_HH = 0.1;
var PLAQUE_GAP = 0.05;         // between plaques of one lane, radians of arc
var WEST_LIMIT = -2.8;         // no plaque centre further west: the back of the globe
var LEASE_HALF = 0.035;        // lease band half height, radians
var LEASE_SEC = 2700;          // Mandrel's default claim lease
var LEASE_LON = 0.6;           // the lit arc of a whole lease, radians east of now
var LOST_SEC = 600;            // explicit heartbeat age at which lost begins (22d73eeb)
var MARKS_SEC = [60, 300, 900, 3600, 6 * 3600, 86400];   // time meridians: 1m 5m 15m 1h 6h 1d
var TRUST = { trusted: 1.0, ok: 0.8, unproven: 0.6, stale: 0.42, superseded: 0.3, contradicted: 0.22 };
var KIND_COLOR = { context: "#8fd3ff", decision: "#e0a85a", task: "#6ee7b7", activity: "#b9a2ff" };
var SUN = {
    live: [-0.55, 0.45, -0.7], forming: [-0.55, 0.45, -0.7], quiet: [-0.95, 0.25, 0.05],
    lost: [0.3, 0.2, 0.95], dormant: [0.6, 0.4, 0.7], ended: [0, 0, 1]
};
var LIGHT = { live: 1.0, forming: 0.85, quiet: 0.7, lost: 0.55, dormant: 0.4, ended: 0.25 };
// The fixed loupe, in globe radii (screen space, y up): centre, radius, magnification, the
// rim's flattening (k), where its rim band starts (clear: the plaque under it stays inside) and
// how bright plaque text is outside it (dim; meridian.frag dimOut). Every plaque that faces you is
// drawn; the rim cuts one like real glass (magnified inside, unmagnified and dimmed outside), so
// the record under the loupe stays the focus and its neighbours stay readable (decision c197bf39).
// Left of centre, so with a record under it now and the lit future stay in view to its right.
var LOUPE = { x: -0.4, y: -0.18, r: 0.52, mag: 1.5, k: 0.12, clear: 0.86, dim: 0.6 };
var CAM_Z = 5;
var SCALE = CAM_Z / Math.sqrt(CAM_Z * CAM_Z - 1);

// Spin physics: drag turns the globe under the hand; let go and it coasts with friction,
// then the detent springs the nearest plaque under the loupe (critically damped).
var FRICTION = 2.2;            // 1/s
var DETENT_SPEED = 0.35;       // rad/s: below it the detent takes over
var MAX_SPEED = 8;             // rad/s
var OMEGA = 7;                 // detent spring, rad/s
var PITCH_LIMIT = 1.2;
var SETTLE_POS = 1e-4, SETTLE_VEL = 1e-3;

function toMs(v) {
    if (v === null || v === undefined || v === "") return null;
    if (typeof v === "number") return v;
    var t = Date.parse(v);
    return isNaN(t) ? null : t;
}
function clamp(x, a, b) { return x < a ? a : x > b ? b : x; }
function wrap(a) { return a - 2 * Math.PI * Math.floor((a + Math.PI) / (2 * Math.PI)); }   // to [-pi, pi)
function lonOf(ageSec) { return -KL * Math.log(1 + Math.max(0, ageSec) / TAU_SEC); }
function futureLon(sec) { return sec > 0 ? LEASE_LON * clamp(sec / LEASE_SEC, 0, 1) : 0; }
function brightness(trust) { return TRUST[trust] !== undefined ? TRUST[trust] : TRUST.unproven; }
function lonHalf(hw, lat) { return hw / Math.max(Math.cos(lat), 0.05); }

function ago(sec) {
    sec = Math.max(0, Math.floor(sec));
    if (sec < 60) return sec + "s";
    if (sec < 3600) return Math.floor(sec / 60) + "m";
    if (sec < 86400) return Math.floor(sec / 3600) + "h " + Math.floor((sec % 3600) / 60) + "m";
    return Math.floor(sec / 86400) + "d";
}
function mmss(sec) {
    sec = Math.max(0, Math.floor(sec));
    return ("0" + Math.floor(sec / 60)).slice(-2) + ":" + ("0" + (sec % 60)).slice(-2);
}

function sessionOf(scene, id) {
    for (var i = 0; i < scene.sessions.length; i++) if (scene.sessions[i].id === id || scene.sessions[i].id8 === id) return scene.sessions[i];
    return null;
}
function heldTask(scene, sessionId) {
    for (var i = 0; i < scene.tasks.length; i++) if (scene.tasks[i].orbSessionId === sessionId) return scene.tasks[i];
    return null;
}

// The session's own records at scene time nowMs, newest first: its contexts and decisions
// (scene.allRecords by session_id), the task it holds, and its loop activities.
function recordsOf(scene, session, nowMs) {
    var out = [], all = scene.allRecords || scene.latest || [];
    for (var i = 0; i < all.length; i++) {
        var r = all[i];
        if (r.sessionId !== session.id || (r.kind !== "context" && r.kind !== "decision")) continue;
        out.push({ kind: r.kind, type: r.type, id: r.id, id8: r.id8, url: r.url, title: r.title, at: toMs(r.at), trust: r.trust || null });
    }
    var t = heldTask(scene, session.id);
    if (t) out.push({ kind: "task", type: t.lane, id: t.id, id8: t.id8, url: t.url, title: t.title,
                      at: toMs(t.updatedAt) || toMs(t.createdAt), trust: null });
    var acts = session.loopActivities || [];
    for (var j = 0; j < acts.length; j++) {
        var a = acts[j];
        out.push({ kind: "activity", type: a.kind || null, id: session.id, id8: session.id8, url: session.url,
                   title: a.detail || a.kind || "activity", at: toMs(a.at || a.created_at || a.createdAt), trust: null });
    }
    out = out.filter(function (x) { return x.at !== null && x.at <= nowMs; });
    out.sort(function (a, b) { return b.at - a.at; });
    return out;
}

// Plaques: the newest records, at most LANE_CAP per lane and MAX_PLAQUES in all, each at
// (time, lane). Within a lane a plaque that would overlap a newer one moves west of it;
// one pushed past WEST_LIMIT is not drawn.
function plaques(scene, session, nowMs) {
    var recs = recordsOf(scene, session, nowMs), out = [], lastLon = {}, count = {};
    for (var i = 0; i < recs.length && out.length < MAX_PLAQUES; i++) {
        var r = recs[i], lat = LANES[r.kind];
        if ((count[r.kind] || 0) >= LANE_CAP) continue;
        var half = lonHalf(PLAQUE_HW, lat), lon = lonOf((nowMs - r.at) / 1000);
        if (lastLon[r.kind] !== undefined) lon = Math.min(lon, lastLon[r.kind] - 2 * half - lonHalf(PLAQUE_GAP, lat));
        if (lon < WEST_LIMIT) continue;
        lastLon[r.kind] = lon;
        count[r.kind] = (count[r.kind] || 0) + 1;
        var age = (nowMs - r.at) / 1000;
        out.push({
            slot: out.length, kind: r.kind, type: r.type, id: r.id, id8: r.id8, url: r.url, title: r.title,
            at: r.at, trust: r.trust || "unproven",
            bright: brightness(r.trust), color: KIND_COLOR[r.kind],
            head: (r.kind === "activity" ? (r.type || "activity") : r.kind).toUpperCase() + (r.kind === "activity" ? "" : "  ·  " + r.id8),
            meta: ago(age) + " ago" + (r.kind === "context" || r.kind === "decision" ? " · trust " + (r.trust || "unproven") : r.type ? " · " + r.type : ""),
            lon: lon, lat: lat, hw: PLAQUE_HW, hh: PLAQUE_HH
        });
    }
    return out;
}

function lease(scene, session, nowMs) {
    var t = heldTask(scene, session.id);
    if (!t || !t.claimExpiresAt) return { lon: 0, leftSec: 0, held: false, task: t };
    var left = Math.max(0, (toMs(t.claimExpiresAt) - nowMs) / 1000);
    var held = !!t.claimLive && left > 0;
    return { lon: held ? futureLon(left) : 0, leftSec: left, held: held, task: t, text: held ? mmss(left) : "expired" };
}

// Everything the focused orb draws for session `id` (full id or id8) at scene time nowMs.
// The scene's liveness must already be ticked to nowMs (Mandrel.tickScene).
function globe(scene, id, nowMs) {
    var s = scene ? sessionOf(scene, id) : null;
    if (!s) return null;
    var hb = toMs(s.lastExplicitHeartbeatAt), hbAge = hb === null ? null : (nowMs - hb) / 1000;
    var sun = SUN[s.liveness] || SUN.dormant, n = Math.sqrt(sun[0] * sun[0] + sun[1] * sun[1] + sun[2] * sun[2]);
    var pl = plaques(scene, s, nowMs), newest = -1;
    for (var i = 0; i < pl.length; i++) if (newest < 0 || pl[i].at > pl[newest].at) newest = i;
    var wrote = toMs(s.lastActivityAt);
    return {
        session: { id: s.id, id8: s.id8, title: s.title, name: s.orbName || s.displayTitle, untitled: !s.title,
                   role: s.role || "agent", liveness: s.liveness, url: s.url, threadUrl: s.threadUrl,
                   creationReason: s.creationReason, totalTokens: s.totalTokens,
                   wroteAgo: wrote === null ? null : ago((nowMs - wrote) / 1000),
                   heartbeatAgo: hbAge === null ? null : ago(hbAge) },
        plaques: pl, newest: newest,
        lease: lease(scene, s, nowMs),
        marks: MARKS_SEC.map(lonOf),
        sun: [sun[0] / n, sun[1] / n, sun[2] / n],
        light: LIGHT[s.liveness] !== undefined ? LIGHT[s.liveness] : LIGHT.dormant,
        lost: s.liveness === "lost" ? 1 : 0, dorm: s.liveness === "dormant" ? 1 : 0, ended: s.liveness === "ended" ? 1 : 0,
        hbFuse: hbAge === null ? -1 : clamp(1 - hbAge / LOST_SEC, 0, 1)
    };
}

// ---------------------------------------------------------------- camera (meridian.frag)
function norm(v) { var l = Math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]) || 1; return [v[0] / l, v[1] / l, v[2] / l]; }
function ray(px, py) { return norm([px * SCALE, py * SCALE, CAM_Z]); }
// The world point of the unit globe seen at screen p, or null.
function hit(px, py) {
    var d = ray(px, py), b = -CAM_Z * d[2], c = CAM_Z * CAM_Z - 1, h = b * b - c;
    if (h < 0) return null;
    var t = -b - Math.sqrt(h);
    return [d[0] * t, d[1] * t, -CAM_Z + d[2] * t];
}
function project(P) { var k = Math.sqrt(CAM_Z * CAM_Z - 1) / (P[2] + CAM_Z); return [P[0] * k, P[1] * k]; }
// world = Rx(pitch) Ry(yaw) obj
function toWorld(n, yaw, pitch) {
    var c = Math.cos(yaw), s = Math.sin(yaw);
    var a = [n[0] * c + n[2] * s, n[1], -n[0] * s + n[2] * c];
    c = Math.cos(pitch); s = Math.sin(pitch);
    return [a[0], a[1] * c - a[2] * s, a[1] * s + a[2] * c];
}
function toObj(w, yaw, pitch) {
    var c = Math.cos(-pitch), s = Math.sin(-pitch);
    var a = [w[0], w[1] * c - w[2] * s, w[1] * s + w[2] * c];
    c = Math.cos(-yaw); s = Math.sin(-yaw);
    return [a[0] * c + a[2] * s, a[1], -a[0] * s + a[2] * c];
}
function objOf(lon, lat) { return [Math.sin(lon) * Math.cos(lat), Math.sin(lat), -Math.cos(lon) * Math.cos(lat)]; }
function lonLat(n) { return [Math.atan2(n[0], -n[2]), Math.asin(clamp(n[1], -1, 1))]; }
// The loupe shows the globe point pp at screen point p: pp = lc + (p - lc) / mag * (1 + k q^2), q = |p - lc| / r.
function throughLoupe(px, py) {
    var dx = px - LOUPE.x, dy = py - LOUPE.y, q = Math.sqrt(dx * dx + dy * dy) / LOUPE.r;
    if (q >= 1) return [px, py];
    var f = (1 + LOUPE.k * q * q) / LOUPE.mag;
    return [LOUPE.x + dx * f, LOUPE.y + dy * f];
}
// Where in the loupe (q = distance / radius) a globe point seen at pp shows; > 1: outside it.
function loupeQ(ppx, ppy) {
    var d = Math.sqrt((ppx - LOUPE.x) * (ppx - LOUPE.x) + (ppy - LOUPE.y) * (ppy - LOUPE.y));
    var f = function (x) { return x / LOUPE.mag * (1 + LOUPE.k * (x / LOUPE.r) * (x / LOUPE.r)); };
    if (f(LOUPE.r) < d) return 1 + d;
    var lo = 0, hi = LOUPE.r;
    for (var i = 0; i < 50; i++) { var m = (lo + hi) / 2; if (f(m) < d) lo = m; else hi = m; }
    return lo / LOUPE.r;
}
// The obj point under the loupe's centre for this orientation.
function loupePoint(yaw, pitch) { var W = hit(LOUPE.x, LOUPE.y); return lonLat(toObj(W, yaw, pitch)); }
// The orientation that puts plaque p's centre under the loupe's centre, nearest to yaw.
// Solved exactly: pitch tilts the loupe's world point W onto latitude p.lat (Wy cos t + Wz sin t
// = sin lat, the front-facing root), then yaw turns p.lon onto its longitude.
function detentFor(p, yaw) {
    var W = hit(LOUPE.x, LOUPE.y);
    var A = Math.sqrt(W[1] * W[1] + W[2] * W[2]), phi = Math.atan2(W[2], W[1]);
    var c = Math.acos(clamp(Math.sin(p.lat) / A, -1, 1)), best = null;
    for (var k = -1; k <= 1; k += 2) {
        var t = phi + k * c, z = -W[1] * Math.sin(t) + W[2] * Math.cos(t);
        if (z < 0 && (best === null || Math.abs(wrap(t)) < Math.abs(wrap(best)))) best = t;
    }
    var pitch = wrap(best), z1 = -W[1] * Math.sin(pitch) + W[2] * Math.cos(pitch);
    var lon1 = Math.atan2(W[0], -z1), y = p.lon - lon1;
    return { yaw: yaw + wrap(y - yaw), pitch: pitch };
}
// How far out in the loupe the plaque's outline reaches (max q over its edge); visible: every edge point faces the camera.
function plaqueInLoupe(p, yaw, pitch) {
    var worst = 0, half = lonHalf(p.hw, p.lat), N = 12;
    for (var i = 0; i <= N; i++) for (var e = 0; e < 4; e++) {
        var u = i / N * 2 - 1;
        var lon = e < 2 ? p.lon + u * half : p.lon + (e === 2 ? -half : half);
        var lat = e < 2 ? p.lat + (e === 0 ? -p.hh : p.hh) : p.lat + u * p.hh;
        var W = toWorld(objOf(lon, lat), yaw, pitch);
        if (1 + CAM_Z * W[2] >= 0) return Infinity;      // behind the horizon
        var pp = project(W);
        worst = Math.max(worst, loupeQ(pp[0], pp[1]));
    }
    return worst;
}
// The plaque drawn at screen p (globe radii, y up), through the loupe; -1 for none.
function pick(st, px, py, pl) {
    var pp = throughLoupe(px, py), W = hit(pp[0], pp[1]);
    if (!W) return -1;
    var ll = lonLat(toObj(W, st.yaw, st.pitch));
    for (var i = 0; i < pl.length; i++) {
        var q = pl[i];
        if (Math.abs(wrap(ll[0] - q.lon)) * Math.cos(ll[1]) < q.hw && Math.abs(ll[1] - q.lat) < q.hh) return i;
    }
    return -1;
}
// What meridian.frag lights at screen p once landed: the plaque there (-1 none, as pick) and its
// text's brightness, trust (bright) inside the loupe and LOUPE.dim of it outside.
function plaqueLight(st, px, py, pl) {
    var i = pick(st, px, py, pl), inL = Math.hypot(px - LOUPE.x, py - LOUPE.y) < LOUPE.r;
    return { i: i, light: i < 0 ? 0 : pl[i].bright * (inL ? 1 : LOUPE.dim) };
}

// ---------------------------------------------------------------- spin physics
function spin(yaw, pitch) {
    return { yaw: yaw, pitch: pitch, vy: 0, vp: 0, mode: "idle", target: -1, tyaw: yaw, tpitch: pitch };
}
// The hand moved (dx, dy) px in dt s on a globe of R px: the surface follows it.
function drag(st, dx, dy, dt, R) {
    var pxPerRad = R * Math.sqrt(CAM_Z * CAM_Z - 1) / (CAM_Z - 1);
    var dyaw = -dx / pxPerRad, dpitch = -dy / pxPerRad;
    st.mode = "drag"; st.target = -1;
    st.yaw += dyaw;
    st.pitch = clamp(st.pitch + dpitch, -PITCH_LIMIT, PITCH_LIMIT);
    st.vy = clamp(dyaw / Math.max(dt, 1e-3), -MAX_SPEED, MAX_SPEED);
    st.vp = 0;
    st.tyaw = st.yaw; st.tpitch = st.pitch;
    return st;
}
function release(st) { if (st.mode === "drag") st.mode = "coast"; return st; }
// The plaque nearest the point under the loupe (along the surface).
function nearest(st, pl) {
    var at = loupePoint(st.yaw, st.pitch), best = -1, bd = Infinity;
    for (var i = 0; i < pl.length; i++) {
        var dx = wrap(pl[i].lon - at[0]) * Math.cos(at[1]), dy = pl[i].lat - at[1], d = dx * dx + dy * dy;
        if (d < bd) { bd = d; best = i; }
    }
    return best;
}
function detentTo(st, i, pl) {
    if (i < 0 || !pl[i]) { st.mode = "idle"; st.vy = 0; st.vp = 0; st.target = -1; st.tyaw = st.yaw; st.tpitch = st.pitch; return st; }
    var d = detentFor(pl[i], st.yaw);
    st.mode = "detent"; st.target = i; st.tyaw = d.yaw; st.tpitch = d.pitch;
    return st;
}
// Advance dt s; returns true while the globe still moves.
function step(st, dt, pl) {
    dt = clamp(dt, 0, 0.1);
    if (st.mode === "coast") {
        st.yaw += st.vy * dt;
        st.vy *= Math.exp(-FRICTION * dt);
        if (Math.abs(st.vy) < DETENT_SPEED) detentTo(st, nearest(st, pl), pl);
    }
    if (st.mode === "detent") {
        var n = Math.max(1, Math.ceil(dt * 240)), h = dt / n;
        for (var i = 0; i < n; i++) {
            st.vy += (-OMEGA * OMEGA * (st.yaw - st.tyaw) - 2 * OMEGA * st.vy) * h;
            st.vp += (-OMEGA * OMEGA * (st.pitch - st.tpitch) - 2 * OMEGA * st.vp) * h;
            st.yaw += st.vy * h; st.pitch += st.vp * h;
        }
        if (Math.abs(st.yaw - st.tyaw) < SETTLE_POS && Math.abs(st.pitch - st.tpitch) < SETTLE_POS
            && Math.abs(st.vy) < SETTLE_VEL && Math.abs(st.vp) < SETTLE_VEL) {
            st.yaw = st.tyaw; st.pitch = st.tpitch; st.vy = 0; st.vp = 0; st.mode = "idle";
        }
    }
    return st.mode === "coast" || st.mode === "detent";
}
// New data while settled: the plaque under the loupe has drifted (time moves it west); keep it
// there, by id, without animating (the record moved, not the hand). Returns its new index.
function follow(st, pl, id) {
    if (st.mode !== "idle") return st.target;
    for (var i = 0; i < pl.length; i++) if (pl[i].id === id && pl[i].kind !== "activity") {
        var d = detentFor(pl[i], st.yaw);
        st.target = i; st.yaw = st.tyaw = d.yaw; st.pitch = st.tpitch = d.pitch;
        return i;
    }
    st.target = -1;
    return -1;
}

// ---------------------------------------------------------------- redraw budget
// Whether globe b draws differently from a by a visible amount: eps radians of arc for
// positions (about a pixel: 1 / globe radius in px), any change for text and state. A live
// scene ticks every second; the globe redraws only when that moves something.
function changed(a, b, eps) {
    if (!a || !b) return a !== b;
    var big = function (x, y) { return Math.abs(x - y) >= eps; };
    if (a.plaques.length !== b.plaques.length || a.newest !== b.newest) return true;
    for (var i = 0; i < a.plaques.length; i++) {
        var p = a.plaques[i], q = b.plaques[i];
        if (p.id !== q.id || p.kind !== q.kind || p.head !== q.head || p.title !== q.title || p.meta !== q.meta
            || p.bright !== q.bright || big(p.lon, q.lon) || big(p.lat, q.lat)) return true;
    }
    if (big(a.lease.lon, b.lease.lon) || a.lease.held !== b.lease.held || a.lease.text !== b.lease.text) return true;
    if (a.light !== b.light || a.lost !== b.lost || a.dorm !== b.dorm || a.ended !== b.ended) return true;
    if (Math.abs(a.hbFuse - b.hbFuse) >= 0.01 || (a.hbFuse < 0) !== (b.hbFuse < 0)) return true;
    var s = a.session, t = b.session;
    return s.liveness !== t.liveness || s.name !== t.name || s.wroteAgo !== t.wroteAgo || s.heartbeatAgo !== t.heartbeatAgo
        || s.totalTokens !== t.totalTokens;
}
