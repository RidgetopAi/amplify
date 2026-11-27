// Apply one mutation from tools/motion/mutations.json to a tree (tools/mutate.sh
// runs this on a scratch copy, never on the working tree).
//   node tools/motion/apply.mjs <tree> <id>       exit 0 applied, 3 stale (an edit does not match exactly once)
//   node tools/motion/apply.mjs <tree> --check    every mutation applies to <tree> (in memory); exit 3 if any is stale
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const here = path.dirname(fileURLToPath(import.meta.url));
export const catalogue = () => JSON.parse(fs.readFileSync(path.join(here, "mutations.json"), "utf8")).mutations;

// Returns { files: {path: newText}, stale: [why] } without writing.
export function plan(tree, mut) {
    const files = {}, stale = [];
    const read = (f) => files[f] ?? fs.readFileSync(path.join(tree, f), "utf8");
    for (const e of mut.edits) {
        // { file, truncate: n }: keep the file's first n bytes (a binary such as a committed .qsb).
        if (e.truncate !== undefined) {
            const b = fs.readFileSync(path.join(tree, e.file));
            if (b.length <= e.truncate) stale.push(`${e.file}: ${b.length} bytes, not over ${e.truncate}`);
            else files[e.file] = b.subarray(0, e.truncate);
            continue;
        }
        // { file, copy: path }: replace the file with another file of the tree, byte for byte
        // (ship an old binary, such as fixtures/shaders/meridian-array-ctor.frag.qsb).
        if (e.copy !== undefined) {
            const src = path.join(tree, e.copy);
            if (!fs.existsSync(path.join(tree, e.file)) || !fs.existsSync(src)) stale.push(`${e.file} or ${e.copy} missing`);
            else if (fs.readFileSync(src).equals(fs.readFileSync(path.join(tree, e.file)))) stale.push(`${e.file} is already ${e.copy}`);
            else files[e.file] = fs.readFileSync(src);
            continue;
        }
        const s = read(e.file), n = s.split(e.from).length - 1;
        if (n !== 1) { stale.push(`${e.file}: "${e.from.slice(0, 60)}" matches ${n} times`); continue; }
        files[e.file] = s.replace(e.from, () => e.to);
    }
    if (mut.deleteRow) {
        const f = "docs/motion.json", spec = JSON.parse(read(f));
        const before = spec.rows.length;
        spec.rows = spec.rows.filter((r) => r.id !== mut.deleteRow);
        if (spec.rows.length !== before - 1) stale.push(`no spec row ${mut.deleteRow}`);
        files[f] = JSON.stringify(spec, null, 1);
    }
    if (!mut.edits.length && !mut.deleteRow && mut.id !== "control") stale.push("no edits");
    return { files, stale };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
    const [tree, id] = process.argv.slice(2);
    const all = catalogue();
    if (id === "--check") {
        let bad = 0;
        for (const m of all) for (const s of plan(tree, m).stale) { console.log(`STALE ${m.id}: ${s}`); bad++; }
        console.log(`${all.length} mutations, ${bad} stale edits`);
        process.exit(bad ? 3 : 0);
    }
    const m = all.find((x) => x.id === id);
    if (!m) { console.error(`no mutation ${id}`); process.exit(2); }
    const { files, stale } = plan(tree, m);
    if (stale.length) { for (const s of stale) console.log(`STALE ${id}: ${s}`); process.exit(3); }
    for (const [f, s] of Object.entries(files)) {
        const p = path.join(tree, f);
        const mode = fs.statSync(p).mode;   // keep a mutated script executable
        fs.rmSync(p, { force: true });
        fs.writeFileSync(p, s, { mode });
    }
    // An edited shared source (data/mandrel.js, ...) reaches the plugin's copies of it,
    // as it would after tools/sync-shared.sh; an edit to a copy itself stays drift.
    execFileSync("bash", [path.join(tree, "tools", "sync-shared.sh"), ...Object.keys(files)], { stdio: "inherit" });
}
