// SSE ticket flow (POST /api/events/ticket, GET /api/events?ticket=) against a
// local fake server, debounced refetch, reconnect on missing heartbeat, and the
// replay driver over the real snapshot fixture.
import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { createRequire } from "node:module";

const node = createRequire(import.meta.url)("../node.cjs");
const { M } = node;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(pred, ms = 3000) {
    const end = Date.now() + ms;
    while (!pred()) { if (Date.now() > end) throw new Error("timed out"); await sleep(10); }
}

// ---------------------------------------------------------------- parser

test("SSE parser handles split chunks, CRLF, comments and multi-line data", () => {
    const events = [], comments = [];
    const p = M.createSseParser((e) => events.push(e), (c) => comments.push(c));
    p.feed(": hb\n\nevent: entity\nda");
    p.feed("ta: {\"a\":1}\r\nid: 7\r\n\r\ndata: x\ndata: y\n");
    assert.equal(events.length, 1);
    p.feed("\n");
    assert.deepEqual(events, [{ event: "entity", data: "{\"a\":1}", id: "7" }, { event: "message", data: "x\ny", id: "7" }]);
    assert.deepEqual(comments, ["hb"]);
});

// ---------------------------------------------------------------- fake server

function fakeMandrel({ heartbeatMs = null } = {}) {
    const st = { tickets: [], gets: [], streams: new Set(), issued: new Set(), ticketAuth: [] };
    const server = http.createServer((req, res) => {
        const url = new URL(req.url, "http://x");
        if (req.method === "POST" && url.pathname === "/api/events/ticket") {
            st.ticketAuth.push(req.headers.authorization || null);
            if (req.headers.authorization !== "Bearer viewer-test") { res.writeHead(401); return res.end(); }
            const t = "tk-" + (st.tickets.length + 1);
            st.tickets.push(t); st.issued.add(t);
            res.writeHead(200, { "Content-Type": "application/json" });
            return res.end(JSON.stringify({ ticket: t }));
        }
        if (req.method === "GET" && url.pathname === "/api/events") {
            const t = url.searchParams.get("ticket");
            st.gets.push({ ticket: t, auth: req.headers.authorization || null, accept: req.headers.accept });
            if (!st.issued.delete(t)) { res.writeHead(403); return res.end(); } // single-use
            res.writeHead(200, { "Content-Type": "text/event-stream" });
            res.write(": open\n\n");
            const s = { res, timer: null };
            if (heartbeatMs) s.timer = setInterval(() => res.write("event: heartbeat\ndata: {}\n\n"), heartbeatMs);
            st.streams.add(s);
            req.on("close", () => { clearInterval(s.timer); st.streams.delete(s); });
            return;
        }
        res.writeHead(404); res.end();
    });
    st.send = (ev) => { for (const s of st.streams) s.res.write(`event: entity\ndata: ${JSON.stringify(ev)}\n\n`); };
    st.endAll = () => { for (const s of st.streams) { clearInterval(s.timer); s.res.end(); } };
    return new Promise((resolve) => server.listen(0, "127.0.0.1", () => {
        st.url = `http://127.0.0.1:${server.address().port}`;
        st.close = () => new Promise((r) => { for (const s of st.streams) { clearInterval(s.timer); s.res.destroy(); } server.close(r); });
        resolve(st);
    }));
}

function client(srv, o = {}) {
    const refetches = [], states = [], events = [];
    const es = M.createEventStream({
        config: M.resolveConfig({ MANDREL_URL: srv.url, MANDREL_VIEWER_TOKEN: "viewer-test" }),
        transport: node.fetchTransport(), timers: node.timers,
        debounceMs: 60, heartbeatTimeoutMs: 250, reconnectMs: 30, ...o,
        onChange: () => refetches.push(Date.now()), onState: (s, why) => states.push([s, why]), onEvent: (e) => events.push(e),
    });
    return { es, refetches, states, events };
}

