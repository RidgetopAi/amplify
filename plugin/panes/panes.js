.pragma library
// Panes model (task bc45ee1d): live stats, the newest context, decision and task, a project
// switcher across Mandrel projects and quick links, from the scene data/mandrel.js builds
// (viewer contract 22d73eeb). Read-only: every action opens <base>/r/<id8> or a link.
// Dependency-free; the host passes the scene, the clock and the needs-you rows in.

var LANES = ["draft", "ready", "claimed", "verifying", "evidence", "merged", "deployed"];
var IN_FLIGHT = { draft: 1, ready: 1, claimed: 1, verifying: 1, evidence: 1 };
var LIVENESS = ["live", "forming", "quiet", "lost", "dormant"];
var AMP_URL = "https://ampcode.com/threads";
var HOUR = 3600000;

var EMPTY = { context: "No contexts yet", decision: "No decisions yet", task: "No tasks yet" };
var UNTITLED = { context: "Untitled context", decision: "Untitled decision", task: "Untitled task" };
var NY_KIND = { thread: ["Amp thread", "Amp threads"], merge: ["merge", "merges"], lost: ["lost holder", "lost holders"],
                decision: ["open decision", "open decisions"], blocked: ["blocked task", "blocked tasks"],
                task: ["blocked task", "blocked tasks"], session: ["lost session", "lost sessions"] };

function toMs(v) {
    if (v === null || v === undefined || v === "") return null;
    if (typeof v === "number") return v;
    var t = Date.parse(v);
    return isNaN(t) ? null : t;
}

function recordUrl(baseUrl, id8) { return baseUrl && id8 ? baseUrl + "/r/" + id8 : ""; }

// "just now", "12m ago", "3h ago", "2d ago" (to the minute, so a live pane redraws at most once a minute).
function ago(ms, nowMs) {
    if (ms === null || nowMs === null) return null;
    var m = Math.floor(Math.max(0, nowMs - ms) / 60000);
    if (m < 1) return "just now";
    if (m < 60) return m + "m ago";
    var h = Math.floor(m / 60);
    return h < 48 ? h + "h ago" : Math.floor(h / 24) + "d ago";
}

function plural(n, word) { return n + " " + (word[n === 1 ? 0 : 1]); }

// scene: buildScene output (or null). opts: { now (ms; the scene clock), needsYou: the basin's
// rows (basin.js buildBasin) when the host has them, else the scene's needsYou }.
function buildPanes(scene, opts) {
    opts = opts || {};
    var meta = (scene && scene.meta) || {};
    var nowMs = opts.now !== undefined && opts.now !== null ? toMs(opts.now) : toMs(meta.builtAt);
    var base = meta.baseUrl || "";
    var sessions = (scene && scene.sessions) || [];
    var lanes = (scene && scene.lanes) || {};
    var records = (scene && scene.records) || { context: null, decision: null, task: null, times: [] };

    // Open sessions: every session that has not ended, by liveness.
    var by = {}, open = 0;
    sessions.forEach(function (s) { if (s.liveness !== "ended") { open++; by[s.liveness] = (by[s.liveness] || 0) + 1; } });
    var parts = LIVENESS.filter(function (k) { return by[k]; }).map(function (k) { return by[k] + " " + k; });

    // Lanes (decision c1f75776): tasks per lane; in flight is every lane before merged.
    var laneRows = LANES.map(function (l) { return { lane: l, count: (lanes[l] || []).length }; });
    var flight = 0, done = 0;
    laneRows.forEach(function (r) { if (IN_FLIGHT[r.lane]) flight += r.count; else done += r.count; });
    var busiest = laneRows.filter(function (r) { return IN_FLIGHT[r.lane] && r.count; })
        .sort(function (a, b) { return b.count - a.count; })[0];

    // Activity rate: records written in the hour up to the scene clock.
    var times = (records.times || []).filter(function (t) { return nowMs === null || t <= nowMs; });
    var hour = times.filter(function (t) { return nowMs !== null && t > nowMs - HOUR; }).length;
    var last = times.length ? Math.max.apply(null, times) : null;

    // Waiting on you: the basin's rows (same count as its headline) or the scene's needsYou.
    var ny = opts.needsYou || (scene && scene.needsYou) || [];
    var kinds = {}, kindOrder = [];
    ny.forEach(function (r) { if (!kinds[r.kind]) { kinds[r.kind] = 0; kindOrder.push(r.kind); } kinds[r.kind]++; });

    var stats = [
        { key: "sessions", label: "open sessions", value: String(open),
          note: open ? parts.join(" · ") : "no session open", warm: false },
        { key: "lanes", label: "tasks in flight", value: String(flight),
          note: busiest ? "most in " + busiest.lane + " · " + done + " merged" : (done ? done + " merged, none in flight" : "no tasks yet"),
          warm: false },
        { key: "rate", label: "writes / hour", value: String(hour),
          note: last === null ? "no writes yet" : "last " + ago(last, nowMs), warm: false },
        { key: "waiting", label: "waiting on you", value: String(ny.length),
          note: ny.length ? kindOrder.map(function (k) { return plural(kinds[k], NY_KIND[k] || [k, k]); }).join(" · ") : "nothing needs you",
          warm: ny.length > 0 }
    ];

    var latest = ["context", "decision", "task"].map(function (k) {
        var r = records[k];
        if (!r) return { kind: k, key: k, label: k.toUpperCase(), title: EMPTY[k], meta: "", url: "", empty: true };
        var at = toMs(r.at);
        return { kind: k, key: k + ":" + r.id, label: (k + (r.type ? " · " + r.type : "")).toUpperCase(),
                 title: r.fullTitle || UNTITLED[k],
                 meta: r.id8 + (at !== null ? " · " + ago(at, nowMs) : "") + (r.trust ? " · " + r.trust : ""),
                 url: r.url && base ? r.url : recordUrl(base, r.id8), empty: false };
    });

    // Projects: the scene's project is current; with no project id and one project, that one.
    var plist = (scene && scene.projects) || [];
    var currentId = meta.projectId || (plist.length === 1 ? plist[0].id : null);
    var projects = plist.map(function (p) {
        return { id: p.id, id8: p.id8, name: p.name || p.id8 || "Unnamed project", url: recordUrl(base, p.id8),
                 current: !!currentId && p.id === currentId };
    }).sort(function (a, b) {
        var x = String(a.name).toLowerCase(), y = String(b.name).toLowerCase();
        return (b.current - a.current) || (x < y ? -1 : x > y ? 1 : 0);
    });
    var current = projects.filter(function (p) { return p.current; })[0] || null;

    return {
        stats: stats,
        lanes: laneRows,
        latest: latest,
        projects: projects,
        project: current ? current.name : plist.length ? "All projects" : "No project",
        projectUrl: current ? current.url : "",
        projectNote: plist.length ? plural(plist.length, ["project", "projects"]) + " in Mandrel" : "no projects visible to this viewer",
        links: [
            { key: "mandrel", label: "Mandrel", url: base, note: base ? base.replace(/^https?:\/\//, "") : "MANDREL_URL unset" },
            { key: "amp", label: "Amp", url: AMP_URL, note: "ampcode.com/threads" }
        ]
    };
}
