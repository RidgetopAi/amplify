# Current river

The punch lifecycle as a river (direction c755578f, lane mapping c1f75776). `Service.qml` mounts one `River` per screen under the orbs.

| Data (scene model from `data/mandrel.js`) | Drawn as |
| --- | --- |
| `task.lane` (draft → ready → claimed → verifying → evidence → merged → deployed) | Vessel in that lane; lanes widen with load; the `deployed` lane is labelled "trunk" |
| Lane change between two scenes | Vessel sails to its new lane |
| verifying → a later lane | Critic PASS: a gold ring |
| verifying or evidence → an earlier lane | REJECT: an eddy where it lands and an arc back upstream |
| `claimActor`, `claimExpiresAt` vs. the scene clock | Tether from the holder's mooring; lit length = lease left; slack and dashed once expired, even if `claimLive` is still true; toned by the holder's liveness (`tetherTone`: live, quiet/dormant dimmer, lost muted red) |
| `eddy` (blocked) / `needsYou` | Slow swirl around the hull; warm hull (the only warm colour here) |
| Tasks updated in the last 15 min / live sessions | Water flow speed (`flowSpeed`, 0 at flow 0) and wake length / water light. With no task updated in 15 min the water stands still and the frame clock stops |

`river.js` holds the layout as pure functions (`layout`, `lease`, `tetherTone`, `transitions`, `placeMoorings`, `replaySceneAt`), tested by `node --test plugin/river/test/`. `shaders/river.frag` is the water; it compiles to `plugin/shaders/river.frag.qsb`.

Quickshell resolves imports and URLs outside the config folder to `qrc:/qs-blackhole`. That is why `mandrel.js`, `amplify-snapshot.json`, and `river.frag.qsb` here are relative symlinks to `data/`, `fixtures/`, and `plugin/shaders/`.

## Replay and preview

- `quickshell -p plugin/river` shows the river alone.
- `AMPLIFY_RIVER_FIXTURE=<path>` replays another fixture. `test/busy-frames.json` comes from `node plugin/river/test/make-busy.mjs`: it is the real snapshot's records, staged with 9 claims (one expired, one held by a lost session, one by a quiet one), a blocked task, a PASS, and a REJECT.
- `AMPLIFY_RIVER_AT=<ISO>` freezes the replay clock at that time, one step after the previous scene, so that step's lane changes show.
- `AMPLIFY_STILL=1` freezes motion.
- `HEADLESS_MESA=… plugin/river/test/shot.sh` writes `docs/shots/river-{default,busy,in-service}.png` and runs 18 checks: logged lanes, tethers and verdicts; what still mode draws (only blocked hulls show a swirl; the REJECT rings turn about the landing point; each tether's lit fraction is its lease and its tone its holder's liveness); frame-sequence motion gates (still mode static, flow 0 static, the flowing control, vessels sail then settle, the blocked swirl on its own hull in 6/6 frame pairs, verdict effects static and `fx done` within 5 s, everything off the water settled by 5 s); Quickshell CPU under 2 % of a core in every idle window (decision 25eced40); a still-mode replay where a verdict shows for one step; and a runtime log with no QML errors or binding loops. Every animation is listed in `docs/river-animations.md`.