test("ticket flow: POST ticket with the viewer token, GET stream with the ticket only", async (t) => {
    const srv = await fakeMandrel({ heartbeatMs: 50 });
    const c = client(srv);
    t.after(async () => { c.es.stop(); await srv.close(); });
    c.es.start();
    await until(() => c.es.state() === "open" && srv.streams.size === 1);
    assert.deepEqual(srv.ticketAuth, ["Bearer viewer-test"]);
    assert.deepEqual(srv.gets, [{ ticket: "tk-1", auth: null, accept: "text/event-stream" }]);
});

test("a burst of entity events triggers one debounced refetch", async (t) => {
    const srv = await fakeMandrel({ heartbeatMs: 50 });
    const c = client(srv);
    t.after(async () => { c.es.stop(); await srv.close(); });
    c.es.start();
    await until(() => c.refetches.length === 1); // catch-up refetch on open
    for (let i = 0; i < 5; i++) { srv.send({ entity: "task", op: "update", id: "t" + i }); await sleep(10); }
    await until(() => c.events.length === 5);
    assert.equal(c.refetches.length, 1, "no refetch before the debounce window closes");
    await sleep(150);
    assert.equal(c.refetches.length, 2, "five events collapse into one refetch");
    assert.deepEqual(c.events[4].data, { entity: "task", op: "update", id: "t4" });
    srv.send({ entity: "context", op: "insert" });
    await until(() => c.refetches.length === 3);
    assert.equal(c.es.stats().heartbeats > 0, true, "heartbeat events are not entity events");
    assert.equal(c.es.stats().events, 6);
});

test("heartbeats keep the stream; a missing heartbeat reconnects with a fresh ticket", async (t) => {
    const steady = await fakeMandrel({ heartbeatMs: 50 });
    const a = client(steady);
    t.after(async () => { a.es.stop(); await steady.close(); });
    a.es.start();
    await sleep(800); // > 3 heartbeat timeouts
    assert.equal(steady.tickets.length, 1, "no reconnect while heartbeats arrive");
    assert.equal(a.es.stats().reconnects, 0);

    const silent = await fakeMandrel({ heartbeatMs: null });
    const b = client(silent);
    t.after(async () => { b.es.stop(); await silent.close(); });
    b.es.start();
    await until(() => silent.gets.length >= 2, 2000);
    assert.ok(b.states.some(([s, why]) => s === "reconnecting" && why === "heartbeat timeout"));
    assert.deepEqual(silent.gets.slice(0, 2).map((g) => g.ticket), ["tk-1", "tk-2"]);
    await until(() => b.es.state() === "open");
    assert.ok(b.refetches.length >= 1, "reconnect schedules a catch-up refetch");
});

test("server closing the stream reconnects; stop() ends cleanly", async (t) => {
    const srv = await fakeMandrel({ heartbeatMs: 50 });
    const c = client(srv);
    t.after(async () => { c.es.stop(); await srv.close(); });
    c.es.start();
    await until(() => srv.streams.size === 1);
    srv.endAll();
    await until(() => srv.tickets.length === 2 && srv.streams.size === 1);
    assert.ok(c.states.some(([s, why]) => s === "reconnecting" && why === "stream ended"));
    c.es.stop();
    await until(() => srv.streams.size === 0);
    const n = srv.tickets.length;
    await sleep(400);
    assert.equal(srv.tickets.length, n, "stopped stream does not reconnect");
    assert.equal(c.es.state(), "stopped");
});

test("a rejected ticket retries instead of throwing", async (t) => {
    const srv = await fakeMandrel({ heartbeatMs: 50 });
    const c = client(srv, { config: M.resolveConfig({ MANDREL_URL: srv.url, MANDREL_VIEWER_TOKEN: "wrong" }) });
    t.after(async () => { c.es.stop(); await srv.close(); });
    c.es.start();
    await until(() => srv.ticketAuth.length >= 2);
    assert.ok(c.states.some(([s, why]) => s === "reconnecting" && /ticket failed: HTTP 401/.test(why)));
    assert.equal(srv.gets.length, 0);
});

// ---------------------------------------------------------------- replay

const snap = node.loadSnapshot();

