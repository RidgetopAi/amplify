// node --test plugin/focus/test/
// Meridian, the focused orb (task 85ff482a), against the shipped capture
// fixtures/amplify-snapshot.json at its capture time (04:00:17Z). Expected values come
// from the capture's timestamps and trust bands and from decision 49f5d444's mapping,
// not from the code under test.
import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import fs from "node:fs";

const require = createRequire(import.meta.url);
const { M } = require("../../../data/node.cjs");
const G = require("./load.cjs");
const snap = JSON.parse(fs.readFileSync(new URL("../../../fixtures/amplify-snapshot.json", import.meta.url)));
const NOW = Date.parse(snap.meta.captured_at);
const COORD = "de463c37";      // amplify-coord: 8 contexts, 4 decisions of its own, no claim
const WORKER = "4af6ff22";     // data-core: holds 0edf3b35, claim expires 04:45:17Z
const scene = (s = snap, at = NOW) => M.replayScene(s, at);
const ctxs = (s) => s.responses["/api/contexts"].contexts || s.responses["/api/contexts"];

test("time is longitude: now faces you, the past runs west on a log scale", () => {
  const g = G.globe(scene(), COORD, NOW);
  const own = ctxs(snap).filter((c) => c.session_id.startsWith(COORD)).sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at));
  const newest = g.plaques.find((p) => p.kind === "context");
  assert.equal(newest.id, own[0].id);
  // 03:50:36.270Z, 580.73 s before the capture: -0.52 ln(1 + 580.73 / 90).
  assert.ok(Math.abs(newest.lon - -0.52 * Math.log(1 + 580.73 / 90)) < 1e-3, `lon ${newest.lon}`);

  for (const p of g.plaques) assert.ok(p.lon < 0, `${p.id8} is in the past, west of now`);
  // Log, not linear: a record 4x older sits far less than 4x further west.
  assert.ok(G.lonOf(4 * 3600) / G.lonOf(3600) < 1.5);
  assert.ok(G.lonOf(60) < 0 && G.lonOf(0) === 0 && G.lonOf(3600) < G.lonOf(60));
  // Within a lane, newer is east.
  const lane = g.plaques.filter((p) => p.kind === "context");
  for (let i = 1; i < lane.length; i++) assert.ok(lane[i].lon < lane[i - 1].lon && lane[i].at <= lane[i - 1].at);
});

test("record type is latitude: one lane per kind, contexts and decisions north, tasks south", () => {
  const lats = {};
  for (const id of [COORD, WORKER]) for (const p of G.globe(scene(), id, NOW).plaques) (lats[p.kind] ||= new Set()).add(p.lat);
  for (const k of Object.keys(lats)) assert.equal(lats[k].size, 1, `${k} on one latitude`);
  assert.ok([...lats.context][0] > [...lats.decision][0] && [...lats.decision][0] > 0);
  assert.ok([...lats.task][0] < 0);
});

test("trust is brightness, never hue: trusted > unproven > superseded, one colour per kind", () => {
  const g = G.globe(scene(), COORD, NOW);
  const band = (b) => g.plaques.find((p) => p.kind === "context" && p.trust === b);
  // The capture's own bands: 8593dade trusted, 53163e57 unproven, cae2c3da superseded.
  assert.equal(band("trusted").id8, "8593dade");
  assert.equal(band("superseded").id8, "cae2c3da");
  assert.ok(band("trusted").bright > band("unproven").bright && band("unproven").bright > band("superseded").bright);
  const hues = new Set(g.plaques.filter((p) => p.kind === "context").map((p) => p.color));
  assert.equal(hues.size, 1, "contexts of three trust bands share one colour");
  assert.notEqual(g.plaques.find((p) => p.kind === "decision").color, band("trusted").color, "kinds differ in hue");
  // A record with no band reads as unproven (decisions carry none in the capture).
  assert.equal(g.plaques.find((p) => p.kind === "decision").bright, band("unproven").bright);
});

