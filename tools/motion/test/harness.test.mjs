// node --test tools/motion/test/
// The shared motion harness: the follow check fails each wrong path it exists to
// catch (and passes the right one), the spec check matches the code, and every
// catalogue mutation still applies to this tree.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { check, parse } from "../follow.mjs";
import { checkSpec } from "../spec.mjs";
import { catalogue, plan } from "../apply.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const realSpec = JSON.parse(fs.readFileSync(path.join(root, "docs/motion.json"), "utf8"));

// A log from per-tick frames: frames[k] = { axis: value } for one item, 16 ms apart.
function log(items) {
    const out = [];
    let t = 1000;
    for (const [id, frames] of Object.entries(items)) {
        const [comp, part, ident] = id.split(" ");
        const last = {};
        frames.forEach((f, k) => {
            // Like Trace.qml: an axis logs only when it changes.
            for (const [a, v] of Object.entries(f)) if (last[a] !== v && (last[a] = v) !== undefined) out.push([k, `amplify: trace ${comp} ${part} ${ident} ${a} ${v.toFixed(6)} ${t + k * 16} ${k + 1}`]);
        });
    }
    // Items' frames interleave, as they do in a real run (stable sort by frame).
    return out.sort((x, y) => x[0] - y[0]).map((x) => x[1]).join("\n");
}
const spring = { kind: "spring", min: 20, eps: 0.5, clear: 1, minBetween: 3, maxStep: 0.5, overshoot: 0.15, settle: 4 };
const spec = (axes, want = {}, still = false) => ({
    rows: [{ id: "t", comp: "c", parts: [{ part: "p", axes }, { part: "q", axes: { x: { kind: "rides", with: "p", tol: 1 } } }] }],
    scenarios: { s: { want, still } }
});
// Move from 0 to 100 through path (values after the target change), then hold.
const move = (path, hold = 30) => [{ x: 0, "x:to": 0 }, { "x:to": 100 }, ...path.map((x) => ({ x })), ...Array(hold).fill({ x: 100 })];
const ease = Array.from({ length: 30 }, (_, k) => 100 * (1 - Math.exp(-k / 5)));
const run = (axes, items, want, still) => check(spec(axes, want, still), "s", log(items));

test("spring: a smooth slide passes; a jump, an overshoot, a wrong start and a lag fail", () => {
    assert.ok(run({ x: spring }, { "c p a": move([...ease, 100]) }, { "c.p.x": 1 }).ok);
    assert.equal(run({ x: spring }, { "c p a": move([100]) }).ok, false, "jump");
    assert.equal(run({ x: spring }, { "c p a": move([10, 30, 60, 90, 130, 115, 100]) }).ok, false, "overshoot 30 %");
    assert.ok(run({ x: spring }, { "c p a": move([10, 30, 60, 90, 110, 104, 100]) }).ok, "overshoot 10 % is inside 15 %");
    assert.equal(run({ x: spring }, { "c p a": move([-5, 20, 40, 60, 80, 100]) }).ok, false, "first move away");
    assert.equal(run({ x: spring }, { "c p a": move([1, 2, 3, 4, 5], 0) }).ok, false, "never arrives");
    assert.equal(run({ x: { ...spring, settle: 0.1 } }, { "c p a": move([...ease, 100]) }).ok, false, "too slow to settle");
    // holds then jumps: samples sit at the start, then one step.
    assert.equal(run({ x: spring }, { "c p a": move([0, 0, 0, 0, 100]) }).ok, false, "holds then jumps");
});

test("spring: the drawn value must hold at its target before it changes, and want counts movers", () => {
    assert.equal(run({ x: spring }, { "c p a": [{ x: 0, "x:to": 0 }, { x: 40 }, { x: 0 }] }).ok, false, "moves without a record");
    const r = run({ x: spring }, { "c p a": [{ x: 0, "x:to": 0 }, { x: 0 }] }, { "c.p.x": 1 });
    assert.equal(r.ok, false, "nothing moved but the scenario wants a mover");
});

test("rides: within 1 px of its partner passes; 3 px off or ending elsewhere fails", () => {
    const p = move([...ease, 100]);
    const xs = p.map((f) => f.x).filter((x) => x !== undefined);
    assert.ok(run({ x: spring }, { "c p a": p, "c q a": xs.map((x) => ({ x })) }).ok);
    assert.equal(run({ x: spring }, { "c p a": p, "c q a": xs.map((x) => ({ x: x + 3 })) }).ok, false);
    assert.equal(run({ x: spring }, { "c p a": p, "c q a": [{ x: 0 }] }).ok, false, "rider never moves");
});

