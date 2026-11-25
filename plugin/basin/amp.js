.pragma library
// Amp live thread state for Amplify. Dependency-free; QML imports it as a
// .pragma library file and Node loads it through data/amp/node.cjs.
//
// Primary source: amp top --stream-jsonl, one JSON object per line whenever
// the thread list changes (Amp marks the schema EXPERIMENTAL). Observed shape:
//   {"updatedAt": ISO, "reconnecting": bool,
//    "threads": [{"id": "T-…", "title", "url", "project", "status", "updatedAt",
//                 "working": bool, "executorConnected": bool}]}
// where status is "working" or a relative age such as "15m" for an idle thread.
// Fallback: amp threads list --json, an array of {id, title, updated, tree,
// messageCount}. It carries no live state, so its threads are state "unknown".
//
// Parsing is tolerant: unknown fields are ignored, malformed lines are skipped,
// and a state this file does not recognise becomes "unknown", which never
// counts as needing a human.

var THREAD_BASE = "https://ampcode.com/threads/";

// States the basin can rely on. Only the two awaiting states need a human.
var STATES = ["working", "idle", "awaiting_input", "awaiting_approval", "error", "unknown"];
var HUMAN_STATES = { awaiting_input: true, awaiting_approval: true };

var STATE_ALIASES = {
    working: "working", running: "working", streaming: "working", thinking: "working",
    busy: "working", active: "working", tool_running: "working",
    idle: "idle", done: "idle", completed: "idle", finished: "idle", ready: "idle", stopped: "idle",
    awaiting_input: "awaiting_input", waiting_for_input: "awaiting_input", needs_input: "awaiting_input",
    awaiting_user_input: "awaiting_input", awaiting_user: "awaiting_input", awaiting_answer: "awaiting_input",
    waiting_for_user: "awaiting_input", blocked_on_user: "awaiting_input", question: "awaiting_input",
    awaiting_approval: "awaiting_approval", awaiting_tool_approval: "awaiting_approval",
    needs_approval: "awaiting_approval", tool_approval: "awaiting_approval",
    waiting_for_approval: "awaiting_approval", approval_required: "awaiting_approval",
    error: "error", errored: "error", failed: "error", executor_error: "error"
};

var AGE_UNITS = { s: 1, m: 60, h: 3600, d: 86400, w: 604800, mo: 2592000, y: 31536000 };

function str(v) { return typeof v === "string" ? v : null; }

function toMs(v) {
    if (v === null || v === undefined || v === "") return null;
    if (typeof v === "number") return v;
    var t = Date.parse(v);
    return isNaN(t) ? null : t;
}

// "15m" -> 900, "2h" -> 7200, "now" -> 0; anything else -> null.
function relativeAgeSec(s) {
    s = String(s || "").trim().toLowerCase();
    if (s === "now" || s === "just now") return 0;
    var m = /^(\d+)\s*(mo|s|m|h|d|w|y)(?:\s*ago)?$/.exec(s);
    return m ? Number(m[1]) * AGE_UNITS[m[2]] : null;
}

function stateKey(s) {
    return String(s).trim().toLowerCase().replace(/[\s-]+/g, "_");
}

// One thread row -> one of STATES. The first recognised value among the agent
// state fields and the display status wins; a relative age means idle. When no
// value is recognised, working: true still means working, working: false
// means idle only if there was no status at all, and anything else is unknown.
function threadState(t) {
    if (!t || typeof t !== "object") return "unknown";
    var cands = [t.agentState, t.agent_state, t.state, t.status];
    var sawStatus = false;
    for (var i = 0; i < cands.length; i++) {
        var c = cands[i];
        if (c && typeof c === "object") c = c.state || c.status || c.kind || null;
        if (typeof c !== "string" || !c.trim()) continue;
        sawStatus = true;
        var key = stateKey(c);
        if (STATE_ALIASES[key]) return STATE_ALIASES[key];
        if (relativeAgeSec(c) !== null) return "idle";
    }
    if (t.working === true) return "working";
    if (t.working === false && !sawStatus) return "idle";
    return "unknown";
}

// "needs-you · P1 basin" -> "needs-you"
function orbNameOf(title) {
    var m = /^\s*([^·]+?)\s*·/.exec(title || "");
    return m ? m[1] : null;
}

function threadUrl(id, url) {
    if (typeof url === "string" && url.indexOf(THREAD_BASE) === 0) return url;
    return id ? THREAD_BASE + id : null;
}