test("the lease is the lit future: claim_expires_at - now, as a share of the lease, east of now", () => {
  const w = G.globe(scene(), WORKER, NOW);
  // 04:45:17Z - 04:00:17Z = 2700 s, the whole default lease.
  assert.equal(Math.round(w.lease.leftSec), 2700);
  assert.ok(w.lease.held);
  assert.ok(Math.abs(w.lease.lon - G.LEASE_LON) < 1e-6, "a whole lease lights the whole arc");
  // 30 min later 900 s are left: the arc is shorter, never negative; expired at 04:46.
  const later = Date.parse("2026-11-22T04:30:17Z");
  const l2 = G.globe(scene(snap, NOW), WORKER, later).lease;
  assert.equal(Math.round(l2.leftSec), 900);
  assert.ok(Math.abs(l2.lon - G.LEASE_LON / 3) < 1e-6, "a third of the lease left lights a third of the arc");
  assert.equal(G.globe(scene(snap, NOW), WORKER, Date.parse("2026-11-22T04:46:00Z")).lease.lon, 0);
  assert.equal(G.globe(scene(), COORD, NOW).lease.lon, 0, "no claim, no lit arc");
  // With its task under the loupe, now (lon 0) and the whole lit future face the camera.
  const d = G.detentFor(w.plaques[w.newest], 0);
  for (const lon of [0, w.lease.lon]) assert.ok(G.toWorld(G.objOf(lon, 0), d.yaw, d.pitch)[2] < -0.3, `lon ${lon} in view`);
});

test("the lease arc never overlaps a plaque, and plaques never overlap each other", () => {
  for (const id of [COORD, WORKER]) {
    const pl = G.globe(scene(), id, NOW).plaques;
    for (const p of pl) assert.ok(Math.abs(p.lat) - p.hh > G.LEASE_HALF + 0.05, `${p.id8} clear of the lease band`);
    for (let i = 0; i < pl.length; i++) for (let j = i + 1; j < pl.length; j++) {
      const a = pl[i], b = pl[j];
      const dl = Math.abs(G.wrap(a.lon - b.lon)), lat = Math.min(Math.abs(a.lat), Math.abs(b.lat));
      const apart = Math.abs(a.lat - b.lat) >= a.hh + b.hh || dl * Math.cos(lat) >= a.hw + b.hw;
      assert.ok(apart, `${a.id8} and ${b.id8} overlap`);
    }
  }
});

test("under the loupe a plaque is whole: its outline stays inside the loupe's clear glass", () => {
  for (const id of [COORD, WORKER]) for (const p of G.globe(scene(), id, NOW).plaques) {
    const d = G.detentFor(p, 0);
    const q = G.plaqueInLoupe(p, d.yaw, d.pitch);
    assert.ok(q < G.LOUPE.clear, `${p.id8} reaches q=${q.toFixed(3)} of the loupe (rim from ${G.LOUPE.clear})`);
    // and the detent really puts its centre under the loupe's centre
    const at = G.loupePoint(d.yaw, d.pitch);
    assert.ok(Math.abs(G.wrap(at[0] - p.lon)) < 1e-6 && Math.abs(at[1] - p.lat) < 1e-6);
  }
});

// A throw: 6 drag steps of 30 px in 16 ms each on a 450 px globe, then let go.
function throwGlobe(st, R = 450) {
  for (let i = 0; i < 6; i++) G.drag(st, 30, 0, 0.016, R);
  G.release(st);
  return st;
}
function settle(st, pl) {
  const path = [];
  for (let t = 0; t < 20; t += 1 / 60) { path.push(st.yaw); if (!G.step(st, 1 / 60, pl)) return { path, t }; }
  return { path, t: Infinity };
}

test("hand spin: the surface follows the hand, coasts on with inertia, and the detent centres the nearest plaque", () => {
  const pl = G.globe(scene(), COORD, NOW).plaques;
  const st = G.spin(0, 0);
  const before = st.yaw;
  throwGlobe(st);
  const released = st.yaw;
  assert.ok(released < before, "dragging right turns the front west: earlier records come into view");
  assert.ok(st.vy < -G.DETENT_SPEED, "it leaves the hand moving");
  const { path, t } = settle(st, pl);
  assert.ok(t < 8, `settles (took ${t} s)`);
  assert.ok(Math.min(...path) < released - 0.3, "it coasts well past where the hand let go");
  assert.equal(st.mode, "idle");
  assert.ok(st.target >= 0);
  const p = pl[st.target];
  const at = G.loupePoint(st.yaw, st.pitch);
  assert.ok(Math.abs(G.wrap(at[0] - p.lon)) < 1e-3 && Math.abs(at[1] - p.lat) < 1e-3, "a plaque sits exactly under the loupe");
  assert.equal(st.target, G.nearest(st, pl));
  assert.ok(G.plaqueInLoupe(p, st.yaw, st.pitch) < G.LOUPE.clear);
});

