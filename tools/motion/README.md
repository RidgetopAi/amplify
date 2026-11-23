# Motion harness

One spec, one trace, one check and one mutation list, shared by builder and critic (task e0cabe57, decision 6c8e54d5). A critic who wants a new measure of correct motion adds it here, so the builder can see it and run it.

| Piece | File | What it does |
| --- | --- | --- |
| Trace | `plugin/motion/Trace.qml` (symlinked into `plugin/river`, `plugin/orbs`, `plugin/basin`) | With `AMPLIFY_TRACE=1`, every moving item logs its drawn axes once per animation tick: `amplify: trace <comp> <part> <ident> <axis> <value> <ms> <n>`. `<axis>:to` is the value its record asks for and `<axis>:rate` the rate a clock or spin should turn at. Off, the hosts' `Loader`s are inactive and nothing is created. |
| Spec | `docs/motion.json` | One row per animation inventory row of river, orbs, basin and the service orbs: what moves, record, trigger, start/end, stop condition, the code that declares it (`code`: file + a substring of each declaring line, `^` for a line start, `count`) and, per traced part, each axis's check. |
| Spec check | `tools/motion/spec.mjs` | Fails when a `Behavior on`, `*Animation`, `Timer`, `Transition`, rotation binding or `Rotation` in `plugin/**/*.qml` is claimed by no row (or by two), when an anchor matches the wrong number of lines, or when a spec part has no `Trace` hook (or a hook no part). |
| Follow check | `tools/motion/follow.mjs <scenario> <log>` | Checks every traced axis of a run against its spec row. Movers come from the data (`:to` changes, `:rate` non-zero, effects that exist), never from hand-named keys. |
| Pixels | `tools/motion/frames.mjs` | Frame-sequence checks that need the picture: still, region, eddy, flow, gold. |
| Mutations | `tools/motion/mutations.json`, `tools/mutate.sh` | The catalogue and its runner. |
| Tests | `tools/motion/test/` | The check catches each wrong path it exists to catch; the spec matches the code; every mutation still applies. |

## Check kinds (spec `axes`)

- `spring`, `tween`: for each target change a → b, the drawn value starts at a, first moves toward b, has `minBetween` samples strictly between (clear of both ends by `clear` px or `clearFrac` of the way), no step over `maxStep` of the way, overshoots by at most `overshoot` of the way (a tween: none, and monotone), reaches b and is there by `settle` s. Before any change it holds at its target. `min` is the mover threshold; smaller changes only have to arrive. `enter`: a new item comes in from this value. `retarget`: the record may move on before the tween ends (orbs' 1 s data tick).
- `rides`: within `tol` of a partner (`with`, `axis`) sample for sample, and ends on it (tether ends and knots on their hull).
- `sweep`: once from `from` to `to`, monotone, `minBetween` samples between, no step over `maxStep` (PASS ring, REJECT rings).
- `spin`, `clock`: turns at `:rate` (within `rateTol`) over each run of 1 s or more; holds while the rate is 0.
- `pulse`: moves between `lo` and `hi` while `:on` is 1, holds while 0 (basin halo).
- `step`: drawn at its target at every sample (no animation by design).
- `none`: not checked; `why` says why.

Scenarios (`scenarios` in the spec) name the runs, set `still: true` for `AMPLIFY_STILL=1` (nothing may change between data steps) and set `want` floors on the number of movers per axis, so a check cannot pass with nothing moving. They run inside the existing gates: river `shot.sh` (river-settle, river-fx, river-eddy, river-still) and orbs `shot.sh motion` (service, service-still, orbs-decay).

## Mutation catalogue

```sh
tools/mutate.sh                 # control, then all mutations
tools/mutate.sh K1-lease-tween-removed X1-tether-voff-behavior-removed
tools/mutate.sh --list
```

Each mutation edits a scratch copy of the working tree (`from` → `to`, exactly once, or `deleteRow` for a spec row) and runs the gates it lists. RED means a gate caught it, GREEN means it survives, STALE means the catalogue no longer matches the code. The builder runs the whole catalogue before handoff and puts the table in the run report; the critic runs the same command and adds any surviving mutation it finds.

## Verdict tiers (proposal)

- **PASS**: gates green, catalogue all RED, control GREEN, no new survivor.
- **PASS-with-gaps**: as PASS, but the critic found a mutation that survives and the code it mutates is right. The critic adds it to `mutations.json` in a follow-up punch (with the gate change that makes it RED); the punch under review is not failed for it.
- **FAIL**: a code defect (the product does something the spec or a decision rules out), a regression, or a red gate. A survivor counts only when it shows such a defect.
