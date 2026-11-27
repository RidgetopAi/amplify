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

// Most spans {ms, end} open at any one instant: a sweep over start and end events, ends
// first at equal times, so a span that ends as another starts does not overlap it.
const peak = (xs) => {
    let open = 0, top = 0;
    const ev = xs.flatMap((x) => [[x.ms, 1], [x.end, -1]]).sort((a, b) => a[0] - b[0] || a[1] - b[1]);
    for (const [, d] of ev) top = Math.max(top, (open += d));
    return top;
};

test("peak() counts spans open at once, not spans overlapping one span", () => {
    // Each span overlaps the middle one, but the first ends before the last starts.
    assert.equal(peak([{ ms: 0, end: 429 }, { ms: 179, end: 600 }, { ms: 516, end: 944 }]), 2);
    assert.equal(peak([{ ms: 0, end: 500 }, { ms: 100, end: 600 }, { ms: 200, end: 300 }]), 3);
    assert.equal(peak([{ ms: 0, end: 10 }, { ms: 10, end: 20 }]), 1);
});

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

// A scratch repo with the real mutate.sh, apply.mjs and sync-shared.sh, stub gates and this catalogue.
// The tree is removed, and whatever its gates left running killed, when the test ends, pass or fail.
function tree(ctx, mutations, flags = "ok\n") {
    const t = fs.mkdtempSync(path.join(os.tmpdir(), "mutate-test-"));
    ctx.after(() => { leftovers(t); fs.rmSync(t, { recursive: true, force: true }); });
    const put = (f, s, mode = 0o644) => { fs.mkdirSync(path.dirname(path.join(t, f)), { recursive: true }); fs.writeFileSync(path.join(t, f), s, { mode }); };
    fs.mkdirSync(path.join(t, "tools/motion"), { recursive: true });
    fs.copyFileSync(path.join(root, "tools/mutate.sh"), path.join(t, "tools/mutate.sh"));
    fs.chmodSync(path.join(t, "tools/mutate.sh"), 0o755);
    fs.copyFileSync(path.join(root, "tools/motion/apply.mjs"), path.join(t, "tools/motion/apply.mjs"));
    fs.copyFileSync(path.join(root, "tools/sync-shared.sh"), path.join(t, "tools/sync-shared.sh"));
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

test("mutate.sh -j 4: same table as -j 1, runs overlap in their own trees and runtime dirs, render gates capped", (ctx) => {
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
    assert.ok(peak(spans) > 1, "-j 4 runs gates at once");
    const render = spans.filter((x) => /shot|headless/.test(x.gate));
    assert.ok(peak(render) <= 2, "at most MUTATE_RENDER_JOBS render gates at once");
    // Each gate has its own runtime dir; each run's tree carries only its own mutation.
    assert.equal(new Set(spans.map((x) => x.rt)).size, spans.length);
    const flagOf = new Map();
    for (const s of spans) {
        assert.ok(!flagOf.has(s.dir) || flagOf.get(s.dir) === s.flag, `${s.dir} saw two trees`);
        flagOf.set(s.dir, s.flag);
    }
    assert.equal(new Set(flagOf.values()).size, flagOf.size, "no two runs share a tree");
    assert.ok(render.some((a) => render.some((b) => a !== b && overlap(a, b))), "render gates overlap");
    for (const o of render.filter((x) => x.gate === "orbs-shot"))
        assert.ok(!render.some((x) => x !== o && overlap(o, x)), "the orbs-shot gate renders alone");
    assert.deepEqual(leftovers(t), []);
});

// Headless runs are isolated (their own VNC socket, task 87f71d95), so they take one render
// slot each and run side by side up to the cap; before, each held every slot and the 25
// headless runs of the catalogue ran one at a time (critic gap G4 of verdict 0d8e0859).
test("mutate.sh runs headless gates at once, up to MUTATE_RENDER_JOBS", (ctx) => {
    const t = tree(ctx, [mut("H0", ["headless"], "headless-bad"), mut("H1", ["headless"], "headless-bad"), mut("H2", ["headless"], "headless-bad")]);
    const r = mutate(t, ["-j", "4"], { STUB_SLEEP: "0.6", MUTATE_RENDER_JOBS: "2" });
    assert.equal(r.status, 0);
    const spans = r.runs.filter((x) => x.what === "start").map((s) => ({ ...s, end: r.runs.find((x) => x.what === "end" && x.dir === s.dir && x.ms >= s.ms).ms }));
    assert.equal(spans.length, 4, "control and three mutations");
    assert.equal(peak(spans), 2, "two headless gates at once, never more than the cap");
});

// A gate that never ends (a readiness wait whose timeout never fires) is stopped after
// MUTATE_GATE_TIMEOUT s and counts as RED with exit 124, so the catalogue still finishes.
test("mutate.sh stops a gate after MUTATE_GATE_TIMEOUT and reports it RED (124)", (ctx) => {
    const t = tree(ctx, [mut("HANG", ["data", "river-shot"])]);
    const t0 = Date.now();
    const r = mutate(t, ["HANG"], { STUB_SLEEP: "60", MUTATE_GATE_TIMEOUT: "2" });
    assert.ok(Date.now() - t0 < 30000, "the run finished well before the stubs' 60 s");
    assert.match(r.row("HANG"), /RED\s+data=124$/);
    assert.match(r.row("control"), /RED\s+data=124$/);
    assert.deepEqual(leftovers(t), []);
});

// shot_wait (tools/shot-reap.sh), the render gates' readiness wait (task 87f71d95).
const shotWait = (script, timeout = 15000) => {
    const t0 = Date.now();
    const r = spawnSync("bash", ["-c", `. "${path.join(root, "tools/shot-reap.sh")}"; ${script}`], { encoding: "utf8", timeout });
    return { ...r, secs: (Date.now() - t0) / 1000 };
};

test("shot_wait returns only once its condition holds, and then at once", (ctx) => {
    const d = fs.mkdtempSync(path.join(os.tmpdir(), "shot-wait-"));
    ctx.after(() => fs.rmSync(d, { recursive: true, force: true }));
    const r = shotWait(`( sleep 1; echo "amplify: ready" > "${d}/log" ) & ready() { grep -q "amplify: ready" "${d}/log" 2>/dev/null; }; shot_wait 10 "the ready line" ready; echo "rc=$? $(cat "${d}/log")"`);
    assert.match(r.stdout, /rc=0 amplify: ready/, "it returned after the line was written");
    assert.ok(r.secs >= 0.9 && r.secs < 3, `took ${r.secs} s (the line came at 1 s)`);
});

test("shot_wait gives up after its timeout, returns 1 and says what it waited for", () => {
    const r = shotWait(`shot_wait 1 "a line that never comes" false; echo "rc=$?"`);
    assert.notEqual(r.status, null, "it never returned (the timeout did not fire)");
    assert.match(r.stdout, /rc=1/);
    assert.match(r.stderr, /timed out after 1 s waiting for a line that never comes/);
    assert.ok(r.secs >= 0.9 && r.secs < 5, `took ${r.secs} s`);
});

// shot_stop (task 859896c9): a TERM that lands before the launch's exec is lost, so the stop
// is bounded. A process that ignores TERM stands in for one whose TERM was lost.
test("shot_stop reaps a process at once on TERM, and one that survives TERM within 5 s by SIGKILL", () => {
    const quick = shotWait(`sleep 30 & p=$!; shot_stop $p; kill -0 $p 2>/dev/null && echo alive || echo gone`);
    assert.match(quick.stdout, /^gone$/m);
    assert.ok(quick.secs < 2, `a plain TERM took ${quick.secs} s`);
    const deaf = shotWait(`bash -c 'trap "" TERM; exec sleep 30' & p=$!; sleep 0.2; shot_stop $p; kill -0 $p 2>/dev/null && echo alive || echo gone`);
    assert.notEqual(deaf.status, null, "shot_stop never returned (no SIGKILL after the grace)");
    assert.match(deaf.stdout, /^gone$/m);
    assert.match(deaf.stderr, /timed out after 5 s waiting for process \d+ to exit on SIGTERM \(sending SIGKILL\)/);
    assert.ok(deaf.secs >= 4.9 && deaf.secs < 8, `took ${deaf.secs} s`);
});

// The render gates' cleanup guard (task 859896c9): a launch TERMed before its exec runs the
// gate's traps in the forked child, so cleanup() must do nothing outside the gate's own shell
// ($BASHPID != $$), or that child tears down the run's compositor and run dir mid-run. Each
// gate's own cleanup() is called in a subshell (another $BASHPID, the gate's $$), then in
// the gate's shell, where it must still remove the run dir.
test("each render gate's cleanup runs only in the gate's own shell, never in a forked child", () => {
    for (const gate of ["tools/headless-shot.sh", "plugin/orbs/test/shot.sh"]) {
        const lines = fs.readFileSync(path.join(root, gate), "utf8").split("\n");
        const at = lines.findIndex((l) => l.startsWith("cleanup() {"));
        assert.ok(at >= 0, `${gate} defines cleanup()`);
        const end = lines.findIndex((l, i) => i >= at && /(^|; )\}$/.test(l));
        const def = lines.slice(at, end + 1).join("\n");
        const r = spawnSync("bash", ["-c", `RUN=$(mktemp -d) LOGS=$(mktemp -d); SHEET="$RUN.qml" PIDS=()
shot_reap() { :; }
${def}
( cleanup ); [[ -d $RUN ]] && echo "child kept" || echo "child removed"
cleanup > /dev/null; [[ -d $RUN ]] && echo "gate kept" || echo "gate removed"; rm -rf "$RUN" "$LOGS"`], { encoding: "utf8", timeout: 15000 });
        assert.match(r.stdout, /^child kept$/m, `${gate}: cleanup() in a forked child removed the run dir`);
        assert.match(r.stdout, /^gate removed$/m, `${gate}: cleanup() in the gate's shell left the run dir`);
    }
});

