// Builds plugin/river/test/busy-frames.json from the real amplify snapshot
// (fixtures/amplify-snapshot.json): the same task and session records, with
// stages, claims and leases staged so the river shows 9 claims (one expired, one held by a
// lost session, one by a quiet one),
// a blocked eddy, a critic PASS and a REJECT. Two frames, 60 s apart, so the
// PASS and REJECT come from the lane change between successive scenes, the
// same way successive live refetches produce them.
//
//   node plugin/river/test/make-busy.mjs
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../../..");
const snap = JSON.parse(fs.readFileSync(path.join(root, "fixtures/amplify-snapshot.json"), "utf8"));
const R = snap.responses;
const T = Date.parse(snap.meta.captured_at);
const iso = (ms) => new Date(ms).toISOString();
const min = 60 * 1000;

const list = (v, k) => (Array.isArray(v) ? v : v[k] || v.data);
const sessions = list(R["/api/sessions"], "sessions").map((s) => ({ ...s }));
const tasks = list(R["/api/tasks"], "tasks").map((t) => ({ ...t }));
const actorOf = (id8) => sessions.find((s) => s.id.startsWith(id8)).actor;

// Holders: nine real actors from the snapshot. Their sessions are kept open
// (ended_at cleared) and heartbeating, because only open sessions hold claims.
const holders = ["de463c37", "4f96630e", "4af6ff22", "7ca5e6b2", "80c16aeb", "b324f5cc", "4ac9c312", "7d26fa7f", "cda05272"];
for (const s of sessions) {
    if (!holders.some((h) => s.id.startsWith(h))) continue;
    s.ended_at = null;
    s.state = "active";
    s.last_activity_at = iso(T - 2 * min);
    s.last_heartbeat_at = iso(T - 1 * min);
}
// Two holders that are not live (viewer contract 22d73eeb): e3f2e1a4's holder
// lost (explicit heartbeat 15 min old) and a40d7440's quiet (heartbeating, no
// write for 12 min). Their tethers wear the lost and quiet tones.
Object.assign(sessions.find((s) => s.id.startsWith("4ac9c312")), { last_explicit_heartbeat_at: iso(T - 15 * min) });
Object.assign(sessions.find((s) => s.id.startsWith("b324f5cc")), { last_activity_at: iso(T - 12 * min) });

// [task id8, holder session id8, lease left at T in minutes, status]
const claims = [
    ["a15523ac", "4f96630e", 44, "in_progress"],
    ["0edf3b35", "4af6ff22", 37, "in_progress"],
    ["e3f2e1a4", "4ac9c312", 30, "in_progress"],
    ["a40d7440", "b324f5cc", 24, "in_progress"],
    ["63e691ec", "80c16aeb", 18, "in_progress"],
    ["85ff482a", "7ca5e6b2", 11, "blocked"],
    ["bc45ee1d", "de463c37", 6, "in_progress"],
    ["23a62966", "cda05272", 2, "in_progress"],
    ["523461dd", "7d26fa7f", -3, "in_progress"],   // expired 3 min ago, server row still says live
];
const stage = { "379c80c6": "verifying", "6bbaf7d0": "verifying", b416eb7d: "evidence",
                b5a51e99: "merged", e953b166: "merged", "45de8d89": "draft", "80af28cb": "ready" };

function frame0() {
    return tasks.map((t0) => {
        const t = { ...t0, claim_actor: null, claim_live: false, claim_expires_at: null, blocked_on: null };
        const c = claims.find((x) => t.id.startsWith(x[0]));
        if (c) {
            Object.assign(t, { status: c[3], stage: "claimed", claim_actor: actorOf(c[1]), claim_live: true,
                               claim_expires_at: iso(T + c[2] * min), started_at: iso(T - 20 * min),
                               updated_at: iso(T - (20 - claims.indexOf(c)) * min), completed_at: null });
            if (c[3] === "blocked") t.blocked_on = "human";
        }
        const s = Object.keys(stage).find((k) => t.id.startsWith(k));
        if (s) {
            t.stage = stage[s];
            t.status = stage[s] === "merged" ? "completed" : stage[s] === "draft" || stage[s] === "ready" ? "todo" : "in_progress";
            if (t.status !== "completed") t.completed_at = null;
            t.updated_at = iso(T - 8 * min);
        }
        return t;
    });
}

function frame1() {
    // 60 s later: the critic passes 379c80c6 and rejects 6bbaf7d0 back to ready.
    return frame0().map((t) => {
        if (t.id.startsWith("379c80c6")) return { ...t, stage: "evidence", updated_at: iso(T + 1 * min) };
        if (t.id.startsWith("6bbaf7d0")) return { ...t, stage: "ready", status: "todo", updated_at: iso(T + 1 * min) };
        return t;
    });
}

const responses = (ts) => ({ ...R, "/api/sessions": sessions, "/api/tasks": ts });
const out = {
    meta: {
        ...snap.meta,
        kind: "replay-frames",
        label: "amplify load fixture (staged from the 04:00Z snapshot)",
        notice: "STAGED LOAD FIXTURE. Real amplify task and session records from fixtures/amplify-snapshot.json; stages, claims, leases and session liveness are rewritten by plugin/river/test/make-busy.mjs to exercise 8+ claims, an expired lease, a lost and a quiet holder, a blocked eddy, a critic PASS and a REJECT. Not a capture of real state.",
        replay_from: iso(T - 1 * min),
        captured_at: iso(T + 3 * min),
    },
    frames: [
        { at: iso(T - 1 * min), responses: responses(frame0()) },
        { at: iso(T + 1 * min), responses: responses(frame1()) },
    ],
};
fs.writeFileSync(path.join(here, "busy-frames.json"), JSON.stringify(out, null, 1) + "\n");
console.log("make-busy: wrote plugin/river/test/busy-frames.json");
