# Amplify data layer

`data/mandrel.js` turns the Mandrel Command REST responses into one scene model for the Current river and the Meridian orb. It has no dependencies. QML imports it as a `.pragma library` file (`import "../data/mandrel.js" as Mandrel`). Node loads the same file through `data/node.cjs`. The library does no env reads, networking, or timers of its own: the host passes in the clock, the transport, and the timers.

## Config

The data layer reads only `MANDREL_URL` and `MANDREL_VIEWER_TOKEN` (`resolveConfig(env)`; the host reads the env, marked `// env-read:`). If either is unset, or the token starts with `mdl_` (an MCP read-write token), it falls back to replaying `fixtures/amplify-snapshot.json`. Never commit a token.

## API

- `loadScene(fetchJson, opts)` fetches `/api/sessions`, `/api/sessions/:id` for open sessions, `/api/tasks`, `/api/contexts`, `/api/decisions`, and `/api/projects`, then calls `buildScene`.
- `fetcherFor(cfg, transport, snapshot)` returns the live fetcher, or the replay fetcher when unconfigured. `xhrTransport()` is for QML; `node.fetchTransport()` is for Node.
- `buildScene(inputs, {now, baseUrl, projectId, mode, label})` returns:
  `{ meta, projects[], sessions[], orbs[], links[], tasks[], lanes{draft..deployed}, latest[], needsYou[], counts }`.
  - `sessions[]`: `id, id8, url, title, displayTitle, actor, role, orbName, threadId, threadUrl, liveness, serverLiveness, creationReason`, timestamps, `counts`, `totalTokens`, `latestActivity`, `punchActivity`, `loopActivities`.
  - `orbs[]`: sessions that have not ended: `sessionId, name, role, liveness, threadUrl, taskId, url`.
  - `links[]`: `{from, to, kind, at, taskId, resolved}`, from `outbound_link_activity` / `inbound_link_activity` `.to_session`, deduplicated.
  - `tasks[]` have `lane, eddy, needsYou, hidden`, and `lanes` groups the visible ones.
  - `needsYou[]`: tasks blocked on a human, open decisions, and lost sessions, oldest first.
- `tickScene(scene, now)` re-derives liveness on the client clock between refetches (run it once per animation tick).
- `createEventStream({config, transport, timers, onChange, debounceMs, heartbeatTimeoutMs})` runs `POST /api/events/ticket`, then `GET /api/events?ticket=`. Each entity event schedules one debounced `onChange` (refetch). Silence longer than `heartbeatTimeoutMs` drops the stream and reconnects with a fresh ticket.
- `createReplayDriver(snapshot, {timers, speed, stepMs, onScene})` plays the snapshot from `meta.replay_from` to `meta.captured_at`, then loops. Its scenes carry `meta.mode: "replay"` and a `REPLAYED SNAPSHOT` label.

## Liveness (viewer contract 22d73eeb)

| State | Rule |
| --- | --- |
| ended | `ended_at` set |
| lost | explicit heartbeat more than 600 s old |
| dormant | no heartbeat within 180 s and no write within the last 30 min |
| forming | alive, `creation_reason` is `connect`, and no writes yet |
| quiet | heartbeat within 180 s and no write for 600 s or more |
| live | otherwise alive |

Server `liveness` is the truth at fetch time. When the server value and the client-clock value disagree, the worse one wins.

## Lanes (decision c1f75776)

A task with a stage rides its stage lane. Without a stage, the status decides:

- todo goes to ready.
- in_progress goes to claimed with a live claim, otherwise to verifying.
- blocked is an eddy at ready, or at claimed if the claim is live.
- completed goes to merged.
- cancelled is hidden.

A `blocked_on: "human"` task also goes to the needs-you basin.

## Tests

`node --test data/test/` runs these files:

- `scene.test.mjs`: the scene model from the real snapshot.
- `liveness.test.mjs`: both sides of every threshold, plus the lane mapping.
- `stream.test.mjs`: the SSE flow against a local fake server, and replay.
