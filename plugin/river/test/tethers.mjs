// Checks the tethers a still-mode river drew (plugin/river/test/shot.sh).
//
//   node tethers.mjs <frames fixture> <scene ISO time> <quickshell log>
//
// River.qml logs 'amplify: river tether <id8> lit=<f> tone=<#rgb> holder=<liveness>'
// for each tether it draws. Expected values come from the fixture alone, not
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
for (const m of fs.readFileSync(log, "utf8").matchAll(/amplify: river tether (\w+) lit=([\d.]+) tone=(#\w+) holder=(\w+)/g))
    got[m[1]] = { lit: Number(m[2]), tone: m[3], holder: m[4] };

const bad = [];
for (const [id, f] of Object.entries(want)) {
    const g = got[id];
    if (!g) { bad.push(`${id}: not drawn`); continue; }
    if (Math.abs(g.lit - f) > 6e-4) bad.push(`${id}: lit ${g.lit}, lease ${f.toFixed(4)}`);
    const [holder, tone] = f === 0 ? [null, SLACK] : tones[id] || [null, LIVE];
    if (holder && g.holder !== holder) bad.push(`${id}: holder ${g.holder}, want ${holder}`);
    if (g.tone !== tone) bad.push(`${id}: tone ${g.tone}, want ${tone}`);
    if (g.tone === WARM) bad.push(`${id}: warm needs-you hue on a tether`);
}
for (const id of Object.keys(got)) if (!(id in want)) bad.push(`${id}: drawn without a claim`);
console.log(bad.length ? bad.join("; ") : Object.entries(got).map(([id, g]) => `${id}=${g.lit}`).join(" "));
process.exit(bad.length ? 1 : 0);
