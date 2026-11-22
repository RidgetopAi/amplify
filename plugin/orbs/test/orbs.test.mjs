// node --test plugin/orbs/test/
// Desktop-orb mapping (task a40d7440) against the real capture in
// plugin/orbs/fixtures/orbs-snapshot.json. Expected values come from the
// viewer contract thresholds (22d73eeb) and the captured timestamps, not from
// the code under test.
import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import fs from "node:fs";

const require = createRequire(import.meta.url);
const { M } = require("../../../data/node.cjs");
const O = require("./load.cjs");
const snap = JSON.parse(fs.readFileSync(new URL("../fixtures/orbs-snapshot.json", import.meta.url)));
const FETCH = Date.parse(snap.meta.captured_at);           // 04:55:40Z
const MIN = 60000;

function sceneAtFetch() {
  const r = snap.responses;
  return M.buildScene({ sessions: r["/api/sessions"], tasks: r["/api/tasks"], contexts: [], decisions: [],
                        projects: r["/api/projects"] },
                      { now: FETCH, baseUrl: snap.meta.base_url, mode: "replay" });
}
const ORBS = "b8bbe543-2f9b-464c-adf2-20aecba6ff66";       // explicit hb 04:55:10Z, claim to 05:28:51Z
const NEEDS = "5be105be-d94e-4cc8-ae6d-a63df93c0d6b";      // server quiet, no heartbeat, last write 04:44:07Z
const COORD = "de463c37-c3d0-42ac-b3a3-e63d4e64f814";

test("each liveness state has its own material; dormant is a hollow shell, not live", () => {
  const states = ["live", "forming", "quiet", "lost", "dormant", "ended"];
  const sig = states.map((s) => JSON.stringify(O.material(s)));
  assert.equal(new Set(sig).size, states.length);
  const live = O.material("live"), dorm = O.material("dormant");
  assert.equal(dorm.dorm, 1);
  assert.equal(dorm.spin, 0);
  assert.ok(dorm.light < live.light && dorm.sat < live.sat);
  assert.equal(O.material("lost").lost, 1);
  assert.equal(live.lost + live.dorm, 0);
});

test("a dormant session renders with the dormant material", () => {
  const scene = sceneAtFetch();
  const f = O.frame(scene, FETCH + 20 * MIN, 1920, 1080, M.tickScene);
  const n = f.orbs[NEEDS];
  assert.equal(n.liveness, "dormant");
  assert.equal(n.dorm, 1);
  assert.equal(n.spin, 0);
  assert.ok(n.light <= 0.3);
});

test("states decay on the client clock between refetches (no refetch)", () => {
  const scene = sceneAtFetch();
  let f = O.frame(scene, FETCH, 1920, 1080, M.tickScene);
  assert.equal(f.orbs[ORBS].liveness, "live");
  assert.equal(f.orbs[NEEDS].liveness, "quiet");     // server truth at fetch
  // 04:55:10 + 600 s = 05:05:10; just before it the fuse is nearly out, still live.
  f = O.frame(scene, Date.parse("2026-11-22T05:05:05Z"), 1920, 1080, M.tickScene);
  assert.notEqual(f.orbs[ORBS].liveness, "lost");
  assert.ok(f.orbs[ORBS].fuse > 0 && f.orbs[ORBS].fuse < 0.02);
  // Past it: lost by the client clock alone, and it still holds a live claim, so it needs you.
  f = O.frame(scene, Date.parse("2026-11-22T05:05:20Z"), 1920, 1080, M.tickScene);
  assert.equal(f.orbs[ORBS].liveness, "lost");
  assert.equal(f.orbs[ORBS].lost, 1);
  assert.equal(f.orbs[ORBS].need, 1);
  assert.equal(f.orbs[ORBS].fuse, 0);
  // needs-you's last write 04:44:07 + 30 min = 05:14:07: dormant after it.
  f = O.frame(scene, Date.parse("2026-11-22T05:14:30Z"), 1920, 1080, M.tickScene);
  assert.equal(f.orbs[NEEDS].liveness, "dormant");
});

