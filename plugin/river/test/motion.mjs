// Frame-sequence motion checks for plugin/river/test/shot.sh. Reads grim PNGs
// through ImageMagick (`magick … rgb:-`), so it needs only node and magick.
//
//   node motion.mjs still <f0.png> <f1.png> …
//       Every frame identical to the first. Prints the changed-pixel count of
//       each frame against the first; exit 1 if any differs.
//   node motion.mjs region <x0,y0,x1,y1> <eddy cx,cy | -> <f0.png> <f1.png> …
//       Changed pixels inside the box between consecutive frames, leaving out
//       the water (the current moves with flow, under every effect) and the
//       blocked swirl around (cx, cy). Prints one count per pair; exit 0.
//   node motion.mjs eddy <cx,cy> <f0.png> <f1.png> …
//       The blocked swirl turns in place on its hull at (cx, cy): every
//       consecutive pair changes some pixels and at least 90 % of them lie on
//       the swirl's rings (radius 54 and 66 px, squashed 0.5 in y, so r in
//       44..76 after unsquashing). Exit 1 unless every pair passes.
// Coordinates are screen px; the water band comes from river.js (centerY,
// halfWidth), scaled the way River.qml scales its 1080-high design space.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const src = fs.readFileSync(path.join(here, "../river.js"), "utf8").replace(/^\.pragma library\s*$/m, "");
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
} else {
    console.error("usage: motion.mjs still|region|eddy …");
    process.exit(2);
}
