// Checks the tethers a still-mode river drew (plugin/river/test/shot.sh).
//
//   node tethers.mjs <frames fixture> <scene ISO time> <quickshell log>
//
// River.qml logs 'amplify: river tether <id8> lit=<f> tone=<#rgb> holder=<liveness> path=<12 numbers>'
// for each tether it draws; path is what the two ShapePaths draw: the lit
// stroke's start, control and end, then the spent stroke's start, control and
// end (design px). The lit stroke must end at the point the lease fraction f
// splits the whole tether at (de Casteljau: (1 - f) * lit control + f * spent
// control), where the spent stroke starts, so the lit length on screen tracks
// the lease and not only the logged f. Expected values come from the fixture alone, not
// from river.js: the lit fraction is the lease left (claim_expires_at - now)
// over Mandrel's 2700 s lease, 0 once lapsed or not live; the tone is the lost
// muted red, the quiet dim tone, the slack grey or the live periwinkle
// (decision 23973614, viewer contract 22d73eeb). Exit 1 on any difference.
import fs from "node:fs";

const [fixture, iso, log] = process.argv.slice(2);
const now = Date.parse(iso);
const frame = JSON.parse(fs.readFileSync(fixture, "utf8")).frames.filter((f) => Date.parse(f.at) <= now).pop();
const want = {};
for (const t of frame.responses["/api/tasks"]) {
    if (!t.claim_actor) continue;
    const left = (Date.parse(t.claim_expires_at) - now) / 1000;
    want[t.id.slice(0, 8)] = t.claim_live && left > 0 ? Math.min(1, left / 2700) : 0;
}
// Holders the busy fixture stages as not live; every other leased tether is live.
const tones = { e3f2e1a4: ["lost", "#e0786a"], a40d7440: ["quiet", "#8f9bd6"] };
const SLACK = "#7d8799", LIVE = "#b4c0ff", WARM = "#ff9e74";

const got = {};
for (const m of fs.readFileSync(log, "utf8").matchAll(/amplify: river tether (\w+) lit=([\d.]+) tone=(#\w+) holder=(\w+) path=([-\d.,]+)/g))
    got[m[1]] = { lit: Number(m[2]), tone: m[3], holder: m[4], path: m[5].split(",").map(Number) };

const bad = [];
for (const [id, f] of Object.entries(want)) {
    const g = got[id];
    if (!g) { bad.push(`${id}: not drawn`); continue; }
    if (Math.abs(g.lit - f) > 6e-4) bad.push(`${id}: lit ${g.lit}, lease ${f.toFixed(4)}`);
    const [holder, tone] = f === 0 ? [null, SLACK] : tones[id] || [null, LIVE];
    if (holder && g.holder !== holder) bad.push(`${id}: holder ${g.holder}, want ${holder}`);
    if (g.tone !== tone) bad.push(`${id}: tone ${g.tone}, want ${tone}`);
    if (g.tone === WARM) bad.push(`${id}: warm needs-you hue on a tether`);
    const [p0x, p0y, clx, cly, qx, qy, sx, sy, csx, csy, p2x, p2y] = g.path;
    const ex = (1 - f) * clx + f * csx, ey = (1 - f) * cly + f * csy;
    if (Math.hypot(qx - ex, qy - ey) > 0.5) bad.push(`${id}: lit stroke ends at ${qx},${qy}, lease ${f.toFixed(4)} splits the tether at ${ex.toFixed(2)},${ey.toFixed(2)}`);
    if (Math.hypot(sx - qx, sy - qy) > 0.5) bad.push(`${id}: spent stroke starts at ${sx},${sy}, not where the lit one ends`);
    if (f >= 0.05) {   // the whole tether's control point, recovered from the lit half, must give the spent control too
        const p1x = (clx - (1 - f) * p0x) / f, p1y = (cly - (1 - f) * p0y) / f;
        const kx = (1 - f) * p1x + f * p2x, ky = (1 - f) * p1y + f * p2y;
        if (Math.hypot(csx - kx, csy - ky) > 0.5 / f) bad.push(`${id}: spent control ${csx},${csy}, lease ${f.toFixed(4)} gives ${kx.toFixed(2)},${ky.toFixed(2)}`);
    }
    if (Math.hypot(qx - p0x, qy - p0y) < 1 && f > 0.05) bad.push(`${id}: lit stroke has no length at lease ${f.toFixed(4)}`);
}
for (const id of Object.keys(got)) if (!(id in want)) bad.push(`${id}: drawn without a claim`);
console.log(bad.length ? bad.join("; ") : Object.entries(got).map(([id, g]) => `${id}=${g.lit}`).join(" "));
process.exit(bad.length ? 1 : 0);