test("sweep: once from start to end, monotone; static, backwards or short fails", () => {
    const sw = { kind: "sweep", from: 0, to: -140, tol: 1, minBetween: 10, maxStep: 0.25 };
    const turn = (f) => Array.from({ length: 41 }, (_, k) => ({ x: f(k / 40) }));
    assert.ok(run({ x: sw }, { "c p a": turn((p) => -140 * p) }).ok);
    assert.equal(run({ x: sw }, { "c p a": turn(() => 0) }).ok, false, "static");
    assert.equal(run({ x: sw }, { "c p a": turn((p) => 140 * p) }).ok, false, "wrong way");
    assert.equal(run({ x: sw }, { "c p a": turn((p) => -140 * Math.min(1, p * 1.2) + (p > 0.5 && p < 0.6 ? 20 : 0)) }).ok, false, "turns back");
    assert.equal(run({ x: sw }, { "c p a": turn((p) => -70 * p) }).ok, false, "stops halfway");
});

test("spin and clock: turn at the record's rate, hold at rate 0", () => {
    const sp = { kind: "spin", rateTol: 0.25 };
    const frames = (rate, drawn) => Array.from({ length: 120 }, (_, k) => ({ x: drawn * k * 0.016, "x:rate": rate }));
    assert.ok(run({ x: sp }, { "c p a": frames(-40, -40) }).ok);
    assert.equal(run({ x: sp }, { "c p a": frames(-40, 40) }).ok, false, "wrong way");
    assert.equal(run({ x: sp }, { "c p a": frames(-40, -20) }).ok, false, "half speed");
    assert.equal(run({ x: sp }, { "c p a": frames(0, 5) }).ok, false, "turns with rate 0");
});

test("still: a change outside a data step fails", () => {
    assert.ok(run({ x: spring }, { "c p a": [{ x: 0, "x:to": 0 }, { x: 100, "x:to": 100 }] }, {}, true).ok);
    assert.equal(run({ x: spring }, { "c p a": [{ x: 0, "x:to": 0 }, { "x:to": 100 }, { x: 50 }, { x: 100 }] }, {}, true).ok, false);
});

test("a traced part or axis the spec does not list fails", () => {
    assert.equal(run({ x: spring }, { "c z a": [{ x: 1 }] }).ok, false);
    assert.equal(run({ x: spring }, { "c p a": [{ x: 0, "x:to": 0, y: 3 }] }).ok, false);
});

test("a recreated item (its emit count restarts) is a new series, not merged into the old", () => {
    const text = log({ "c p a": [{ x: 1 }, { x: 2 }] }) + "\n" + log({ "c p a": [{ x: 9 }] });
    assert.deepEqual([...parse(text).keys()], ["c p a", "c p a#2"]);
});

test("docs/motion.json matches the code: every animation claimed, every part hooked", () => {
    const r = checkSpec(realSpec, root);
    assert.deepEqual(r.problems, []);
    assert.ok(r.decls >= 40, `${r.decls} declarations found`);
});

test("the spec check fails when a row is deleted or an animation is added without one", () => {
    const less = { ...realSpec, rows: realSpec.rows.filter((r) => r.id !== "river-8") };
    assert.ok(checkSpec(less, root).problems.some((p) => p.includes("rotation: -fxi.p * 140")));
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "spec-"));
    fs.cpSync(path.join(root, "plugin"), path.join(tmp, "plugin"), { recursive: true, verbatimSymlinks: true });
    const f = path.join(tmp, "plugin/basin/Basin.qml");
    fs.writeFileSync(f, fs.readFileSync(f, "utf8").replace("  width: 500\n", "  width: 500\n  NumberAnimation on opacity { running: false }\n"));
    const r = checkSpec(realSpec, tmp);
    fs.rmSync(tmp, { recursive: true });
    assert.ok(r.problems.some((p) => p.includes("Basin.qml") && p.includes("not in docs/motion.json")), r.problems.join("\n"));
});

test("the mutation catalogue applies to this tree and covers the river records", () => {
    const all = catalogue(), ids = all.map((m) => m.id);
    assert.equal(new Set(ids).size, ids.length, "ids unique");
    const gates = new Set(["data", "orbs", "river", "motion", "spec", "river-shot", "orbs-shot", "headless"]);
    for (const m of all) {
        assert.deepEqual(plan(root, m).stale, [], m.id);
        assert.ok(m.gates.length && m.gates.every((g) => gates.has(g)), `${m.id} gates ${m.gates}`);
    }
    for (const id of ["K1-lease-tween-removed", "K2-hull-y-target", "K4-tether-y2-target", "K14-pass-ring-still-only", "X1-tether-voff-behavior-removed", "SP-row-deleted"])
        assert.ok(ids.includes(id), id);
    assert.ok(all.filter((m) => m.source.startsWith("05a122b0") || m.source.startsWith("07b07aed")).length >= 51, "the 51 river mutations");
});
