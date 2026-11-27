// Panes (task bc45ee1d): stats, the newest context/decision/task with their whole titles each
// opening <base>/r/<id8>, the project switcher and the quick links, from the data layer's scene.
// Expected values are read from the raw snapshot here, not from the code under test.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { M } = require("../../../data/node.cjs");
const { basin: B, loadPragma, ROOT } = require("../../../data/amp/node.cjs");
const P = loadPragma(path.join(ROOT, "plugin", "panes", "panes.js"));

const snap = JSON.parse(fs.readFileSync(path.join(ROOT, "fixtures", "amplify-snapshot.json"), "utf8"));
const projects = JSON.parse(fs.readFileSync(path.join(ROOT, "plugin", "panes", "test", "projects.json"), "utf8"));
const BASE = snap.meta.base_url;
const AT = Date.parse(snap.meta.captured_at);
const raw = (k) => snap.responses[`/api/${k}`][k];

function strings(v, out = []) {
    if (typeof v === "string") out.push(v);
    else if (v && typeof v === "object") for (const x of Object.values(v)) strings(x, out);
    return out;
}
const stat = (m, key) => m.stats.find((s) => s.key === key);

test("stats from the replayed capture: open sessions, lanes, writes per hour, waiting on you", () => {
    const scene = M.replayScene(snap, AT);
    const rows = B.buildBasin(scene, null, { now: AT });
    const m = P.buildPanes(scene, { now: AT, needsYou: rows });

    const open = scene.sessions.filter((s) => s.liveness !== "ended").length;
    assert.equal(stat(m, "sessions").value, String(open));
    assert.equal(open, 3);

    // Records created in the hour up to the capture, counted from the raw responses.
    const hour = ["contexts", "decisions", "tasks"].flatMap(raw)
        .map((r) => Date.parse(r.created_at)).filter((t) => t > AT - 3600000 && t <= AT).length;
    assert.ok(hour > 0);
    assert.equal(stat(m, "rate").value, String(hour));

    const inFlight = ["draft", "ready", "claimed", "verifying", "evidence"].reduce((n, l) => n + scene.lanes[l].length, 0);
    assert.equal(stat(m, "lanes").value, String(inFlight));
    assert.deepEqual(m.lanes.map((l) => l.count), ["draft", "ready", "claimed", "verifying", "evidence", "merged", "deployed"].map((l) => scene.lanes[l].length));

    assert.equal(stat(m, "waiting").value, String(rows.length), "the same count the basin's headline shows");
    assert.equal(rows.length, 2);
    assert.equal(stat(m, "waiting").note, "2 open decisions");
    assert.equal(stat(m, "waiting").warm, true);
});

test("latest context, decision and task: the newest of each, whole first line, opening <base>/r/<id8>", () => {
    const m = P.buildPanes(M.replayScene(snap, AT), { now: AT });
    for (const [kind, list, titleOf] of [["context", "contexts", (r) => r.content], ["decision", "decisions", (r) => r.title],
                                          ["task", "tasks", (r) => r.title]]) {
        const newest = raw(list).filter((r) => Date.parse(r.created_at) <= AT)
            .sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at))[0];
        const row = m.latest.find((r) => r.kind === kind);
        assert.equal(row.url, `${BASE}/r/${newest.id.slice(0, 8)}`, kind);
        assert.equal(row.title, titleOf(newest).split("\n")[0], kind);
    }
    assert.ok(m.latest.some((r) => r.title.length > 30), "a title longer than 30 characters is shown whole");
});

test("a title longer than the scene's 120-character cut is shown whole", () => {
    const title = "Amplify: " + "a decision whose title keeps going well past any cut a list view would make, ".repeat(2) + "and ends here";
    assert.ok(title.length > 150);
    const scene = M.buildScene({
        decisions: [{ id: "d0000001-0000-4000-8000-000000000001", title, created_at: "2026-11-22T03:00:00Z" }],
        contexts: [{ id: "c0000001-0000-4000-8000-000000000001", content: title + "\nsecond line", created_at: "2026-11-22T03:10:00Z" }]
    }, { now: AT, baseUrl: BASE });
    const m = P.buildPanes(scene, { now: AT });
    assert.equal(m.latest.find((r) => r.kind === "decision").title, title);
    assert.equal(m.latest.find((r) => r.kind === "context").title, title, "the first line, whole");
    assert.equal(m.latest.find((r) => r.kind === "decision").url, `${BASE}/r/d0000001`);
});

test("the switcher marks the scene's project, whichever it is, across every Mandrel project", () => {
    const inputs = () => ({ ...M.replayResponses(snap, AT), projects });
    for (const p of projects.projects.filter((x) => ["vidflow", "amplify", "daily log"].includes(x.name))) {
        const m = P.buildPanes(M.buildScene(inputs(), { now: AT, baseUrl: BASE, projectId: p.id }), { now: AT });
        assert.equal(m.projects.length, projects.projects.length);
        assert.equal(m.project, p.name);
        assert.equal(m.projectUrl, `${BASE}/r/${p.id.slice(0, 8)}`);
        assert.deepEqual(m.projects.filter((x) => x.current).map((x) => x.name), [p.name]);
        assert.equal(m.projects[0].name, p.name, "the current project leads the list");
        assert.ok(m.projects.every((x) => x.url === `${BASE}/r/${x.id8}`));
    }
    // Live scenes carry no project id: one project visible is the current one; several, none.
    assert.equal(P.buildPanes(M.replayScene(snap, AT), { now: AT }).project, "amplify");
    const all = P.buildPanes(M.buildScene({ projects }, { now: AT, baseUrl: BASE }), { now: AT });
    assert.equal(all.project, "All projects");
    assert.equal(all.projects.filter((x) => x.current).length, 0);
    const names = all.projects.map((x) => x.name.toLowerCase());
    assert.deepEqual(names, [...names].sort());
});

test("quick links open Mandrel at the base URL and Amp's threads", () => {
    const m = P.buildPanes(M.replayScene(snap, AT), { now: AT });
    assert.deepEqual(m.links.map((l) => [l.key, l.url]), [["mandrel", BASE], ["amp", "https://ampcode.com/threads"]]);
});

test("null fields read as words: no scene, an empty scene, untitled records", () => {
    for (const scene of [null, M.buildScene({}, { now: AT })]) {
        const m = P.buildPanes(scene, { now: AT });
        for (const s of strings(m)) assert.ok(!/\b(null|undefined|NaN)\b/.test(s), `"${s}"`);
        assert.deepEqual(m.latest.map((r) => r.title), ["No contexts yet", "No decisions yet", "No tasks yet"]);
        assert.ok(m.latest.every((r) => r.url === ""));
        assert.deepEqual(m.stats.map((s) => s.value), ["0", "0", "0", "0"]);
        assert.equal(m.project, "No project");
        assert.equal(m.links[0].url, "");
    }
    const scene = M.buildScene({
        contexts: [{ id: "c0000002-0000-4000-8000-000000000002", content: null, created_at: "2026-11-22T03:50:00Z" }],
        tasks: [{ id: "70000002-0000-4000-8000-000000000002", title: null, status: "todo", created_at: "2026-11-22T03:55:00Z" }]
    }, { now: AT, baseUrl: BASE });
    const m = P.buildPanes(scene, { now: AT });
    assert.equal(m.latest[0].title, "Untitled context");
    assert.equal(m.latest[2].title, "untitled task", "the data layer's word, as the river shows it");
    assert.equal(m.latest[0].url, `${BASE}/r/c0000002`);
    for (const s of strings(m)) assert.ok(!/\b(null|undefined|NaN)\b/.test(s), `"${s}"`);
});