function normThread(raw, source, atMs) {
    if (!raw || typeof raw !== "object") return null;
    var id = str(raw.id) || str(raw.threadId) || str(raw.thread_id);
    if (!id || !/^T-[0-9a-zA-Z-]+$/.test(id)) return null;
    var state = source === "list" ? "unknown" : threadState(raw);
    var updatedAt = str(raw.updatedAt) || str(raw.updated_at) || str(raw.updated) || null;
    var status = typeof raw.status === "string" ? raw.status : null;
    var age = status !== null ? relativeAgeSec(status) : null;
    if (age === null && updatedAt && atMs !== null && atMs !== undefined) {
        var u = toMs(updatedAt);
        if (u !== null) age = Math.max(0, (atMs - u) / 1000);
    }
    var title = str(raw.title) || null;
    return {
        id: id,
        title: title,
        orbName: orbNameOf(title),
        url: threadUrl(id, raw.url),
        project: str(raw.project) || null,
        state: state,
        rawState: status,
        needsHuman: !!HUMAN_STATES[state],
        updatedAt: updatedAt,
        ageSec: age,
        executorConnected: raw.executorConnected === undefined ? null : !!raw.executorConnected,
        source: source
    };
}

function threadsOf(rows, source, atMs) {
    var out = [], seen = {};
    if (!Array.isArray(rows)) return out;
    for (var i = 0; i < rows.length; i++) {
        var t = normThread(rows[i], source, atMs);
        if (!t || seen[t.id]) continue;
        seen[t.id] = true;
        out.push(t);
    }
    return out;
}

// One amp top --stream-jsonl line -> snapshot, or null when the line is not
// a thread-list object (blank, partial, log noise, or another schema).
function parseTopLine(line) {
    if (typeof line !== "string") return null;
    line = line.trim();
    if (!line || line.charAt(0) !== "{") return null;
    var o;
    try { o = JSON.parse(line); } catch (e) { return null; }
    if (!o || typeof o !== "object") return null;
    var rows = Array.isArray(o.threads) ? o.threads : (o.data && Array.isArray(o.data.threads) ? o.data.threads : null);
    if (!rows) return null;
    var at = toMs(o.updatedAt || o.updated_at);
    return { source: "top", updatedAt: str(o.updatedAt) || str(o.updated_at) || null,
             reconnecting: o.reconnecting === true, threads: threadsOf(rows, "top", at) };
}

// amp threads list --json output (text or parsed) -> snapshot, or null.
function parseThreadsList(input, nowMs) {
    var o = input;
    if (typeof input === "string") {
        try { o = JSON.parse(input); } catch (e) { return null; }
    }
    var rows = Array.isArray(o) ? o : (o && Array.isArray(o.threads) ? o.threads : null);
    if (!rows) return null;
    var at = nowMs === undefined ? null : toMs(nowMs);
    return { source: "list", updatedAt: at === null ? null : new Date(at).toISOString(),
             reconnecting: false, threads: threadsOf(rows, "list", at) };
}

// Incremental reader for the stream. feed(chunk) accepts any split of the byte
// stream; each complete line that parses calls onSnapshot(snapshot).
function createTopReader(onSnapshot) {
    var buf = "", stats = { lines: 0, snapshots: 0, skipped: 0 }, last = null;
    function line(l) {
        if (!l.trim()) return;
        stats.lines++;
        var s = parseTopLine(l);
        if (!s) { stats.skipped++; return; }
        stats.snapshots++;
        last = s;
        if (onSnapshot) onSnapshot(s);
    }
    return {
        feed: function (chunk) {
            buf += chunk;
            var nl;
            while ((nl = buf.search(/\r?\n/)) >= 0) {
                var l = buf.slice(0, nl);
                buf = buf.slice(nl + (buf.charAt(nl) === "\r" ? 2 : 1));
                line(l);
            }
        },
        // One already-split line, as Quickshell's SplitParser delivers it.
        line: line,
        flush: function () { var l = buf; buf = ""; line(l); },
        last: function () { return last; },
        stats: function () { return stats; }
    };
}

// The threads that wait on a human, longest-waiting first.
function waitingThreads(snapshot) {
    if (!snapshot || !snapshot.threads) return [];
    return snapshot.threads.filter(function (t) { return t.needsHuman; }).sort(function (a, b) {
        return (toMs(a.updatedAt) || 0) - (toMs(b.updatedAt) || 0);
    });
}
