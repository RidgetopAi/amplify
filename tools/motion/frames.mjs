// Frame-sequence motion checks (pixels) for the shot.sh gates; the trace checks are follow.mjs. Reads grim PNGs
// through ImageMagick (`magick … rgb:-`), so it needs only node and magick.
//
//   node tools/motion/frames.mjs still <f0.png> <f1.png> …
//       Every frame identical to the first. Prints the changed-pixel count of
//       each frame against the first; exit 1 if any differs.
//   node tools/motion/frames.mjs region <x0,y0,x1,y1> <eddy cx,cy | -> <f0.png> <f1.png> …
//       Changed pixels inside the box between consecutive frames, leaving out
//       the water (the current moves with flow, under every effect) and the
//       blocked swirl around (cx, cy). Prints one count per pair; exit 0.
//   node tools/motion/frames.mjs eddy <cx,cy> <f0.png> <f1.png> …
//       The blocked swirl turns in place on its hull at (cx, cy): every
//       consecutive pair changes some pixels and at least 90 % of them lie on
//       the swirl's rings (radius 54 and 66 px, squashed 0.5 in y, so r in
//       44..76 after unsquashing). Exit 1 unless every pair passes.
//   node tools/motion/frames.mjs flow <f0.png> <f1.png> <f2.png>
//       Which way the water runs, from three frames a short, equal time apart:
//       along the river curve (17 depths across the band) the change f1 - f0
//       reappears in f2 - f1 shifted by however far the streaks travelled
//       (still terrain, hulls and labels cancel in the differences). Prints
//       the shift s (-240..240 px) where the two changes correlate best, and the
//       correlation there and at -s; exit 1 unless s >= 3 (content moved left
//       to right, downstream), the peak is at least 0.5 and -s stays under 0.2.
//       The range covers the water at 90 px/s between grabs up to 2.6 s apart:
//       under load grim takes 0.3-0.9 s a frame, so frames asked for 0.2 s apart
//       land 60-100 px of travel apart (task 1f323acc; a ±60 px search clipped
//       the peak there). Every shift is scored over the same columns.
//   node tools/motion/frames.mjs gold <cx,cy> <f.png>
//       The critic PASS ring drawn around (cx, cy): pixels of the ring's gold
//       (bright, red > green > blue, red - blue >= 40) on the ring at p = 0.5
//       (r = 56 design px, 48..64 after scaling), counted in twelve 30-degree
//       sectors. Prints the count and the sectors that have 5 or more; exit 1
//       unless the count is at least 250 and 9 sectors are lit (the arc
//       sweeps 306 degrees; the gold hull border alone lights at most 4).
// Coordinates are screen px; the water band comes from river.js (centerY,
// halfWidth), scaled the way River.qml scales its 1080-high design space.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const src = fs.readFileSync(path.join(here, "../../plugin/river/river.js"), "utf8").replace(/^\.pragma library\s*$/m, "");
const R = new Function(`${src}\nreturn { centerY, halfWidth };`)();

function load(file) {
    const [w, h] = execFileSync("magick", ["identify", "-format", "%w %h", file], { encoding: "utf8" }).trim().split(" ").map(Number);
    return { w, h, px: execFileSync("magick", [file, "-depth", "8", "rgb:-"], { maxBuffer: 64 << 20 }) };
}

function changed(a, b, keep = () => true, box = [0, 0, a.w, a.h]) {
    const out = [];
    for (let y = Math.max(0, box[1]); y < Math.min(a.h, box[3]); y++)
        for (let x = Math.max(0, box[0]); x < Math.min(a.w, box[2]); x++) {
            const i = (y * a.w + x) * 3;
            if ((a.px[i] !== b.px[i] || a.px[i + 1] !== b.px[i + 1] || a.px[i + 2] !== b.px[i + 2]) && keep(x, y)) out.push([x, y]);
        }
    return out;
}

const nums = (s) => s.split(",").map(Number);
const ring = (cx, cy) => (x, y) => Math.hypot(x - cx, (y - cy) * 2);
const [cmd, ...args] = process.argv.slice(2);

