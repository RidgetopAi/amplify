// Trajectory checks for plugin/river/test/shot.sh. With AMPLIFY_RIVER_TRACE=1,
// River.qml logs each moving row's drawn value whenever it changes:
//   amplify: river trace vessel <id8> <hull centre x>     (inventory row 5)
//   amplify: river trace gate <lane> <gate x>              (row 2)
//   amplify: river trace tether <id8> <hull end x2>        (row 3)
//   amplify: river trace rings <id8> <rotation, degrees>   (row 8)
// The first line of each series is its value when its delegate was made (the
// scene before), the last its settled value.
//
//   node trace.mjs <quickshell log> <check> …
//     slide <row> <key,…|events|*> <min count>
//         Each named series (events: the tasks in the log's 'river events'
//         line; *: every series of that row that moves 20 px or more) slides
//         from its start to its end: at least 3 samples lie strictly between
//         them (1 px clear of both), it first moves toward the end, and no
//         step covers more than half the distance (a jump). At least
//         <min count> series must move.
//     follow
//         Every tether's hull end slides (as above) whenever its vessel does,
//         ends where its vessel ends, and each sample is within 1 px of one
//         of its vessel's samples (it rides the hull, not ahead of it).
//     turn <id8> <to degrees>
//         The REJECT rings turn one way from 0 to <to>: every step goes the
//         same way, at least 10 samples lie strictly between, the last is
//         within 1 degree of <to>, no step covers more than a quarter of it.
// Prints one line per check; exit 1 if any fails.
import fs from "node:fs";

const [log, ...args] = process.argv.slice(2);
const text = fs.readFileSync(log, "utf8");
const S = {};
for (const m of text.matchAll(/amplify: river trace (\w+) (\S+) (-?[\d.]+)/g))
    ((S[m[1]] ??= {})[m[2]] ??= []).push(Number(m[3]));
const events = [...text.matchAll(/amplify: river events (.*)/g)].flatMap((m) => [...m[1].matchAll(/\w+ ([0-9a-f]{8}) /g)].map((e) => e[1]));

function slide(v) {
    const a = v[0], b = v[v.length - 1], d = Math.abs(b - a);
    if (d < 1) return { ok: false, why: `does not move (${a.toFixed(1)})` };
    const lo = Math.min(a, b) + 1, hi = Math.max(a, b) - 1;
    const between = v.filter((x) => x > lo && x < hi).length;
    const first = v.find((x) => Math.abs(x - a) > 0.01);
    let step = 0;
    for (let i = 1; i < v.length; i++) step = Math.max(step, Math.abs(v[i] - v[i - 1]));
    const toward = first !== undefined && Math.sign(first - a) === Math.sign(b - a);
    const ok = between >= 3 && toward && step <= d / 2;
    return { ok, why: `${a.toFixed(1)}→${b.toFixed(1)}: ${between} between, largest step ${step.toFixed(1)} of ${d.toFixed(1)}${toward ? "" : ", starts the wrong way"}` };
}

let fail = false;
const report = (ok, msg) => { console.log(`${ok ? "ok  " : "BAD "} ${msg}`); if (!ok) fail = true; };

for (let i = 0; i < args.length; i++) {
    if (args[i] === "slide") {
        const [row, which, min] = [args[i + 1], args[i + 2], Number(args[i + 3])]; i += 3;
        const all = S[row] || {};
        const keys = which === "*" ? Object.keys(all).filter((k) => Math.abs(all[k].at(-1) - all[k][0]) >= 20)
            : which === "events" ? events : which.split(",");
        report(keys.length >= min, `${row} ${which}: ${keys.length} moving series (want ≥ ${min})`);
        for (const k of keys) {
            const r = all[k] ? slide(all[k]) : { ok: false, why: "not traced" };
            report(r.ok, `${row} ${k} slides ${r.why}`);
        }
    } else if (args[i] === "follow") {
        const T = S.tether || {}, V = S.vessel || {};
        report(Object.keys(T).length > 0, `tethers traced: ${Object.keys(T).length}`);
        for (const [k, t] of Object.entries(T)) {
            const v = V[k];
            if (!v) { report(false, `tether ${k}: its vessel is not traced`); continue; }
            const moves = Math.abs(v.at(-1) - v[0]) >= 1;
            const r = moves ? slide(t) : { ok: true, why: "vessel still" };
            const off = Math.max(...t.map((x) => Math.min(...v.map((y) => Math.abs(x - y)))));
            const end = Math.abs(t.at(-1) - v.at(-1));
            report(r.ok && off <= 1 && end <= 1, `tether ${k} rides its hull: ${r.why}; ${off.toFixed(2)} px off the hull's path, ends ${end.toFixed(2)} px from it`);
        }
    } else if (args[i] === "turn") {
        const [k, to] = [args[i + 1], Number(args[i + 2])]; i += 2;
        const v = (S.rings || {})[k] || [];
        const sgn = Math.sign(to);
        let mono = true, step = 0;
        for (let j = 1; j < v.length; j++) {
            if (Math.sign(v[j] - v[j - 1]) === -sgn) mono = false;
            step = Math.max(step, Math.abs(v[j] - v[j - 1]));
        }
        const lo = Math.min(0, to) + 1, hi = Math.max(0, to) - 1;
        const between = v.filter((x) => x > lo && x < hi).length;
        const ok = v.length > 0 && Math.abs(v[0]) <= 1 && Math.abs(v.at(-1) - to) <= 1 && mono && between >= 10 && step <= Math.abs(to) / 4;
        report(ok, `rings ${k} turn ${v.length ? `${v[0].toFixed(1)}→${v.at(-1).toFixed(1)}` : "never"} (want 0→${to}): ${between} between, largest step ${step.toFixed(1)}${mono ? "" : ", turns back"}`);
    } else {
        console.error(`trace.mjs: unknown check ${args[i]}`);
        process.exit(2);
    }
}
process.exit(fail ? 1 : 0);
