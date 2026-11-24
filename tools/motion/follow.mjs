// The one follow check: reads the motion spec (docs/motion.json) and a
// Quickshell log written with AMPLIFY_TRACE=1, and checks every traced axis of
// every moving item against its spec row. Movers are found from the data, not
// named: an axis whose record target ('<axis>:to') changes is a mover, an
// effect that exists is a sweep, a clock or spin whose record rate
// ('<axis>:rate') is non-zero must turn at that rate.
//
//   node tools/motion/follow.mjs <scenario> <log> [--spec docs/motion.json] [--json]
//
// Trace lines (plugin/motion/Trace.qml):
//   amplify: trace <comp> <part> <ident> <axis> <value> <ms> <n>
// Lines of one trace with the same n were drawn in the same animation tick.
//
// Kinds (spec rows' axes):
//   spring, tween  for each target change a -> b: the drawn value starts at a
//                  (within eps), its first move goes toward b, at least
//                  minBetween samples lie strictly between a and b (clear of
//                  both by max(clear, clearFrac * |b - a|)), no step is larger
//                  than maxStep * |b - a|, it overshoots b by at most
//                  overshoot * |b - a|, it is at b (within eps) by settle s and
//                  stays there. A tween is a spring that may not overshoot and
//                  must be monotone. Before any target change the drawn value
//                  holds at its target (within eps). enter: the value a new
//                  item comes in from when it does not start at its target
//                  (enterRequired: it always must, basin rows).
//   rides          every sample is within tol of the partner's (with: part,
//                  axis) samples just before or after it, and it ends on it.
//   sweep          each item goes once from `from` to `to` (within tol),
//                  monotone, with minBetween samples strictly between and no
//                  step over maxStep of the way.
//   spin, clock    while '<axis>:rate' is r != 0 the value changes at r per s
//                  (within rateTol, over each run of at least 1 s); while r = 0
//                  it does not change.
//   pulse          while '<axis>:on' is 1 it moves between lo and hi (within
//                  tol), reaching both ends; while 0 it holds.
//   step           the drawn value is its target at every sample (no animation
//                  by design).
//   none           not checked (spec says why).
// Scenario options (docs/motion.json scenarios):
//   still: true    AMPLIFY_STILL=1: nothing animates. Each drawn axis changes
//                  only in the tick its target changes and is then at it; no
//                  sweep, spin, clock or pulse changes after its first sample.
//   want           { "<comp>.<part>.<axis>": n }: at least n movers of that
//                  axis in this run (so a check cannot pass with nothing moving).
// A traced (comp, part) or axis the spec does not list fails: every moving
// thing needs a row. A log with no trace lines fails (still scenarios have no
// mover floors, so an untraced run would otherwise pass). Prints one line per
// check; exit 1 if any fails.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

export function parse(text) {
    const S = new Map(), G = new Map();
    let i = 0;
    for (const m of text.matchAll(/amplify: trace (\S+) (\S+) (\S+) (\S+) (-?[\d.]+) (\d+) (\d+)/g)) {
        const [, comp, part, ident, axis, v, t, n] = m;
        // A trace whose emit count goes back is a new item with the same ident
        // (a delegate made again): its own series, ident#2, #3, ...
        const base = `${comp} ${part} ${ident}`;
        const gen = (G.get(base) ?? { k: 1, n: 0 });
        if (Number(n) < gen.n) gen.k++;
        gen.n = Number(n); G.set(base, gen);
        const id = gen.k > 1 ? `${ident}#${gen.k}` : ident;
        const key = `${comp} ${part} ${id}`;
        if (!S.has(key)) S.set(key, { comp, part, ident: id, axes: {} });
        (S.get(key).axes[axis] ??= []).push({ i: i++, t: Number(t), n: Number(n), v: Number(v) });
    }
    return S;
}

// Value of samples s at log position i (the last sample at or before it).
const at = (s, i) => { let v; for (const x of s) { if (x.i > i) break; v = x.v; } return v; };
// Value of samples s of the same trace at emit n (the last sample emitted at or before it).
const atN = (s, n) => { let v; for (const x of s) { if (x.n > n) break; v = x.v; } return v; };

