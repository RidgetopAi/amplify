.pragma library
// Desktop orbs (task a40d7440): pure mapping from the data layer's scene model
// (data/mandrel.js buildScene / tickScene) to what OrbField draws. No timers,
// env reads or I/O; the host passes the clock in. Loaded by QML as a
// `.pragma library` and by node:test through plugin/orbs/test/load.cjs.

var LEASE_SEC = 2700;          // Mandrel's default claim lease (task claim)
var ENDED_SHOW_SEC = 15 * 60;  // an ended session stays as an ember this long
var ENDED_COLLAPSE_SEC = 90;   // collapse from orb to ember
var FORM_SEC = 10 * 60;        // forming fills over the quiet threshold
var PULSE_SEC = 30;            // a heartbeat pulse ring lives this long
var LOST_SEC = 10 * 60;        // explicit heartbeat age at which lost begins (22d73eeb)
var WRITE_GLOW_SEC = 10 * 60;  // write-recency glow time constant
var LINK_SHOW_SEC = 30 * 60;   // a beam fades out over this window

// Liveness -> material. Each state has its own look (viewer contract 22d73eeb,
// decision 23973614). spin is turns of the surface per minute of client time.
var MATERIAL = {
    live:    { spin: 1.0,  sat: 1.0,  light: 1.0,  dorm: 0, lost: 0 },
    forming: { spin: 0.3,  sat: 0.6,  light: 0.7,  dorm: 0, lost: 0 },
    quiet:   { spin: 0.3,  sat: 0.42, light: 0.6,  dorm: 0, lost: 0 },
    lost:    { spin: 0.08, sat: 0.12, light: 0.5,  dorm: 0, lost: 1 },
    dormant: { spin: 0.0,  sat: 0.15, light: 0.3,  dorm: 1, lost: 0 },
    ended:   { spin: 0.0,  sat: 0.0,  light: 0.55, dorm: 0, lost: 0 }
};

// Lane colours (Direction C): cool, slate -> periwinkle -> lavender -> gold.
var LANE_COLOR = {
    draft: "#6b778c", ready: "#7fa6d9", claimed: "#919ef7", verifying: "#b7a0f4",
    evidence: "#e9c47c", merged: "#f1e6d0", deployed: "#f1e6d0"
};

var ROLES = { coord: 0, worker: 1, critic: 2 };

function toMs(v) {
    if (v === null || v === undefined || v === "") return null;
    if (typeof v === "number") return v;
    var t = Date.parse(v);
    return isNaN(t) ? null : t;
}

function ageSec(v, nowMs) {
    var t = toMs(v);
    return t === null ? null : (nowMs - t) / 1000;
}

function clamp01(x) { return x < 0 ? 0 : x > 1 ? 1 : x; }

function material(liveness) { return MATERIAL[liveness] || MATERIAL.dormant; }

// Stable per-session phase in [0, 1) so orbs never turn in lockstep.
function seedOf(id) {
    var s = String(id || ""), h = 2166136261;
    for (var i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = (h * 16777619) >>> 0; }
    return (h % 10000) / 10000;
}

function roleOf(session) {
    var r = session && session.role;
    return ROLES[r] !== undefined ? r : "worker";
}

// Lease left in [0, 1] on the client clock; null when the task has no claim expiry.
function leaseFraction(task, nowMs) {
    if (!task || !task.claimExpiresAt) return null;
    var left = (toMs(task.claimExpiresAt) - nowMs) / 1000;
    return clamp01(left / LEASE_SEC);
}

function leaseLeftSec(task, nowMs) {
    if (!task || !task.claimExpiresAt) return null;
    return Math.max(0, (toMs(task.claimExpiresAt) - nowMs) / 1000);
}

function heldTask(scene, sessionId) {
    for (var i = 0; i < scene.tasks.length; i++)
        if (scene.tasks[i].orbSessionId === sessionId) return scene.tasks[i];
    return null;
}

// Sessions that get an orb: every open session, plus sessions ended within
// ENDED_SHOW_SEC (they settle as embers, then leave).
function visibleSessions(scene, nowMs) {
    var out = [];
    for (var i = 0; i < scene.sessions.length; i++) {
        var s = scene.sessions[i];
        if (s.liveness !== "ended") { out.push(s); continue; }
        var age = ageSec(s.endedAt, nowMs);
        if (age !== null && age >= 0 && age < ENDED_SHOW_SEC) out.push(s);
    }
    return out;
}

function fmtLeft(sec) {
    if (sec === null) return "";
    var m = Math.floor(sec / 60);
    return m >= 60 ? Math.floor(m / 60) + "h" + ("0" + (m % 60)).slice(-2) : m + "m";
}

