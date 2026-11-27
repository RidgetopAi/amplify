.pragma library
// The ambient music field (task 523461dd). Its height is a Mandrel field: how many sessions
// the scene shows active (scene.counts.liveness live + forming + quiet, viewer contract
// 22d73eeb). Music never adds to it: while an MPRIS player reports Playing, cava's bands
// only scale that height up and down, so a desktop with no active session stays dark
// whatever plays, and with nothing playing the field holds still (0 fps once drawn).
// Plain ES5, loaded by QML and by node:test (plugin/ambient/test/load.cjs).

var BARS = 16;            // cava bars = field bands (plugin/ambient/cava.conf)
var MAX_RANGE = 1000;     // cava ascii_max_range
var FULL_SESSIONS = 6;    // active sessions at which the field is at full height
var MOD = 0.8;            // a band at 0 draws (1 - MOD/2) of the field, at 1 (1 + MOD/2)

// One cava raw ascii frame ("12;0;999;...;" + newline) as BARS values in 0..1, or null
// when it is not a whole frame of numbers.
function parseFrame(line, bars, maxRange) {
    bars = bars || BARS; maxRange = maxRange || MAX_RANGE;
    var parts = String(line).replace(/[;\s]+$/, "").split(";");
    if (parts.length !== bars) return null;
    var out = [];
    for (var i = 0; i < parts.length; i++) {
        if (!/^\s*\d+\s*$/.test(parts[i])) return null;
        out.push(Math.min(1, Number(parts[i]) / maxRange));
    }
    return out;
}

// MPRIS playback states ("Playing", "Paused", "Stopped"), one per player: is any playing?
function isPlaying(states) {
    for (var i = 0; i < (states || []).length; i++) if (states[i] === "Playing") return true;
    return false;
}

// cava runs only while something plays and at least one screen draws the field.
function cavaShouldRun(o) { return !!(o && o.playing && o.drawing > 0); }

// The named Mandrel field the ambient height follows.
function fieldBase(scene) {
    var c = scene && scene.counts && scene.counts.liveness;
    var active = c ? (c.live || 0) + (c.forming || 0) + (c.quiet || 0) : 0;
    return { field: "scene.counts.liveness", active: active, level: Math.min(1, active / FULL_SESSIONS) };
}

// The resting shape: a low hill, highest mid-screen.
function envelope(i, n) { return 0.55 + 0.45 * Math.sin(Math.PI * (i + 0.5) / n); }

// Each band's drawn height (fraction of the field's full height): base x envelope, scaled
// by the music band when there is one (null: no music, or this screen paused).
function fieldLevels(base, bands, n) {
    n = n || BARS;
    var out = [];
    for (var i = 0; i < n; i++) {
        var m = bands ? 1 + MOD * ((bands[i] || 0) - 0.5) : 1;
        out.push(base * envelope(i, n) * m);
    }
    return out;
}