function follow(drawn, target, p) {
    const out = [];
    const eps = p.eps ?? 0.5;
    const changes = [];
    for (let k = 1; k < target.length; k++) if (target[k].v !== target[k - 1].v) changes.push(k);
    // Before the first change: hold at the creation target (or enter from p.enter).
    const firstI = changes.length ? target[changes[0]].i : Infinity;
    const pre = drawn.filter((d) => d.i < firstI);
    const t0 = target[0].v;
    // enter: a new item comes in from p.enter, so a target away from it must be reached by a path.
    // enter: a new item comes in from p.enter, so a target away from it must be reached by a
    // path. Without enterRequired, an item that already starts at its target only has to hold
    // (a binding that is there when the delegate is made does not animate).
    const entering = p.enter !== undefined && Math.abs(p.enter - t0) > eps
        && (p.enterRequired || (pre.length && Math.abs(pre[0].v - t0) > eps));
    if (entering) {
        // The entry runs until the first change at least `min` away from the creation target
        // (smaller record drift on the way does not end it).
        const big = changes.find((k) => Math.abs(target[k].v - t0) >= (p.min ?? 0));
        const endI = big === undefined ? Infinity : target[big].i;
        const into = drawn.filter((d) => d.i < endI);
        const k = into.findIndex((d) => Math.abs(d.v - p.enter) <= eps);
        // It has entered at the first sample on its target at that moment (the target may drift).
        const arrive = k < 0 ? -1 : into.findIndex((d, j) => j > k && Math.abs(d.v - at(target, d.i)) <= eps);
        const seg = k < 0 ? [] : arrive < 0 ? into.slice(k) : into.slice(k, arrive + 1);
        const b = arrive < 0 ? t0 : at(target, into[arrive].i);
        const cut = p.retarget && endI !== Infinity && arrive < 0;
        out.push({ kind: "enter", mover: true, ...path_(p.enter, b, seg, cut ? { ...p, cut } : p, seg[0]?.t ?? 0) });
    } else {
        const off = pre.length ? Math.max(...pre.map((d) => Math.abs(d.v - t0))) : 0;
        out.push({ kind: "hold", ok: off <= eps, why: `holds at ${t0.toFixed(2)} before any change (${off.toFixed(2)} off)`, still: true });
    }
    for (let c = 0; c < changes.length; c++) {
        const k = changes[c], T = target[k], b = T.v;
        const a = target[k - 1].v;
        const endI = c + 1 < changes.length ? target[changes[c + 1]].i : Infinity;
        const before = at(drawn, T.i - 1);
        const seg = drawn.filter((d) => d.i > T.i - 0.5 && d.i < endI);
        if (Math.abs(b - a) < (p.min ?? 0)) {
            // Below the mover threshold: only check it gets there.
            const last = seg.length ? seg.at(-1).v : before;
            const cut = p.retarget && (endI !== Infinity || p.logEnd - T.t < 2000);
            if (!cut && last !== undefined && Math.abs(last - b) > eps)
                out.push({ kind: "small", ok: false, why: `small change ${a.toFixed(2)} → ${b.toFixed(2)} ends at ${last.toFixed(2)}` });
            continue;
        }
        // retarget: the record moves on before this tween can end (a tween longer than the data tick);
        // then only the path so far is checked, not where it ends or where it started.
        const cut = p.retarget && (endI !== Infinity || p.logEnd - T.t < 2000);
        const r = path_(before ?? a, b, seg, cut ? { ...p, cut: true } : p, T.t, cut ? (before ?? a) : a);
        out.push({ kind: "move", mover: true, ...r });
    }
    return out;
}

