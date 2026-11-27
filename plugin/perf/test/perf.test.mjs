// node --test plugin/perf/test/
// The performance budget rules (task 523461dd): the 30 fps cap and when a screen pauses.
import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const P = require("./load.cjs")("../perf.js");

test("the frame gate passes at most 30 frames a second from a 120 fps producer", () => {
  const g = P.createFrameGate(P.FPS_CAP);
  let n = 0;
  for (let t = 0; t < 1000; t += 1000 / 120) if (g.accept(Math.round(t))) n++;
  assert.ok(n <= 30 && n >= 29, `${n} frames passed`);
});

test("the frame gate passes every frame of a producer at or under the cap", () => {
  const g = P.createFrameGate(30);
  let n = 0;
  for (let k = 0; k < 24; k++) if (g.accept(Math.round(k * 1000 / 24))) n++;
  assert.equal(n, 24);
});

test("a screen pauses under a fullscreen or maximized window on it, not one elsewhere or minimized", () => {
  const win = (o) => ({ fullscreen: false, maximized: false, minimized: false, screens: ["DP-1"], ...o });
  const st = (tops, tiled) => P.screenState(tops, "DP-1", tiled);
  assert.equal(P.shouldDraw(st([])), true);
  assert.equal(P.shouldDraw(st([win({})])), true, "a floating window leaves the desktop showing");
  assert.deepEqual(st([win({ fullscreen: true })]), { fullscreen: true, covered: true });
  assert.equal(P.shouldDraw(st([win({ maximized: true })])), false);
  assert.equal(P.shouldDraw(st([win({ fullscreen: true, screens: ["DP-2"] })])), true, "fullscreen on another screen");
  assert.equal(P.shouldDraw(st([win({ maximized: true, minimized: true })])), true, "minimized");
  assert.equal(P.shouldDraw(st([], 2)), false, "tiled windows on the shown Hyprland workspace cover it");
});

test("cpuPercent: ticks over seconds as a percent of one core", () => {
  assert.equal(P.cpuPercent(100, 120, 100, 10), 2);
});
