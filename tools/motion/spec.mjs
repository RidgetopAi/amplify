// Checks docs/motion.json against the code (task e0cabe57, done-when 2):
//  - every animation declaration in plugin/**/*.qml (Behavior on, *Animation,
//    *Animator, Timer, Transition, an orbs Ease, a rotation binding, a Rotation transform, a
//    "<axis>:rate" trace hook) is claimed by exactly one spec row anchor;
//  - every anchor matches as many declaring lines as it says (count, default 1);
//  - every traced part in the spec has a Trace hook in its component's QML,
//    and every Trace hook in the QML has a spec part.
//   node tools/motion/spec.mjs [--spec docs/motion.json] [--root .]
// Prints one line per problem; exit 1 if any.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const DECL = /\bEase\s*\{|Behavior on |\b[A-Z][A-Za-z]*Animation\b|\b[A-Z][A-Za-z]*Animator\b|\bTimer\s*\{|\bTransition\s*\{|^\s*rotation\s*:|\bRotation\s*\{/;
const DIRS = { river: "plugin/river", orbs: "plugin/orbs", basin: "plugin/basin", service: "plugin" };
DIRS.puck = "plugin/puck";

function qmlFiles(root) {
    const out = [];
    const walk = (d) => {
        for (const e of fs.readdirSync(path.join(root, d), { withFileTypes: true })) {
            const p = path.join(d, e.name);
            if (e.isDirectory()) { if (!/^(test|motion|shaders)$/.test(e.name)) walk(p); }
            else if (e.name.endsWith(".qml") && e.name !== "Trace.qml" && e.name !== "shell.qml") out.push(p);
        }
    };
    walk("plugin");
    return out;
}

export function checkSpec(spec, root) {
    const problems = [];
    const decls = [];
    for (const f of qmlFiles(root)) {
        // Trace hooks (the Loader blocks that make a Trace) are test hooks, not animations.
        let depth = 0;
        fs.readFileSync(path.join(root, f), "utf8").split("\n").forEach((line, i) => {
            const code = line.replace(/\/\/.*$/, "");
            const braces = (code.match(/\{/g) || []).length - (code.match(/\}/g) || []).length;
            if (depth > 0 || /\bTrace \{/.test(code)) { depth = Math.max(0, depth + braces); return; }
            if (DECL.test(code)) decls.push({ file: f, line: i + 1, text: code.trim(), claimed: 0 });
        });
    }
    for (const r of spec.rows) for (const a of r.code || []) {
        // An anchor starting with ^ matches the start of the declaring line.
        const hit = (t) => a.line.startsWith("^") ? t.startsWith(a.line.slice(1)) : t.includes(a.line);
        const hits = decls.filter((d) => d.file === a.file && hit(d.text));
        hits.forEach((d) => d.claimed++);
        if (hits.length !== (a.count ?? 1))
            problems.push(`row ${r.id}: anchor ${a.file} "${a.line}" matches ${hits.length} declarations (want ${a.count ?? 1})`);
    }
    for (const d of decls) {
        if (d.claimed > 1) problems.push(`${d.file}:${d.line} claimed by ${d.claimed} anchors: ${d.text}`);
        if (d.claimed === 0) problems.push(`${d.file}:${d.line} animation not in docs/motion.json: ${d.text}`);
    }
    // Trace hooks <-> spec parts.
    const hooks = new Set();
    for (const f of qmlFiles(root)) {
        const s = fs.readFileSync(path.join(root, f), "utf8");
        for (const m of s.matchAll(/comp: "(\w+)"; part: "(\w+)"/g)) hooks.add(`${m[1]} ${m[2]}`);
    }
    const parts = new Set();
    for (const r of spec.rows) for (const p of r.parts || []) {
        parts.add(`${r.comp} ${p.part}`);
        if (!DIRS[r.comp]) problems.push(`row ${r.id}: unknown comp ${r.comp}`);
    }
    for (const p of parts) if (!hooks.has(p)) problems.push(`spec part ${p} has no Trace hook in the QML`);
    for (const h of hooks) if (!parts.has(h)) problems.push(`Trace hook ${h} has no spec part`);
    for (const [name, sc] of Object.entries(spec.scenarios))
        for (const w of Object.keys(sc.want || {})) {
            const [c, p] = w.split(".");
            if (!parts.has(`${c} ${p}`)) problems.push(`scenario ${name} wants ${w}, not a spec part`);
        }
    return { problems, decls: decls.length, rows: spec.rows.length };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
    const args = process.argv.slice(2);
    const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
    const root = path.resolve(opt("--root", path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..")));
    const spec = JSON.parse(fs.readFileSync(opt("--spec", path.join(root, "docs/motion.json")), "utf8"));
    const r = checkSpec(spec, root);
    for (const p of r.problems) console.log(`BAD  ${p}`);
    console.log(`spec: ${r.rows} rows, ${r.decls} declarations, ${r.problems.length} problems`);
    process.exit(r.problems.length ? 1 : 0);
}