// One move from a to b through samples seg (after the change at ms t).
function path_(a, b, seg, p, t, recordFrom = a) {
    const d = Math.abs(b - a), sg = Math.sign(b - a);
    const eps = p.eps ?? 0.5;
    const why = [];
    const f = (x) => (Math.abs(x) < 10 ? x.toFixed(4) : x.toFixed(2));
    let ok = true;
    const bad = (c, m) => { if (c) { ok = false; why.push(m); } };
    bad(Math.abs(a - recordFrom) > eps, `starts at ${a.toFixed(2)}, not the record's ${recordFrom.toFixed(2)}`);
    const clear = Math.max(p.clear ?? 0, (p.clearFrac ?? 0) * d);
    const lo = Math.min(a, b) + clear, hi = Math.max(a, b) - clear;
    const between = seg.filter((x) => x.v > lo && x.v < hi).length;
    let step = 0, prev = a, back = false, peak = 0;
    for (const x of seg) {
        step = Math.max(step, Math.abs(x.v - prev));
        if (Math.sign(x.v - prev) === -sg && Math.abs(x.v - prev) > 1e-6 && (x.v - b) * sg < 0) back = true;
        peak = Math.max(peak, (x.v - b) * sg);
        prev = x.v;
    }
    const first = seg.find((x) => Math.abs(x.v - a) > 1e-6);
    const last = seg.length ? seg.at(-1).v : a;
    const settled = seg.filter((x) => Math.abs(x.v - b) > eps).at(-1);
    const settle = settled ? (settled.t - t) / 1000 : 0;
    bad(!(p.cut && d < 4 * eps) && between < (p.minBetween ?? 3), `${between} samples between (want ${p.minBetween ?? 3})`);
    bad(d > 0 && step > (p.maxStep ?? 0.5) * d, `jumps ${step.toFixed(2)} of ${d.toFixed(2)}`);
    bad(first && Math.sign(first.v - a) !== sg && (p.toward ?? true), "first move goes the wrong way");
    bad(!p.cut && Math.abs(last - b) > eps, `ends at ${last.toFixed(2)}, not ${b.toFixed(2)}`);
    bad(peak > (p.overshoot ?? 0) * d + eps, `overshoots by ${peak.toFixed(2)} (max ${((p.overshoot ?? 0) * d).toFixed(2)})`);
    bad(p.monotone && back, "turns back");
    bad(!p.cut && p.settle !== undefined && settle > p.settle, `settles after ${settle.toFixed(2)} s (max ${p.settle})`);
    return { ok, why: `${a.toFixed(2)} → ${b.toFixed(2)}: ${between} between, step ${step.toFixed(2)}, overshoot ${peak.toFixed(2)}, settled ${settle.toFixed(2)} s${why.length ? "; " + why.join("; ") : ""}` };
}

function rate(drawn, rates, p) {
    // Split the run where the record rate changes; check each run.
    const out = [];
    if (!rates || !rates.length) return [{ ok: false, why: "no :rate traced" }];
    const runs = [];
    for (let k = 0; k < rates.length; k++) runs.push({ r: rates[k].v, n0: rates[k].n, n1: k + 1 < rates.length ? rates[k + 1].n : Infinity });
    for (const run of runs) {
        // Samples drawn in the emits after the one the rate changed in, up to the next change.
        const s = drawn.filter((x) => x.n > run.n0 && x.n < run.n1);
        if (run.r === 0) {
            const moved = s.length ? Math.max(...s.map((x) => Math.abs(x.v - (atN(drawn, run.n0) ?? s[0].v)))) : 0;
            out.push({ ok: moved <= (p.eps ?? 1e-3), why: `rate 0: moved ${moved.toFixed(3)}`, still: true });
            continue;
        }
        if (s.length < 2 || s.at(-1).t - s[0].t < 1000) continue;
        const got = (s.at(-1).v - s[0].v) / ((s.at(-1).t - s[0].t) / 1000);
        const tol = p.rateTol ?? 0.35;
        let back = false;
        for (let k = 1; k < s.length; k++) if (Math.sign(s[k].v - s[k - 1].v) === -Math.sign(run.r) && Math.abs(s[k].v - s[k - 1].v) > 1e-6) back = true;
        out.push({ mover: true, ok: !back && Math.abs(got - run.r) <= tol * Math.abs(run.r), why: `turns at ${got.toFixed(3)}/s, record says ${run.r.toFixed(3)}/s${back ? ", turns back" : ""}` });
    }
    return out;
}

