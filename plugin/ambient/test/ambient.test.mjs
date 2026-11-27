// node --test plugin/ambient/test/
// The ambient music field (task 523461dd): cava's frames, the MPRIS gate, and that music
// only modulates the Mandrel field. Expected values are worked out here, not taken from the code.
import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const load = require("../../perf/test/load.cjs");
const A = load("../../ambient/ambient.js");
const { M, loadSnapshot } = require("../../../data/node.cjs");

test("a cava raw ascii frame parses to bars in 0..1; partial or garbled frames are dropped", () => {
  assert.deepEqual(A.parseFrame("0;500;1000;\n", 3, 1000), [0, 0.5, 1]);
  assert.deepEqual(A.parseFrame("250;1200", 2, 1000), [0.25, 1]);
  assert.equal(A.parseFrame("0;500;\n", 3, 1000), null);
  assert.equal(A.parseFrame("0;x;5;", 3, 1000), null);
  assert.equal(A.parseFrame(Array(16).fill(10).join(";") + ";").length, 16, "the shipped bar count");
});

test("cava runs only while a player reports Playing and a screen draws", () => {
  assert.equal(A.isPlaying(["Paused", "Playing"]), true);
  assert.equal(A.isPlaying(["Paused", "Stopped"]), false);
  assert.equal(A.isPlaying([]), false);
  assert.equal(A.cavaShouldRun({ playing: true, drawing: 1 }), true);
  assert.equal(A.cavaShouldRun({ playing: false, drawing: 3 }), false, "paused: no cava");
  assert.equal(A.cavaShouldRun({ playing: true, drawing: 0 }), false, "every screen covered: no cava");
});

test("the field's height is the scene's active sessions (live + forming + quiet) over 6", () => {
  const scene = { counts: { liveness: { live: 2, forming: 1, quiet: 0, lost: 3, dormant: 4, ended: 5 } } };
  assert.deepEqual(A.fieldBase(scene), { field: "scene.counts.liveness", active: 3, level: 0.5 });
  assert.equal(A.fieldBase(null).level, 0);
  assert.equal(A.fieldBase({ counts: { liveness: { live: 9 } } }).level, 1);
});

test("the shipped replay has active sessions, so the field shows", () => {
  const snap = loadSnapshot();
  const scene = M.replayScene(snap, Date.parse(snap.meta.captured_at));
  const raw = scene.sessions.filter((s) => ["live", "forming", "quiet"].includes(s.liveness)).length;
  assert.ok(raw > 0);
  assert.equal(A.fieldBase(scene).active, raw);
});

test("music only modulates: no field, no light; no music, the resting shape; bands scale it within 0.6..1.4", () => {
  const loud = Array(16).fill(1), quiet = Array(16).fill(0), mid = Array(16).fill(0.5);
  assert.ok(A.fieldLevels(0, loud).every((v) => v === 0), "no active session: music draws nothing");
  const rest = A.fieldLevels(0.5, null);
  assert.equal(rest.length, 16);
  assert.ok(Math.abs(rest[0] - 0.5 * (0.55 + 0.45 * Math.sin(Math.PI * 0.5 / 16))) < 1e-12);
  assert.ok(rest[7] > rest[0] && Math.abs(rest[7] - rest[8]) < 1e-12, "a hill, highest mid-screen");
  assert.deepEqual(A.fieldLevels(0.5, mid), rest, "a mid band is the resting height");
  A.fieldLevels(0.5, loud).forEach((v, i) => assert.ok(Math.abs(v - rest[i] * 1.4) < 1e-12));
  A.fieldLevels(0.5, quiet).forEach((v, i) => assert.ok(Math.abs(v - rest[i] * 0.6) < 1e-12));
});
