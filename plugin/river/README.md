# Current river

The punch lifecycle as a river (direction c755578f, lane mapping c1f75776). `Service.qml` mounts one `River` per screen under the orbs.

| Data (scene model from `data/mandrel.js`) | Drawn as |
| --- | --- |
| `task.lane` (draft → ready → claimed → verifying → evidence → merged → deployed) | Vessel in that lane; lanes widen with load; the `deployed` lane is labelled "trunk" |
| Lane change between two scenes | Vessel sails to its new lane |
| verifying → a later lane | Critic PASS: a gold ring |
| verifying or evidence → an earlier lane | REJECT: an eddy where it lands and an arc back upstream |
| `claimActor`, `claimExpiresAt` vs. the scene clock | Tether from the holder's mooring; lit length = lease left; slack and dashed once expired, even if `claimLive` is still true |
| `eddy` (blocked) / `needsYou` | Slow swirl around the hull; warm hull (the only warm colour here) |
| Tasks updated in the last 15 min / live sessions | Water flow speed and wake length / water light; still water when nothing moves |

`river.js` holds the layout as pure functions (`layout`, `lease`, `transitions`, `placeMoorings`, `replaySceneAt`), tested by `node --test plugin/river/test/`. `shaders/river.frag` is the water; it compiles to `plugin/shaders/river.frag.qsb`.

Quickshell resolves imports and URLs outside the config folder to `qrc:/qs-blackhole`. That is why `mandrel.js`, `amplify-snapshot.json`, and `river.frag.qsb` here are relative symlinks to `data/`, `fixtures/`, and `plugin/shaders/`.

## Replay and preview

- `quickshell -p plugin/river` shows the river alone.
- `AMPLIFY_RIVER_FIXTURE=<path>` replays another fixture. `test/busy-frames.json` comes from `node plugin/river/test/make-busy.mjs`: it is the real snapshot's records, staged with 9 claims (one expired), a blocked task, a PASS, and a REJECT.
- `AMPLIFY_RIVER_AT=<ISO>` freezes the replay clock at that time, one step after the previous scene, so that step's lane changes show.
- `AMPLIFY_STILL=1` freezes motion.
- `HEADLESS_MESA=… plugin/river/test/shot.sh` writes `docs/shots/river-{default,busy,in-service}.png` and checks the logged lanes, tethers, and verdicts.
