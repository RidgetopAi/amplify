// The plugin's copies of shared files (tools/sync-shared.sh, task af4b39ff): each copy
// matches its one source, and plugin/ holds no symlinks, which omarchy plugin validate rejects.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const check = (root) => spawnSync("bash", [path.join(root, "tools", "sync-shared.sh"), "--check"], { encoding: "utf8" });

test("every plugin copy of a shared file matches its source, and plugin/ has no symlinks", () => {
    const r = check(ROOT);
    assert.equal(r.status, 0, r.stderr);
});

test("sync-shared.sh --check fails on a drifted copy and on a symlink", (ctx) => {
    const t = fs.mkdtempSync(path.join(os.tmpdir(), "shared-test-"));
    ctx.after(() => fs.rmSync(t, { recursive: true, force: true }));
    for (const d of ["data", "fixtures", "plugin", "tools"]) fs.cpSync(path.join(ROOT, d), path.join(t, d), { recursive: true });
    assert.equal(check(t).status, 0, "a fresh copy of this tree passes");

    const copy = path.join(t, "plugin", "orbs", "mandrel.js");
    fs.appendFileSync(copy, "// edited in the copy\n");
    let r = check(t);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /plugin\/orbs\/mandrel\.js differs from data\/mandrel\.js/);

    spawnSync("bash", [path.join(t, "tools", "sync-shared.sh")]);
    assert.equal(check(t).status, 0, "sync restores the copy");
    fs.symlinkSync("../shaders/river.frag.qsb", path.join(t, "plugin", "river", "extra.qsb"));
    r = check(t);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /symlinks inside plugin\/: plugin\/river\/extra\.qsb/);
});

// One replay snapshot (task 844a60aa) on one clock (task 679fbbc5): the only shipped reader of
// a snapshot by default (Qt.resolvedUrl("<file>.json") outside plugin/*/test/) is the scene
// clock, whose copies read copies of the shared capture, so orbs, river and basin show the same
// capture; the orbs' test-only fixture
// (fixtures/test/orbs-states.json) is never referenced from shipped code.
test("every shipped replay reads a copy of fixtures/amplify-snapshot.json", () => {
    const shared = fs.readFileSync(path.join(ROOT, "fixtures", "amplify-snapshot.json"));
    const qml = fs.readdirSync(path.join(ROOT, "plugin"), { recursive: true })
        .filter((f) => f.endsWith(".qml") && !f.split(path.sep).includes("test"));
    const readers = [];
    for (const f of qml) {
        const src = fs.readFileSync(path.join(ROOT, "plugin", f), "utf8");
        assert.ok(!/"[^"\n]*(fixtures\/test|orbs-states)[^"\n]*"/.test(src), `${f} replays the test-only orbs fixture`);
        for (const m of src.matchAll(/resolvedUrl\("([^"]+\.json)"\)/g)) {
            const file = path.join(ROOT, "plugin", path.dirname(f), m[1]);
            assert.ok(fs.existsSync(file) && shared.equals(fs.readFileSync(file)),
                `${f} replays ${path.relative(ROOT, file)}, not a copy of fixtures/amplify-snapshot.json`);
            readers.push(path.basename(f));
        }
    }
    assert.deepEqual([...new Set(readers)].sort(), ["SceneClock.qml"]);
    const { M } = require("../node.cjs");
    const src = (f) => M.replaySource(JSON.parse(fs.readFileSync(path.join(ROOT, "fixtures", f), "utf8")));
    assert.match(src("amplify-snapshot.json"), /^captured 2026-11-22T04:00:17\.000Z sessions 12 tasks \d+ records [0-9a-f]{8}$/);
    assert.notEqual(src("amplify-snapshot.json").split(" records ")[1], src("test/orbs-states.json").split(" records ")[1]);
});
