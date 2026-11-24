// node --test tools/motion/test/
// tools/mutate.sh itself (task 5afeee5f): selection, stop at the first red gate, the
// exit-status contract and -j isolation, run on a scratch tree whose gates are stubs
// (no render stack). Every stub logs what it saw to $STUB_LOG and fails when the
// tree's `flags` file names it ("<gate>-bad"); the shot stubs also leave a process
// running, which mutate.sh must kill.
import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");

const shotStub = (g) => `#!/usr/bin/env bash
echo "start ${g} $(date +%s%3N) $PWD $SHOT_RUNTIME_DIR $(head -1 flags)" >> "$STUB_LOG"
sleep "\${STUB_SLEEP:-0}"
# Left running with the gate's descriptors closed, so it holds no render-slot lock and
# a reap that misses it shows as a leftover rather than as a stalled queue.
( for f in /proc/$BASHPID/fd/*; do n=\${f##*/}; (( n > 2 )) && eval "exec $n>&-"; done; exec sleep 600 ) > /dev/null 2>&1 &
echo "end ${g} $(date +%s%3N) $PWD" >> "$STUB_LOG"
grep -q "${g}-bad" flags && exit 1
exit 0
`;
const nodeStub = (g) => `import fs from "node:fs";
import { execFileSync } from "node:child_process";
const log = (w) => fs.appendFileSync(process.env.STUB_LOG, \`\${w} ${g} \${Date.now()} \${process.cwd()} \${process.env.SHOT_RUNTIME_DIR} \${fs.readFileSync("flags", "utf8").split("\\n")[0]}\\n\`);
log("start");
execFileSync("sleep", [process.env.STUB_SLEEP || "0"]);
log("end");
if (fs.readFileSync("flags", "utf8").includes("${g}-bad")) process.exit(1);
`;

// A scratch repo with the real mutate.sh and apply.mjs, stub gates and this catalogue.
// The tree is removed, and whatever its gates left running killed, when the test ends, pass or fail.
function tree(ctx, mutations, flags = "ok\n") {
    const t = fs.mkdtempSync(path.join(os.tmpdir(), "mutate-test-"));
    ctx.after(() => { leftovers(t); fs.rmSync(t, { recursive: true, force: true }); });
    const put = (f, s, mode = 0o644) => { fs.mkdirSync(path.dirname(path.join(t, f)), { recursive: true }); fs.writeFileSync(path.join(t, f), s, { mode }); };
    fs.mkdirSync(path.join(t, "tools/motion"), { recursive: true });
    fs.copyFileSync(path.join(root, "tools/mutate.sh"), path.join(t, "tools/mutate.sh"));
    fs.chmodSync(path.join(t, "tools/mutate.sh"), 0o755);
    fs.copyFileSync(path.join(root, "tools/motion/apply.mjs"), path.join(t, "tools/motion/apply.mjs"));
    put("tools/motion/mutations.json", JSON.stringify({ mutations }));
    put("flags", flags);
    put(".gitignore", "stub.log\nout/\n");
    for (const [g, dir] of [["data", "data/test"], ["orbs", "plugin/orbs/test"], ["river", "plugin/river/test"], ["motion", "tools/motion/test"]])
        put(`${dir}/stub.test.mjs`, nodeStub(g));
    put("tools/motion/spec.mjs", nodeStub("spec"));
    put("plugin/river/test/shot.sh", shotStub("river-shot"), 0o755);
    put("plugin/orbs/test/shot.sh", shotStub("orbs-shot"), 0o755);
    put("tools/headless-shot.sh", shotStub("headless"), 0o755);
    spawnSync("git", ["init", "-q"], { cwd: t });
    return t;
}
// mut(id, gates, marker): turns the first flags line into "<id> <marker>".
const mut = (id, gates, marker = "x") => ({ id, source: "test", edits: [{ file: "flags", from: "ok\n", to: `${id} ${marker}\n` }], gates });

function mutate(t, args, env = {}) {
    const stubLog = path.join(t, "stub.log"), out = path.join(t, "out");
    fs.writeFileSync(stubLog, "");
    // Without NODE_TEST_CONTEXT: under this test runner, the gates' own node --test would
    // report to it and exit 0 whatever their tests do.
    const { NODE_TEST_CONTEXT, ...base } = process.env;
    const r = spawnSync(path.join(t, "tools/mutate.sh"), args, {
        cwd: t, encoding: "utf8", timeout: 120000,
        env: { ...base, STUB_LOG: stubLog, MUTATE_OUT: out, ...env }
    });
    const rows = r.stdout.split("\n").filter((l) => /^\S+\s+(RED|GREEN|STALE|ERROR)\b/.test(l));
    const runs = fs.readFileSync(stubLog, "utf8").trim().split("\n").filter(Boolean).map((l) => {
        const [what, gate, ms, dir, rt, ...flag] = l.split(" ");
        return { what, gate, ms: Number(ms), dir, rt, flag: flag.join(" ") };
    });
    return { status: r.status, stdout: r.stdout, rows, runs, row: (id) => rows.find((x) => x.split(/\s+/)[0] === id) };
}
// Processes still running with this tree's STUB_LOG in their environment (killed here,
// so a failing run leaves nothing behind either).
function leftovers(t) {
    const tag = `STUB_LOG=${path.join(t, "stub.log")}`, left = [];
    for (const p of fs.readdirSync("/proc").filter((x) => /^\d+$/.test(x))) {
        try { if (fs.readFileSync(`/proc/${p}/environ`, "utf8").split("\0").includes(tag)) left.push(p); } catch {}
    }
    for (const p of left) try { process.kill(Number(p)); } catch {}
    return left;
}

