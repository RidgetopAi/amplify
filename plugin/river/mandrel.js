.pragma library
// Amplify data layer: one scene model from the Mandrel Command REST shapes.
// Dependency-free. Loads in QML as: import "mandrel.js" as Mandrel (.pragma library)
// and in Node through data/node.cjs. No env reads, network, or timers live here:
// the host passes the clock, the transport, and the timers in.

var LANES = ["draft", "ready", "claimed", "verifying", "evidence", "merged", "deployed"];
var STAGES = LANES;

// Viewer contract 22d73eeb liveness thresholds (seconds).
var LIVE_HEARTBEAT_SEC = 180;     // live: heartbeat <= 180 s
var LIVE_WRITE_SEC = 30 * 60;     // live: or a write < 30 min ago
var QUIET_WRITE_SEC = 10 * 60;    // quiet: heartbeat fresh, no write >= 10 min
var LOST_EXPLICIT_SEC = 10 * 60;  // lost: explicit heartbeat > 10 min old

// Worse states win when client decay and server truth disagree.
var LIVENESS_RANK = { forming: 0, live: 0, quiet: 1, dormant: 2, lost: 3, ended: 4 };

function pick(o) {
    if (!o) return undefined;
    for (var i = 1; i < arguments.length; i++) {
        var v = o[arguments[i]];
        if (v !== undefined) return v;
    }
    return undefined;
}

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

function id8(id) { return id ? String(id).slice(0, 8) : null; }

function recordUrl(baseUrl, id) {
    if (!id) return null;
    return (baseUrl || "") + "/r/" + id8(id);
}

// Accepts a bare array or the usual envelopes ({sessions:[]}, {data:[]}, ...).
function listOf(resp, key) {
    if (!resp) return [];
    if (Array.isArray(resp)) return resp;
    var keys = [key, "data", "results", "items", "rows"];
    for (var i = 0; i < keys.length; i++) {
        var v = resp[keys[i]];
        if (Array.isArray(v)) return v;
        if (v && typeof v === "object" && Array.isArray(v[key])) return v[key];
    }
    return [];
}

function objectOf(resp, key) {
    if (!resp || Array.isArray(resp)) return resp || null;
    if (resp[key] && typeof resp[key] === "object" && !Array.isArray(resp[key])) return resp[key];
    if (resp.data && typeof resp.data === "object" && !Array.isArray(resp.data)) return resp.data;
    return resp;
}

// ---------------------------------------------------------------- config

// env is a plain object; the host reads the environment (see node.cjs).
function resolveConfig(env) {
    env = env || {};
    var url = String(env.MANDREL_URL || "").trim().replace(/\/+$/, "");
    var token = String(env.MANDREL_VIEWER_TOKEN || "").trim();
    var cfg = { baseUrl: url || null, token: token || null, mode: "replay", reason: null };
    if (token && token.indexOf("mdl_") === 0) {
        cfg.token = null;
        cfg.reason = "mdl_ tokens are MCP read-write tokens, not viewer tokens; using replay";
    } else if (!url || !token) {
        cfg.reason = "MANDREL_URL or MANDREL_VIEWER_TOKEN unset; using replay";
    } else {
        cfg.mode = "live";
    }
    return cfg;
}

// The user's config file (task 45de8d89): $XDG_CONFIG_HOME/amplify/mandrel.env, else
// ~/.config/amplify/mandrel.env. It lives in the user's home, never in the repo or the
// installed plugin folder (which is a clone of the repo), so a token is never committed.
// env holds XDG_CONFIG_HOME and HOME as the host read them; null when neither is set.
function configFilePath(env) {
    env = env || {};
    var xdg = String(env.XDG_CONFIG_HOME || "").trim();
    var home = String(env.HOME || "").trim();
    var dir = xdg.charAt(0) === "/" ? xdg : (home.charAt(0) === "/" ? home.replace(/\/+$/, "") + "/.config" : "");
    return dir ? dir.replace(/\/+$/, "") + "/amplify/mandrel.env" : null;
}

