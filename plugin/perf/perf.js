.pragma library
// Performance budget (task 523461dd): the frame cap, the pause rule and the CPU sum the
// ambient field and docs/perf/REPORT.md use. Plain ES5, no Qt types, so node:test loads
// it (plugin/perf/test/load.cjs) the way QML does.

// The most frames a second anything driven by an outside stream (cava) may ask for.
var FPS_CAP = 30;

// A gate that lets at most `fps` frames a second through, on the caller's clock (ms).
// A frame closer than one interval to the last accepted one is dropped, not queued, so a
// producer running faster than the cap cannot build a backlog. 1 ms of slack absorbs a
// clock that ticks in whole ms (30 fps: 33.3 ms).
function createFrameGate(fps) {
    var interval = 1000 / (fps || FPS_CAP), last = -Infinity;
    return {
        accept: function (nowMs) {
            if (nowMs - last < interval - 1) return false;
            last = nowMs;
            return true;
        },
        reset: function () { last = -Infinity; }
    };
}

// What the windows on one screen sit under. toplevels: plain objects
// { fullscreen, maximized, minimized, screens: [screen names] } (ToplevelManager, which
// Hyprland and sway both serve); tiled: how many windows the screen's active Hyprland
// workspace holds (0 elsewhere). A desktop layer is covered when a window fills the
// screen: fullscreen, maximized, or tiled on the shown workspace.
function screenState(toplevels, screenName, tiled) {
    var st = { fullscreen: false, covered: (tiled || 0) > 0 };
    for (var i = 0; i < (toplevels || []).length; i++) {
        var t = toplevels[i];
        if (t.minimized || (t.screens || []).indexOf(screenName) < 0) continue;
        if (t.fullscreen) st.fullscreen = true;
        if (t.fullscreen || t.maximized) st.covered = true;
    }
    return st;
}

// A window draws only while nothing covers its screen.
function shouldDraw(st) { return !st.covered && !st.fullscreen; }

// Percent of one core from /proc/<pid>/stat utime+stime ticks over secs.
function cpuPercent(ticks0, ticks1, clkTck, secs) { return (ticks1 - ticks0) / clkTck / secs * 100; }
