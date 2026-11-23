// Needs-you basin: every kind of human-needed item, ordered by urgency, each
// opening the Amp thread or /r/<id8>. Built on the data layer's scene.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { M } = require("../node.cjs");
const { amp: A, basin: B, ROOT } = require("../amp/node.cjs");
const snap = JSON.parse(fs.readFileSync(path.join(ROOT, "fixtures", "amplify-snapshot.json"), "utf8"));

const BASE = "https://brian.mandrel.ridgetopai.net";
const NOW = Date.parse("2026-11-22T05:00:00Z");
const ago = (min) => new Date(NOW - min * 60000).toISOString();
const W = "brian/amp-worker-t-01a20190-0000-7000-8000-000000000001";
const W2 = "brian/amp-worker-t-01a20190-0000-7000-8000-000000000002";
const W3 = "brian/amp-worker-t-01a20190-0000-7000-8000-000000000003";

// Ages are chosen so oldest-first would give a different order than urgency.
function scene() {
    return M.buildScene({
        sessions: [
            { id: "5e550001-0000-4000-8000-000000000001", title: "lost-holder · worker", actor: W, liveness: "lost",
              started_at: ago(300), last_activity_at: ago(40), last_explicit_heartbeat_at: ago(30) },
            { id: "5e550002-0000-4000-8000-000000000002", title: "lost-free · worker", actor: W2, liveness: "lost",
              started_at: ago(300), last_activity_at: ago(50), last_explicit_heartbeat_at: ago(45) },
            { id: "5e550003-0000-4000-8000-000000000003", title: "ended · worker", actor: "brian/amp-critic-x",
              started_at: ago(300), ended_at: ago(100) },
            // Decision 23973614: an expired claim keeps claim_actor but is not live, so it never lights the basin.
            { id: "5e550004-0000-4000-8000-000000000004", title: "lost-expired · worker", actor: W3, liveness: "lost",
              started_at: ago(300), last_activity_at: ago(70), last_explicit_heartbeat_at: ago(65) },
        ],
        tasks: [
            { id: "7a5c0001-0000-4000-8000-000000000001", title: "Blocked on Brian", status: "blocked", blocked_on: "human", updated_at: ago(400) },
            { id: "7a5c0002-0000-4000-8000-000000000002", title: "Basin punch", status: "in_progress", stage: "evidence", updated_at: ago(20) },
            { id: "7a5c0003-0000-4000-8000-000000000003", title: "Held by lost orb", status: "in_progress", claim_live: true, claim_actor: W, updated_at: ago(60) },
            { id: "7a5c0004-0000-4000-8000-000000000004", title: "Older merge", status: "in_progress", stage: "evidence", updated_at: ago(90) },
            { id: "7a5c0005-0000-4000-8000-000000000005", title: "Blocked on agent", status: "blocked", blocked_on: "agent", updated_at: ago(500) },
            { id: "7a5c0006-0000-4000-8000-000000000006", title: "Merged already", status: "completed", stage: "merged", updated_at: ago(10) },
            { id: "7a5c0007-0000-4000-8000-000000000007", title: "Cancelled block", status: "cancelled", blocked_on: "human", updated_at: ago(600) },
            { id: "7a5c0008-0000-4000-8000-000000000008", title: "Expired claim", status: "in_progress", claim_live: false, claim_actor: W3, updated_at: ago(80) },
            { id: "7a5c0009-0000-4000-8000-000000000009", title: "Completed at evidence", status: "completed", stage: "evidence", updated_at: ago(95) },
            { id: "7a5c0010-0000-4000-8000-000000000010", title: "Blocked, no time", status: "blocked", blocked_on: "human" },
        ],
        decisions: [
            { id: "dec00001-0000-4000-8000-000000000001", title: "Pick a direction", answer_status: "open", created_at: ago(300) },
            { id: "dec00002-0000-4000-8000-000000000002", title: "Settled", answer_status: "decided", created_at: ago(5) },
        ],
    }, { now: NOW, baseUrl: BASE });
}

function amp(rows) {
    return A.parseTopLine(JSON.stringify({ updatedAt: new Date(NOW).toISOString(), reconnecting: false, threads: rows }));
}
const thread = (id, status, minAgo, title) => ({ id, title: title || "coord · amplify", url: `https://ampcode.com/threads/${id}`,
    project: "amplify-coord", status, updatedAt: ago(minAgo), working: status === "working", executorConnected: true });
const T1 = "T-01a20009-9e9d-75b8-a1df-698ad360d5e0";
const T2 = "T-01a20190-7ef4-70e4-86be-7efb153b3945";

