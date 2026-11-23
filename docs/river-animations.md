# Current river: animation inventory

Every moving thing under `plugin/river/` and `shaders/river*`, with the Mandrel record that drives it and when it stops. Brian's rule: nothing moves without a record. `AMPLIFY_STILL=1` (`River.animate = false`) disables every row below except the replay clock, which then only steps when `AMPLIFY_RIVER_AT` is unset. The list is complete against:

```sh
rg -n "Animation|Behavior|Timer|callLater|rotation|uniform|phase" plugin/river/*.qml plugin/river/river.js shaders/river.frag
```

(`plugin/river/mandrel.js` is a symlink to `data/mandrel.js`; its `timers.setTimeout` calls are the live SSE debounce and watchdog, which draw nothing.)

| # | file:line | What moves | Record that drives it | When it stops | Pivot | Gate |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `plugin/river/River.qml:128` `FrameAnimation` → `phase` → `shaders/river.frag:14` `phase` uniform | Water streaks advected downstream | Tasks whose `updated_at` falls in the 15 min before the scene clock (`layout().flow`, `flowSpeed` = 90 × flow) | `speed == 0` (no task touched in 15 min), `!animate`, or `!visible`: the frame clock stops and the shader is not re-rendered | n/a (texture offset) | shot.sh `idle` (4 frames identical and Quickshell CPU under 2 % at flow 0), `settle`, `flowing` (control), `still`; node `water speed is zero` |
| 2 | `River.qml:164` `Behavior on x` (`SpringAnimation`) | Lane gates slide when lanes widen or narrow | Task count per lane (`stage`/`status` via lane mapping c1f75776) | Spring settles (`epsilon 0.2`) after each scene change | n/a (translation) | shot.sh `fx` (off-water settle 5 → 6 s), `still` |
| 3 | `River.qml:196` `Behavior on vx` (`SpringAnimation`), tether | Tether's hull end follows its vessel | Task lane change between two scenes | Spring settles | n/a | shot.sh `fx` (off-water settle 5 → 6 s), `still` |
| 4 | `River.qml:198` `Behavior on f` (`NumberAnimation`, `stepMs`) | Lit length of a tether shrinks | Task `claim_expires_at` and `claim_live` against the scene clock (`lease()`) | Ends after one step (`stepMs`); with a frozen clock the value does not change, so nothing runs | n/a | node `tether shows the remaining lease`, `expired claim draws a slack tether`; shot.sh busy `tethers` (drawn lit fraction = the fixture's lease), `idle`, `fx` settle |
| 5 | `River.qml:279` `Behavior on vx` (`SpringAnimation`), vessel | Vessel sails to its new lane (hull `y` follows `vx` along the river curve) | Task lane change between two scenes | Spring settles | n/a | node lane tests; shot.sh `settle` (vessels sail ready → claimed at flow 0, then 3 frames identical and CPU idle), `still` |
| 6 | `River.qml:311` `RotationAnimation on rotation` (9 s, `Animation.Infinite`) | Blocked swirl turns in place around its hull | Task `status: blocked` (`scene.tasks[].eddy`, lane mapping c1f75776) | When the task is no longer blocked (`model.eddy` false), `!animate`, or `!visible`. It loops for as long as the record says blocked | `transformOrigin: Item.TopLeft` (L309): the arcs are centred on the Shape's (0, 0), which sits on the hull centre | shot.sh `eddy` (swirl on 85ff482a's own hull in 6/6 frame pairs; one eddy logged); busy `swirl` (only 85ff482a shows one); `idle` (none); `still` |
| 7 | `River.qml:351` `NumberAnimation on p` (3.2 s, once) | Critic PASS gold ring / REJECT eddy and upstream arc fade out | One lane change event between two scenes: `verifying` → later lane (PASS), `verifying`/`evidence` → earlier lane (REJECT) (`transitions()`) | `onFinished` (L355) → `dropFx` removes the effect and logs `fx done`. Still mode: effects show at `p = 0.5` and are dropped (also logging `fx done`) at the next scene step (L84) | n/a | shot.sh `fx` (both regions static by 5 s; both `fx done` lines), `replay` (still mode with the clock running: fx 2 for one step, then 0); node transitions table |
| 8 | `River.qml:413` `rotation: -fxi.p * 140` (REJECT rings) | REJECT eddy turns while it fades | Same event as row 7 (bound to `p`) | With row 7 | Zero-size Item at the landing point, so the default origin is (0, 0), the landing point | shot.sh `fx`; busy `rings` (still mode: the turned rings are centred on the landing point) |
| 9 | `plugin/river/RiverFeed.qml:67` `Timer` (1 s) | The replay clock: each tick builds the next scene from the fixture (60 virtual s per tick) and loops | The fixture's real records (`fixtures/amplify-snapshot.json`, or `AMPLIFY_RIVER_FIXTURE`) through `data/mandrel.js` `buildScene` | `AMPLIFY_RIVER_AT` freezes it (does not run); live mode will replace it with refetches | n/a | shot.sh frozen runs (`still` sees any step); `replay` runs it; data `replay driver` tests |

No other `Animation`, `Behavior`, `FrameAnimation`, `Timer`, or shader time uniform exists in these files. `light` and `flow` in `river.frag` are per-scene values, not clocks.

## Audit for the attempt-2 bug class (wrong pivot, never ends, moves without a record)

- **Wrong pivot.** Row 6 was the bug (E1): fixed with `transformOrigin: Item.TopLeft`. Row 8 rotates a zero-size Item, so it already turned about its landing point. The design canvas scales about `Item.TopLeft` (L136). No other rotation or scale exists.
- **Never ends.** Two more cases besides E2, both fixed:
  - Two effects finishing in the same frame: `Qt.callLater(river.dropFx, uid)` merges repeated calls to the same function, so only the last effect was dropped and the other stayed in the model forever (seen in the PASS + REJECT busy fixture: only `fx done pass` was logged). Each effect now passes its own closure.
  - Still mode never ran the effect animation, so effects were never dropped and piled up step after step while the replay clock ran. They are now dropped at each scene step (shot.sh `replay`).
  - The swirl kept animating while the river was hidden. It now also stops on `!visible`, like the water clock.
- **Moves without a record.** None found. Every row above is bound to a scene value from a record. The idle gate shows that a scene with no recent updates, no blocked task and no verdict produces identical frames.