// Everything one orb needs, from one session at client time nowMs. The
// session's liveness must already be ticked (Mandrel.tickScene) for nowMs.
function orbProps(scene, session, nowMs) {
    var liveness = session.liveness;
    var mat = material(liveness);
    var role = roleOf(session);

    var started = ageSec(session.startedAt, nowMs);
    var wrote = ageSec(session.lastActivityAt, nowMs);
    var explicitAge = ageSec(session.lastExplicitHeartbeatAt, nowMs);
    var hbAge = ageSec(session.lastHeartbeatAt, nowMs);
    var endedAge = ageSec(session.endedAt, nowMs);

    var task = heldTask(scene, session.id);
    var lease = leaseFraction(task, nowMs);
    var held = !!(task && task.claimLive && lease !== null && lease > 0);

    var untitled = !session.title;
    return {
        id: session.id, id8: session.id8, role: role, roleIndex: ROLES[role],
        liveness: liveness, serverLiveness: session.serverLiveness,
        name: untitled ? "untitled" : (session.orbName || session.displayTitle),
        untitled: untitled,
        sub: (session.role || "agent") + " · " + liveness + " · " + session.id8,
        url: session.url, threadUrl: session.threadUrl,
        spin: mat.spin, sat: mat.sat, light: mat.light, dorm: mat.dorm, lost: mat.lost,
        energy: liveness === "live" && wrote !== null ? Math.exp(-Math.max(0, wrote) / WRITE_GLOW_SEC) : 0,
        form: liveness === "forming" ? Math.max(0.12, clamp01((started || 0) / FORM_SEC)) : 1,
        ended: liveness === "ended" ? clamp01((endedAge || 0) / ENDED_COLLAPSE_SEC) : 0,
        endedFade: liveness === "ended" ? 1 - clamp01(((endedAge || 0) - ENDED_COLLAPSE_SEC) / (ENDED_SHOW_SEC - ENDED_COLLAPSE_SEC)) * 0.7 : 1,
        fuse: explicitAge === null ? -1 : clamp01(1 - explicitAge / LOST_SEC),
        neverHeartbeat: explicitAge === null && hbAge === null,
        pulse: hbAge !== null && hbAge >= 0 && hbAge < PULSE_SEC ? hbAge / PULSE_SEC : 1,
        need: liveness === "lost" && held ? 1 : 0,
        seed: seedOf(session.id),
        task: task ? {
            id: task.id, id8: task.id8, url: task.url, lane: task.lane,
            color: LANE_COLOR[task.lane] || LANE_COLOR.claimed,
            lease: lease === null ? 0 : lease, held: held,
            left: held ? fmtLeft(leaseLeftSec(task, nowMs)) : "expired"
        } : null
    };
}

// Desktop layout (Direction C): coordinators at the left of the upper band,
// workers across it, critics on the lower band below the river. Order is by
// start time so orbs keep their place as others come and go.
// Returns {id: {x, y, r}} in pixels for a w x h field.
function layout(list, w, h) {
    var unit = Math.min(w / 1920, h / 1080);
    var R = { coord: 46 * unit, worker: 37 * unit, critic: 39 * unit };
    var groups = { coord: [], worker: [], critic: [] };
    list.slice().sort(function (a, b) {
        return (toMs(a.startedAt) || 0) - (toMs(b.startedAt) || 0) || (a.id < b.id ? -1 : 1);
    }).forEach(function (s) { groups[roleOf(s)].push(s); });
    var out = {};
    function row(items, x0, x1, y, wobble, role) {
        var n = items.length;
        for (var i = 0; i < n; i++) {
            var t = n === 1 ? 0.5 : i / (n - 1);
            var x = n === 1 ? x0 : x0 + (x1 - x0) * t;
            out[items[i].id] = { x: x * w, y: (y + (i % 2 ? wobble : 0)) * h, r: R[role] };
        }
    }
    // Several coordinators stack downward at the left edge.
    for (var c = 0; c < groups.coord.length; c++)
        out[groups.coord[c].id] = { x: 0.1 * w, y: (0.33 + 0.15 * c) * h, r: R.coord };
    var nw = groups.worker.length;
    row(groups.worker, nw === 1 ? 0.33 : 0.24, Math.min(0.88, 0.24 + 0.12 * Math.max(0, nw - 1)), 0.29, 0.07, "worker");
    var nc = groups.critic.length;
    row(groups.critic, nc === 1 ? 0.52 : 0.42, Math.min(0.78, 0.42 + 0.12 * Math.max(0, nc - 1)), 0.75, -0.03, "critic");
    return out;
}

// Beams for links whose sessions both have an orb, fading by link age.
function beams(scene, nowMs, placed) {
    var out = [], seen = {};
    for (var i = 0; i < scene.links.length; i++) {
        var l = scene.links[i];
        if (!placed[l.from] || !placed[l.to]) continue;
        var age = ageSec(l.at, nowMs);
        if (age === null || age < 0 || age >= LINK_SHOW_SEC) continue;
        var key = l.from + ">" + l.to;
        if (seen[key]) continue;   // newest row per direction (links are newest first)
        seen[key] = true;
        out.push({ key: key, from: l.from, to: l.to, kind: l.kind,
                   alpha: 0.25 + 0.75 * (1 - age / LINK_SHOW_SEC) });
    }
    return out;
}

// One call per tick. tick is the data layer's tickScene: it re-derives every
// session's liveness on the client clock before anything is drawn, so states
// decay between refetches (viewer contract 22d73eeb).
function frame(scene, nowMs, w, h, tick) {
    tick(scene, nowMs);
    var list = visibleSessions(scene, nowMs);
    var placed = layout(list, w, h);
    var orbs = {}, ids = [];
    for (var i = 0; i < list.length; i++) {
        var p = orbProps(scene, list[i], nowMs);
        var at = placed[p.id];
        p.x = at.x; p.y = at.y; p.r = at.r;
        orbs[p.id] = p;
        ids.push(p.id);
    }
    return { ids: ids, orbs: orbs, beams: beams(scene, nowMs, placed) };
}