if (cmd === "still") {
    const f = args.map(load);
    const counts = f.slice(1).map((g) => changed(f[0], g).length);
    console.log(counts.join(" "));
    process.exit(counts.every((c) => c === 0) ? 0 : 1);
} else if (cmd === "region") {
    const box = nums(args[0]);
    const f = args.slice(2).map(load);
    const k = f[0].h / 1080, dw = 1080 * f[0].w / f[0].h;
    const r = args[1] === "-" ? null : ring(...nums(args[1]));
    const keep = (x, y) => {
        const X = x / k, Y = y / k;
        if (Math.abs(Y - R.centerY(X, dw)) <= R.halfWidth(X, dw) * 1.03 + 4) return false;   // water
        return !(r && r(x, y) <= 90);                                                       // blocked swirl
    };
    const counts = [];
    for (let i = 1; i < f.length; i++) counts.push(changed(f[i - 1], f[i], keep, box).length);
    console.log(counts.join(" "));
} else if (cmd === "eddy") {
    const [cx, cy] = nums(args[0]);
    const r = ring(cx, cy);
    const f = args.slice(1).map(load);
    let ok = true;
    for (let i = 1; i < f.length; i++) {
        const c = changed(f[i - 1], f[i]);
        const on = c.filter(([x, y]) => r(x, y) >= 44 && r(x, y) <= 76).length;
        const frac = c.length ? on / c.length : 0;
        const pass = c.length > 0 && frac >= 0.9;
        ok = ok && pass;
        console.log(`pair ${i}: ${c.length} px changed, ${(frac * 100).toFixed(1)}% on the swirl rings around ${cx},${cy} ${pass ? "ok" : "OFF HULL"}`);
    }
    process.exit(ok ? 0 : 1);
} else if (cmd === "flow") {
    const [a, b, c] = args.map(load);
    const k = a.h / 1080, dw = 1080 * a.w / a.h;
    const lum = (f, i) => f.px[i] * 0.3 + f.px[i + 1] * 0.59 + f.px[i + 2] * 0.11;
    const rows = [];
    for (let j = -8; j <= 8; j++) {
        const d1 = [], d2 = [];
        for (let x = 0; x < a.w; x++) {
            const X = x / k, y = Math.round((R.centerY(X, dw) + j / 10 * R.halfWidth(X, dw)) * k);
            const i = (y * a.w + x) * 3;
            d1.push(lum(b, i) - lum(a, i)); d2.push(lum(c, i) - lum(b, i));
        }
        rows.push([d1, d2]);
    }
    const S = 240;
    const corr = (s) => {
        let xy = 0, xx = 0, yy = 0;
        for (const [d1, d2] of rows)
            for (let x = S + 20; x < a.w - S - 20; x++) { const p = d1[x], q = d2[x + s]; xy += p * q; xx += p * p; yy += q * q; }
        return xx && yy ? xy / Math.sqrt(xx * yy) : 0;
    };
    let best = 0, top = -2;
    for (let s = -S; s <= S; s++) { const r = corr(s); if (r > top) { top = r; best = s; } }
    const back = corr(-best);
    console.log(`streaks moved ${best} px (correlation ${top.toFixed(2)}; at ${-best} px ${back.toFixed(2)})`);
    process.exit(best >= 3 && top >= 0.5 && back < 0.2 ? 0 : 1);
} else if (cmd === "gold") {
    const [cx, cy] = nums(args[0]);
    const f = load(args[1]);
    const k = f.h / 1080, sectors = new Array(12).fill(0);
    let n = 0;
    for (let y = Math.max(0, Math.floor(cy - 70 * k)); y < Math.min(f.h, cy + 70 * k); y++)
        for (let x = Math.max(0, Math.floor(cx - 70 * k)); x < Math.min(f.w, cx + 70 * k); x++) {
            const r = Math.hypot(x - cx, y - cy) / k;
            if (r < 48 || r > 64) continue;
            const i = (y * f.w + x) * 3, [R_, G, B] = [f.px[i], f.px[i + 1], f.px[i + 2]];
            if (!(R_ >= 110 && R_ > G && G > B && R_ - B >= 40)) continue;
            n++;
            sectors[Math.floor(((Math.atan2(y - cy, x - cx) * 180 / Math.PI) + 360) % 360 / 30)]++;
        }
    const lit = sectors.filter((c) => c >= 5).length;
    console.log(`${n} gold px on the ring, ${lit}/12 sectors lit (${sectors.join(" ")})`);
    process.exit(n >= 250 && lit >= 9 ? 0 : 1);
} else {
    console.error("usage: frames.mjs still|region|eddy|flow|gold …");
    process.exit(2);
}
