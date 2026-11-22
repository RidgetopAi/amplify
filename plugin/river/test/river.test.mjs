// node --test plugin/river/test/
// Loads plugin/river/river.js the way QML does (minus `.pragma library`) and
// drives it with scenes the data layer builds from real fixtures.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../../..");
const { M } = createRequire(import.meta.url)(path.join(root, "data/node.cjs"));
const src = fs.readFileSync(path.join(here, "../river.js"), "utf8").replace(/^\.pragma library\s*$/m, "");
const names = [...src.matchAll(/^(?:function|var)\s+([A-Za-z_$][\w$]*)/gm)].map((m) => m[1]);
const R = new Function(`${src}\nreturn { ${names.join(", ")} };`)();

const snapshot = JSON.parse(fs.readFileSync(path.join(root, "fixtures/amplify-snapshot.json"), "utf8"));
const busy = JSON.parse(fs.readFileSync(path.join(here, "busy-frames.json"), "utf8"));
const W = 1920;
const at = (iso) => Date.parse(iso);
const captured = at(snapshot.meta.captured_at);
const T = captured; // busy fixture is staged around the same instant

function gateOf(lay, lane) { return lay.gates.find((g) => g.lane === lane); }

test("every visible task rides its scene-model lane, inside that lane's span", () => {
    const scene = R.replaySceneAt(M, snapshot, captured);
    const lay = R.layout(scene, captured, W);
    assert.deepEqual(lay.gates.map((g) => g.label), ["draft", "ready", "claimed", "verifying", "evidence", "merged", "trunk"]);
    const visible = scene.tasks.filter((t) => !t.hidden);
    assert.equal(lay.vessels.length + Object.values(lay.overflow).reduce((a, b) => a + b, 0), visible.length);
    for (const v of lay.vessels) {
        const t = scene.tasks.find((x) => x.id === v.id);
        assert.equal(v.lane, t.lane, v.id8);
        const g = gateOf(lay, v.lane);
        assert.ok(v.x > g.x && v.x < g.x1, `${v.id8} x ${v.x} outside ${v.lane} [${g.x}, ${g.x1}]`);
    }
    // Snapshot at capture: 9 drafts, P0's 2 claims, 5 merged; the cancelled smoke punch is hidden.
    assert.equal(gateOf(lay, "draft").count, 9);
    assert.equal(gateOf(lay, "claimed").count, 2);
    assert.equal(gateOf(lay, "merged").count, 5);
    assert.ok(!lay.vessels.some((v) => v.id.startsWith("f5dc63e9")));
    for (let i = 1; i < lay.gates.length; i++) assert.equal(lay.gates[i].x, lay.gates[i - 1].x1);
});

test("tether shows the remaining lease on the scene clock", () => {
    const scene = R.replaySceneAt(M, snapshot, captured);
    const lay = R.layout(scene, captured, W);
    const p0 = lay.tethers.find((x) => x.id.startsWith("a15523ac"));
    // claim_expires_at 04:37:50.421 vs captured 04:00:17: 37.5 min of 45.
    assert.equal(p0.expired, false);
    assert.ok(Math.abs(p0.fraction - (37 * 60 + 33.421) / 2700) < 1e-6, String(p0.fraction));
    assert.equal(p0.text, "37m left");
    assert.equal(p0.holder, "shell-spike");
});

test("an expired claim draws a slack tether even while the row still says live", () => {
    const scene = R.replaySceneAt(M, snapshot, captured);
    const late = at("2026-11-22T04:40:00Z"); // after a15523ac expired (04:37:50), before 0edf3b35 (04:45:17)
    const lay = R.layout(scene, late, W);
    const a = lay.tethers.find((x) => x.id.startsWith("a15523ac"));
    const b = lay.tethers.find((x) => x.id.startsWith("0edf3b35"));
    assert.equal(scene.tasks.find((t) => t.id === a.id).claimLive, true);
    assert.equal(a.expired, true);
    assert.equal(a.fraction, 0);
    assert.equal(a.text, "lease expired");
    assert.equal(b.expired, false);
    assert.ok(b.fraction > 0.1 && b.fraction < 0.12, String(b.fraction));
    assert.deepEqual(R.lease({ claimLive: false, claimExpiresAt: "2026-11-22T05:00:00Z" }, late),
                     { expired: true, fraction: 0, remainingSec: 0 });
});

test("critic PASS and REJECT come from lane changes; a reject sails upstream", () => {
    const prev = R.replaySceneAt(M, busy, T);
    const next = R.replaySceneAt(M, busy, T + 90 * 1000);
    const ev = R.transitions(prev, next);
    const pass = ev.find((e) => e.taskId.startsWith("379c80c6"));
    const rej = ev.find((e) => e.taskId.startsWith("6bbaf7d0"));
    assert.deepEqual([pass.kind, pass.from, pass.to], ["pass", "verifying", "evidence"]);
    assert.deepEqual([rej.kind, rej.from, rej.to], ["reject", "verifying", "ready"]);
    assert.equal(ev.length, 2);

    const lay = R.layout(next, T + 90 * 1000, W);
    const v = lay.vessels.find((x) => x.id === rej.taskId);
    const ready = gateOf(lay, "ready"), verifying = gateOf(lay, "verifying");
    assert.equal(v.lane, "ready");
    assert.ok(v.x > ready.x && v.x < ready.x1 && v.x < verifying.x, `reject at ${v.x}`);
    const p = lay.vessels.find((x) => x.id === pass.taskId);
    assert.equal(p.lane, "evidence");
    assert.ok(p.x > gateOf(lay, "evidence").x);
    // Ordinary moves are not verdicts.
    const back = R.transitions({ tasks: [{ id: "x", lane: "claimed" }] }, { tasks: [{ id: "x", lane: "ready" }] });
    assert.equal(back[0].kind, "retreat");
});

