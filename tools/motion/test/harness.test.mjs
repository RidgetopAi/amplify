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
import { spawnSync } from "node:child_process";
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
    scenarios: { s: { want, still, ...(still && { traced: ["c"] }) } }
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

test("a log with no trace lines fails, still or not (G1)", () => {
    const untraced = "amplify: ready layer=bottom screen=HEADLESS-1\namplify: palette accent=#7aa2f7";
    assert.equal(check(spec({ x: spring }, {}, true), "s", untraced).ok, false, "still scenario, no floors");
    assert.equal(check(spec({ x: spring }), "s", "").ok, false, "live scenario, no floors");
    assert.equal(check(realSpec, "service-still", untraced).ok, false, "service-still");
    assert.equal(check(realSpec, "river-still", untraced).ok, false, "river-still");
});

test("a still scenario fails when one component it names logs no trace, or it names none (GAP-A)", () => {
    const two = { rows: [{ id: "t", comp: "c", parts: [{ part: "p", axes: { x: spring } }] }, { id: "u", comp: "d", parts: [{ part: "q", axes: { x: spring } }] }],
                  scenarios: { s: { still: true, want: {}, traced: ["c", "d.q"] }, bare: { still: true, want: {} } } };
    const held = [{ x: 0, "x:to": 0 }, { x: 0 }];
    assert.equal(check(two, "s", log({ "c p a": held, "d q b": held })).ok, true, "both traced");
    assert.equal(check(two, "s", log({ "c p a": held })).ok, false, "d untraced (only c logs)");
    assert.equal(check(two, "s", log({ "d q b": held })).ok, false, "c untraced (only d logs)");
    assert.equal(check(two, "bare", log({ "c p a": held, "d q b": held })).ok, false, "still scenario without traced");
    for (const sc of ["service-still", "river-still"]) assert.ok(realSpec.scenarios[sc].traced.length, `${sc} names its components`);
    assert.deepEqual(new Set(realSpec.scenarios["service-still"].traced.map((x) => x.split(".")[0])), new Set(["river", "orbs", "basin"]));
});

test("a traced part or axis the spec does not list fails", () => {
    assert.equal(run({ x: spring }, { "c z a": [{ x: 1 }] }).ok, false);
    assert.equal(run({ x: spring }, { "c p a": [{ x: 0, "x:to": 0, y: 3 }] }).ok, false);
});

test("a recreated item (its emit count restarts) is a new series, not merged into the old", () => {
    const text = log({ "c p a": [{ x: 1 }, { x: 2 }] }) + "\n" + log({ "c p a": [{ x: 9 }] });
    assert.deepEqual([...parse(text).keys()], ["c p a", "c p a#2"]);
    // keyed: an item made again fails; the same item kept, or a new ident, passes (8b5eca2f).
    const sp = { ...spec({ x: { kind: "none" } }), scenarios: { s: { keyed: ["c.p"] } } };
    assert.equal(check(sp, "s", text).ok, false);
    assert.equal(check(sp, "s", log({ "c p a": [{ x: 1 }, { x: 2 }, { x: 9 }] }) + "\n" + log({ "c p b": [{ x: 9 }] })).ok, true);
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
    const src = fs.readFileSync(f, "utf8");
    for (const decl of ["NumberAnimation on opacity { running: false }", "OpacityAnimator on opacity { running: false }", "RotationAnimator { target: pool; running: false }"]) {
        fs.writeFileSync(f, src.replace("  width: 500\n", `  width: 500\n  ${decl}\n`));
        const r = checkSpec(realSpec, tmp);
        assert.ok(r.problems.some((p) => p.includes("Basin.qml") && p.includes("not in docs/motion.json") && p.includes(decl)), `${decl}\n${r.problems.join("\n")}`);
    }
    fs.rmSync(tmp, { recursive: true });
});