// build-shaders.sh --check (task 1f323acc G1): qsb output is byte-identical only within one
// version, so a qsb other than the pinned one gets one toolchain message and exit 2, not a
// "differs" line per file. A stub qsb stands in for both versions; it writes junk, so with
// the pinned version the per-file comparison still runs and flags every file.
test("build-shaders --check with another qsb version says so once and exits 2; the pinned version compares files", (ctx) => {
    const d = fs.mkdtempSync(path.join(os.tmpdir(), "qsb-stub-"));
    ctx.after(() => fs.rmSync(d, { recursive: true, force: true }));
    const pin = fs.readFileSync(path.join(root, "tools/build-shaders.sh"), "utf8").match(/^QSB_PIN=(\S+)$/m)[1];
    const run = (version) => {
        const q = path.join(d, `qsb-${version}`);
        fs.writeFileSync(q, `#!/usr/bin/env bash
[[ $1 == --version ]] && { echo "qsb ${version}"; exit 0; }
while (( $# )); do [[ $1 == -o ]] && { echo junk > "$2"; shift; }; shift; done
`, { mode: 0o755 });
        return spawnSync(path.join(root, "tools/build-shaders.sh"), ["--check"], { cwd: root, encoding: "utf8", env: { ...process.env, QSB: q } });
    };
    const other = run("6.8.3");
    assert.equal(other.status, 2);
    const lines = other.stderr.trim().split("\n");
    assert.equal(lines.length, 1, other.stderr);
    assert.match(lines[0], new RegExp(`toolchain mismatch: qsb 6\\.8\\.3 .*built by qsb ${pin.replace(/\./g, "\\.")}`));
    const pinned = run(pin);
    assert.equal(pinned.status, 1);
    assert.doesNotMatch(pinned.stderr, /toolchain/);
    assert.match(pinned.stderr, /orbbeam\.frag\.qsb \(\d+ bytes\) differs from its source's build/);
});
