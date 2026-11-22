.pragma library
// Needs-you basin model. Combines the Mandrel scene (data/mandrel.js buildScene)
// with Amp live thread state (data/amp/amp.js) into one list ordered by urgency.
// Dependency-free; the host passes everything in.
//
// Tiers (lower is more urgent), from decision 23973614 and punch 63e691ec:
//   0  Amp thread awaiting input or approval  -> opens the Amp thread
//   1  merge approval: task at stage evidence -> /r/<id8>
//   2  lost session still holding a live claim -> /r/<id8> of the session
//   3  open decision                           -> /r/<id8>
//   4  task blocked on a human                 -> /r/<id8>
// Within a tier the longest-waiting item comes first. A lost session without a
// claim, a thread in any other state (including unknown), and ended sessions
// stay out of the basin: warm is reserved for things a human must act on.

var TIER = { thread: 0, merge: 1, lost: 2, decision: 3, blocked: 4 };

var KIND_LABEL = {
    thread: "Amp thread · awaiting input",
    approval: "Amp thread · awaiting approval",
    merge: "merge · needs approval",
    lost: "session lost · holds a claim",
    decision: "decision · needs your answer",
    blocked: "task · blocked on you"
};

function toMs(v) {
    if (v === null || v === undefined || v === "") return null;
    if (typeof v === "number") return v;
    var t = Date.parse(v);
    return isNaN(t) ? null : t;
}

function id8(id) { return id ? String(id).slice(0, 8) : null; }

function recordUrl(baseUrl, id) { return id ? (baseUrl || "") + "/r/" + id8(id) : null; }

function short(s, max) {
    s = String(s || "").split("\n")[0];
    return s.length > max ? s.slice(0, max - 1) + "…" : s;
}

// "12m", "3h 05m", "2d"
function waited(sinceMs, nowMs) {
    if (sinceMs === null || nowMs === null) return null;
    var s = Math.max(0, Math.round((nowMs - sinceMs) / 1000));
    if (s < 60) return s + "s";
    var m = Math.floor(s / 60);
    if (m < 60) return m + "m";
    var h = Math.floor(m / 60);
    if (h < 24) return h + "h " + (m % 60 < 10 ? "0" : "") + (m % 60) + "m";
    return Math.floor(h / 24) + "d";
}

// scene: buildScene output (or null). amp: an amp.js snapshot (or null).
// opts: { now (ms), baseUrl, threadNow (ms; the clock for Amp rows when the
//         scene is a replay frozen at its capture time, default now) }
function buildBasin(scene, amp, opts) {
    opts = opts || {};
    var nowMs = opts.now !== undefined ? toMs(opts.now) : Date.now();
    var baseUrl = opts.baseUrl || (scene && scene.meta && scene.meta.baseUrl) || "";
    var rows = [];
    var tasks = (scene && scene.tasks) || [];
    var sessions = (scene && scene.sessions) || [];

    var threadNowMs = opts.threadNow !== undefined ? toMs(opts.threadNow) : nowMs;
    function add(r) {
        r.sinceMs = toMs(r.since);
        r.waited = waited(r.sinceMs, r.kind === "thread" ? threadNowMs : nowMs);
        rows.push(r);
    }

    // 0: Amp threads waiting on a human.
    var threads = (amp && amp.threads) || [];
    for (var i = 0; i < threads.length; i++) {
        var th = threads[i];
        if (!th.needsHuman) continue;
        var approval = th.state === "awaiting_approval";
        add({ key: "thread:" + th.id, kind: "thread", tier: TIER.thread,
              label: approval ? KIND_LABEL.approval : KIND_LABEL.thread,
              title: (th.orbName ? th.orbName + " is waiting" : short(th.title || th.id, 80)) +
                     (approval ? ": approve a tool call" : " for your answer"),
              meta: th.id.slice(0, 10) + " · " + th.state.replace("_", " "),
              url: th.url, go: "Open thread", since: th.updatedAt, threadId: th.id });
    }

    // 1: merge approval (critic passed, human merges); 4: blocked on a human.
    for (var t = 0; t < tasks.length; t++) {
        var tk = tasks[t];
        if (tk.hidden) continue;
        if (tk.stage === "evidence" && tk.status !== "completed") {
            add({ key: "merge:" + tk.id, kind: "merge", tier: TIER.merge, label: KIND_LABEL.merge,
                  title: "Merge " + tk.id8 + "? " + short(tk.title, 70), meta: tk.id8 + " · stage evidence",
                  url: tk.url || recordUrl(baseUrl, tk.id), go: "Open record", since: tk.updatedAt, taskId: tk.id });
        } else if (tk.needsYou) {
            add({ key: "blocked:" + tk.id, kind: "blocked", tier: TIER.blocked, label: KIND_LABEL.blocked,
                  title: short(tk.title, 80), meta: tk.id8 + " · blocked on human",
                  url: tk.url || recordUrl(baseUrl, tk.id), go: "Open record", since: tk.updatedAt, taskId: tk.id });
        }
    }

    // 2: lost sessions that still hold a live claim.
    for (var s = 0; s < sessions.length; s++) {
        var se = sessions[s];
        if (se.liveness !== "lost" || !se.actor) continue;
        var held = null;
        for (var c = 0; c < tasks.length && !held; c++)
            if (tasks[c].claimLive && tasks[c].claimActor === se.actor) held = tasks[c];
        if (!held) continue;
        add({ key: "lost:" + se.id, kind: "lost", tier: TIER.lost, label: KIND_LABEL.lost,
              title: (se.orbName || se.displayTitle) + " stopped heartbeating, still holds " + held.id8,
              meta: "session " + se.id8 + " · task " + held.id8,
              url: se.url || recordUrl(baseUrl, se.id), go: "Open session",
              since: se.lastExplicitHeartbeatAt || se.lastHeartbeatAt || se.lastActivityAt,
              sessionId: se.id, taskId: held.id, threadUrl: se.threadUrl });
    }

    // 3: open decisions, from the scene's needsYou list.
    var ny = (scene && scene.needsYou) || [];
    for (var d = 0; d < ny.length; d++) {
        if (ny[d].kind !== "decision") continue;
        add({ key: "decision:" + ny[d].id, kind: "decision", tier: TIER.decision, label: KIND_LABEL.decision,
              title: short(ny[d].title, 80), meta: ny[d].id8 + " · open decision",
              url: ny[d].url || recordUrl(baseUrl, ny[d].id), go: "Open in Mandrel", since: ny[d].since });
    }

    rows.sort(function (a, b) {
        if (a.tier !== b.tier) return a.tier - b.tier;
        var x = a.sinceMs === null ? Infinity : a.sinceMs, y = b.sinceMs === null ? Infinity : b.sinceMs;
        if (x !== y) return x < y ? -1 : 1;
        return a.key < b.key ? -1 : a.key > b.key ? 1 : 0;
    });
    for (var r = 0; r < rows.length; r++) rows[r].rank = r + 1;
    return rows;
}

function headline(rows) {
    var n = rows ? rows.length : 0;
    if (!n) return "Nothing needs you";
    return n === 1 ? "1 thing needs you" : n + " things need you";
}
