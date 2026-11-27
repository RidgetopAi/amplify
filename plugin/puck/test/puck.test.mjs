// node --test plugin/puck/test/
// Puck's mapping (task 23a62966) against the shipped capture (fixtures/amplify-snapshot.json).
// Expected values come from the punch (curious, never a frown; a click runs
// `amp-desktop --puck`), the viewer contract (22d73eeb: needs-you rows) and the captured
// timestamps, not from the code under test.
import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import fs from "node:fs";

const require = createRequire(import.meta.url);
const { M } = require("../../../data/node.cjs");
const P = require("./load.cjs");
const read = (f) => fs.readFileSync(new URL(f, import.meta.url), "utf8");
const snap = JSON.parse(read("../../../fixtures/amplify-snapshot.json"));
const CAP = Date.parse(snap.meta.captured_at);            // 04:00:17Z: two open decisions need you
const EARLY = Date.parse(snap.meta.replay_from);          // 21:36:00Z: nothing needs you

test("curious by default, never a frown: the mouth corners turn up at rest and smile wider on hover", () => {
  assert.ok(P.mouth(false) > 0, `rest bend ${P.mouth(false)} must be above 0 (0 is flat, below is a frown)`);
  assert.ok(P.mouth(true) > P.mouth(false), "hover smiles wider than rest");
  assert.ok(P.mouthHalf(false) > 0 && P.mouthHalf(true) > P.mouthHalf(false));
  assert.ok(P.BROW > 0, "brows raised");
});

test("both shaders draw the mouth bend Puck.qml hands them, unchanged (no frown re-mapped in GLSL)", () => {
  const cel = read("../../../shaders/puck_cel.frag"), fig = read("../../../shaders/puck_figurine.frag");
  // y = mouth * x^2 under the nose: the uniform itself is the bend.
  assert.match(cel, /u\.y - \(-0\.36 \+ mouth \* fx \* fx\)/);
  assert.match(fig, /m\.y - mouth \* fx \* fx/);
  for (const [name, src] of [["cel", cel], ["figurine", fig]]) {
    const code = src.replace(/\/\/.*$/gm, "");
    const uses = [...code.matchAll(/\bmouth\b/g)].length;
    assert.equal(uses, 2, `${name}: the mouth uniform is declared once and used once, in the bend`);
  }
  const qml = read("../Puck.qml");
  assert.match(qml, /property real mouth: P\.mouth\(pointing\)/);
  assert.match(qml, /property real mouth: puck\.mouth\n/);
});

test("a click runs amp-desktop --puck, never a URL", () => {
  assert.deepEqual(P.command(), ["amp-desktop", "--puck"]);
  P.command().push("x");
  assert.deepEqual(P.command(), ["amp-desktop", "--puck"], "callers get a copy");
  const qml = read("../Puck.qml");
  const act = qml.slice(qml.indexOf("function activate()"), qml.indexOf("}", qml.indexOf("function activate()")));
  assert.match(act, /Quickshell\.execDetached\(argv\)/);
  assert.match(act, /var argv = P\.command\(\)/);
  assert.doesNotMatch(qml, /openUrlExternally|https?:\/\//, "Puck opens nothing in a browser");
  assert.match(qml, /onClicked: puck\.activate\(\)/);
});

test("the finger is up while the capture has needs-you rows, half raised when it has none, up on hover", () => {
  const cap = M.replayScene(snap, CAP), early = M.replayScene(snap, EARLY);
  assert.equal(P.needs(cap), 2);          // two open decisions at 04:00Z
  assert.equal(P.needs(early), 0);
  assert.equal(P.raise(cap, false), 1);
  assert.equal(P.raise(early, false), P.RAISE_REST);
  assert.ok(P.RAISE_REST > 0 && P.RAISE_REST < 1);
  assert.equal(P.raise(early, true), 1);
  assert.equal(P.raise(null, false), P.RAISE_REST);
});

test("a blink needs the newest activity to move later; the first scene and a held replay never blink", () => {
  assert.equal(P.blinks(null, CAP), false, "first scene: baseline");
  const held = M.lastActivityMs(M.replayScene(snap, CAP), CAP);
  assert.equal(P.blinks(held, M.lastActivityMs(M.replayScene(snap, CAP), CAP)), false, "held capture: no change");
  // The replay stepped 10 s (the motion sheet): the newest activity moves on.
  const t = Date.parse("2026-11-22T02:29:00Z");
  const a0 = M.lastActivityMs(M.replayScene(snap, t), t), a1 = M.lastActivityMs(M.replayScene(snap, t + 10000), t + 10000);
  assert.equal(P.blinks(a0, a1), true);
  assert.equal(P.blinks(a1, a0), false, "an earlier moment never blinks");
  assert.equal(P.blinks(a0, null), false);
});

test("the glance turns toward the pointer (right and up are positive) and saturates", () => {
  assert.deepEqual(P.look(50, -25, 100), { x: 0.5, y: 0.25 });
  assert.deepEqual(P.look(-400, 400, 100), { x: -1, y: -1 });
  assert.deepEqual(P.REST_LOOK, { x: 0, y: 0 });
});

test("desktop size: 210 px at 1920x1080, scaled by the smaller side", () => {
  assert.equal(P.deskSize(1920, 1080), 210);
  assert.equal(P.deskSize(3840, 2160), 420);
  assert.equal(P.deskSize(1600, 900), 175);
});