test("basin.js is a dependency-free QML .pragma library", () => {
    const raw = fs.readFileSync(path.join(ROOT, "plugin", "basin", "basin.js"), "utf8");
    assert.equal(raw.split("\n")[0], ".pragma library");
    for (const banned of [/\brequire\s*\(/, /\bprocess\./, /\bmodule\.exports\b/, /^\s*(import|export)\s/m, /\bconst\s/, /\blet\s/, /=>/, /`/])
        assert.ok(!banned.test(raw), `QML-incompatible construct ${banned}`);
});

test("basin orders by urgency, then longest-waiting, and every row opens its exact place", () => {
    const rows = B.buildBasin(scene(), amp([
        thread(T1, "awaiting_input", 2, "amplify-coord · orchestration"),
        thread(T2, "awaiting_approval", 8, "river · P1 Current river scene"),
        thread("T-01a20190-8edf-777f-86cb-98cb293c2f69", "working", 1),
        thread("T-01a20190-9d35-77e0-aca5-ea97ce9dc814", "15m", 15),
    ]), { now: NOW });
    assert.deepEqual(rows.map((r) => [r.rank, r.kind, r.url]), [
        [1, "thread", `https://ampcode.com/threads/${T2}`],      // approval, waited 8m
        [2, "thread", `https://ampcode.com/threads/${T1}`],      // input, waited 2m
        [3, "merge", `${BASE}/r/7a5c0004`],                      // evidence 90m
        [4, "merge", `${BASE}/r/7a5c0002`],                      // evidence 20m
        [5, "lost", `${BASE}/r/5e550001`],                       // lost, holds 7a5c0003
        [6, "decision", `${BASE}/r/dec00001`],
        [7, "blocked", `${BASE}/r/7a5c0001`],                    // oldest of all, least urgent
        [8, "blocked", `${BASE}/r/7a5c0010`],                    // no time sorts last in its tier
    ]);
    assert.equal(rows[0].label, "Amp thread · awaiting approval");
    assert.equal(rows[0].title, "river is waiting: approve a tool call");
    assert.equal(rows[1].title, "amplify-coord is waiting for your answer");
    assert.equal(rows[4].title, "lost-holder stopped heartbeating, still holds 7a5c0003");
    assert.equal(rows[2].waited, "1h 30m");
    assert.equal(rows[4].waited, "30m", "a lost row waits since its last explicit heartbeat, not its start");
    assert.equal(rows[7].waited, null);
    assert.equal(B.headline(rows), "8 things need you");
});

test("left out: lost without a live claim, completed evidence, ended, agent blocks, settled, cancelled, and non-waiting threads", () => {
    const rows = B.buildBasin(scene(), amp([thread(T1, "teleporting", 3), thread(T2, "error", 3), thread("T-01a20190-8edf-777f-86cb-98cb293c2f69", "idle", 3)]), { now: NOW });
    const keys = rows.map((r) => r.key);
    for (const k of ["lost:5e550002-0000-4000-8000-000000000002", "lost:5e550003-0000-4000-8000-000000000003",
        "blocked:7a5c0005-0000-4000-8000-000000000005", "decision:dec00002-0000-4000-8000-000000000002",
        "blocked:7a5c0007-0000-4000-8000-000000000007", "merge:7a5c0006-0000-4000-8000-000000000006",
        "lost:5e550004-0000-4000-8000-000000000004", "merge:7a5c0009-0000-4000-8000-000000000009"])
        assert.ok(!keys.includes(k), k);
    assert.ok(!rows.some((r) => r.kind === "thread"), "unknown, error, and idle threads never enter the basin");
    assert.equal(rows.length, 6);
});

test("empty and missing inputs are calm", () => {
    assert.deepEqual(B.buildBasin(null, null, { now: NOW }), []);
    assert.equal(B.headline([]), "Nothing needs you");
    assert.equal(B.headline(B.buildBasin(null, amp([thread(T1, "awaiting_input", 1)]), { now: NOW })), "1 thing needs you");
});

test("real snapshot: the two open decisions, oldest first, linked to /r/<id8>", () => {
    const at = Date.parse(snap.meta.captured_at);
    const sc = M.replayFetcher(snap, () => at);
    return M.loadScene(sc, { now: at, baseUrl: snap.meta.base_url, projectId: snap.meta.project_id }).then((s) => {
        const real = fs.readFileSync(path.join(ROOT, "data", "amp", "fixtures", "top-capture.jsonl"), "utf8").trim().split("\n");
        const rows = B.buildBasin(s, A.parseTopLine(real[1]), { now: at });
        assert.deepEqual(rows.map((r) => [r.kind, r.url]), [
            ["decision", `${BASE}/r/f74dcdfc`], ["decision", `${BASE}/r/c755578f`]]);
    });
});