// KEY=VALUE lines, as a shell env file: blank lines and # comments skipped, an optional
// "export ", values optionally in matching single or double quotes. Only MANDREL_URL and
// MANDREL_VIEWER_TOKEN are kept.
function parseConfigFile(text) {
    var out = {};
    var lines = String(text || "").split(/\r?\n/);
    for (var i = 0; i < lines.length; i++) {
        var m = lines[i].match(/^\s*(?:export\s+)?(MANDREL_URL|MANDREL_VIEWER_TOKEN)\s*=\s*(.*?)\s*$/);
        if (!m) continue;
        var v = m[2];
        var q = v.match(/^(["'])(.*)\1$/);
        out[m[1]] = q ? q[2] : v.replace(/\s+#.*$/, "");
    }
    return out;
}

// The config from the environment and the config file's text (null or "" when missing or
// unreadable): each variable set in the environment wins over the file. Anything missing
// replays (resolveConfig); this never throws.
function configFrom(env, fileText) {
    env = env || {};
    var file = parseConfigFile(fileText);
    var merged = {
        MANDREL_URL: String(env.MANDREL_URL || "").trim() || file.MANDREL_URL || "",
        MANDREL_VIEWER_TOKEN: String(env.MANDREL_VIEWER_TOKEN || "").trim() || file.MANDREL_VIEWER_TOKEN || ""
    };
    return resolveConfig(merged);
}

function authHeaders(cfg) {
    var h = { "Accept": "application/json" };
    if (cfg && cfg.token) h["Authorization"] = "Bearer " + cfg.token;
    return h;
}

// ---------------------------------------------------------------- liveness

function writeCount(s) {
    var n = 0;
    var keys = [["context_count", "contextCount"], ["task_count", "taskCount"],
                ["decision_count", "decisionCount"], ["files_modified_count", "filesModifiedCount"]];
    for (var i = 0; i < keys.length; i++) n += Number(pick(s, keys[i][0], keys[i][1]) || 0);
    return n;
}

// Client-clock liveness from timestamps alone.
function clientLiveness(s, nowMs) {
    var state = pick(s, "state");
    if (pick(s, "ended_at", "endedAt") || state === "ended") return "ended";

    var explicitAge = ageSec(pick(s, "last_explicit_heartbeat_at", "lastExplicitHeartbeatAt"), nowMs);
    if (explicitAge !== null && explicitAge > LOST_EXPLICIT_SEC) return "lost";

    var hbAge = ageSec(pick(s, "last_heartbeat_at", "lastHeartbeatAt"), nowMs);
    var writeAge = ageSec(pick(s, "last_write_at", "lastWriteAt", "last_activity_at", "lastActivityAt"), nowMs);
    var hbFresh = hbAge !== null && hbAge <= LIVE_HEARTBEAT_SEC;

    // Proven alive by a fresh heartbeat or a write in the last 30 min; otherwise dormant.
    if (!hbFresh && !(writeAge !== null && writeAge < LIVE_WRITE_SEC)) return "dormant";
    // Just connected and nothing written yet.
    if (pick(s, "creation_reason", "creationReason") === "connect" && writeCount(s) === 0) return "forming";
    // Heartbeat fresh but no write for 10 min or more. Without a fresh heartbeat,
    // a write under 30 min is still live (quiet needs a heartbeat).
    if (hbFresh && (writeAge === null || writeAge >= QUIET_WRITE_SEC)) return "quiet";
    return "live";
}

// Server liveness is truth at fetch time; between refetches the client clock may
// only decay it. The worse of the two wins (forming counts as live).
function sessionLiveness(s, nowMs) {
    var client = clientLiveness(s, nowMs);
    var server = pick(s, "liveness");
    if (!server || LIVENESS_RANK[server] === undefined) return client;
    if (LIVENESS_RANK[server] > LIVENESS_RANK[client]) return server;
    return client;
}

// ---------------------------------------------------------------- lanes

// Decision c1f75776.
function taskLane(t) {
    var status = pick(t, "status");
    var stage = pick(t, "stage");
    var claimLive = !!pick(t, "claim_live", "claimLive");
    var blockedOn = pick(t, "blocked_on", "blockedOn");
    var r = { lane: null, eddy: false, needsYou: false, hidden: false };

    if (status === "cancelled") { r.hidden = true; return r; }

    if (stage && STAGES.indexOf(stage) >= 0) r.lane = stage;
    else if (status === "todo") r.lane = "ready";
    else if (status === "in_progress") r.lane = claimLive ? "claimed" : "verifying";
    else if (status === "completed") r.lane = "merged";
    else if (status === "blocked") r.lane = claimLive ? "claimed" : "ready";
    else r.lane = "ready";

    if (status === "blocked") r.eddy = true;
    if (blockedOn === "human" && status !== "completed") r.needsYou = true;
    return r;
}

// ---------------------------------------------------------------- scene

function parseActor(actor) {
    // "brian/amp-worker-t-01a2...-..." -> role worker, thread T-01a2...
    var m = /amp-(coord|worker|critic)-(t-[0-9a-f-]{36})/i.exec(actor || "");
    if (!m) return { role: null, threadId: null };
    return { role: m[1].toLowerCase(), threadId: "T-" + m[2].slice(2) };
}

function parseTitle(title) {
    // "data-core · worker" -> name data-core, role worker
    var m = /^\s*([^·]+?)\s*·\s*(\S+)\s*$/.exec(title || "");
    return m ? { name: m[1], role: m[2] } : { name: null, role: null };
}

function normSession(raw, detail, baseUrl, nowMs) {
    var s = {};
    var k;
    for (k in raw) s[k] = raw[k];
    if (detail) for (k in detail) if (detail[k] !== undefined && detail[k] !== null) s[k] = detail[k];

    var id = pick(s, "id", "session_id", "sessionId");
    var actor = pick(s, "actor", "actor_id", "actorId") || null;
    var title = pick(s, "title") || null;
    var fromActor = parseActor(actor);
    var fromTitle = parseTitle(title);
    var role = fromTitle.role || fromActor.role;
    return {
        id: id, id8: id8(id), url: recordUrl(baseUrl, id),
        title: title,
        displayTitle: title || fromTitle.name || (fromActor.role ? fromActor.role + " " + id8(id) : "untitled " + id8(id)),
        actor: actor, role: role, orbName: fromTitle.name,
        threadId: fromActor.threadId,
        threadUrl: fromActor.threadId ? "https://ampcode.com/threads/" + fromActor.threadId : null,
        projectId: pick(s, "project_id", "projectId") || null,
        goal: pick(s, "goal") || null,
        serverLiveness: pick(s, "liveness") || null,
        liveness: sessionLiveness(s, nowMs),
        creationReason: pick(s, "creation_reason", "creationReason") || null,
        startedAt: pick(s, "started_at", "startedAt", "created_at", "createdAt") || null,
        endedAt: pick(s, "ended_at", "endedAt") || null,
        lastActivityAt: pick(s, "last_activity_at", "lastActivityAt") || null,
        lastHeartbeatAt: pick(s, "last_heartbeat_at", "lastHeartbeatAt") || null,
        lastExplicitHeartbeatAt: pick(s, "last_explicit_heartbeat_at", "lastExplicitHeartbeatAt") || null,
        counts: {
            contexts: Number(pick(s, "context_count", "contextCount") || 0),
            tasks: Number(pick(s, "task_count", "taskCount") || 0),
            decisions: Number(pick(s, "decision_count", "decisionCount") || 0),
            files: Number(pick(s, "files_modified_count", "filesModifiedCount") || 0)
        },
        totalTokens: pick(s, "total_tokens", "totalTokens") !== undefined ? String(pick(s, "total_tokens", "totalTokens")) : null,
        latestActivity: pick(s, "latest_activity", "latestActivity") || null,
        punchActivity: pick(s, "punch_activity", "punchActivity") || null,
        loopActivities: pick(s, "loop_activities", "loopActivities") || [],
        _raw: s
    };
}

function linkRows(s, key, camel) {
    var v = pick(s, key, camel);
    if (!v) return [];
    return Array.isArray(v) ? v : [v];
}

function buildLinks(sessions) {
    var known = {};
    for (var i = 0; i < sessions.length; i++) known[sessions[i].id] = true;
    var seen = {}, out = [];
    function add(from, to, row) {
        if (!from || !to || from === to) return;
        var kind = pick(row, "kind") || "note";
        var at = pick(row, "at", "created_at", "createdAt") || null;
        var key = from + "|" + to + "|" + kind + "|" + at;
        if (seen[key]) return;
        seen[key] = true;
        out.push({ from: from, to: to, kind: kind, at: at, detail: pick(row, "detail") || null,
                   taskId: pick(row, "task_id", "taskId") || null,
                   resolved: !!(known[from] && known[to]) });
    }
    for (var j = 0; j < sessions.length; j++) {
        var s = sessions[j]._raw;
        var outs = linkRows(s, "outbound_link_activity", "outboundLinkActivity");
        for (var a = 0; a < outs.length; a++)
            add(sessions[j].id, pick(outs[a], "to_session", "toSession", "to_session_id"), outs[a]);
        // Inbound rows name the other session; which field holds it is not pinned in
        // the contract, so take the first candidate that is not this session.
        var ins = linkRows(s, "inbound_link_activity", "inboundLinkActivity");
        for (var b = 0; b < ins.length; b++) {
            var cands = ["from_session", "fromSession", "session_id", "sessionId", "to_session", "toSession"];
            var other = null;
            for (var c = 0; c < cands.length && !other; c++) {
                var v = ins[b][cands[c]];
                if (v && v !== sessions[j].id) other = v;
            }
            add(other, sessions[j].id, ins[b]);
        }
    }
    out.sort(function (x, y) { return (toMs(y.at) || 0) - (toMs(x.at) || 0); });
    return out;
}

function normTask(raw, baseUrl) {
    var id = pick(raw, "id", "task_id", "taskId");
    var lane = taskLane(raw);
    return {
        id: id, id8: id8(id), url: recordUrl(baseUrl, id),
        title: pick(raw, "title") || "untitled task",
        status: pick(raw, "status") || null,
        stage: pick(raw, "stage") || null,
        lane: lane.lane, eddy: lane.eddy, needsYou: lane.needsYou, hidden: lane.hidden,
        priority: pick(raw, "priority") || null,
        progress: Number(pick(raw, "progress") || 0),
        assignedTo: pick(raw, "assigned_to", "assignedTo") || null,
        claimActor: pick(raw, "claim_actor", "claimActor") || null,
        claimLive: !!pick(raw, "claim_live", "claimLive"),
        claimExpiresAt: pick(raw, "claim_expires_at", "claimExpiresAt") || null,
        blockedOn: pick(raw, "blocked_on", "blockedOn") || null,
        dependencies: pick(raw, "dependencies") || [],
        tags: pick(raw, "tags") || [],
        createdAt: pick(raw, "created_at", "createdAt") || null,
        updatedAt: pick(raw, "updated_at", "updatedAt") || null,
        orbSessionId: null
    };
}

function firstLine(text, max) {
    var s = String(text || "").split("\n")[0];
    return s.length > max ? s.slice(0, max - 1) + "…" : s;
}

// inputs: { sessions, sessionDetails: {id: resp}, tasks, contexts, decisions, projects }
// opts:   { now (ms), baseUrl, projectId, mode, label, latestLimit, fetchedAt }
function buildScene(inputs, opts) {
    inputs = inputs || {};
    opts = opts || {};
    var nowMs = opts.now !== undefined ? toMs(opts.now) : Date.now();
    var baseUrl = opts.baseUrl || "";
    var details = inputs.sessionDetails || {};

    var rawSessions = listOf(inputs.sessions, "sessions");
    var sessions = [];
    for (var i = 0; i < rawSessions.length; i++) {
        var sid = pick(rawSessions[i], "id", "session_id", "sessionId");
        sessions.push(normSession(rawSessions[i], objectOf(details[sid], "session"), baseUrl, nowMs));
    }
    if (opts.projectId) sessions = sessions.filter(function (s) { return !s.projectId || s.projectId === opts.projectId; });
    sessions.sort(function (a, b) { return (toMs(b.lastActivityAt) || 0) - (toMs(a.lastActivityAt) || 0); });

    var tasks = listOf(inputs.tasks, "tasks").map(function (t) { return normTask(t, baseUrl); });
    var byActor = {};
    for (var s1 = 0; s1 < sessions.length; s1++)
        if (sessions[s1].actor && sessions[s1].liveness !== "ended") byActor[sessions[s1].actor] = sessions[s1];

    var lanes = {};
    for (var l = 0; l < LANES.length; l++) lanes[LANES[l]] = [];
    for (var t1 = 0; t1 < tasks.length; t1++) {
        var t = tasks[t1];
        if (t.claimLive && t.claimActor && byActor[t.claimActor]) t.orbSessionId = byActor[t.claimActor].id;
        if (!t.hidden && t.lane) lanes[t.lane].push(t);
    }

    var orbs = [];
    for (var o = 0; o < sessions.length; o++) {
        var se = sessions[o];
        if (se.liveness === "ended") continue;
        var orbTask = null;
        for (var t2 = 0; t2 < tasks.length; t2++) if (tasks[t2].orbSessionId === se.id) { orbTask = tasks[t2].id; break; }
        var pa = se.punchActivity;
        if (!orbTask && pa) orbTask = pick(pa, "task_id", "taskId", "id") || null;
        orbs.push({ sessionId: se.id, name: se.orbName || se.displayTitle, role: se.role,
                    liveness: se.liveness, threadId: se.threadId, threadUrl: se.threadUrl,
                    taskId: orbTask, url: se.url });
    }

    var contexts = listOf(inputs.contexts, "contexts");
    var decisions = listOf(inputs.decisions, "decisions");
    var latest = [];
    contexts.forEach(function (c) {
        var id = pick(c, "id");
        latest.push({ kind: "context", type: pick(c, "context_type", "contextType", "type") || null, id: id, id8: id8(id),
                      url: recordUrl(baseUrl, id), title: firstLine(pick(c, "content", "title"), 120),
                      fullTitle: firstLine(pick(c, "content", "title"), Infinity) || null,
                      at: pick(c, "created_at", "createdAt") || null, sessionId: pick(c, "session_id", "sessionId") || null,
                      trust: pick(c, "trust") && typeof c.trust === "object" ? c.trust.band : (pick(c, "trust") || null) });
    });
    decisions.forEach(function (d) {
        var id = pick(d, "id");
        latest.push({ kind: "decision", type: pick(d, "decision_type", "decisionType") || null, id: id, id8: id8(id),
                      url: recordUrl(baseUrl, id), title: firstLine(pick(d, "title"), 120),
                      fullTitle: firstLine(pick(d, "title"), Infinity) || null,
                      at: pick(d, "created_at", "createdAt", "decision_date", "decisionDate") || null,
                      sessionId: pick(d, "session_id", "sessionId") || null, trust: null });
    });
    tasks.forEach(function (tk) {
        latest.push({ kind: "task", type: tk.status, id: tk.id, id8: tk.id8, url: tk.url, title: firstLine(tk.title, 120),
                      fullTitle: firstLine(tk.title, Infinity) || null, at: tk.createdAt, sessionId: null, trust: null });
    });
    latest.sort(function (a, b) { return (toMs(b.at) || 0) - (toMs(a.at) || 0); });
    // records (panes, task bc45ee1d): the newest context, decision and task (fullTitle is the
    // whole first line; title is cut at 120), and every record's created time, newest first,
    // taken before latest is cut to latestLimit.
    var records = { context: null, decision: null, task: null, times: [] };
    latest.forEach(function (r) {
        var m = toMs(r.at);
        if (m !== null) records.times.push(m);
        if (records[r.kind] === null) records[r.kind] = r;
    });
    // allRecords: every record, newest first, before the cut; the focused orb (plugin/focus,
    // task 85ff482a) reads one session's own. records above keeps the panes shape.
    var allRecords = latest.slice();
    latest = latest.slice(0, opts.latestLimit || 12);

    var needsYou = [];
    tasks.forEach(function (tk) {
        if (tk.needsYou) needsYou.push({ kind: "task", id: tk.id, id8: tk.id8, url: tk.url, title: tk.title,
                                         reason: "blocked on human", since: tk.updatedAt });
    });
    decisions.forEach(function (d) {
        if (pick(d, "answer_status", "answerStatus") === "open") {
            var id = pick(d, "id");
            needsYou.push({ kind: "decision", id: id, id8: id8(id), url: recordUrl(baseUrl, id),
                            title: firstLine(pick(d, "title"), 120), reason: "open decision",
                            since: pick(d, "created_at", "createdAt", "decision_date", "decisionDate") || null });
        }
    });
    sessions.forEach(function (se) {
        if (se.liveness === "lost") needsYou.push({ kind: "session", id: se.id, id8: se.id8, url: se.url,
                                                    title: se.displayTitle, reason: "lost heartbeat",
                                                    since: se.lastExplicitHeartbeatAt });
    });
    needsYou.sort(function (a, b) { return (toMs(a.since) || 0) - (toMs(b.since) || 0); });

    var projects = listOf(inputs.projects, "projects").map(function (p) {
        var id = pick(p, "id", "project_id", "projectId");
        return { id: id, id8: id8(id), name: pick(p, "name") || id8(id), url: recordUrl(baseUrl, id),
                 current: !!opts.projectId && id === opts.projectId };
    });

    var links = buildLinks(sessions);
    var livenessCounts = { forming: 0, live: 0, quiet: 0, lost: 0, dormant: 0, ended: 0 };
    sessions.forEach(function (se) { livenessCounts[se.liveness]++; delete se._raw; });

    var scene = {
        meta: { mode: opts.mode || "live", label: opts.label || null, baseUrl: baseUrl || null,
                projectId: opts.projectId || null, builtAt: new Date(nowMs).toISOString(),
                fetchedAt: opts.fetchedAt || new Date(nowMs).toISOString() },
        projects: projects,
        sessions: sessions,
        orbs: orbs,
        links: links,
        tasks: tasks,
        lanes: lanes,
        latest: latest,
        records: records,
        allRecords: allRecords,
        needsYou: needsYou,
        counts: { liveness: livenessCounts, tasks: tasks.filter(function (x) { return !x.hidden; }).length,
                  needsYou: needsYou.length }
    };
    return scene;
}

// Re-derive time-driven state between refetches (call per animation tick).
function tickScene(scene, nowMs, rawSessionsById) {
    var counts = { forming: 0, live: 0, quiet: 0, lost: 0, dormant: 0, ended: 0 };
    for (var i = 0; i < scene.sessions.length; i++) {
        var s = scene.sessions[i];
        var raw = (rawSessionsById && rawSessionsById[s.id]) || {
            liveness: s.serverLiveness, ended_at: s.endedAt, last_activity_at: s.lastActivityAt,
            last_heartbeat_at: s.lastHeartbeatAt, last_explicit_heartbeat_at: s.lastExplicitHeartbeatAt,
            creation_reason: s.creationReason, context_count: s.counts.contexts, task_count: s.counts.tasks,
            decision_count: s.counts.decisions, files_modified_count: s.counts.files
        };
        s.liveness = sessionLiveness(raw, nowMs);
        counts[s.liveness]++;
    }
    for (var j = 0; j < scene.orbs.length; j++)
        for (var k = 0; k < scene.sessions.length; k++)
            if (scene.sessions[k].id === scene.orbs[j].sessionId) scene.orbs[j].liveness = scene.sessions[k].liveness;
    scene.counts.liveness = counts;
    return scene;
}

// ---------------------------------------------------------------- client

var ENDPOINTS = {
    sessions: "/api/sessions", tasks: "/api/tasks", contexts: "/api/contexts",
    decisions: "/api/decisions", projects: "/api/projects"
};

// fetchJson(path) -> Promise<json>. Live: HTTP with the viewer token. Replay: the snapshot.
function loadScene(fetchJson, opts) {
    opts = opts || {};
    var names = Object.keys(ENDPOINTS);
    return Promise.all(names.map(function (n) { return fetchJson(ENDPOINTS[n]); })).then(function (rs) {
        var inputs = {};
        for (var i = 0; i < names.length; i++) inputs[names[i]] = rs[i];
        var open = listOf(inputs.sessions, "sessions").filter(function (s) {
            return !pick(s, "ended_at", "endedAt") && pick(s, "state") !== "ended";
        }).slice(0, opts.maxDetails || 12);
        return Promise.all(open.map(function (s) {
            var id = pick(s, "id", "session_id", "sessionId");
            return Promise.resolve(fetchJson("/api/sessions/" + id)).then(
                function (d) { return [id, d]; }, function () { return [id, null]; });
        })).then(function (pairs) {
            inputs.sessionDetails = {};
            pairs.forEach(function (p) { if (p[1]) inputs.sessionDetails[p[0]] = p[1]; });
            return buildScene(inputs, opts);
        });
    });
}

// ---------------------------------------------------------------- SSE

// Incremental text/event-stream parser. feed(chunk) calls onEvent({event, data, id})
// for each dispatched event and onComment(text) for ":" lines.
function createSseParser(onEvent, onComment) {
    var buf = "", data = [], evt = null, lastId = null;
    function dispatch() {
        if (data.length || evt) onEvent({ event: evt || "message", data: data.join("\n"), id: lastId });
        data = []; evt = null;
    }
    return {
        feed: function (chunk) {
            buf += chunk;
            var nl;
            while ((nl = buf.search(/\r\n|\r|\n/)) >= 0) {
                var line = buf.slice(0, nl);
                buf = buf.slice(nl + (buf.substr(nl, 2) === "\r\n" ? 2 : 1));
                if (line === "") { dispatch(); continue; }
                if (line.charAt(0) === ":") { if (onComment) onComment(line.slice(1).trim()); continue; }
                var c = line.indexOf(":");
                var field = c < 0 ? line : line.slice(0, c);
                var value = c < 0 ? "" : line.slice(c + 1).replace(/^ /, "");
                if (field === "data") data.push(value);
                else if (field === "event") evt = value;
                else if (field === "id") lastId = value;
            }
        }
    };
}

var HEARTBEAT_EVENTS = { heartbeat: true, ping: true, keepalive: true, hello: true, ready: true };

// SSE live client: POST /api/events/ticket, then GET /api/events?ticket=...
// Entity events schedule one debounced onChange (refetch). Silence longer than
// heartbeatTimeoutMs drops the stream and reconnects with a fresh ticket.
// transport: { postJson(url, headers, body) -> Promise<json>,
//              openStream(url, headers, onChunk, onEnd(err)) -> { close() } }
// timers:    { setTimeout(fn, ms) -> handle, clearTimeout(handle) }
function createEventStream(o) {
    var cfg = o.config, transport = o.transport, timers = o.timers;
    var debounceMs = o.debounceMs !== undefined ? o.debounceMs : 750;
    var heartbeatTimeoutMs = o.heartbeatTimeoutMs !== undefined ? o.heartbeatTimeoutMs : 45000;
    var reconnectMs = o.reconnectMs !== undefined ? o.reconnectMs : 2000;
    var onChange = o.onChange || function () {};
    var onState = o.onState || function () {};
    var onEvent = o.onEvent || function () {};

    var stream = null, debounceT = null, watchdogT = null, reconnectT = null;
    var stopped = true, generation = 0;
    var stats = { tickets: 0, connects: 0, reconnects: 0, events: 0, refetches: 0, heartbeats: 0 };
    var state = "stopped";

    function setState(s, why) { state = s; onState(s, why); }

    function scheduleRefetch() {
        if (debounceT !== null) timers.clearTimeout(debounceT);
        debounceT = timers.setTimeout(function () {
            debounceT = null;
            if (stopped) return;
            stats.refetches++;
            onChange();
        }, debounceMs);
    }

    function armWatchdog(gen) {
        if (watchdogT !== null) timers.clearTimeout(watchdogT);
        watchdogT = timers.setTimeout(function () {
            watchdogT = null;
            if (gen === generation) drop("heartbeat timeout");
        }, heartbeatTimeoutMs);
    }

    function drop(why) {
        if (stopped) return;
        generation++;
        if (stream) { try { stream.close(); } catch (e) {} stream = null; }
        if (watchdogT !== null) { timers.clearTimeout(watchdogT); watchdogT = null; }
        setState("reconnecting", why);
        if (reconnectT !== null) timers.clearTimeout(reconnectT);
        reconnectT = timers.setTimeout(function () { reconnectT = null; stats.reconnects++; connect(); }, reconnectMs);
    }

    function connect() {
        if (stopped) return;
        var gen = ++generation;
        setState("connecting", null);
        var headers = authHeaders(cfg);
        Promise.resolve(transport.postJson(cfg.baseUrl + "/api/events/ticket", headers, {})).then(function (res) {
            if (stopped || gen !== generation) return;
            var ticket = res && (res.ticket || (res.data && res.data.ticket));
            if (!ticket) throw new Error("no ticket in response");
            stats.tickets++;
            var parser = createSseParser(function (ev) {
                if (gen !== generation) return;
                armWatchdog(gen);
                if (HEARTBEAT_EVENTS[ev.event]) { stats.heartbeats++; return; }
                stats.events++;
                var payload = null;
                try { payload = ev.data ? JSON.parse(ev.data) : null; } catch (e) { payload = ev.data; }
                onEvent({ event: ev.event, data: payload, id: ev.id });
                scheduleRefetch();
            }, function () { if (gen === generation) { stats.heartbeats++; armWatchdog(gen); } });
            var url = cfg.baseUrl + "/api/events?ticket=" + encodeURIComponent(ticket);
            var sh = {};
            for (var k in headers) if (k !== "Authorization") sh[k] = headers[k];
            sh["Accept"] = "text/event-stream";
            stream = transport.openStream(url, sh, function (chunk) {
                if (gen === generation) parser.feed(chunk);
            }, function (err) {
                if (gen === generation) drop(err ? String(err.message || err) : "stream ended");
            });
            stats.connects++;
            armWatchdog(gen);
            setState("open", null);
            scheduleRefetch(); // catch up on anything missed while disconnected
        }).catch(function (err) {
            if (gen === generation) drop("ticket failed: " + String(err && err.message || err));
        });
    }

    return {
        start: function () { if (!stopped) return; stopped = false; connect(); },
        stop: function () {
            stopped = true; generation++;
            if (stream) { try { stream.close(); } catch (e) {} stream = null; }
            [debounceT, watchdogT, reconnectT].forEach(function (h) { if (h !== null) timers.clearTimeout(h); });
            debounceT = watchdogT = reconnectT = null;
            setState("stopped", null);
        },
        state: function () { return state; },
        stats: function () { return stats; }
    };
}

// ---------------------------------------------------------------- replay

// One line naming the capture a component replays (task 844a60aa): its capture time,
// session and task counts, and an FNV-1a hash of its records, so components that log it
// on load (orbs, river, basin) can be checked to replay one snapshot (tools/headless-shot.sh).
function replaySource(snapshot) {
    var r = snapshot.responses || {};
    var s = JSON.stringify(r), h = 0x811c9dc5;
    for (var i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; }
    return "captured " + (snapshot.meta && snapshot.meta.captured_at) +
        " sessions " + listOf(r["/api/sessions"], "sessions").length +
        " tasks " + listOf(r["/api/tasks"], "tasks").length +
        " records " + ("0000000" + h.toString(16)).slice(-8);
}

// A snapshot (fixtures/amplify-snapshot.json) holds REST-shaped responses captured
// at meta.captured_at. replayResponses(snapshot, t) rewinds them to virtual time t:
// records created after t disappear, sessions end only once t passes ended_at, and
// tasks closed after t show as still open.
function replayResponses(snapshot, atMs) {
    var r = snapshot.responses;
    var t = toMs(atMs);
    function before(v) { var m = toMs(v); return m !== null && m <= t; }

    var sessions = listOf(r["/api/sessions"], "sessions").filter(function (s) {
        return before(pick(s, "started_at", "created_at"));
    }).map(function (s) {
        var c = {};
        for (var k in s) c[k] = s[k];
        if (c.ended_at && !before(c.ended_at)) { c.ended_at = null; c.state = "active"; }
        if (c.last_activity_at && !before(c.last_activity_at)) c.last_activity_at = new Date(t).toISOString();
        c.liveness = null; // the client clock decides during replay
        return c;
    });

    var tasks = listOf(r["/api/tasks"], "tasks").filter(function (x) { return before(x.created_at); }).map(function (x) {
        var c = {};
        for (var k in x) c[k] = x[k];
        if (c.completed_at && !before(c.completed_at)) {
            c.completed_at = null;
            c.status = before(c.started_at) ? "in_progress" : "todo";
            c.stage = before(c.started_at) ? "claimed" : "ready";
        }
        if (c.claim_live && !before(c.started_at)) { c.claim_live = false; c.status = "todo"; c.stage = c.stage === "claimed" ? "ready" : c.stage; }
        return c;
    });

    var contexts = listOf(r["/api/contexts"], "contexts").filter(function (x) { return before(x.created_at); });
    var decisions = listOf(r["/api/decisions"], "decisions").filter(function (x) { return before(x.created_at); });
    // Session bodies carry the rewound session row, and only for sessions that exist at t.
    var details = {};
    var d = r["/api/sessions/:id"] || {};
    sessions.forEach(function (s) {
        var body = d[s.id];
        if (!body) return;
        var c = {};
        for (var k in body) c[k] = body[k];
        c.session = s;
        details[s.id] = c;
    });
    return { sessions: sessions, tasks: tasks, contexts: contexts, decisions: decisions,
             projects: r["/api/projects"], sessionDetails: details };
}

// fetchJson over a replayed snapshot, so loadScene works unchanged in demo mode.
function replayFetcher(snapshot, clock) {
    return function (path) {
        var at = clock();
        var rs = replayResponses(snapshot, at);
        var m = /^\/api\/sessions\/(.+)$/.exec(path);
        if (m) return Promise.resolve(rs.sessionDetails[m[1]] || null);
        var key = path.replace(/^\/api\//, "");
        return Promise.resolve(rs[key] !== undefined ? rs[key] : null);
    };
}

// The scene of a replayed snapshot at virtual time ms: its responses rewound to ms (a
// frames fixture, such as plugin/river/test/busy-frames.json, uses the last frame at or
// before ms), labelled as a replay.
function replayScene(snapshot, ms) {
    var snap = snapshot;
    if (snapshot.frames) {
        var f = snapshot.frames[0];
        for (var i = 0; i < snapshot.frames.length; i++)
            if (toMs(snapshot.frames[i].at) <= ms) f = snapshot.frames[i];
        snap = { meta: snapshot.meta, responses: f.responses };
    }
    return buildScene(replayResponses(snap, ms), {
        now: ms, mode: "replay", label: "REPLAYED SNAPSHOT · " + (snapshot.meta.label || ""),
        baseUrl: snapshot.meta.base_url || "", projectId: snapshot.meta.project_id || null,
        fetchedAt: snapshot.meta.captured_at
    });
}

// ---------------------------------------------------------------- scene time

// The last write a scene shows at time atMs: the newest session activity, task update or
// record at or before atMs, as ms (null when there is none).
function lastActivityMs(scene, atMs) {
    var at = toMs(atMs), best = null;
    function see(v) { var m = toMs(v); if (m !== null && m <= at && (best === null || m > best)) best = m; }
    (scene.sessions || []).forEach(function (s) { see(s.lastActivityAt); });
    (scene.tasks || []).forEach(function (t) { see(t.updatedAt || t.createdAt); });
    (scene.latest || []).forEach(function (r) { see(r.at); });
    return best;
}

function minuteOf(ms) { return new Date(ms).toISOString().slice(0, 16).replace("T", " ") + "Z"; }

// The one caption (task 679fbbc5, decision cfce981b): orbs, river and basin all draw this
// for the scene clock's scene and the moment they show, so they read the same text:
//   REPLAYED SNAPSHOT · <label> · as of <moment> · last activity <time>
//   LIVE · <base url> · as of <moment> · last activity <time>
// To the minute, so a live caption changes (and redraws) at most once a minute.
function sceneCaption(scene, atMs) {
    if (!scene || !scene.meta) return "";
    var m = scene.meta, at = toMs(atMs), last = lastActivityMs(scene, at);
    return (m.mode === "replay" ? m.label : "LIVE · " + (m.baseUrl || "")) +
        " · as of " + minuteOf(at) + " · last activity " + (last === null ? "none" : minuteOf(last));
}

// Replay driver: plays the snapshot from meta.replay_from to meta.captured_at at
// speed virtual seconds per real second, emitting a scene every stepMs.
function createReplayDriver(snapshot, o) {
    o = o || {};
    var timers = o.timers;
    var from = toMs(o.from || snapshot.meta.replay_from);
    var to = toMs(o.to || snapshot.meta.captured_at);
    var speed = o.speed || 60;
    var stepMs = o.stepMs || 1000;
    var loop = o.loop !== false;
    var virt = from, handle = null, running = false;

    function sceneAt(ms) { return replayScene(snapshot, ms); }
    function step() {
        if (!running) return;
        var scene = sceneAt(virt);
        if (o.onScene) o.onScene(scene, virt);
        if (virt >= to) {
            if (!loop) { running = false; if (o.onEnd) o.onEnd(); return; }
            virt = from;
        } else {
            virt = Math.min(to, virt + stepMs * speed);
        }
        handle = timers.setTimeout(step, stepMs);
    }
    return {
        sceneAt: sceneAt,
        start: function () { if (running) return; running = true; step(); },
        stop: function () { running = false; if (handle !== null) timers.clearTimeout(handle); handle = null; },
        seek: function (ms) { virt = Math.max(from, Math.min(to, toMs(ms))); },
        position: function () { return virt; },
        range: function () { return { from: from, to: to }; }
    };
}

// ---------------------------------------------------------------- QML transport

// XMLHttpRequest transport for QML (Qt delivers progressive responseText at
// readyState 3). Node uses node.cjs instead.
function xhrTransport() {
    return {
        getJson: function (url, headers) {
            return new Promise(function (resolve, reject) {
                var x = new XMLHttpRequest();
                x.open("GET", url);
                for (var k in headers) x.setRequestHeader(k, headers[k]);
                x.onreadystatechange = function () {
                    if (x.readyState !== 4) return;
                    if (x.status >= 200 && x.status < 300) {
                        try { resolve(JSON.parse(x.responseText)); } catch (e) { reject(e); }
                    } else reject(new Error("HTTP " + x.status + " " + url));
                };
                x.send();
            });
        },
        postJson: function (url, headers, body) {
            return new Promise(function (resolve, reject) {
                var x = new XMLHttpRequest();
                x.open("POST", url);
                for (var k in headers) x.setRequestHeader(k, headers[k]);
                x.setRequestHeader("Content-Type", "application/json");
                x.onreadystatechange = function () {
                    if (x.readyState !== 4) return;
                    if (x.status >= 200 && x.status < 300) {
                        try { resolve(JSON.parse(x.responseText)); } catch (e) { reject(e); }
                    } else reject(new Error("HTTP " + x.status + " " + url));
                };
                x.send(JSON.stringify(body || {}));
            });
        },
        openStream: function (url, headers, onChunk, onEnd) {
            var x = new XMLHttpRequest(), seen = 0, closed = false;
            x.open("GET", url);
            for (var k in headers) x.setRequestHeader(k, headers[k]);
            x.onreadystatechange = function () {
                if (closed) return;
                if (x.readyState === 3 || x.readyState === 4) {
                    var t = x.responseText || "";
                    if (t.length > seen) { onChunk(t.slice(seen)); seen = t.length; }
                }
                if (x.readyState === 4) { closed = true; onEnd(x.status >= 200 && x.status < 300 ? null : new Error("HTTP " + x.status)); }
            };
            x.send();
            return { close: function () { closed = true; try { x.abort(); } catch (e) {} } };
        }
    };
}

function liveFetcher(cfg, transport) {
    return function (path) { return transport.getJson(cfg.baseUrl + path, authHeaders(cfg)); };
}

// Live when configured, otherwise the replayed snapshot (demo mode). The replay
// clock defaults to the snapshot's capture time.
function fetcherFor(cfg, transport, snapshot, clock) {
    if (cfg && cfg.mode === "live") return liveFetcher(cfg, transport);
    return replayFetcher(snapshot, clock || function () { return toMs(snapshot.meta.captured_at); });
}
