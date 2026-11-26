.pragma library
// Current river layout (direction c755578f, lane mapping c1f75776).
// Pure functions from the data layer's scene model (data/mandrel.js buildScene)
// to what River.qml draws. No QML, timers, or env reads here, so Node tests
// load it exactly like QML does (see test/river.test.mjs).
//
// Design space: height 1080, width = 1080 * aspect. River.qml scales it to the screen.

var LANES = ["draft", "ready", "claimed", "verifying", "evidence", "merged", "deployed"];
var LABELS = { draft: "draft", ready: "ready", claimed: "claimed", verifying: "verifying",
               evidence: "evidence", merged: "merged", deployed: "trunk" };
// Cool by stage (decision 23973614); warm is reserved for needs-you.
var COLORS = { draft: "#6b778c", ready: "#7fa6d9", claimed: "#919ef7", verifying: "#b7a0f4",
               evidence: "#e9c47c", merged: "#f1e6d0", deployed: "#f6f1e7" };
var WARM = "#ff9e74";
var PASS_GOLD = "#e9c47c";
// Tether tones by the holder's liveness (viewer contract 22d73eeb). Lost is a
// muted red, never the warm needs-you coral (decision 23973614).
var TONES = { slack: "#7d8799", lost: "#e0786a", quiet: "#8f9bd6", live: "#b4c0ff" };

var H = 1080;
var LEASE_SEC = 2700;      // Mandrel's default claim lease
// Vessel rows across the current, filled in this order. The upstream row is
// shifted half a column, so a tether dropping onto a centre-row hull passes
// through the gap between the hulls above it.
var ROWS = [0, -1, 1];
var ROW_SHIFT = [0, -0.5, -0.5];
var ROW_GAP = 34;
var HULL = 80;
var COL_W = 92;            // hull + gap
var LANE_PAD = 14;
var MIN_LANE = 130;
var MOOR_GAP = 132;        // minimum spacing between tether moorings
var MARGIN_L = 0.025;      // river starts at 2.5 % of the width

// ---------------------------------------------------------------- geometry
// Same curve as shaders/river.frag (keep in sync).
function centerY(x, W) {
    var u = x / W;
    return 548 + 46 * Math.sin(u * 5.568 + 0.4) + 22 * Math.sin(u * 13.632 + 1.7);
}
function halfWidth(x, W) {
    var u = x / W;
    return 74 + 18 * Math.sin(u * 7.68 + 2.0);
}

function laneIndex(lane) { return LANES.indexOf(lane); }

// Lane spans breathe with load: every lane keeps MIN_LANE, the rest is shared
// by the columns of vessels each lane needs.
function gates(counts, W) {
    var x = W * MARGIN_L, avail = W - x;
    var need = [], sum = 0;
    for (var i = 0; i < LANES.length; i++) {
        var n = counts[LANES[i]] || 0;
        var w = Math.ceil(n / 2) + 0.5;     // two rows preferred
        need.push(w); sum += w;
    }
    var spare = Math.max(0, avail - MIN_LANE * LANES.length);
    var out = [];
    for (var j = 0; j < LANES.length; j++) {
        var span = MIN_LANE + spare * need[j] / sum;
        out.push({ lane: LANES[j], label: LABELS[LANES[j]], color: COLORS[LANES[j]],
                   x: x, x1: x + span, count: counts[LANES[j]] || 0 });
        x += span;
    }
    return out;
}

// ---------------------------------------------------------------- claims

function toMs(v) {
    if (v === null || v === undefined || v === "") return null;
    if (typeof v === "number") return v;
    var t = Date.parse(v);
    return isNaN(t) ? null : t;
}

// Remaining lease of a claim on the scene clock. A claim the server reports
// as not live, or whose expiry has passed, is expired: its tether goes slack.
function lease(task, nowMs) {
    var exp = toMs(task.claimExpiresAt);
    if (!task.claimLive || exp === null || exp <= nowMs)
        return { expired: true, fraction: 0, remainingSec: 0 };
    var rem = (exp - nowMs) / 1000;
    return { expired: false, fraction: Math.min(1, rem / LEASE_SEC), remainingSec: rem };
}

