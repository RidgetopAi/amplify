.pragma library
// Puck (task 23a62966): Amp's mascot on the desktop. A cel die-cut sticker at desktop
// size, the raymarched figurine in focus (orb-lab 01e8ede7). Puck reads the same scene as
// the orbs (viewer contract 22d73eeb) and never writes: a click runs Amp's own
// `amp-desktop --puck`. Pure mapping only; Puck.qml draws it.

// What a click runs (the orb-lab feasibility note: Process ["amp-desktop", "--puck"]).
var COMMAND = ["amp-desktop", "--puck"];
function command() { return COMMAND.slice(); }

// Expression. The mouth bend is the parabola the shaders draw, y = bend * x^2: above 0
// the corners turn up. Curious by default (a small, short upturn under raised brows; the
// orb-lab Puck rested at -1.6, a frown, coordinator review 8593dade); a wider smile while
// the pointer is on Puck. Never below 0.
var MOUTH_REST = 0.7;
var MOUTH_HOVER = 1.9;
var MOUTH_REST_HALF = 0.15;   // half width of the mouth, ball units (hover: 0.24)
var MOUTH_HOVER_HALF = 0.24;
var BROW = 1;                 // brows raised: the curious look
function mouth(hovered) { return hovered ? MOUTH_HOVER : MOUTH_REST; }
function mouthHalf(hovered) { return hovered ? MOUTH_HOVER_HALF : MOUTH_REST_HALF; }

// The raised finger (Puck's signature pose): fully up while something needs you
// (scene.needsYou: tasks blocked on a human, open decisions, lost sessions) or while the
// pointer is on Puck; otherwise half raised.
var RAISE_REST = 0.55;
var RAISE_UP = 1;
function needs(scene) { return scene && scene.needsYou ? scene.needsYou.length : 0; }
function raise(scene, hovered) { return hovered || needs(scene) > 0 ? RAISE_UP : RAISE_REST; }

// Blink: once each time the scene's newest activity (Mandrel.lastActivityMs: a session
// write, a task update or a new record) moves later than the one Puck has seen. The
// first scene is the baseline, so a held replay never blinks.
function blinks(seenMs, newMs) { return seenMs !== null && newMs !== null && newMs > seenMs; }

// Glance: the eyes (cel: the face decal) turn toward the pointer while it is on Puck,
// (dx, dy) from Puck's centre in pixels, y down; reach is the distance in pixels that
// turns them fully. Off Puck they face the viewer.
function clamp(v, a, b) { return Math.max(a, Math.min(b, v)); }
function look(dx, dy, reach) {
    var r = Math.max(reach, 1);
    return { x: clamp(dx / r, -1, 1), y: clamp(-dy / r, -1, 1) };
}
var REST_LOOK = { x: 0, y: 0 };

// Desktop size and place: bottom left, above the orbs' caption, clear of the orbs' bands
// (orbs.js layout), the basin (lower right) and the empty-desktop click spot
// (tools/headless-shot.sh: bottom centre). Square item; the sticker's ball is 1/5.2 of it.
function deskSize(w, h) { return Math.round(210 * Math.min(w / 1920, h / 1080)); }
var DESK_LEFT = 36;
var DESK_BOTTOM = 40;
