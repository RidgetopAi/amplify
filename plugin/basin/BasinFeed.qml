import Quickshell
import Quickshell.Io
import QtQuick
// amp.js and mandrel.js are copies of data/ (tools/sync-shared.sh): Quickshell refuses
// imports from outside the config directory (they resolve to qrc:/qs-blackhole).
import "amp.js" as Amp
import "mandrel.js" as Mandrel
import "basin.js" as Basin

// One feed per shell (mount at the plugin root, not per screen): Amp live
// thread state from `amp top --stream-jsonl`, falling back to polling
// `amp threads list --json` while the stream is down, plus the Mandrel scene of
// the scene clock (SceneClock.qml, task 679fbbc5) the orbs and river read, at its moment.
QtObject {
  id: feed

  required property var sceneClock
  readonly property var activeScene: sceneClock.scene
  // The one caption (Mandrel.sceneCaption) for the moment the basin shows.
  readonly property string caption: activeScene ? Mandrel.sceneCaption(activeScene, now) : ""
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
  property var _reader: Amp.createTopReader(function (s) { feed.amp = s; feed.ampSource = "top"; feed.rebuild() })
  property int _topFailures: 0

  function clock() { return pinnedNow ? (Number(pinnedNow) || Date.parse(pinnedNow)) : Date.now() }

  // Mandrel rows at the scene clock's moment; Amp thread waits on the wall clock (or AMPLIFY_NOW).
  function rebuild() {
    var sc = activeScene
    now = sc ? sceneClock.nowMs : clock()
    if (sc) Mandrel.tickScene(sc, now)
    rows = Basin.buildBasin(sc, amp, { now: now, threadNow: clock() })
  }
  onActiveSceneChanged: {
    if (activeScene && activeScene.meta.mode === "replay")
      console.log("amplify: replay basin " + Mandrel.replaySource(sceneClock.snapshot))
    rebuild()
  }
  property Connections _clock: Connections { target: feed.sceneClock; function onNowMsChanged() { feed.rebuild() } }

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

    // Amp thread waiting times move without a refetch.
    Timer { interval: 15000; repeat: true; running: !feed.pinnedNow; onTriggered: feed.rebuild() }
  ]

  onRowsChanged: console.log("amplify: basin rows=" + rows.length + " source=" + ampSource
    + (rows.length ? " first=" + rows[0].kind + ":" + rows[0].url : ""))
}
