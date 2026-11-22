// One scene model from the Command REST shapes; the library loads as a QML
// `.pragma library` file and from Node.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const node = require("../node.cjs");
const { M } = node;
const DATA = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const ROOT = path.dirname(DATA);
const snap = node.loadSnapshot();
const CAPTURED = Date.parse(snap.meta.captured_at);

test("mandrel.js is a dependency-free QML .pragma library", () => {
    const raw = fs.readFileSync(path.join(DATA, "mandrel.js"), "utf8");
    assert.equal(raw.split("\n")[0], ".pragma library");
    for (const banned of [/\brequire\s*\(/, /\bprocess\./, /\bmodule\.exports\b/, /^\s*(import|export)\s/m, /\bconst\s/, /\blet\s/, /=>/, /`/])
        assert.ok(!banned.test(raw), `QML-incompatible construct ${banned}`);
    for (const fn of ["buildScene", "loadScene", "clientLiveness", "taskLane", "createEventStream", "createReplayDriver", "resolveConfig"])
        assert.equal(typeof M[fn], "function", fn);
});

test("package has no npm dependencies", () => {
    assert.equal(fs.existsSync(path.join(ROOT, "package.json")) && JSON.parse(fs.readFileSync(path.join(ROOT, "package.json"))).dependencies !== undefined, false);
    assert.equal(fs.existsSync(path.join(ROOT, "node_modules")), false);
});

async function sceneFromSnapshot(at = CAPTURED) {
    const seen = [];
    const replay = M.replayFetcher(snap, () => at);
    const fetchJson = (p) => { seen.push(p); return replay(p); };
    const scene = await M.loadScene(fetchJson, { now: at, mode: "replay", baseUrl: snap.meta.base_url, projectId: snap.meta.project_id });
    return { scene, seen };
}

test("loadScene reads all six endpoints and details only open sessions", async () => {
    const { seen } = await sceneFromSnapshot();
    for (const p of ["/api/sessions", "/api/tasks", "/api/contexts", "/api/decisions", "/api/projects"]) assert.ok(seen.includes(p), p);
    const detail = seen.filter((p) => p.startsWith("/api/sessions/")).sort();
    assert.deepEqual(detail, [
        "/api/sessions/4af6ff22-9c34-45e6-b32e-5083bf4ed157",
        "/api/sessions/4f96630e-4366-4dfa-8720-0433bc0edf6b",
        "/api/sessions/de463c37-c3d0-42ac-b3a3-e63d4e64f814",
    ]);
});

test("scene from the real amplify snapshot", async () => {
    const { scene } = await sceneFromSnapshot();
    assert.equal(scene.sessions.length, 12);
    assert.deepEqual(scene.counts.liveness, { forming: 2, live: 1, quiet: 0, lost: 0, dormant: 0, ended: 9 });

    // Orbs are the not-ended sessions, named from "<name> · <role>" titles.
    assert.deepEqual(scene.orbs.map((o) => [o.name, o.role, o.liveness]).sort(), [
        ["amplify-coord", "coord", "live"], ["data-core", "worker", "forming"], ["shell-spike", "worker", "forming"]]);
    const dataCore = scene.orbs.find((o) => o.name === "data-core");
    assert.equal(dataCore.taskId, "0edf3b35-3e91-45db-8aa4-d0b5f57c81e0");
    assert.equal(dataCore.threadUrl, "https://ampcode.com/threads/T-01a20161-d86d-7337-9b81-bbc70d3b28e9");
    assert.equal(dataCore.url, "https://brian.mandrel.ridgetopai.net/r/4af6ff22");

    const counts = Object.fromEntries(Object.entries(scene.lanes).map(([k, v]) => [k, v.length]));
    assert.deepEqual(counts, { draft: 9, ready: 0, claimed: 2, verifying: 0, evidence: 0, merged: 5, deployed: 0 });
    assert.equal(scene.counts.tasks, 16, "the cancelled smoke task is hidden");
    assert.ok(!Object.values(scene.lanes).flat().some((t) => t.id.startsWith("f5dc63e9")));

    assert.deepEqual(scene.needsYou.map((n) => [n.kind, n.id8]), [["decision", "f74dcdfc"], ["decision", "c755578f"]]);

    assert.equal(scene.latest[0].id8, "53163e57");
    assert.equal(scene.latest[0].title, "MODE: build");
    for (let i = 1; i < scene.latest.length; i++) assert.ok(Date.parse(scene.latest[i - 1].at) >= Date.parse(scene.latest[i].at));

    assert.deepEqual(scene.projects.map((p) => [p.name, p.current]), [["amplify", true]]);
    assert.equal(scene.meta.mode, "replay");
});

test("null fields render: untitled sessions get a display title", async () => {
    const { scene } = await sceneFromSnapshot();
    const untitled = scene.sessions.filter((s) => s.title === null);
    assert.equal(untitled.length, 2);
    for (const s of untitled) assert.match(s.displayTitle, /^coord [0-9a-f]{8}$/);
    const bare = M.buildScene({ sessions: [{ id: "abcdef12-0000" }] }, { now: CAPTURED });
    assert.equal(bare.sessions[0].displayTitle, "untitled abcdef12");
    assert.equal(bare.sessions[0].liveness, "dormant");
});

test("activity links come from outbound/inbound_link_activity.to_session and dedupe", () => {
    const A = "aaaaaaaa-0000-0000-0000-000000000000", B = "bbbbbbbb-0000-0000-0000-000000000000";
    const at = "2026-11-22T03:59:00.000Z";
    const scene = M.buildScene({ sessions: { sessions: [
        { id: A, outbound_link_activity: [{ kind: "assigned", to_session: B, at, task_id: "0edf3b35" }, { kind: "note", to_session: "cccccccc-gone", at }] },
        { id: B, inbound_link_activity: [{ kind: "assigned", to_session: A, at }] },
    ] } }, { now: CAPTURED });
    assert.equal(scene.links.length, 2);
    const ab = scene.links.find((l) => l.to === B);
    assert.deepEqual([ab.from, ab.to, ab.kind, ab.taskId, ab.resolved], [A, B, "assigned", "0edf3b35", true]);
    assert.equal(scene.links.find((l) => l.to !== B).resolved, false);
});

test("details from /api/sessions/:id override list rows", () => {
    const id = "dddddddd-0000-0000-0000-000000000000";
    const scene = M.buildScene({
        sessions: [{ id, title: null, liveness: "live", last_activity_at: "2026-11-22T03:59:00Z" }],
        sessionDetails: { [id]: { session: { id, title: "late · critic", total_tokens: 12345, punch_activity: { task_id: "beefbeef" } } } },
    }, { now: CAPTURED });
    assert.equal(scene.sessions[0].displayTitle, "late · critic");
    assert.equal(scene.sessions[0].role, "critic");
    assert.equal(scene.sessions[0].totalTokens, "12345");
    assert.equal(scene.orbs[0].taskId, "beefbeef");
});

test("a lost session appears in needsYou with reason lost heartbeat", () => {
    const id = "eeeeeeee-0000-0000-0000-000000000000";
    const hb = new Date(CAPTURED - 601 * 1000).toISOString();
    const scene = M.buildScene({ sessions: [{ id, title: "gone · worker", creation_reason: "resume", context_count: 2,
        last_heartbeat_at: hb, last_explicit_heartbeat_at: hb, last_activity_at: hb }] }, { now: CAPTURED });
    assert.equal(scene.sessions[0].liveness, "lost");
    assert.deepEqual(scene.needsYou.map((n) => [n.kind, n.id, n.reason, n.since]), [["session", id, "lost heartbeat", hb]]);
    assert.equal(scene.counts.needsYou, 1);
});

test("projectId filter drops other projects' sessions", () => {
    const scene = M.buildScene({ sessions: [{ id: "1", project_id: "p1" }, { id: "2", project_id: "p2" }] }, { now: CAPTURED, projectId: "p1" });
    assert.deepEqual(scene.sessions.map((s) => s.id), ["1"]);
});

test("config reads MANDREL_URL and MANDREL_VIEWER_TOKEN only; replay when unset", () => {
    assert.equal(M.resolveConfig({}).mode, "replay");
    assert.equal(M.resolveConfig({ MANDREL_URL: "https://m.example" }).mode, "replay");
    const live = M.resolveConfig({ MANDREL_URL: "https://m.example//", MANDREL_VIEWER_TOKEN: "vt_x" });
    assert.deepEqual([live.mode, live.baseUrl, live.token], ["live", "https://m.example", "vt_x"]);
    const mdl = M.resolveConfig({ MANDREL_URL: "https://m.example", MANDREL_VIEWER_TOKEN: "mdl_secret" });
    assert.deepEqual([mdl.mode, mdl.token], ["replay", null]);
    assert.equal(node.config({}).mode, "replay");
});

test("demo mode: fetcherFor with no config replays the snapshot without a transport", async () => {
    const noNet = { getJson() { throw new Error("network used in replay"); } };
    const scene = await M.loadScene(M.fetcherFor(M.resolveConfig({}), noNet, snap), { now: CAPTURED, mode: "replay" });
    assert.equal(scene.sessions.length, 12);
});

test("every env read is marked and no token is committed", () => {
    const files = fs.readdirSync(DATA).filter((f) => /\.(c?js|mjs)$/.test(f)).map((f) => path.join(DATA, f));
    for (const f of files) {
        const lines = fs.readFileSync(f, "utf8").split("\n");
        lines.forEach((l, i) => {
            if (/process\.env|getenv|Qt\.application\.arguments|Quickshell\.env/.test(l))
                assert.match(lines.slice(Math.max(0, i - 2), i + 1).join("\n"), /\/\/ env-read:/, `${f}:${i + 1}`);
        });
    }
    for (const dir of [DATA, path.join(ROOT, "fixtures")]) {
        for (const f of fs.readdirSync(dir, { recursive: true })) {
            const p = path.join(dir, f);
            if (!fs.statSync(p).isFile()) continue;
            const s = fs.readFileSync(p, "utf8");
            assert.doesNotMatch(s, /mdl_[A-Za-z0-9]{8,}/, p);
            assert.doesNotMatch(s, /eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/, p);
        }
    }
});