test("mutate.sh --list prints every mutation; an unknown id exits 2", (ctx) => {
    const t = tree(ctx, [mut("A", ["data"]), mut("B", ["spec"])]);
    const l = spawnSync(path.join(t, "tools/mutate.sh"), ["--list"], { cwd: t, encoding: "utf8" });
    assert.equal(l.status, 0);
    assert.deepEqual(l.stdout.trim().split("\n").map((x) => x.split(/\s+/)[0]), ["A", "B"]);
    assert.equal(mutate(t, ["nope"]).status, 2);
});

test("mutate.sh runs only the selection, stops at the first red gate, and exits survivors + stale", (ctx) => {
    const t = tree(ctx, [
        mut("A", ["data", "river-shot"], "data-bad"), mut("B", ["data", "river-shot"], "river-shot-bad"),
        mut("S", ["spec"]), { id: "T", source: "test", edits: [{ file: "flags", from: "nope", to: "x" }], gates: ["data"] },
        mut("U", ["orbs-shot"], "orbs-shot-bad")
    ]);
    const r = mutate(t, ["A", "B", "S", "T"]);
    assert.deepEqual(r.rows.map((x) => x.split(/\s+/)[0]), ["control", "A", "B", "S", "T"]);
    // The control runs every gate the selection uses (and only those), cheapest first.
    assert.match(r.row("control"), /GREEN\s+data=0 spec=0 river-shot=0$/);
    // A fails its first gate: river-shot never runs in its tree.
    assert.match(r.row("A"), /RED\s+data=1$/);
    assert.ok(!r.runs.some((x) => x.gate === "river-shot" && x.flag.startsWith("A ")));
    assert.match(r.row("B"), /RED\s+data=0 river-shot=1$/);
    assert.match(r.row("S"), /GREEN\s+spec=0$/);
    assert.match(r.row("T"), /STALE/);
    assert.ok(!r.runs.some((x) => x.flag.startsWith("U ")), "U is not selected");
    assert.match(r.stdout, /2 RED, 1 GREEN \(survived\), 1 STALE of 4; control GREEN/);
    assert.equal(r.status, 2, "1 survivor + 1 stale");
    // All RED and a GREEN control: exit 0.
    assert.equal(mutate(t, ["A", "B", "U"]).status, 0);
    assert.deepEqual(leftovers(t), [], "every process a gate left running is killed");
});

test("mutate.sh adds 1 when the control is not GREEN", (ctx) => {
    const t = tree(ctx, [mut("A", ["data", "spec"], "data-bad")], "ok\nspec-bad\n");
    const r = mutate(t, ["A"]);
    assert.match(r.row("control"), /RED\s+data=0 spec=1$/);
    assert.match(r.stdout, /control is not GREEN/);
    assert.equal(r.status, 1);
});

test("mutate.sh -j 4: same table as -j 1, runs overlap in their own trees and runtime dirs, render gates capped, headless alone", (ctx) => {
    const ms = [];
    for (let k = 0; k < 4; k++) ms.push(mut(`R${k}`, ["data", "river-shot"], k % 2 ? "river-shot-bad" : "x"));
    for (let k = 0; k < 3; k++) ms.push(mut(`O${k}`, ["orbs-shot"], k ? "orbs-shot-bad" : "x"));
    ms.push(mut("H0", ["headless"], "headless-bad"), mut("D0", ["data", "spec"], "spec-bad"), mut("D1", ["data", "spec"]));
    const t = tree(ctx, ms);
    const env = { STUB_SLEEP: "0.4", MUTATE_RENDER_JOBS: "2" };
    const one = mutate(t, ["-j", "1"], env), four = mutate(t, ["-j", "4"], env);
    assert.deepEqual(four.rows, one.rows);
    assert.equal(four.status, one.status);
    assert.equal(four.status, 4, "R0, R2, O0 and D1 survive");

    const spans = [];
    for (const s of four.runs.filter((x) => x.what === "start")) {
        const e = four.runs.find((x) => x.what === "end" && x.gate === s.gate && x.dir === s.dir && x.ms >= s.ms);
        spans.push({ ...s, end: e.ms });
    }
    const overlap = (a, b) => a.ms < b.end && b.ms < a.end;
    const most = (xs) => Math.max(...xs.map((a) => xs.filter((b) => overlap(a, b)).length));
    assert.ok(most(spans) > 1, "-j 4 runs gates at once");
    const render = spans.filter((x) => /shot|headless/.test(x.gate));
    assert.ok(most(render) <= 2, "at most MUTATE_RENDER_JOBS render gates at once");
    for (const h of render.filter((x) => x.gate === "headless"))
        assert.ok(!render.some((x) => x !== h && overlap(h, x)), "the headless gate renders alone");
    // Each gate has its own runtime dir; each run's tree carries only its own mutation.
    assert.equal(new Set(spans.map((x) => x.rt)).size, spans.length);
    const flagOf = new Map();
    for (const s of spans) {
        assert.ok(!flagOf.has(s.dir) || flagOf.get(s.dir) === s.flag, `${s.dir} saw two trees`);
        flagOf.set(s.dir, s.flag);
    }
    assert.equal(new Set(flagOf.values()).size, flagOf.size, "no two runs share a tree");
    assert.deepEqual(leftovers(t), []);
});
