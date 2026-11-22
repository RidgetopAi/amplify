// Liveness thresholds (viewer contract 22d73eeb) and the status→lane mapping
// (decision c1f75776), each proven on both sides of its boundary.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const { M } = createRequire(import.meta.url)("../node.cjs");

const NOW = Date.parse("2026-11-22T04:00:00.000Z");
const ago = (sec) => new Date(NOW - sec * 1000).toISOString();
// A session with one write so "forming" does not apply unless asked for.
const sess = (o) => ({ state: "active", creation_reason: "resume", context_count: 1, ...o });
const live = (o) => M.clientLiveness(sess(o), NOW);

test("live by heartbeat: 180 s is fresh, 181 s is not", () => {
    assert.equal(live({ last_heartbeat_at: ago(180), last_activity_at: ago(5 * 60) }), "live");
    assert.equal(live({ last_heartbeat_at: ago(181), last_activity_at: ago(31 * 60) }), "dormant");
});

test("heartbeat boundary alone: write 31 min ago, so only the 180 s heartbeat rule decides", () => {
    // Decision b38fc01a: a fresh heartbeat with no write for >= 10 min is quiet;
    // no fresh heartbeat and no write under 30 min is dormant.
    assert.equal(live({ last_heartbeat_at: ago(180), last_activity_at: ago(31 * 60) }), "quiet");
    assert.equal(live({ last_heartbeat_at: ago(181), last_activity_at: ago(31 * 60) }), "dormant");
});

test("live by write: under 30 min is live, 30 min is dormant", () => {
    assert.equal(live({ last_activity_at: ago(30 * 60 - 1) }), "live");
    assert.equal(live({ last_activity_at: ago(30 * 60) }), "dormant");
});

test("quiet: fresh heartbeat and no write for >= 10 min", () => {
    assert.equal(live({ last_heartbeat_at: ago(60), last_activity_at: ago(599) }), "live");
    assert.equal(live({ last_heartbeat_at: ago(60), last_activity_at: ago(600) }), "quiet");
    assert.equal(live({ last_heartbeat_at: ago(60), last_activity_at: null }), "quiet");
    // A write 10-30 min ago without a fresh heartbeat stays live: quiet needs a heartbeat.
    assert.equal(live({ last_heartbeat_at: ago(181), last_activity_at: ago(600) }), "live");
});

test("lost: explicit heartbeat strictly older than 10 min", () => {
    const base = { last_heartbeat_at: ago(30), last_activity_at: ago(60) };
    assert.equal(live({ ...base, last_explicit_heartbeat_at: ago(600) }), "live");
    assert.equal(live({ ...base, last_explicit_heartbeat_at: ago(601) }), "lost");
    // At exactly 600 s a heartbeat-only session is quiet, not lost; one second later it is lost.
    const idle = { last_heartbeat_at: ago(30), last_activity_at: ago(600) };
    assert.equal(live({ ...idle, last_explicit_heartbeat_at: ago(600) }), "quiet");
    assert.equal(live({ ...idle, last_explicit_heartbeat_at: ago(601) }), "lost");
    // Lost outranks dormant: a session that heartbeated explicitly and then went silent is the alarm.
    assert.equal(live({ last_explicit_heartbeat_at: ago(3600), last_heartbeat_at: ago(3600) }), "lost");
    // Never heartbeated explicitly: silence is dormant, not lost.
    assert.equal(live({ last_activity_at: ago(3600) }), "dormant");
});

test("ended wins over every timestamp", () => {
    assert.equal(live({ ended_at: ago(1), last_heartbeat_at: ago(1), last_activity_at: ago(1) }), "ended");
    assert.equal(live({ state: "ended", last_heartbeat_at: ago(1) }), "ended");
});

test("forming: creation_reason connect with no writes yet", () => {
    const fresh = { creation_reason: "connect", context_count: 0, task_count: 0, decision_count: 0 };
    assert.equal(live({ ...fresh, last_heartbeat_at: ago(10), last_activity_at: ago(10) }), "forming");
    assert.equal(live({ ...fresh, last_heartbeat_at: ago(10), last_activity_at: ago(20 * 60) }), "forming");
    assert.equal(live({ ...fresh, context_count: 1, last_heartbeat_at: ago(10), last_activity_at: ago(10) }), "live");
    assert.equal(live({ ...fresh, creation_reason: "resume", last_heartbeat_at: ago(10), last_activity_at: ago(10) }), "live");
    // Forming still decays: not proven alive is dormant.
    assert.equal(live({ ...fresh, last_activity_at: ago(30 * 60) }), "dormant");
});