function holderOf(scene, actor) {
    var ss = scene.sessions || [];
    for (var i = 0; i < ss.length; i++) if (ss[i].actor === actor) return ss[i];
    return null;
}

function holderName(session, actor) {
    if (session) return session.orbName || session.displayTitle;
    var a = String(actor || "unknown");
    var slash = a.lastIndexOf("/");
    a = slash >= 0 ? a.slice(slash + 1) : a;
    return a.length > 18 ? a.slice(0, 11) + "…" + a.slice(-6) : a;
}

function leaseText(l) {
    if (l.expired) return "lease expired";
    var m = Math.floor(l.remainingSec / 60);
    return m >= 1 ? m + "m left" : Math.ceil(l.remainingSec) + "s left";
}

// Colour of a tether: slack once the lease is gone, else by its holder's liveness.
function tetherTone(expired, liveness) {
    if (expired) return TONES.slack;
    if (liveness === "lost") return TONES.lost;
    if (liveness === "quiet" || liveness === "dormant") return TONES.quiet;
    return TONES.live;
}

// Moorings keep the vessels' left-to-right order and at least MOOR_GAP apart,
// so tethers never cross however many claims there are. They sit as close to
// their vessels as that allows (least-squares: pool adjacent violators on
// x_i - i * gap), so a busy lane's tethers fan out evenly around it.
function placeMoorings(xs, W) {
    var n = xs.length, blocks = [];
    for (var i = 0; i < n; i++) {
        blocks.push({ sum: xs[i] - i * MOOR_GAP, n: 1 });
        while (blocks.length > 1) {
            var b = blocks[blocks.length - 1], a = blocks[blocks.length - 2];
            if (a.sum / a.n <= b.sum / b.n) break;
            a.sum += b.sum; a.n += b.n; blocks.pop();
        }
    }
    var out = [];
    blocks.forEach(function (b) { for (var k = 0; k < b.n; k++) out.push(b.sum / b.n + out.length * MOOR_GAP); });
    var lo = 70, hi = W - 70, shift = 0;
    if (n && out[0] < lo) shift = lo - out[0];
    if (n && out[n - 1] + shift > hi) shift = hi - out[n - 1];
    return out.map(function (x) { return x + shift; });
}

// ---------------------------------------------------------------- layout

