import Quickshell
import Quickshell.Io
import QtQuick
// amp.js and mandrel.js are symlinks to data/: Quickshell refuses imports from
// outside the config directory (they resolve to qrc:/qs-blackhole).
import "amp.js" as Amp
import "mandrel.js" as Mandrel
import "basin.js" as Basin

// One feed per shell (mount at the plugin root, not per screen): Amp live
// thread state from `amp top --stream-jsonl`, falling back to polling
// `amp threads list --json` while the stream is down, plus the Mandrel scene.
// Pass `scene` to share another component's scene; otherwise this feed builds
// its own (live with MANDREL_URL + MANDREL_VIEWER_TOKEN, else the replayed
// snapshot).
QtObject {
  id: feed

  property var scene: null
  readonly property var activeScene: scene || ownScene
  property var ownScene: null
  property var amp: null
  property string ampSource: "none"     // top | list | fixture | none
  property var rows: []
  property real now: Date.now()

  // env-read: AMPLIFY_AMP_BIN overrides the amp binary (default: amp on PATH).
  readonly property string ampBin: Quickshell.env("AMPLIFY_AMP_BIN") || "amp"
  // env-read: AMPLIFY_AMP_FIXTURE replays a captured amp top JSONL file instead of running amp (tests, demo).
  readonly property string ampFixture: Quickshell.env("AMPLIFY_AMP_FIXTURE") || ""
  // env-read: AMPLIFY_NOW pins the clock (ISO or ms) for deterministic captures.
  readonly property string pinnedNow: Quickshell.env("AMPLIFY_NOW") || ""
  // env-read: MANDREL_URL, MANDREL_VIEWER_TOKEN (see data/README.md).
  readonly property var config: Mandrel.resolveConfig({
    MANDREL_URL: Quickshell.env("MANDREL_URL") || "",
    MANDREL_VIEWER_TOKEN: Quickshell.env("MANDREL_VIEWER_TOKEN") || ""
  })

  property var _reader: Amp.createTopReader(function (s) { feed.amp = s; feed.ampSource = "top"; feed.rebuild() })
  property int _topFailures: 0

  function clock() { return pinnedNow ? (Number(pinnedNow) || Date.parse(pinnedNow)) : Date.now() }

  function rebuild() {
    var sc = activeScene
    // A replayed snapshot keeps its own clock, so its sessions do not decay to lost.
    var replay = sc && sc.meta && sc.meta.mode === "replay"
    now = replay ? Date.parse(sc.meta.builtAt) : clock()
    if (sc && !scene && !replay) Mandrel.tickScene(sc, now)
    rows = Basin.buildBasin(sc, amp, { now: now, threadNow: clock() })
  }
  onActiveSceneChanged: rebuild()

  property list<QtObject> _parts: [
    // Primary: the live stream. Every line is a full thread list.
    Process {
      id: top
      running: !feed.ampFixture
      command: [feed.ampBin, "top", "--stream-jsonl"]
      stdout: SplitParser { onRead: data => feed._reader.line(data) }
      onRunningChanged: if (!running) {
        // Stream ended (no amp, logged out, crash): poll the list and retry with backoff.
        feed._topFailures++
        if (feed.ampSource === "top") feed.ampSource = "none"
        listProc.running = true
        retry.interval = Math.min(60000, 2000 * Math.pow(2, Math.min(5, feed._topFailures)))
        retry.start()
      }
    },
    Timer { id: retry; repeat: false; onTriggered: if (!feed.ampFixture) top.running = true },

    // Fallback: titles and links only, no live state (rows stay "unknown").
    Process {
      id: listProc
      command: [feed.ampBin, "threads", "list", "--json", "--limit", "50"]
      stdout: StdioCollector {
        onStreamFinished: {
          if (top.running && feed.ampSource === "top") return
          var s = Amp.parseThreadsList(this.text, feed.clock())
          if (s) { feed.amp = s; feed.ampSource = "list"; feed.rebuild() }
        }
      }
    },
    Timer {
      interval: 30000; repeat: true
      running: !feed.ampFixture && !top.running
      onTriggered: listProc.running = true
    },

    // Fixture replay: the captured stream, read once.
    FileView {
      path: feed.ampFixture
      printErrors: false
      onLoaded: {
        var lines = text().split("\n")
        for (var i = 0; i < lines.length; i++) feed._reader.line(lines[i])
        feed.ampSource = "fixture"
      }
    },

    // Mandrel scene when no one shares one: live polling, else the snapshot.
    FileView {
      id: snapshotFile
      // Symlinked in: Quickshell blackholes paths outside the config directory.
      path: Qt.resolvedUrl("amplify-snapshot.json").toString().replace(/^file:\/\//, "")
      printErrors: false
      onLoaded: if (!feed.scene && feed.config.mode !== "live") {
        var snap = JSON.parse(text())
        var at = Date.parse(snap.meta.captured_at)
        feed.ownScene = Mandrel.createReplayDriver(snap, {}).sceneAt(at)
      }
    },
    Timer {
      interval: 30000; repeat: true; triggeredOnStart: true
      running: !feed.scene && feed.config.mode === "live"
      onTriggered: {
        var fetch = Mandrel.fetcherFor(feed.config, Mandrel.xhrTransport(), null)
        Mandrel.loadScene(fetch, { baseUrl: feed.config.baseUrl, mode: "live" }).then(
          function (sc) { feed.ownScene = sc },
          function (err) { console.log("amplify: basin scene fetch failed " + err) })
      }
    },

    // Waiting times and client-clock liveness move without a refetch.
    Timer { interval: 15000; repeat: true; running: !feed.pinnedNow; onTriggered: feed.rebuild() }
  ]

  onRowsChanged: console.log("amplify: basin rows=" + rows.length + " source=" + ampSource
    + (rows.length ? " first=" + rows[0].kind + ":" + rows[0].url : ""))
}
