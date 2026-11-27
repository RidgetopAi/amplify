# Performance budget: ambient music field (task 523461dd)

Budget: Brian's desktop idles at or below **2 % of one core** for Quickshell with Amplify.
The ambient field must cost nothing at idle, cap music at 30 fps, and pause on a covered
or fullscreen screen.

## What the ambient field does

- One `amplify-ambient` window per screen, on `WlrLayer.Bottom`, made before the other
  layers so it sits below them. It covers only the bottom 26 % of the screen, takes no
  input (empty mask) and has no shader. It has no Animation, Behavior or per-frame timer;
  the only Timer is the `AMPLIFY_FPS=1` logger (docs/motion.json `ambient-host`).
- Its height is a Mandrel field: `scene.counts.liveness` live + forming + quiet sessions,
  full at 6 (`plugin/ambient/ambient.js` `fieldBase`), from the one scene clock. With the
  data unchanged it draws nothing (replay holds at the capture).
- Music only modulates it. cava runs only while an MPRIS player reports Playing **and** at
  least one screen is uncovered (`cavaShouldRun`). Its bands scale each band of the field
  between 0.6× and 1.4×, so no active session means no light, whatever plays.
- 30 fps cap: `plugin/ambient/cava.conf` asks cava for 30 frames a second, and
  `plugin/perf/perf.js` `createFrameGate(FPS_CAP = 30)` drops any frame closer than one
  interval to the last, so a faster producer cannot raise the redraw rate.
- Pause: a screen with a fullscreen or maximized window on it (ToplevelManager, which sway
  and Hyprland serve), or with any window on its shown Hyprland workspace (tiled windows),
  holds its resting field and ignores music frames. When every screen is covered, cava is
  stopped.

## Measurements

Headless, in an Amp orb (no GPU): sway headless + pixman, Mesa 26.3.1 llvmpipe, Quickshell
0.3.2, 2 vCPUs. CPU is Quickshell's utime + stime from `/proc/<pid>/stat` over 10 s after a
6–8 s settle, as a percent of one core (the same method as tools/headless-shot.sh). MPRIS
and cava are stubs (`AMPLIFY_MPRIS_FIXTURE`, `AMPLIFY_CAVA_BIN=plugin/ambient/test/cava-stub.sh`,
which prints 120 frames a second, four times the cap). Two 1280×720 screens unless noted.

| Run | Scene | Quickshell CPU | ambient fps per screen |
| --- | --- | --- | --- |
| idle, origin/main 1039f3f9 (no ambient) | held 02:11Z: 1 live orb, river flow 0 | 2 % | – |
| idle, this branch, Paused | same | 2 % | 0.0 / 0.0 |
| playing, this branch, full-screen windows (first draft) | same | 27 % | 25.4 / 25.4 |
| **playing, this branch (shipped: bottom 26 % windows)** | same | **14.1 %** | **25.4 / 25.4** |
| idle, this branch, Paused (shot.sh check 5) | held 04:38:18Z (headless-shot idle scene) | **0.1–0.2 %** (three runs) | 0.0 / 0.0 |
| paused vs playing vs one screen fullscreen (shot.sh 1–3) | capture 04:00:17Z | see note | 0 / 0 · 24–25 / 24–25 · **0** / 24–25 |
| tools/headless-shot.sh idle check, three outputs (one 2560×1440) | held 04:38:18Z | **0.7 %** (PASS, budget 2 %) | 0.0 on all three, in all three of its runs |

Note on the capture moment: at 04:00:17Z the river's water is flowing (river-1
FrameAnimation, flow > 0), and its window draws about 55 fps on every screen in this orb.
That puts Quickshell at about 450 % of a core on llvmpipe both on origin/main (452 %) and
on this branch (423 % with the ambient paused, 458 % playing). That cost is the river's,
not the ambient's, and is outside this punch (plugin/river is in review under aa5e593d).

## Reading

- **Idle budget met.** With nothing playing, the ambient layer adds no frames and no
  measurable CPU: 0.1–0.2 % on the two-screen idle scene and 0.7 % on headless-shot's three-screen one, the same 2 % as main on the 02:11Z scene.
- **Music is capped.** A 120 fps stream draws 24–25 fps per screen (vsync-paced under the
  30 fps cap); without the gate (mutation A3) it would follow the stream.
- **Covered screens cost nothing.** Under a fullscreen window the screen's ambient window
  draws 0 fps and its field holds (0 changes/s) while the uncovered screen keeps the music.
  Sway itself sends a surface under a fullscreen window no frames, so swapped frames alone
  cannot show the pause: a field that kept following the music there (mutation A2) also
  swapped 0 frames and survived the first gate. The `AMPLIFY_FPS=1` line now also logs how
  often each window's field changed (`changes=`), and the gate requires 0 there. Hyprland
  keeps drawing a Bottom layer under tiled windows (milestone 7c3411ec: covered screens drew
  at the same rate), which is what the pause guards.
- **Playing has a cost on software rendering.** About 12 points of one core for two screens
  on llvmpipe, half what full-screen windows cost. On Brian's GPU desktop this should be
  far lower; it is not measured there yet.

## Not measured here

- Brian's desktop (three monitors, GPU, Hyprland, real cava with PipeWire, real MPRIS).
  The Hyprland tiled-window cover and the real cava/MPRIS paths are not exercised in the
  orb; only stubs are.
- Reproduce: `HEADLESS_MESA=$(nix build --no-link --print-out-paths nixpkgs#mesa) plugin/ambient/test/shot.sh`
  (prints every number above for its scenes); on the desktop, `AMPLIFY_FPS=1` and
  `top -b -n 6 -d 10 -p $(pgrep -f omarchy-shell)` with music paused, playing, and a
  fullscreen window.