function manualTimers() {
    const q = [];
    return { q, setTimeout: (fn, ms) => { const h = { fn, ms }; q.push(h); return h; },
             clearTimeout: (h) => { const i = q.indexOf(h); if (i >= 0) q.splice(i, 1); },
             fire() { const h = q.shift(); h.fn(); } };
}

test("snapshot fixture is real amplify data labelled as a replayed snapshot", () => {
    assert.equal(snap.meta.kind, "replayed-snapshot");
    assert.match(snap.meta.notice, /^REPLAYED SNAPSHOT\./);
    assert.equal(snap.meta.project_id, "2b802595-ac66-4a5e-b9eb-f5de489f933b");
    for (const k of ["/api/sessions", "/api/sessions/:id", "/api/tasks", "/api/contexts", "/api/decisions", "/api/projects"])
        assert.ok(snap.responses[k], k);
    const scene = M.createReplayDriver(snap, { timers: manualTimers() }).sceneAt(Date.parse(snap.meta.captured_at));
    assert.equal(scene.meta.mode, "replay");
    assert.match(scene.meta.label, /^REPLAYED SNAPSHOT · Mandrel project amplify/);
});

test("replay rewinds the snapshot to a virtual time", () => {
    const d = M.createReplayDriver(snap, { timers: manualTimers() });
    const at = d.sceneAt(Date.parse("2026-11-22T02:58:00.000Z"));
    // The three design orbs were still running at 02:58; the build punches did not exist.
    assert.deepEqual(at.orbs.map((o) => o.name).sort(), ["amplify-coord", "design-canopy", "design-current", "design-orrery", "orb-lab"]);
    assert.ok(at.sessions.find((s) => s.orbName === "design-current").liveness !== "ended");
    assert.ok(!at.tasks.some((t) => t.id.startsWith("0edf3b35")));
    const mock = at.tasks.find((t) => t.id.startsWith("b416eb7d"));
    assert.deepEqual([mock.status, mock.lane], ["in_progress", "claimed"], "completed at 03:50, so still open at 02:58");
    assert.deepEqual(at.needsYou.map((n) => n.id8), ["f74dcdfc"], "c755578f opened at 03:38");

    const end = d.sceneAt(Date.parse(snap.meta.captured_at));
    assert.equal(end.lanes.merged.length, 5);
    assert.equal(end.sessions.find((s) => s.orbName === "design-current").liveness, "ended");
});

test("replay driver steps virtual time, never regresses, and loops", () => {
    const timers = manualTimers();
    const scenes = [];
    const from = Date.parse("2026-11-22T03:40:00.000Z");
    const to = Date.parse(snap.meta.captured_at);
    const d = M.createReplayDriver(snap, { timers, from, to, speed: 300, stepMs: 1000, onScene: (s, v) => scenes.push([v, s]) });
    d.start();
    const steps = Math.ceil((to - from) / 300000) + 1;
    for (let i = 0; i < steps; i++) timers.fire();
    assert.equal(scenes[0][0], from);
    const ends = scenes.findIndex(([v]) => v === to);
    assert.ok(ends > 0, "reaches captured_at");
    for (let i = 1; i <= ends; i++) {
        assert.ok(scenes[i][0] > scenes[i - 1][0]);
        assert.ok(scenes[i][1].latest.length >= scenes[i - 1][1].latest.length || scenes[i][1].latest.length === 12);
        assert.ok(scenes[i][1].tasks.length >= scenes[i - 1][1].tasks.length);
    }
    assert.ok(scenes[0][1].tasks.length < scenes[ends][1].tasks.length, "punches appear during replay");
    assert.equal(scenes[ends + 1][0], from, "loops back to the start");
    d.stop();
    assert.equal(timers.q.length, 0);
});

test("replayFetcher serves REST paths so loadScene runs unchanged", async () => {
    const at = Date.parse("2026-11-22T02:58:00.000Z");
    const scene = await M.loadScene(M.replayFetcher(snap, () => at), { now: at, mode: "replay" });
    assert.equal(scene.orbs.length, 5);
    assert.equal(await M.replayFetcher(snap, () => at)("/api/sessions/4af6ff22-9c34-45e6-b32e-5083bf4ed157"), null, "data-core did not exist yet");
});