function sweep(s, p) {
    const v = s.map((x) => x.v), from = p.from, to = p.to, sg = Math.sign(to - from), d = Math.abs(to - from);
    const tol = p.tol ?? 1;
    let mono = true, step = 0;
    for (let k = 1; k < v.length; k++) {
        if (Math.sign(v[k] - v[k - 1]) === -sg && Math.abs(v[k] - v[k - 1]) > 1e-6) mono = false;
        step = Math.max(step, Math.abs(v[k] - v[k - 1]));
    }
    const lo = Math.min(from, to) + tol, hi = Math.max(from, to) - tol;
    const between = v.filter((x) => x > lo && x < hi).length;
    const ok = v.length > 0 && Math.abs(v[0] - from) <= tol && Math.abs(v.at(-1) - to) <= tol && mono && between >= (p.minBetween ?? 10) && step <= (p.maxStep ?? 0.25) * d;
    return [{ mover: true, ok, why: `${v.length ? `${v[0].toFixed(2)} → ${v.at(-1).toFixed(2)}` : "never"} (want ${from} → ${to}): ${between} between, step ${step.toFixed(2)}${mono ? "" : ", turns back"}` }];
}

function pulse(s, on, p) {
    const out = [];
    const tol = p.tol ?? 0.02;
    const live = s.filter((x) => atN(on, x.n) === 1);
    const idle = s.filter((x) => atN(on, x.n) !== 1 && x !== s[0] && atN(on, x.n - 1) !== 1);
    if (idle.length) out.push({ ok: false, why: `changes ${idle.length} times while off`, still: true });
    if (!live.length) return out.length ? out : [{ ok: true, why: "off", still: true }];
    const min = Math.min(...live.map((x) => x.v)), max = Math.max(...live.map((x) => x.v));
    out.push({ mover: true, ok: min >= p.lo - tol && max <= p.hi + tol && min <= p.lo + 0.05 && max >= p.hi - 0.05 && live.length >= 10,
               why: `pulses ${min.toFixed(2)}..${max.toFixed(2)} (want ${p.lo}..${p.hi}) in ${live.length} samples` });
    return out;
}

function stepCheck(drawn, target, p) {
    const eps = p.eps ?? 0.5;
    let off = 0;
    // From the second emit: at creation the item may not have its bindings yet.
    for (const d of drawn) {
        if (d.n < 2) continue;
        const t = atN(target, d.n);
        if (t !== undefined) off = Math.max(off, Math.abs(d.v - t));
    }
    return [{ ok: off <= eps, why: `drawn at its target (${off.toFixed(2)} off)` }];
}

// Still mode: an animated axis changes only in the tick its target changes.
function stillCheck(drawn, target) {
    if (!target) {
        const moved = drawn.length > 1 ? Math.max(...drawn.map((x) => Math.abs(x.v - drawn[0].v))) : 0;
        return [{ ok: moved <= 1e-3, why: `still: moved ${moved.toFixed(3)} after its first sample` }];
    }
    const steps = new Set(target.map((x) => x.n));
    // The first change after creation that lands on the target is layout, not motion.
    const loose = drawn.filter((x, k) => !steps.has(x.n) && !(k === 1 && drawn[0].n === 1 && Math.abs(x.v - atN(target, x.n)) <= 0.5));
    const end = Math.abs(drawn.at(-1).v - target.at(-1).v);
    return [{ ok: loose.length === 0 && end <= 0.5, why: `still: ${loose.length} changes outside a data step, ends ${end.toFixed(2)} from its target` }];
}