test("the mutation catalogue applies to this tree and covers the river records", () => {
    const all = catalogue(), ids = all.map((m) => m.id);
    assert.equal(new Set(ids).size, ids.length, "ids unique");
    const gates = new Set(["data", "orbs", "river", "focus", "motion", "spec", "qsb", "mutate", "river-shot", "orbs-shot", "headless", "headless-pair",
                           "ambient", "ambient-shot", "puck", "puck-shot", "basin-shot", "install", "gles", "gles-src"]);
    for (const m of all) {
        assert.deepEqual(plan(root, m).stale, [], m.id);
        assert.ok(m.gates.length && m.gates.every((g) => gates.has(g)), `${m.id} gates ${m.gates}`);
    }
    for (const id of ["K1-lease-tween-removed", "K2-hull-y-target", "K4-tether-y2-target", "K14-pass-ring-still-only", "X1-tether-voff-behavior-removed", "SP-row-deleted", "XG1-service-trace-off-in-still", "XG1b-untraced-still-pool-fades", "XG2-unlisted-animator",
                     "GA-basin-untraced-in-still", "GAb-basin-untraced-still-pool-fades", "N1-blank-capture-guard-off", "G3-broken-pool-frag", "G6-shader-error-only-for-orbs",
                     "QG1-beam-qsb-truncated", "QG2-beam-source-not-rebuilt", "PC1-critic-body-magenta", "PC2-critic-body-black-quad", "PC3-beam-fills-quad-white",
                     "MF1-trust-to-hue", "MF2-loupe-detent-off", "GL1-meridian-array-ctor", "GL2-old-meridian-qsb-shipped"])
        assert.ok(ids.includes(id), id);
    assert.ok(all.filter((m) => m.source.startsWith("05a122b0") || m.source.startsWith("07b07aed")).length >= 51, "the 51 river mutations");
});

// Critic gap G1 (verdict 0d8e0859): a frame-rate tween on an eased orb axis the live-orbs
// window never changes survived every gate. Every eased orbs-orb axis carries a pace floor
// (follow.mjs), and the catalogue tweens each on Qt's driver (form: OF2).
test("every eased orb axis is paced in the spec and tweened on the driver in the catalogue", () => {
    const spec = JSON.parse(fs.readFileSync(path.join(root, "docs/motion.json"), "utf8"));
    const axes = spec.rows.find((r) => r.id === "orbs-orb").parts.find((p) => p.part === "orb").axes;
    const eased = Object.keys(axes).filter((a) => axes[a].kind === "tween");
    assert.deepEqual(eased.sort(), ["dorm", "ended", "energy", "form", "length", "light", "lost", "need", "sat"]);
    for (const a of eased) assert.ok(axes[a].pace >= 100, `orbs.orb.${a} has no pace floor`);
    const ids = catalogue().map((m) => m.id);
    for (const a of ["sat", "light", "dorm", "lost", "need", "ended", "energy", "level"]) assert.ok(ids.includes(`G1-${a}-tween-on-driver`), a);
    assert.ok(ids.includes("OF2-orb-form-tween-on-driver"));
});

test("a mutation of a shared source reaches the plugin's copies of it, as the symlinks did", (ctx) => {
    const t = fs.mkdtempSync(path.join(os.tmpdir(), "apply-test-"));
    ctx.after(() => fs.rmSync(t, { recursive: true, force: true }));
    for (const d of ["data", "fixtures", "plugin", "tools"]) fs.cpSync(path.join(root, d), path.join(t, d), { recursive: true });
    const r = spawnSync(process.execPath, [path.join(root, "tools/motion/apply.mjs"), t, "L3-blocked-no-eddy"], { encoding: "utf8" });
    assert.equal(r.status, 0, r.stdout + r.stderr);
    const src = fs.readFileSync(path.join(t, "data/mandrel.js"), "utf8");
    assert.notEqual(src, fs.readFileSync(path.join(root, "data/mandrel.js"), "utf8"), "the source is mutated");
    for (const c of ["basin", "orbs", "river"]) assert.equal(fs.readFileSync(path.join(t, "plugin", c, "mandrel.js"), "utf8"), src, `plugin/${c}/mandrel.js`);
});
