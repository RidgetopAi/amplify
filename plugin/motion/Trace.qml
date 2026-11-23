import QtQuick

// Motion trace for the shared harness (tools/motion, spec docs/motion.json).
// Hosts make one per moving item inside a Loader whose `active` is their
// `trace` flag (AMPLIFY_TRACE=1), so with tracing off nothing is created or
// evaluated. Each change of an axis logs one line:
//   amplify: trace <comp> <part> <ident> <axis> <value> <ms> <n>
// where n counts this trace's emits, so lines with the same n were drawn together.
// `v` maps axis names to what is drawn now (x, y, rotation, opacity, length,
// or a named value such as a shader uniform); `<axis>:to` is the value the
// record asks for, so tools/motion/follow.mjs finds the movers from the data
// and checks the path the drawn value takes. Changes are sampled once per
// animation tick (the window's afterAnimating), or at the end of the event-loop
// turn for changes outside an animation, so values that several bindings
// update in the same tick log once, after all of them.
// Symlinked into plugin/river, plugin/orbs and plugin/basin: Quickshell
// resolves types only inside the config folder.
Item {
  id: trace
  visible: false
  property string comp: ""
  property string part: ""
  property string ident: ""
  property var v: ({})
  property var last: ({})
  property int n: 0
  property bool ready: false
  property bool dirty: false

  function emit() {
    dirty = false
    if (!ready || ident === "") return
    var t = Date.now(), now = v
    n++
    for (var a in now) {
      var x = Number(now[a])
      if (isNaN(x) || last[a] === x) continue
      last[a] = x
      console.log("amplify: trace " + comp + " " + part + " " + ident + " " + a + " " + x.toFixed(6) + " " + t + " " + n)
    }
  }
  // Qt.callLater drops the call when this item is destroyed first (a removed delegate).
  function flush() { if (dirty) emit() }
  onVChanged: if (!dirty) { dirty = true; Qt.callLater(flush) }
  Connections {
    target: trace.Window.window
    function onAfterAnimating() { if (dirty) emit() }
  }
  onIdentChanged: { last = ({}); emit() }
  Component.onCompleted: { ready = true; emit() }
}
