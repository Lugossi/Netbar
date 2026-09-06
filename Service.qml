import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})
  property string pluginDir: ""

  property bool active: false

  property var ports: []
  property bool loading: false
  property bool everScanned: false
  property string lastError: ""
  property int scannedAt: 0

  property var ignored: ({})
  property bool ignoreLoaded: false
  property string actionStatus: ""

  property var termedAt: ({})
  property var termedKeys: ({})
  readonly property int termGraceMs: 2500

  property var ownsSideEffects: null

  property var docker: ({})
  property bool dockerBusy: false
  readonly property bool dockerProbed: docker && docker.probed === true
  readonly property bool dockerRunning: docker && docker.socket === true
  readonly property bool dockerReadable: docker && docker.readable === true

  readonly property bool dockerNeedsEnable: dockerProbed && dockerRunning && !dockerReadable

  readonly property string statePath: Quickshell.env("HOME")
    + "/.local/state/omarchy/netbar/ignored.json"
  readonly property string scannerPath: pluginDir + "/netbar-scan.py"

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function boolSetting(name, fallback) {
    var v = setting(name, fallback)
    if (typeof v === "boolean") return v
    var s = String(v).toLowerCase()
    return s === "true" || s === "1" || s === "yes"
  }

  readonly property int idleIntervalSec: intSetting("refreshIntervalSec", 15, 3, 600)
  readonly property bool includeUdp: boolSetting("includeUdp", false)
  readonly property bool notifyOnNew: boolSetting("notifyOnNew", false)

  property bool showSystem: boolSetting("showSystem", false)

  function isIgnored(entry) { return ignored[Model.ignoreKey(entry)] === true }

  readonly property var listed: {
    var out = []
    for (var i = 0; i < ports.length; i++) {
      var e = ports[i]
      if (e.isDev || showSystem) out.push(e)
    }
    return out
  }

  readonly property var strays: {
    var out = []
    for (var i = 0; i < ports.length; i++) {
      if (ports[i].isDev && !isIgnored(ports[i])) out.push(ports[i])
    }
    return out
  }

  readonly property int strayCount: strays.length
  readonly property int ignoredCount: {
    var n = 0
    for (var i = 0; i < ports.length; i++) if (ports[i].isDev && isIgnored(ports[i])) n++
    return n
  }

  readonly property int exposedStrayCount: {
    var n = 0
    for (var i = 0; i < strays.length; i++) if (Model.isExposed(strays[i])) n++
    return n
  }

  function refresh() {
    if (scanProc.running || scannerPath === "/netbar-scan.py") return
    loading = true
    var argv = ["/usr/bin/python3", scannerPath, "scan"]
    if (includeUdp) argv.push("--udp")

    if (active) argv.push("--docker")
    scanProc.command = argv
    scanProc.running = true
  }

  property var _seenKeys: ({})

  signal portsUpdated(var payload)

  function applyScan(raw) {
    loading = false
    var parsed
    try {
      parsed = JSON.parse(String(raw || ""))
    } catch (e) {
      lastError = "Could not read scanner output"
      return
    }
    if (!parsed || parsed.ok !== true) {
      lastError = String((parsed && parsed.error) || "Scan failed")
      return
    }
    var owner = !ownsSideEffects || ownsSideEffects()
    applyParsed(parsed, owner)
    if (owner) portsUpdated(parsed)
  }

  function adoptScan(parsed) {
    if (!parsed || parsed.ok !== true) return
    loading = false
    applyParsed(parsed, false)
  }

  function applyParsed(parsed, allowNotify) {
    lastError = ""
    scannedAt = Number(parsed.scannedAt || 0)
    docker = parsed.docker || ({})

    var incoming = parsed.ports || []
    if (notifyOnNew && everScanned && allowNotify) notifyNewListeners(incoming)

    var seen = {}
    for (var i = 0; i < incoming.length; i++) seen[incoming[i].key] = true
    _seenKeys = seen

    var now = Date.now()
    var stillTermed = {}
    var offered = {}
    for (var j = 0; j < incoming.length; j++) {
      var k = incoming[j].key
      var at = termedAt[k]
      if (at === undefined) continue
      stillTermed[k] = at
      if (!incoming[j].container && (now - at) > termGraceMs) offered[k] = true
    }
    termedAt = stillTermed
    termedKeys = offered

    ports = incoming
    everScanned = true
  }

  function notifyNewListeners(incoming) {
    for (var i = 0; i < incoming.length; i++) {
      var e = incoming[i]
      if (!e.isDev || _seenKeys[e.key]) continue
      if (isIgnored(e)) continue
      var body = Model.plainText(Model.displayName(e))
        + (e.project ? " in " + Model.plainText(e.project) : "")
        + (Model.isExposed(e) ? "  ·  " + Model.exposureLabel(e.exposure) : "")
      Quickshell.execDetached([
        "omarchy-notification-send",
        "-u", Model.isExposed(e) ? "normal" : "low",
        "Port " + e.port + " is listening", body
      ])
    }
  }

  Process {
    id: scanProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyScan(text)
    }
    onExited: function(exitCode) {
      root.loading = false

      if (exitCode !== 0 && root.lastError === "") root.lastError = "Scanner exited " + exitCode
    }
  }

  Timer {
    interval: root.active ? 2000 : root.idleIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (root.active || !root.ownsSideEffects || root.ownsSideEffects()) root.refresh()
    }
  }

  function killEntry(entry, force) {
    if (!entry || !entry.pid) return
    actionStatus = (force ? "Force killing " : "Stopping ") + Model.displayName(entry) + "…"
    if (!force) {
      var next = {}
      for (var k in termedAt) next[k] = termedAt[k]
      next[entry.key] = Date.now()
      termedAt = next
    }
    actionProc.command = ["/usr/bin/python3", scannerPath, "kill",
                          String(entry.pid), "--expect", String(entry.comm || entry.name || "")]
    if (force) actionProc.command = actionProc.command.concat(["--force"])
    actionProc.running = true
  }

  function stopContainer(entry) {
    if (!entry || !entry.container) return
    actionStatus = "Stopping container " + entry.container.name + "…"
    actionProc.command = ["/usr/bin/python3", scannerPath, "stop-container",
                          String(entry.container.id)]
    actionProc.running = true
  }

  function terminate(entry, force) {
    if (entry && entry.container) stopContainer(entry)
    else killEntry(entry, force)
  }

  function killAllStrays() {
    var list = strays

    var stamped = {}
    for (var k in termedAt) stamped[k] = termedAt[k]
    var now = Date.now()
    for (var n = 0; n < list.length; n++) {
      if (!list[n].container && list[n].canKill !== false) stamped[list[n].key] = now
    }
    termedAt = stamped
    for (var i = 0; i < list.length; i++) {
      var e = list[i]

      if (e.canKill === false && !e.container) continue
      if (e.container) {
        Quickshell.execDetached(["/usr/bin/python3", scannerPath, "stop-container", String(e.container.id)])
      } else if (e.pid) {
        Quickshell.execDetached(["/usr/bin/python3", scannerPath, "kill",
                                 String(e.pid), "--expect", String(e.comm || e.name || "")])
      }
    }
    actionStatus = list.length === 1
      ? "Stopping 1 dev server…"
      : "Stopping " + list.length + " dev servers…"
    recheck.restart()
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyActionResult(text)
    }
  }

  function applyActionResult(raw) {
    var parsed
    try {
      parsed = JSON.parse(String(raw || ""))
    } catch (e) {
      actionStatus = ""
      return
    }
    actionStatus = parsed.ok === true ? "" : String(parsed.error || "Action failed")
    recheck.restart()
  }

  Timer {
    id: recheck
    interval: 700
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: statusClear
    interval: 6000
    repeat: false
    running: root.actionStatus !== ""
    onTriggered: root.actionStatus = ""
  }

  function openUrl(entry) {
    if (!entry) return
    Util.execArgv(["xdg-open", Model.urlFor(entry)])
  }

  function copyUrl(entry) {
    if (!entry) return
    Util.execArgv(["wl-copy", "--", Model.urlFor(entry)])
    actionStatus = "Copied " + Model.urlFor(entry)
  }

  function enableDocker() {
    if (dockerBusy) return
    dockerBusy = true
    actionStatus = "Waiting for authentication…"
    dockerProc.command = ["pkexec", pluginDir + "/netbar-enable-docker.sh"]
    dockerProc.running = true
  }

  function disableDocker() {
    if (dockerBusy) return
    dockerBusy = true
    actionStatus = "Waiting for authentication…"
    dockerProc.command = ["pkexec", pluginDir + "/netbar-enable-docker.sh", "--disable"]
    dockerProc.running = true
  }

  function applyDockerResult(raw) {
    var parsed
    try {
      parsed = JSON.parse(String(raw || ""))
    } catch (e) {
      return
    }
    if (parsed.ok === true) {
      actionStatus = parsed.enabled === true
        ? "Docker access enabled."
        : "Docker access removed."
      recheck.restart()
    } else {
      actionStatus = String(parsed.error || "Could not change Docker access")
    }
  }

  Process {
    id: dockerProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyDockerResult(text)
    }
    onExited: function(exitCode) {
      root.dockerBusy = false

      if (exitCode === 126 || exitCode === 127) root.actionStatus = "Docker access not granted."
    }
  }

  function toggleIgnore(entry) {
    var key = Model.ignoreKey(entry)
    if (!key) return

    var next = {}
    for (var k in ignored) next[k] = ignored[k]
    if (next[key]) delete next[key]
    else next[key] = true
    ignored = next
    saveIgnored()
  }

  function loadIgnored(raw) {
    var next = {}
    try {
      var parsed = JSON.parse(String(raw || "{}"))
      var list = Array.isArray(parsed) ? parsed : (parsed.ports || [])
      for (var i = 0; i < list.length; i++) next[String(list[i])] = true
    } catch (e) {
    }
    ignored = next
    ignoreLoaded = true
  }

  function saveIgnored() {
    var list = []
    for (var k in ignored) if (ignored[k]) list.push(k)
    list.sort()
    ignoreFile.setText(JSON.stringify({ version: 1, ports: list }, null, 2) + "\n")
  }

  Process {
    id: stateDirProc
    command: ["mkdir", "-p", Quickshell.env("HOME") + "/.local/state/omarchy/netbar"]
    running: true
  }

  FileView {
    id: ignoreFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadIgnored(text())
    onLoadFailed: root.loadIgnored("{}")
    onFileChanged: reload()
  }
}
