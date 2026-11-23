// Amp live thread state: `amp top --stream-jsonl` parsed tolerantly, with
// `amp threads list --json` as the fallback. Fixtures are real captures from
// this orb (amp 0.0.1795320040), with one unrelated thread scrubbed.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { amp: A, ROOT } = require("../amp/node.cjs");
const FIX = path.join(ROOT, "data", "amp", "fixtures");
const topText = fs.readFileSync(path.join(FIX, "top-capture.jsonl"), "utf8");
const listText = fs.readFileSync(path.join(FIX, "threads-list-capture.json"), "utf8");
const topLines = topText.split("\n").filter(Boolean);

// A real captured row with its state replaced, for states this orb did not see live.
const realRow = JSON.parse(topLines[1]).threads[0];
const line = (rows, extra) => JSON.stringify({ updatedAt: "2026-11-22T04:50:00.000Z", threads: rows, reconnecting: false, ...extra });
const row = (over) => ({ ...realRow, ...over });

test("amp.js is a dependency-free QML .pragma library", () => {
    const raw = fs.readFileSync(path.join(ROOT, "data", "amp", "amp.js"), "utf8");
    assert.equal(raw.split("\n")[0], ".pragma library");
    for (const banned of [/\brequire\s*\(/, /\bprocess\./, /\bmodule\.exports\b/, /^\s*(import|export)\s/m, /\bconst\s/, /\blet\s/, /=>/, /`/])
        assert.ok(!banned.test(raw), `QML-incompatible construct ${banned}`);
});

test("real amp top capture: empty first frame, then working and idle threads", () => {
    const snaps = topLines.map(A.parseTopLine);
    assert.equal(snaps.length, 3);
    assert.deepEqual(snaps[0].threads, []);
    const s = snaps[1];
    assert.equal(s.source, "top");
    assert.equal(s.reconnecting, false);
    assert.equal(s.threads.length, 12);
    const byId = Object.fromEntries(s.threads.map((t) => [t.id, t]));
    const me = byId["T-01a20190-95fb-7613-aef0-02919cf90512"];
    assert.equal(me.state, "working");
    assert.equal(me.orbName, "needs-you");
    assert.equal(me.url, "https://ampcode.com/threads/T-01a20190-95fb-7613-aef0-02919cf90512");
    // status "15m" is an idle thread's relative age, not a state.
    const idle = byId["T-01a20184-5e5d-75a7-9fca-609d1b3023e7"];
    assert.equal(idle.state, "idle");
    assert.equal(idle.rawState, "15m");
    assert.equal(idle.ageSec, 900);
    assert.ok(s.threads.every((t) => !t.needsHuman), "nothing in the real capture waits on a human");
    assert.deepEqual(A.waitingThreads(s), []);
});

test("awaiting states need a human; spellings normalise", () => {
    const cases = [["awaiting_input", "awaiting_input"], ["awaiting-approval", "awaiting_approval"],
        ["Awaiting Approval", "awaiting_approval"], ["waiting_for_input", "awaiting_input"],
        ["awaiting_tool_approval", "awaiting_approval"], ["error", "error"], ["idle", "idle"], ["2h", "idle"]];
    for (const [status, want] of cases) {
        const t = A.parseTopLine(line([row({ status })])).threads[0];
        assert.equal(t.state, want, status);
        assert.equal(t.needsHuman, want.startsWith("awaiting"), status);
    }
    // An explicit agent state field wins over the display status.
    const t = A.parseTopLine(line([row({ status: "working", agentState: "awaiting_input" })])).threads[0];
    assert.equal(t.state, "awaiting_input");
});

test("unknown states, fields and shapes are ignored, never awaiting", () => {
    const s = A.parseTopLine(line([
        row({ id: "T-aaaaaaaa-0000-0000-0000-000000000001", status: "teleporting", working: false, futureField: { x: 1 } }),
        row({ id: "T-aaaaaaaa-0000-0000-0000-000000000002", status: { kind: "pondering" }, working: false }),
        row({ id: "T-aaaaaaaa-0000-0000-0000-000000000003", status: undefined, working: undefined }),
        row({ id: "T-aaaaaaaa-0000-0000-0000-000000000004", status: "teleporting", working: true }),
        { title: "no id" }, null, 7, row({ id: "not-a-thread" }),
    ], { schemaVersion: 9, extra: [1, 2] }));
    assert.deepEqual(s.threads.map((t) => [t.id.slice(-1), t.state, t.needsHuman]),
        [["1", "unknown", false], ["2", "unknown", false], ["3", "unknown", false], ["4", "working", false]]);
    assert.deepEqual(A.waitingThreads(s), []);
    for (const bad of ["", "   ", "not json", "{\"threads\":", "[1,2]", "{\"other\":1}", "{\"threads\":\"x\"}", null])
        assert.equal(A.parseTopLine(bad), null, String(bad));
});

test("stream reader handles any chunking, CRLF, noise, and a trailing partial line", () => {
    const awaiting = line([row({ status: "awaiting_input" })]);
    const stream = topText + "warning: reconnecting\r\n" + awaiting + "\n" + awaiting.slice(0, 30);
    const got = [];
    const r = A.createTopReader((s) => got.push(s));
    for (let i = 0; i < stream.length; i += 7) r.feed(stream.slice(i, i + 7));
    assert.equal(got.length, 4);
    assert.equal(r.stats().skipped, 1);
    assert.equal(r.last().threads[0].state, "awaiting_input");
    r.flush(); // partial JSON is dropped, not thrown
    assert.equal(r.stats().skipped, 2);
    assert.equal(got.length, 4);
});

test("waitingThreads orders the longest-waiting first", () => {
    const s = A.parseTopLine(line([
        row({ id: "T-bbbbbbbb-0000-0000-0000-000000000001", status: "awaiting_input", updatedAt: "2026-11-22T04:40:00Z" }),
        row({ id: "T-bbbbbbbb-0000-0000-0000-000000000002", status: "working" }),
        row({ id: "T-bbbbbbbb-0000-0000-0000-000000000003", status: "awaiting_approval", updatedAt: "2026-11-22T04:10:00Z" }),
    ]));
    assert.deepEqual(A.waitingThreads(s).map((t) => t.id.slice(-1)), ["3", "1"]);
});

test("fallback: real amp threads list --json gives threads with unknown state", () => {
    const now = Date.parse("2026-11-22T04:50:00Z");
    const s = A.parseThreadsList(listText, now);
    assert.equal(s.source, "list");
    assert.equal(s.threads.length, 8);
    const c = s.threads.find((t) => t.id === "T-01a20009-9e9d-75b8-a1df-698ad360d5e0");
    assert.equal(c.title, "smoke-coord · coordinator: role-token smoke test");
    assert.equal(c.url, "https://ampcode.com/threads/T-01a20009-9e9d-75b8-a1df-698ad360d5e0");
    assert.equal(c.orbName, "smoke-coord");
    assert.ok(c.ageSec > 0);
    assert.ok(s.threads.every((t) => t.state === "unknown" && !t.needsHuman));
    assert.equal(A.parseThreadsList("oops"), null);
    assert.equal(A.parseThreadsList("{}"), null);
    assert.equal(A.parseThreadsList(JSON.parse(listText)).threads.length, 8, "accepts parsed JSON");
});