test("server liveness is truth; the client clock may only decay it", () => {
    const fresh = { last_heartbeat_at: ago(10), last_activity_at: ago(10) };
    assert.equal(M.sessionLiveness(sess({ ...fresh, liveness: "lost" }), NOW), "lost");
    assert.equal(M.sessionLiveness(sess({ ...fresh, liveness: "dormant" }), NOW), "dormant");
    assert.equal(M.sessionLiveness(sess({ last_heartbeat_at: ago(10), last_activity_at: ago(700), liveness: "live" }), NOW), "quiet");
    assert.equal(M.sessionLiveness(sess({ ...fresh, liveness: "live", creation_reason: "connect", context_count: 0 }), NOW), "forming");
});

test("tickScene decays liveness between refetches", () => {
    const at = Date.parse("2026-11-22T03:00:00.000Z");
    const scene = M.buildScene({ sessions: [{
        id: "11111111-0000-0000-0000-000000000000", title: "a · worker", actor: "brian/amp-worker-t-01a20161-d86d-7337-9b81-bbc70d3b28e9",
        liveness: "live", creation_reason: "resume", context_count: 3,
        last_heartbeat_at: new Date(at).toISOString(), last_explicit_heartbeat_at: new Date(at).toISOString(),
        last_activity_at: new Date(at).toISOString() }] }, { now: at });
    assert.equal(scene.sessions[0].liveness, "live");
    M.tickScene(scene, at + 179 * 1000);
    assert.equal(scene.orbs[0].liveness, "live");
    M.tickScene(scene, at + 601 * 1000);
    assert.equal(scene.sessions[0].liveness, "lost");
    assert.equal(scene.orbs[0].liveness, "lost");
    assert.equal(scene.counts.liveness.lost, 1);
});

// ---------------------------------------------------------------- lanes (c1f75776)

const lane = (o) => M.taskLane(o);

test("a task with a punch stage rides its stage lane", () => {
    for (const stage of M.LANES) assert.equal(lane({ status: "in_progress", stage }).lane, stage);
    assert.equal(lane({ status: "todo", stage: "draft", claim_live: true }).lane, "draft");
});

test("todo maps to ready", () => {
    assert.deepEqual(lane({ status: "todo" }), { lane: "ready", eddy: false, needsYou: false, hidden: false });
});

test("in_progress: live claim is claimed, no live claim is verifying", () => {
    assert.equal(lane({ status: "in_progress", claim_live: true }).lane, "claimed");
    assert.equal(lane({ status: "in_progress", claim_live: false }).lane, "verifying");
    assert.equal(lane({ status: "in_progress", claimLive: true }).lane, "claimed");
});

test("blocked is an eddy at its lane, not the claimed lane", () => {
    const unclaimed = lane({ status: "blocked" });
    assert.equal(unclaimed.lane, "ready");
    assert.equal(unclaimed.eddy, true);
    assert.equal(unclaimed.needsYou, false);
    assert.equal(lane({ status: "blocked", stage: "verifying" }).lane, "verifying");
    assert.equal(lane({ status: "blocked", claim_live: true }).lane, "claimed");
    assert.equal(lane({ status: "todo" }).eddy, false);
});

test("blockedOn human sends a task to the needs-you basin; other parties do not", () => {
    assert.equal(lane({ status: "blocked", blocked_on: "human" }).needsYou, true);
    assert.equal(lane({ status: "blocked", blocked_on: "agent" }).needsYou, false);
    assert.equal(lane({ status: "blocked", blocked_on: "external" }).needsYou, false);
    assert.equal(lane({ status: "in_progress", blockedOn: "human" }).needsYou, true);
});

test("completed is merged and cancelled is hidden", () => {
    assert.equal(lane({ status: "completed" }).lane, "merged");
    assert.equal(lane({ status: "completed", blocked_on: "human" }).needsYou, false);
    const c = lane({ status: "cancelled", stage: "ready", blocked_on: "human" });
    assert.equal(c.hidden, true);
    assert.equal(c.needsYou, false);
});