test("9 claims: tethers keep vessel order, never cross, and moorings stay apart", () => {
    const now = T + 90 * 1000;
    const lay = R.layout(R.replaySceneAt(M, busy, now), now, W);
    assert.equal(lay.tethers.length, 9);
    const vx = Object.fromEntries(lay.vessels.map((v) => [v.id, v.x]));
    for (let i = 1; i < lay.tethers.length; i++) {
        const a = lay.tethers[i - 1], b = lay.tethers[i];
        assert.ok(vx[a.id] <= vx[b.id], "sorted by vessel x");
        assert.ok(b.mx - a.mx >= 132 - 1e-9, `moorings ${a.mx} ${b.mx}`);
        assert.ok(b.mx > 0 && b.mx < W);
    }
    const expired = lay.tethers.filter((t) => t.expired).map((t) => t.id8);
    assert.deepEqual(expired, ["523461dd"]);
    assert.equal(new Set(lay.tethers.map((t) => t.holder)).size, 9);
    const eddy = lay.vessels.find((v) => v.id.startsWith("85ff482a"));
    assert.equal(eddy.eddy, true);
    assert.equal(eddy.needsYou, true);
    assert.equal(eddy.color, R.WARM);
});

test("moorings sit centred on their vessels, not pushed to one side", () => {
    // Four vessels bunched at 1000: the spaced set is centred on them.
    const m = R.placeMoorings([990, 1000, 1000, 1010], W);
    assert.deepEqual(m, [802, 934, 1066, 1198]);
    // Already far apart: untouched.
    assert.deepEqual(R.placeMoorings([200, 600, 1200], W), [200, 600, 1200]);
    // Against the right edge: shifted left as one block.
    assert.deepEqual(R.placeMoorings([1900, 1900], W), [1718, 1850]);
});

test("water speed is zero without recent task updates and rises with flow", () => {
    assert.equal(R.flowSpeed(0), 0);
    assert.ok(R.flowSpeed(0.125) > 0);
    assert.ok(R.flowSpeed(0.5) > R.flowSpeed(0.125));
    assert.ok(R.flowSpeed(1) > R.flowSpeed(0.5));
    // Idle replay (no task touched in the 15 min before 04:30Z): flow 0, still water.
    const idle = at("2026-11-22T04:30:00Z");
    const lay = R.layout(R.replaySceneAt(M, snapshot, idle), idle, W);
    assert.equal(lay.flow, 0);
    assert.equal(R.flowSpeed(lay.flow), 0);
});

test("the upstream row sits half a column off the centre row", () => {
    const lay = R.layout(R.replaySceneAt(M, snapshot, captured), captured, W);
    const draft = lay.vessels.filter((v) => v.lane === "draft");
    const centre = draft.filter((v) => v.row === 0).map((v) => v.x);
    const up = draft.filter((v) => v.row === -1).map((v) => v.x);
    assert.ok(centre.length >= 2 && up.length >= 1, `rows ${centre.length}/${up.length}`);
    for (const x of up) {
        const d = Math.min(...centre.map((c) => Math.abs(c - x)));
        assert.ok(Math.abs(d - 92 / 2) < 1e-9, `upstream hull ${x} is ${d} from the centre row`);
    }
});

test("a released claim leaves no tether; a lapsed one in the claimed lane stays slack", () => {
    const now = at("2026-11-22T04:00:00Z");
    const scene = { tasks: [
        { id: "aaaaaaaa-1", id8: "aaaaaaaa", lane: "ready", claimActor: "brian/x", claimLive: false,
          claimExpiresAt: "2026-11-22T04:30:00Z", updatedAt: "2026-11-22T03:00:00Z" },
        { id: "bbbbbbbb-1", id8: "bbbbbbbb", lane: "claimed", claimActor: "brian/y", claimLive: false,
          claimExpiresAt: "2026-11-22T03:30:00Z", updatedAt: "2026-11-22T03:00:00Z" },
        { id: "cccccccc-1", id8: "cccccccc", lane: "verifying", claimActor: "brian/z", claimLive: true,
          claimExpiresAt: "2026-11-22T04:30:00Z", updatedAt: "2026-11-22T03:00:00Z" },
    ], sessions: [] };
    const lay = R.layout(scene, now, W);
    assert.deepEqual(lay.tethers.map((t) => [t.id8, t.expired]), [["bbbbbbbb", true], ["cccccccc", false]]);
});
