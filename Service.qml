import QtQuick
import Quickshell
import Quickshell.Io

// DaVinci Resolve service for omarchy-shell.
//
// Owns every call into bin/omarchy-resolve — the same engine the terminal
// installer uses — and holds the state Panel.qml and BarWidget.qml render.
// Nothing here reimplements install logic; the engine is the single source of
// truth, and this file is a process runner plus a parser for its @@ protocol.
//
// Privilege model
// ---------------
// The engine is split into a root phase and a user phase. The root phase runs
// under a single pkexec call, which Omarchy's own polkit agent (the built-in
// omarchy.polkit service plugin) renders as a themed password dialog —
// fingerprint included where a sensor is enrolled. That is one prompt for a
// fifteen-minute install. sudo is never used from here: the shell has no
// terminal, so a sudo password prompt would hang forever with nothing to
// answer it.
//
// The user phase then runs unprivileged, because under pkexec $HOME is root's
// and every hyprland/pipewire/desktop file it writes would land in /root.
Item {
  id: root

  // ---- injected by shell.qml (_syncServices/ensureService) ----
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

  readonly property string pluginId: "nosignal.davinci-resolve"
  readonly property string home: Quickshell.env("HOME")

  // This plugin's own directory. `omarchy plugin add` clones the repo here, so
  // the engine ships from the same commit as the UI and no separate install
  // step can leave the two out of step.
  readonly property string pluginDir:
    Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string engine: pluginDir + "/bin/omarchy-resolve"

  // ---------------------------------------------------------------- state
  property bool checking: false
  property bool checked: false
  property var info: ({})              // last `check` result
  property var checks: []              // last `diagnose` result
  property bool diagnosing: false
  property string lastError: ""

  readonly property bool installed: info.installed === true
  readonly property bool resolveRunning: info.running === true
  readonly property string installedVersion: String(info.installedVersion || "")
  readonly property string installedEdition: String(info.installedEdition || "")
  readonly property var zips: info.zips instanceof Array ? info.zips : []
  readonly property bool updateAvailable: info.updateAvailable === true
  // newer | older | same | unknown — how the ZIP that would be installed
  // compares to what is installed now.
  readonly property string zipRelation: String(info.zipRelation || "unknown")
  readonly property bool hasNvidia: String(info.gpu || "") === "nvidia"

  // Which ZIP the user picked; defaults to the newest, matching what the
  // terminal installer would have chosen on its own.
  property string selectedZip: ""

  // Install options, mirroring the engine's flags.
  property bool optAloop: true
  property bool optHyprRules: true
  property bool optAacFix: true
  // A rehearsal: same pkexec call, same streaming, same parsing — the engine
  // just prints what it would do instead of doing it. Worth having in the UI
  // and not only behind a flag, because it is the only way to confirm the
  // authentication and progress plumbing without a 20-minute install.
  property bool optDryRun: false

  // ---- job state ----
  // One job at a time by construction: every action funnels through jobProc,
  // and every entry point refuses to start while `busy` is true.
  property bool busy: false
  property string jobKind: ""          // install | uninstall
  property string jobPhase: ""         // root | user
  property string jobLabel: ""
  property int jobProgress: 0
  property var jobSteps: []            // [{id,label,state}]
  property var logLines: []
  property string jobResult: ""        // "" while running, then ok | failed | cancelled
  // Options captured when the job started, so the user phase runs with the
  // same choices even if the toggles are changed mid-install.
  property var _pendingUserArgs: []
  property bool _purgeData: false

  readonly property int maxLogLines: 600

  signal jobFinished(string kind, bool ok)

  // ------------------------------------------------------------- utilities
  function appendLog(line) {
    var text = String(line || "")
    if (text === "") return
    var next = logLines.slice()
    next.push(text)
    if (next.length > maxLogLines) next = next.slice(next.length - maxLogLines)
    logLines = next
  }

  function clearLog() { logLines = [] }

  function setStep(id, state, label) {
    var next = jobSteps.slice()
    for (var i = 0; i < next.length; i++) {
      if (next[i].id === id) {
        next[i] = { id: id, label: label || next[i].label, state: state }
        jobSteps = next
        return
      }
    }
    next.push({ id: id, label: label || id, state: state })
    jobSteps = next
  }

  // Root phase owns the first 90% of the bar and the user phase the last 10%,
  // which is roughly their real share of the wall clock.
  function scaleProgress(pct) {
    var p = Math.max(0, Math.min(100, Number(pct) || 0))
    return jobPhase === "user" ? 90 + Math.round(p * 0.1) : Math.round(p * 0.9)
  }

  // Parse one line of engine output. Machine events start with @@ and never
  // reach the log; everything else is shown verbatim.
  function handleLine(line) {
    var text = String(line || "")
    if (text.indexOf("@@") !== 0) {
      appendLog(text)
      return
    }
    var parts = text.substring(2).split("|")
    switch (parts[0]) {
    case "PHASE":
      jobPhase = parts[1] || ""
      jobLabel = parts[2] || ""
      break
    case "STEP":
      setStep(parts[1] || "", parts[2] || "", parts[3] || "")
      if (parts[2] === "start") jobLabel = parts[3] || jobLabel
      break
    case "PROGRESS":
      jobProgress = scaleProgress(parts[1])
      break
    case "FIELD":
      // Cheap way to refresh one fact without a whole re-check.
      var patch = info
      patch[parts[1]] = parts[2]
      info = patch
      break
    case "DONE":
      break
    }
  }

  // --------------------------------------------------------------- refresh
  function refresh() {
    if (checkProc.running) return
    checking = true
    checkProc.command = ["bash", engine, "check"]
    checkProc.running = true
  }

  function diagnose() {
    if (diagProc.running) return
    diagnosing = true
    diagProc.command = ["bash", engine, "diagnose"]
    diagProc.running = true
  }

  // ---------------------------------------------------------------- install
  function install() {
    if (busy) return
    var zip = selectedZip !== "" ? selectedZip : String(info.selectedZip || "")
    if (zip === "") {
      lastError = "No DaVinci Resolve ZIP found in " + String(info.zipDir || "~/Downloads")
      return
    }

    busy = true
    jobKind = "install"
    jobPhase = "root"
    jobResult = ""
    jobProgress = 0
    jobSteps = []
    lastError = ""
    clearLog()
    appendLog("$ pkexec omarchy-resolve install --phase root"
              + (optDryRun ? " --dry-run" : "") + " --zip " + zip)
    if (optDryRun) {
      appendLog("Dry run: authenticate as usual, but nothing is written.")
    } else {
      appendLog("Authenticate in the dialog to continue. This takes 10–20 minutes;")
      appendLog("you can close the panel and the install keeps running.")
    }

    var args = ["pkexec", engine, "install", "--phase", "root", "--machine", "--zip", zip]
    if (optDryRun) args.push("--dry-run")
    if (!optAloop) args.push("--no-aloop")

    _pendingUserArgs = ["bash", engine, "install", "--phase", "user", "--machine"]
    if (optDryRun) _pendingUserArgs.push("--dry-run")
    if (!optAloop) _pendingUserArgs.push("--no-aloop")
    if (!optHyprRules) _pendingUserArgs.push("--no-hypr-rules")
    if (!optAacFix) _pendingUserArgs.push("--no-aac-fix")

    jobProc.command = args
    jobProc.running = true
  }

  function uninstall(purgeData) {
    if (busy) return
    busy = true
    jobKind = "uninstall"
    jobPhase = "root"
    jobResult = ""
    jobProgress = 0
    jobSteps = []
    lastError = ""
    _purgeData = purgeData === true
    clearLog()
    appendLog("$ pkexec omarchy-resolve uninstall --phase root")

    _pendingUserArgs = ["bash", engine, "uninstall", "--phase", "user", "--machine"]
    if (_purgeData) _pendingUserArgs.push("--purge-data")

    jobProc.command = ["pkexec", engine, "uninstall", "--phase", "root", "--machine"]
    jobProc.running = true
  }

  // The root phase finished; hand over to the unprivileged half.
  function startUserPhase() {
    jobPhase = "user"
    jobProgress = 90
    appendLog("")
    appendLog("$ omarchy-resolve " + jobKind + " --phase user")
    jobProc.command = _pendingUserArgs
    jobProc.running = true
  }

  function cancelJob() {
    if (!busy) return
    jobProc.running = false
    busy = false
    jobResult = "cancelled"
    appendLog("")
    appendLog("Cancelled. The system may be left half-installed — run the install again to finish.")
  }

  // ----------------------------------------------------------- diagnostics
  property string nvencState: ""
  property string nvencDetail: ""
  function nvencTest() {
    if (nvencProc.running) return
    nvencState = "running"
    nvencDetail = "Encoding a two-second test clip…"
    nvencProc.command = ["bash", engine, "nvenc-test"]
    nvencProc.running = true
  }

  property string probeState: ""
  property string probeDetail: ""
  property string probeFile: ""
  function probe(path) {
    var p = String(path || "").trim()
    if (p === "" || probeProc.running) return
    probeState = "running"
    probeDetail = "Reading codec…"
    probeFile = p.split("/").pop()
    probeProc.command = ["bash", engine, "probe", p]
    probeProc.running = true
  }

  // zenity ships with Omarchy and needs no portal round-trip; the panel also
  // accepts a typed path, so a missing zenity is not a dead end.
  function pickFileToProbe() {
    if (pickProc.running) return
    pickProc.command = ["bash", "-c",
      "zenity --file-selection --title='Choose a clip to check' 2>/dev/null || true"]
    pickProc.running = true
  }

  property string logTail: ""
  function tailLogs() {
    if (logProc.running) return
    logTail = "Reading…"
    logProc.command = ["bash", engine, "logs", "300"]
    logProc.running = true
  }

  function launchResolve() {
    Quickshell.execDetached(["bash", engine, "launch"])
  }

  function openLogFolder() {
    Quickshell.execDetached(["xdg-open", home + "/.local/share/DaVinciResolve/logs"])
  }

  // ------------------------------------------------------------- processes
  Process {
    id: checkProc
    running: false
    command: []
    stdout: StdioCollector { id: checkOut; waitForEnd: true }
    stderr: StdioCollector { id: checkErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.checking = false
      root.checked = true
      // A failed job's message must outlive the refresh that follows it;
      // only preflight errors may be set or cleared here.
      var keepJobError = root.jobResult === "failed"
      if (exitCode !== 0) {
        if (!keepJobError)
          root.lastError = String(checkErr.text || "Preflight failed").trim()
        return
      }
      try {
        root.info = JSON.parse(String(checkOut.text || "{}"))
        if (root.selectedZip === "") root.selectedZip = String(root.info.selectedZip || "")
        if (!keepJobError) root.lastError = ""
      } catch (e) {
        if (!keepJobError) root.lastError = "Could not parse preflight output"
      }
    }
  }

  Process {
    id: diagProc
    running: false
    command: []
    stdout: StdioCollector { id: diagOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.diagnosing = false
      if (exitCode !== 0) return
      try {
        var parsed = JSON.parse(String(diagOut.text || "{}"))
        root.checks = parsed.checks instanceof Array ? parsed.checks : []
      } catch (e) {
        root.checks = []
      }
    }
  }

  Process {
    id: jobProc
    running: false
    command: []
    stdout: SplitParser { onRead: function(data) { root.handleLine(data) } }
    stderr: SplitParser { onRead: function(data) { root.handleLine(data) } }
    onExited: function(exitCode) {
      if (root.jobResult === "cancelled") return

      if (exitCode !== 0) {
        root.busy = false
        root.jobResult = "failed"
        // 126/127 are pkexec's own codes: dismissed or not authorized.
        if (root.jobPhase === "root" && (exitCode === 126 || exitCode === 127))
          root.lastError = "Authentication was dismissed or refused — nothing was changed."
        else
          root.lastError = "The " + root.jobPhase + " phase failed (exit " + exitCode + "). See the log."
        root.appendLog("")
        root.appendLog("✗ " + root.lastError)
        root.jobFinished(root.jobKind, false)
        root.refresh()
        return
      }

      if (root.jobPhase === "root") {
        root.startUserPhase()
        return
      }

      root.busy = false
      root.jobProgress = 100
      root.jobResult = "ok"
      root.appendLog("")
      root.appendLog(root.jobKind === "install"
                     ? (root.optDryRun ? "✓ Dry run finished — nothing was changed."
                                       : "✓ DaVinci Resolve is installed.")
                     : "✓ DaVinci Resolve has been removed.")
      root.jobFinished(root.jobKind, true)
      root.refresh()
      root.diagnose()
    }
  }

  Process {
    id: nvencProc
    running: false
    command: []
    stdout: StdioCollector { id: nvencOut; waitForEnd: true }
    onExited: function() {
      try {
        var r = JSON.parse(String(nvencOut.text || "{}"))
        root.nvencState = String(r.state || "")
        root.nvencDetail = String(r.detail || "")
      } catch (e) {
        root.nvencState = "fail"
        root.nvencDetail = "Could not run the NVENC test"
      }
    }
  }

  Process {
    id: probeProc
    running: false
    command: []
    stdout: StdioCollector { id: probeOut; waitForEnd: true }
    onExited: function() {
      try {
        var r = JSON.parse(String(probeOut.text || "{}"))
        root.probeState = String(r.state || "")
        root.probeDetail = String(r.detail || "")
        if (r.file) root.probeFile = String(r.file)
      } catch (e) {
        root.probeState = "fail"
        root.probeDetail = "Could not read that file"
      }
    }
  }

  Process {
    id: pickProc
    running: false
    command: []
    stdout: StdioCollector { id: pickOut; waitForEnd: true }
    onExited: function() {
      var path = String(pickOut.text || "").trim()
      if (path !== "") root.probe(path)
    }
  }

  Process {
    id: logProc
    running: false
    command: []
    stdout: StdioCollector { id: logOut; waitForEnd: true }
    onExited: function() {
      root.logTail = String(logOut.text || "").trim()
      if (root.logTail === "") root.logTail = "Log is empty."
    }
  }

  // Cheap poll so the bar icon reflects Resolve starting or stopping without
  // the panel being open. Skipped while a job runs — the check would fight
  // the install for the same paths and tell the user nothing new.
  Timer {
    interval: 20000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: if (!root.busy) root.refresh()
  }
}
