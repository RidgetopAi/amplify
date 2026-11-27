// node plugin/focus/test/rim.mjs <shot.png> <session id8> <yaw> <pitch> [cut]
// The loupe's rim on a rendered focus shot (plugin/focus/test/shot.sh; decision c197bf39): every
// plaque that faces you is drawn, and plaque text outside the loupe is dimmed. The globe sits
// where Meridian.qml lands it (centre W/2, 0.52 H; radius toR) at the yaw and pitch its log line
// gave. meridian.js plaqueLight says which screen pixels belong to which plaque, inside the
// loupe (q < 0.8, clear of the rim band) or outside it (q > 1.12, clear of the ring). For each
// plaque and side with at least MIN_PX pixels (off the graticule lines), its light is the 97th
// percentile luminance of its pixels over the median of the bare globe around them (its text and
// border against the ceramic):
//   drawn   every such side lights at least MIN_LIGHT (a hidden plaque is bare globe: about 0);
//   dimmed  a plaque cut by the rim lights less outside than inside: out / in <= MAX_RATIO
//           (magnified text alone lights more inside; the ratio is set between the two).
// Exit status: the number of failed checks.
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import fs from "node:fs";

const require = createRequire(import.meta.url);
const { M } = require("../../../data/node.cjs");
const G = require("./load.cjs");
const [file, id, yaw, pitch, want] = process.argv.slice(2);   // want "cut": a plaque must be cut by the rim
// Calibrated on the three shots (focus, loupe, drag) and on both mutations of the catalogue
// (MF3 rim hides plaques: hidden sides measure 0.6-6.6, the dimmest drawn side, superseded
// cae2c3da outside the loupe, 16.4; MF4/MF5 no dimming: 53163e57 cut mid-drag out/in 0.61,
// dimmed 0.34).
const MIN_PX = 1000, MIN_LIGHT = 11, MAX_RATIO = 0.47;

const [w, h] = execFileSync("magick", ["identify", "-format", "%w %h", file], { encoding: "utf8" }).trim().split(" ").map(Number);
const px = execFileSync("magick", [file, "-depth", "8", "rgb:-"], { maxBuffer: 64 << 20 });
const lum = (x, y) => { const o = (y * w + x) * 3; return 0.299 * px[o] + 0.587 * px[o + 1] + 0.114 * px[o + 2]; };
const snap = JSON.parse(fs.readFileSync(new URL("../../../fixtures/amplify-snapshot.json", import.meta.url)));
const now = Date.parse(snap.meta.captured_at);
const pl = G.globe(M.replayScene(snap, now), id, now).plaques;
const st = G.spin(Number(yaw), Number(pitch));
const cx = w / 2, cy = h * 0.52, R = Math.max(60, Math.min(h * 0.42, (w - 760) / 2.4));

// The graticule, the time meridians and the now meridian are drawn on plaques and bare globe
// alike: pixels within LINE radians of one are left out of both.
const LINE = 0.015, MERIDIANS = [0, ...G.MARKS_SEC.map(G.lonOf)];
function onLine(sx, sy) {
  const pp = G.throughLoupe(sx, sy), W = G.hit(pp[0], pp[1]);
  if (!W) return true;
  const [lon, lat] = G.lonLat(G.toObj(W, st.yaw, st.pitch)), g = Math.PI / 12;
  if (Math.abs(lat - g * Math.round(lat / g)) < LINE) return true;
  return MERIDIANS.some((m) => Math.abs(G.wrap(lon - m)) * Math.cos(lat) < LINE);
}
// side: "in" | "out" | null (rim band or ring); plaque -1 bare globe, -2 off the globe.
const own = new Map();   // `${i} ${side}` -> [[x, y], ...]
for (let y = Math.floor(cy - R); y < cy + R; y++) for (let x = Math.floor(cx - R); x < cx + R; x++) {
  const sx = (x - cx) / R, sy = -(y - cy) / R;
  const q = Math.hypot(sx - G.LOUPE.x, sy - G.LOUPE.y) / G.LOUPE.r;
  const side = q < 0.8 ? "in" : q > 1.12 ? "out" : null;
  if (!side || Math.hypot(sx, sy) > 0.97) continue;
  const i = G.plaqueLight(st, sx, sy, pl).i;
  if (onLine(sx, sy)) continue;
  const k = `${i} ${side}`;
  if (!own.has(k)) own.set(k, []);
  own.get(k).push([x, y]);
}
const pct = (a, f) => { const s = [...a].sort((u, v) => u - v); return s[Math.min(s.length - 1, Math.floor(f * s.length))]; };
function light(i, side) {
  const pts = own.get(`${i} ${side}`) || [];
  if (pts.length < MIN_PX) return null;
  let x0 = Infinity, x1 = -Infinity, y0 = Infinity, y1 = -Infinity;
  for (const [x, y] of pts) { x0 = Math.min(x0, x); x1 = Math.max(x1, x); y0 = Math.min(y0, y); y1 = Math.max(y1, y); }
  const bare = (own.get(`-1 ${side}`) || []).filter(([x, y]) => x > x0 - 40 && x < x1 + 40 && y > y0 - 40 && y < y1 + 40);
  if (bare.length < MIN_PX) return null;
  return pct(pts.map(([x, y]) => lum(x, y)), 0.97) - pct(bare.map(([x, y]) => lum(x, y)), 0.5);
}

let fails = 0, cut = 0;
pl.forEach((p, i) => {
  const a = light(i, "in"), b = light(i, "out");
  const n = (s) => (own.get(`${i} ${s}`) || []).length;
  const parts = [a === null ? "" : `in ${a.toFixed(1)} (${n("in")} px)`, b === null ? "" : `out ${b.toFixed(1)} (${n("out")} px)`].filter(Boolean).join(", ");
  if (!parts) return;
  const bad = [];
  for (const [side, v] of [["in", a], ["out", b]]) if (v !== null && v < MIN_LIGHT) bad.push(`${side} not drawn`);
  if (a !== null && b !== null && b / a > MAX_RATIO) bad.push(`not dimmed outside (out/in ${(b / a).toFixed(2)} > ${MAX_RATIO})`);
  if (a !== null && b !== null) { cut++; console.log(`rim: ${p.id8} cut by the rim: out/in ${(b / a).toFixed(2)}`); }
  console.log(`rim: ${p.id8} ${parts}${bad.length ? "  FAIL " + bad.join("; ") : ""}`);
  fails += bad.length;
});
if (want === "cut" && !cut) { console.log("rim: FAIL no plaque is cut by the rim, so the dimming is not measured"); fails++; }
process.exit(fails);
