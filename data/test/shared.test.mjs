// The plugin's copies of shared files (tools/sync-shared.sh, task af4b39ff): each copy
// matches its one source, and plugin/ holds no symlinks, which omarchy plugin validate rejects.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

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