test("detent: a slow release between plaques springs to the nearer one; idle draws nothing", () => {
  const pl = G.globe(scene(), COORD, NOW).plaques;
  const a = pl.find((p) => p.id8 === "53163e57"), b = pl.find((p) => p.id8 === "cae2c3da");
  const da = G.detentFor(a, 0);
  // Park the loupe 30 % of the way from a toward b, with no speed: the detent takes a.
  const st = G.spin(da.yaw + 0.3 * (b.lon - a.lon), da.pitch);
  st.mode = "coast"; st.vy = 0;
  const { t } = settle(st, pl);
  assert.ok(t < 5);
  assert.equal(pl[st.target].id8, "53163e57");
  assert.ok(Math.abs(st.yaw - da.yaw) < 1e-3 && Math.abs(st.pitch - da.pitch) < 1e-3);
  // Settled: a further step moves nothing and asks for no frame.
  const y = st.yaw, p = st.pitch;
  assert.equal(G.step(st, 1 / 60, pl), false);
  assert.equal(st.yaw, y); assert.equal(st.pitch, p);
});

test("new data while settled keeps the same record under the loupe, without a spring", () => {
  const s0 = scene(), pl0 = G.globe(s0, COORD, NOW).plaques;
  const st = G.spin(0, 0);
  G.detentTo(st, 0, pl0); settle(st, pl0);
  const id = pl0[st.target].id;
  const later = NOW + 5 * 60000, pl1 = G.globe(scene(snap, NOW), COORD, later).plaques;
  const i = G.follow(st, pl1, id);
  assert.equal(pl1[i].id, id);
  assert.notEqual(pl1[i].lon, pl0[0].lon, "the record drifted west as time passed");
  assert.equal(st.mode, "idle");
  const at = G.loupePoint(st.yaw, st.pitch);
  assert.ok(Math.abs(G.wrap(at[0] - pl1[i].lon)) < 1e-6);
});

test("click: the plaque seen under the loupe is the one picked; the bare globe picks none", () => {
  const pl = G.globe(scene(), COORD, NOW).plaques;
  const st = G.spin(0, 0);
  G.detentTo(st, 2, pl); settle(st, pl);
  assert.equal(G.pick(st, G.LOUPE.x, G.LOUPE.y, pl), 2);
  assert.equal(G.pick(st, G.LOUPE.x + 0.15, G.LOUPE.y + 0.05, pl), 2, "inside the magnified plaque");
  assert.equal(G.pick(st, 0.0, 0.92, pl) === 2, false);
  assert.equal(G.pick(st, 1.2, 0, pl), -1, "off the globe");
});

test("null fields: a session with no records of its own draws an empty globe, an unknown id draws none", () => {
  const empty = G.globe(scene(), "3e6797ed", NOW);   // untitled coord, ended, nothing written
  assert.equal(empty.plaques.length, 0);
  assert.equal(empty.newest, -1);
  assert.equal(empty.session.untitled, true);
  assert.equal(empty.lease.lon, 0);
  assert.equal(empty.ended, 1);
  assert.equal(G.globe(scene(), "ffffffff", NOW), null);
  const st = G.spin(0.2, 0.1);
  G.detentTo(st, G.nearest(st, []), []);
  assert.equal(st.mode, "idle");
});

test("the loupe never cuts a plaque: every drawn plaque is wholly inside its clear glass or wholly outside its rim", () => {
  const pl = G.globe(scene(), COORD, NOW).plaques;
  const st = G.spin(0, 0);
  // Every orientation a throw passes through, and every detent.
  const orients = [];
  for (let y = -3; y <= 0.5; y += 0.05) for (const p of [-0.3, 0, 0.3, 0.6]) orients.push([y, p, -1]);
  pl.forEach((p, i) => { const d = G.detentFor(p, 0); orients.push([d.yaw, d.pitch, i]); });
  let hidden = 0;
  for (const [yaw, pitch, target] of orients) {
    const vis = G.shown(pl, yaw, pitch, target);
    if (target >= 0) assert.ok(vis[target], "the plaque under the loupe is always drawn");
    pl.forEach((p, i) => {
      if (!vis[i]) { hidden++; return; }
      // Sample its outline densely (independently of shown's sampling): no edge point on both sides of the rim band.
      let inside = false, outside = false;
      const half = p.hw / Math.cos(p.lat);
      for (let a = 0; a <= 40; a++) for (let b = 0; b <= 10; b++) {
        const W = G.toWorld(G.objOf(p.lon + (a / 20 - 1) * half, p.lat + (b / 5 - 1) * p.hh), yaw, pitch);
        if (1 + 5 * W[2] >= 0) { outside = true; continue; }
        const pp = G.project(W), q = G.loupeQ(pp[0], pp[1]);
        if (q < 1) inside = true; else outside = true;
      }
      assert.ok(!(inside && outside), `${p.id8} drawn across the loupe rim at yaw ${yaw.toFixed(2)} pitch ${pitch}`);
    });
  }
  assert.ok(hidden > 0, "some orientations do put a plaque across the rim (so the rule is exercised)");
});
