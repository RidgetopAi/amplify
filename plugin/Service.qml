import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import "orbs"
import "river"
import "basin"

// Amplify service. Loaded two ways from the same file:
//  - inside omarchy-shell as a third-party `service` plugin (manifest.json),
//    where the host injects `shell` / `manifest` facades we do not need;
//  - standalone via `quickshell -p plugin/` (shell.qml), the fallback path.
// Only Quickshell/QtQuick imports are used (no qs.Commons), so both work.
Item {
  id: root

  // Injected by omarchy-shell when present; unused by the spike.
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  // The desktop layer. Bottom = above the wallpaper, below every window.
  readonly property int desktopLayer: WlrLayer.Bottom
  readonly property string layerName: desktopLayer === WlrLayer.Bottom ? "bottom"
    : desktopLayer === WlrLayer.Top ? "top"
    : desktopLayer === WlrLayer.Background ? "background" : "overlay"

  // env-read: AMPLIFY_THEME_DIR overrides the Omarchy current-theme dir (tests).
  readonly property string themeDir: Quickshell.env("AMPLIFY_THEME_DIR")
    || (Quickshell.env("HOME") + "/.local/state/omarchy/current/theme")
  // env-read: AMPLIFY_PROBE_URL, when set, is fetched once with XMLHttpRequest.
  readonly property string probeUrl: Quickshell.env("AMPLIFY_PROBE_URL") || ""
  // env-read: AMPLIFY_STILL=1 freezes shader time (deterministic screenshots).
  readonly property bool still: Quickshell.env("AMPLIFY_STILL") === "1"
  // env-read: AMPLIFY_FPS=1 logs frames per second per screen every 5 s.
  readonly property bool logFps: Quickshell.env("AMPLIFY_FPS") === "1"

  property color accent: "#89b4fa"
  property color foreground: "#cdd6f4"
  property color warm: "#f9e2af"

  // omarchy-shell shell call ridgetopai.amplify refreshTheme ""
  function refreshTheme(arg) {
    if (!themeProc.running) themeProc.running = true
    return "ok"
  }

  function parseColors(text) {
    var out = {}
    var re = /^\s*([a-z_]+)\s*=\s*"(#[0-9a-fA-F]{6})"/gm, m
    while ((m = re.exec(text)) !== null) out[m[1]] = m[2]
    if (out.accent) accent = out.accent
    if (out.foreground) foreground = out.foreground
    if (out.yellow) warm = out.yellow
    console.log("amplify: palette accent=" + accent + " foreground=" + foreground)
  }

  // Process: read the theme palette out of process (proves Process works
  // for a third-party plugin; data reads later go through the same path).
  Process {
    id: themeProc
    command: ["cat", root.themeDir + "/colors.toml"]
    stdout: StdioCollector { onStreamFinished: root.parseColors(this.text) }
  }

  // Re-read when Omarchy swaps the theme (omarchy-theme-set rewrites the dir).
  FileView {
    path: root.themeDir + "/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: root.refreshTheme("")
  }

  // Standalone: `quickshell ipc -p plugin/ call amplify refreshTheme ""`.
  // Inside omarchy-shell: `omarchy-shell amplify refreshTheme ""`.
  IpcHandler {
    target: "amplify"
    function refreshTheme(arg: string): string { return root.refreshTheme(arg) }
  }

  function probe() {
    if (!probeUrl) return
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState === XMLHttpRequest.DONE)
        console.log("amplify: xhr " + probeUrl + " status=" + xhr.status + " bytes=" + xhr.responseText.length)
    }
    xhr.open("GET", probeUrl)
    xhr.send()
  }

  Component.onCompleted: {
    refreshTheme("")
    probe()
  }

  OrbsLayer { accent: root.accent; foreground: root.foreground; animate: !root.still }
  BasinFeed { id: basinFeed }

  Variants {
    id: windows
    model: Quickshell.screens

    PanelWindow {
      id: win
      required property var modelData

      screen: modelData
      color: "transparent"
      anchors { top: true; bottom: true; left: true; right: true }
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "amplify"
      WlrLayershell.layer: root.desktopLayer
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      // Only the orbs' hit circles take input; everything else falls through
      // to the wallpaper layer and the desktop's own click handling.
      mask: Region {
        regions: [
          Region { item: focusOrb.hitItem },
          Region { item: sideOrb.hitItem },
          Region { item: basin.hitItem }
        ]
      }

      River { anchors.fill: parent; animate: !root.still }

      // Placeholder layout: the Meridian focus orb and one ambient orb.
      Orb {
        id: focusOrb
        name: "meridian"
        width: Math.min(win.width, win.height) * 0.42; height: width
        x: win.width * 0.28 - width / 2; y: win.height * 0.5 - height / 2
        core: root.accent; halo: root.warm; energy: 0.6
        animate: !root.still
        onClicked: name => console.log("amplify: orb click " + name + " screen=" + win.modelData.name)
      }

      Orb {
        id: sideOrb
        name: "ambient"
        width: Math.min(win.width, win.height) * 0.28; height: width
        x: win.width * 0.75 - width / 2; y: win.height * 0.5 - height / 2
        core: root.accent; halo: root.foreground; energy: 0.1
        animate: !root.still
        onClicked: name => console.log("amplify: orb click " + name + " screen=" + win.modelData.name)
      }

      Basin {
        id: basin
        feed: basinFeed
        animate: !root.still
        anchors { right: parent.right; bottom: parent.bottom; rightMargin: 28; bottomMargin: 30 }
      }

      FrameAnimation {
        id: frames
        running: root.logFps
        property int count: 0
        onTriggered: count++
      }
      Timer {
        interval: 5000; repeat: true; running: root.logFps
        onTriggered: {
          console.log("amplify: fps screen=" + win.modelData.name + " " + (frames.count / 5).toFixed(1))
          frames.count = 0
        }
      }

      Timer {
        interval: 1500; running: true
        onTriggered: console.log("amplify: ready layer=" + root.layerName
          + " screen=" + win.modelData.name + " size=" + win.width + "x" + win.height
          + " shader=" + ["uncompiled", "compiled", "error"][focusOrb.shaderStatus] + " " + focusOrb.shaderLog)
      }
    }
  }
}
