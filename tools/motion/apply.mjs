// Apply one mutation from tools/motion/mutations.json to a tree (tools/mutate.sh
// runs this on a scratch copy, never on the working tree).
//   node tools/motion/apply.mjs <tree> <id>       exit 0 applied, 3 stale (an edit does not match exactly once)
//   node tools/motion/apply.mjs <tree> --check    every mutation applies to <tree> (in memory); exit 3 if any is stale
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
export const catalogue = () => JSON.parse(fs.readFileSync(path.join(here, "mutations.json"), "utf8")).mutations;

// Returns { files: {path: newText}, stale: [why] } without writing.
export function plan(tree, mut) {
    const files = {}, stale = [];
    const read = (f) => files[f] ?? fs.readFileSync(path.join(tree, f), "utf8");
    for (const e of mut.edits) {
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
        fs.rmSync(p, { force: true });   // a symlinked file gets its own copy, so the target stays unmutated
        fs.writeFileSync(p, s, { mode });
    }
}