test("vessel liquid level is the lease left on the client clock", () => {
  const scene = sceneAtFetch();
  // Claim a40d7440 expires 05:28:51.245Z; lease length 2700 s.
  const left = (Date.parse("2026-11-22T05:28:51.245Z") - FETCH) / 1000;
  let f = O.frame(scene, FETCH, 1920, 1080, M.tickScene);
  assert.equal(f.orbs[ORBS].task.id8, "a40d7440");
  assert.ok(Math.abs(f.orbs[ORBS].task.lease - left / 2700) < 1e-9);
  assert.equal(f.orbs[ORBS].task.held, true);
  f = O.frame(scene, FETCH + 20 * MIN, 1920, 1080, M.tickScene);
  assert.ok(Math.abs(f.orbs[ORBS].task.lease - (left - 1200) / 2700) < 1e-9);
  f = O.frame(scene, Date.parse("2026-11-22T05:29:00Z"), 1920, 1080, M.tickScene);
  assert.equal(f.orbs[ORBS].task.lease, 0);
  assert.equal(f.orbs[ORBS].task.held, false);
  assert.equal(f.orbs[ORBS].need, 0);                 // lost, but no longer holding a claim
});

test("activity link draws a beam from orbs to amplify-coord and fades by age", () => {
  const scene = sceneAtFetch();
  let f = O.frame(scene, FETCH, 1920, 1080, M.tickScene);
  assert.equal(f.beams.length, 1);
  assert.equal(f.beams[0].from, ORBS);
  assert.equal(f.beams[0].to, COORD);
  const a0 = f.beams[0].alpha;
  f = O.frame(scene, FETCH + 15 * MIN, 1920, 1080, M.tickScene);
  assert.ok(f.beams[0].alpha < a0);
  // Link at 04:46:02 + 30 min show window = 05:16:02.
  f = O.frame(scene, Date.parse("2026-11-22T05:16:10Z"), 1920, 1080, M.tickScene);
  assert.equal(f.beams.length, 0);
});

test("untitled and never-heartbeat sessions are designed, not blank", () => {
  const r = snap.responses;
  const t = Date.parse("2026-11-22T00:28:30Z");
  const scene = M.tickScene(M.buildScene(M.replayResponses(snap, t), { now: t, mode: "replay" }), t);
  const s = scene.sessions.find((x) => x.id8 === "3e6797ed");
  const p = O.orbProps(scene, s, t);
  assert.equal(p.untitled, true);
  assert.equal(p.name, "untitled");
  assert.equal(p.role, "coord");
  assert.match(p.sub, /3e6797ed/);
  assert.equal(p.fuse, -1);                            // never heartbeat: dotted track, socket
  assert.equal(p.neverHeartbeat, true);
  const f = O.frame(sceneAtFetch(), FETCH, 1920, 1080, M.tickScene);
  assert.equal(f.orbs[ORBS].fuse > 0, true);           // explicit heartbeat: a fuse arc
  assert.ok(r);
});

test("roles map to their own programs; ended sessions leave after 15 min", () => {
  const scene = sceneAtFetch();
  const f = O.frame(scene, FETCH, 1920, 1080, M.tickScene);
  assert.equal(f.orbs[COORD].role, "coord");
  assert.equal(f.orbs["f4fe1f7e-0a72-423b-aa3e-c50c5389658e"].role, "critic");
  assert.equal(f.orbs[ORBS].role, "worker");
  // install-fix ended 04:49:37 (6 min before fetch): an ember now, gone at 05:04:37.
  assert.equal(f.orbs["d045e2e7-5063-4e42-80e9-c7f58de7fbd0"].liveness, "ended");
  const later = O.frame(scene, Date.parse("2026-11-22T05:04:40Z"), 1920, 1080, M.tickScene);
  assert.equal(later.orbs["d045e2e7-5063-4e42-80e9-c7f58de7fbd0"], undefined);
});