export function check(spec, scenario, text) {
    const sc = spec.scenarios[scenario];
    if (!sc) throw new Error(`no scenario ${scenario}`);
    const S = parse(text);
    // An empty trace passes every per-item check (still scenarios have no mover floors),
    // so a run that traced nothing fails here (gap G1, verdict d1c6236b).
    if (!S.size) return { results: [{ name: "trace", ok: false, why: "no trace lines in the log (AMPLIFY_TRACE=1 not on, or nothing traced)" }], movers: {}, ok: false };
    const logEnd = Math.max(0, ...[...S.values()].flatMap((s) => Object.values(s.axes).map((a) => a.at(-1).t)));
    const rows = new Map(spec.rows.flatMap((r) => r.parts.map((p) => [`${r.comp} ${p.part}`, { row: r, ...p }])));
    const results = [], movers = {};
    for (const s of S.values()) {
        const def = rows.get(`${s.comp} ${s.part}`);
        if (!def) { results.push({ name: `${s.comp}.${s.part}`, ok: false, why: "traced but not in the spec" }); continue; }
        for (const [axis, drawn] of Object.entries(s.axes)) {
            if (axis.includes(":")) continue;
            const p = def.axes[axis];
            const name = `${s.comp}.${s.part}.${axis}`;
            if (!p) { results.push({ name: `${name} ${s.ident}`, ok: false, why: "axis traced but not in the spec" }); continue; }
            const target = s.axes[`${axis}:to`], rates = s.axes[`${axis}:rate`], on = s.axes[`${axis}:on`];
            let rs;
            if (p.kind === "none") continue;
            if (sc.still && p.kind !== "step" && p.kind !== "rides") rs = stillCheck(drawn, target);
            else if (p.kind === "spring" || p.kind === "tween")
                rs = target ? follow(drawn, target, { ...p, logEnd, monotone: p.kind === "tween", overshoot: p.kind === "tween" ? 0 : p.overshoot })
                    : [{ ok: false, why: `no ${axis}:to traced` }];
            else if (p.kind === "rides") {
                const partner = S.get(`${s.comp} ${p.with} ${s.ident}`)?.axes[p.axis ?? axis];
                if (!partner) rs = [{ ok: false, why: `its ${p.with} ${p.axis ?? axis} is not traced` }];
                else {
                    let off = 0;
                    for (const x of drawn) {
                        const near = partner.filter((y) => y.i <= x.i).at(-1), next = partner.find((y) => y.i > x.i);
                        const cand = [near, next].filter(Boolean).map((y) => Math.abs(y.v - x.v));
                        if (cand.length) off = Math.max(off, Math.min(...cand));
                    }
                    const end = Math.abs(drawn.at(-1).v - partner.at(-1).v);
                    const moves = Math.max(...partner.map((y) => Math.abs(y.v - partner[0].v))) >= 1;
                    rs = [{ mover: moves, ok: off <= (p.tol ?? 1) && end <= (p.tol ?? 1), why: `rides its ${p.with} ${p.axis ?? axis}: ${off.toFixed(2)} off at worst, ends ${end.toFixed(2)} from it` }];
                }
            } else if (p.kind === "sweep") rs = sweep(drawn, p);
            else if (p.kind === "spin" || p.kind === "clock") rs = rate(drawn, rates, p);
            else if (p.kind === "pulse") rs = on ? pulse(drawn, on, p) : [{ ok: false, why: `no ${axis}:on traced` }];
            else if (p.kind === "step") rs = target ? stepCheck(drawn, target, p) : [{ ok: false, why: `no ${axis}:to traced` }];
            else rs = [{ ok: false, why: `unknown kind ${p.kind}` }];
            for (const r of rs) {
                if (r.mover) movers[name] = (movers[name] || 0) + 1;
                if (r.mover || !r.ok || sc.still || process.env.FOLLOW_ALL) results.push({ name: `${name} ${s.ident}`, ok: r.ok, why: r.why });
            }
        }
    }
    for (const [name, n] of Object.entries(sc.want || {}))
        results.push({ name, ok: (movers[name] || 0) >= n, why: `${movers[name] || 0} movers (want ≥ ${n})`, want: true });
    return { results, movers, ok: results.every((r) => r.ok) };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
    const args = process.argv.slice(2);
    const si = args.indexOf("--spec");
    const specPath = si >= 0 ? args.splice(si, 2)[1] : path.join(root, "docs/motion.json");
    const json = args.includes("--json");
    const [scenario, log] = args.filter((a) => a !== "--json");
    const r = check(JSON.parse(fs.readFileSync(specPath, "utf8")), scenario, fs.readFileSync(log, "utf8"));
    if (json) console.log(JSON.stringify(r));
    else for (const x of r.results) console.log(`${x.ok ? "ok  " : "BAD "} ${x.name}: ${x.why}`);
    process.exit(r.ok ? 0 : 1);
}