// scene: buildScene output. Returns everything River.qml draws, in design units.
function layout(scene, nowMs, W) {
    var tasks = (scene && scene.tasks) || [];
    var by = {};
    for (var l = 0; l < LANES.length; l++) by[LANES[l]] = [];
    for (var i = 0; i < tasks.length; i++) {
        var t = tasks[i];
        if (t.hidden || !t.lane || !by[t.lane]) continue;
        by[t.lane].push(t);
    }
    var counts = {};
    for (var c = 0; c < LANES.length; c++) counts[LANES[c]] = by[LANES[c]].length;
    var gs = gates(counts, W);

    var vessels = [], overflow = {};
    for (var g = 0; g < gs.length; g++) {
        var gate = gs[g], list = by[gate.lane];
        // Longest in the lane sails furthest downstream.
        list.sort(function (a, b) {
            return (toMs(a.updatedAt) || 0) - (toMs(b.updatedAt) || 0) || (a.id < b.id ? -1 : 1);
        });
        var cols = Math.max(1, Math.floor((gate.x1 - gate.x - LANE_PAD * 2 - COL_W / 2) / COL_W));
        var cap = cols * ROWS.length;
        overflow[gate.lane] = Math.max(0, list.length - cap);
        for (var k = 0; k < list.length && k < cap; k++) {
            var tk = list[k];
            var ri = Math.floor(k / cols), col = k % cols, row = ROWS[ri];
            var x = gate.x1 - LANE_PAD - COL_W * (col + 0.5 - ROW_SHIFT[ri]);
            vessels.push({ id: tk.id, id8: tk.id8, title: tk.title, url: tk.url, lane: gate.lane,
                           color: tk.needsYou ? WARM : gate.color, x: x, row: row,
                           off: row * ROW_GAP, eddy: !!tk.eddy, needsYou: !!tk.needsYou });
        }
    }

    var vx = {};
    for (var v = 0; v < vessels.length; v++) vx[vessels[v].id] = vessels[v];
    var claims = [];
    for (var q = 0; q < tasks.length; q++) {
        var tq = tasks[q];
        if (!tq.claimActor || !vx[tq.id]) continue;
        if (!tq.claimLive && tq.lane !== "claimed") continue;  // released claims leave no tether
        claims.push(tq);
    }
    claims.sort(function (a, b) { return vx[a.id].x - vx[b.id].x || (a.id < b.id ? -1 : 1); });
    var moor = placeMoorings(claims.map(function (t) { return vx[t.id].x; }), W);
    var tethers = [];
    for (var m = 0; m < claims.length; m++) {
        var tc = claims[m], ls = lease(tc, nowMs), ses = holderOf(scene, tc.claimActor);
        var mx = moor[m];
        tethers.push({ id: tc.id, id8: tc.id8, holder: holderName(ses, tc.claimActor),
                       holderUrl: ses ? (ses.threadUrl || ses.url) : null,
                       holderLiveness: ses ? ses.liveness : null,
                       mx: mx, my: centerY(mx, W) - halfWidth(mx, W) - 92,
                       expired: ls.expired, fraction: ls.fraction, remainingSec: ls.remainingSec,
                       tone: tetherTone(ls.expired, ses ? ses.liveness : null), text: leaseText(ls) });
    }

    // Flow speed and light come from real activity: tasks touched in the last
    // 15 min of scene time and sessions that are live. No activity, still water.
    var recent = 0;
    for (var r = 0; r < tasks.length; r++) {
        var u = toMs(tasks[r].updatedAt);
        if (u !== null && nowMs - u >= 0 && nowMs - u < 15 * 60 * 1000) recent++;
    }
    var live = 0, ss = (scene && scene.sessions) || [];
    for (var s = 0; s < ss.length; s++) if (ss[s].liveness === "live" || ss[s].liveness === "forming") live++;

    return { gates: gs, vessels: vessels, tethers: tethers, overflow: overflow,
             flow: Math.min(1, recent / 8), light: Math.min(1, 0.55 + live * 0.12),
             recent: recent, live: live };
}

// Water speed in design px per second for a layout's flow (0..1). Zero at zero
// flow: with no recent task updates the water stands still and River.qml stops
// its frame clock, so an idle desktop does not re-render the river.
function flowSpeed(flow) {
    return flow > 0 ? 90 * Math.min(1, flow) : 0;
}

// ---------------------------------------------------------------- replay

// Scene at virtual time ms from a snapshot (fixtures/amplify-snapshot.json) or
// a frames fixture ({meta, frames: [{at, responses}]}, latest frame at or
// before ms). M is the data layer (data/mandrel.js), passed in so Node and
// QML share this code.
function replaySceneAt(M, fixture, ms) { return M.replayScene(fixture, ms); }

// ---------------------------------------------------------------- transitions

// Lane changes between two successive scenes (refetches or replay steps).
// pass: verifying moved downstream (critic PASS, a gold ring).
// reject: verifying or evidence moved back upstream (an eddy, then the vessel
// sails back to the lane the server put it in).
function transitions(prev, next) {
    var out = [];
    if (!prev || !next) return out;
    var before = {};
    (prev.tasks || []).forEach(function (t) { if (!t.hidden) before[t.id] = t.lane; });
    (next.tasks || []).forEach(function (t) {
        if (t.hidden || !t.lane) return;
        var from = before[t.id];
        if (!from || from === t.lane) return;
        var a = laneIndex(from), b = laneIndex(t.lane), kind = b > a ? "advance" : "retreat";
        if (from === "verifying" && b > a) kind = "pass";
        else if ((from === "verifying" || from === "evidence") && b < a) kind = "reject";
        out.push({ kind: kind, taskId: t.id, id8: t.id8, from: from, to: t.lane });
    });
    return out;
}
