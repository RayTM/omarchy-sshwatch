import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Headless singleton (kind: service) and the single source of truth. It owns
// the scan timer, the backoff, the last good session list, the RECENT diff,
// and the 1 Hz clock every displayed duration ticks against. Panel.qml is a
// pure view over this object, so two monitors can never disagree (§8.5).
Item {
  id: root

  // Injected by the shell's service loader.
  property var shell: null

  // Settings live on the bar widget's shell.json entry, not on the service —
  // every widget instance pushes them here via applySettings(). minAgeSec is
  // applied by the helper (--min-age); the rest are applied in QML so a
  // settings change takes effect without waiting for a scan (§5).
  property int refreshIntervalSec: 5
  property int minAgeSec: 3
  property int staleAfterHours: 4
  property int recentCount: 5
  property bool showForwards: true

  // --- state the views render ------------------------------------------
  property bool ok: true
  property string lastError: ""
  property var sessions: []
  readonly property int count: sessions.length
  property double generatedAt: 0
  // In-memory only, capped, cleared with the shell process (§2 decision 14).
  property var recent: []
  readonly property bool scanning: statusProcess.running
  // Local 1 Hz clock. The helper reports absolute startedAt; ticking locally
  // keeps durations smooth even at a 30 s scan interval (§2 decision 18).
  property double nowSec: Date.now() / 1000

  readonly property string barState: Model.barState(ok, sessions, nowSec, staleAfterHours)
  readonly property string tooltip: Model.tooltipText(ok, sessions, nowSec, staleAfterHours, lastError)

  // --- backoff: interval ×2 → ×4 on repeated failure, capped at 60 s;
  // one success resets it (§8.5).
  property int failureStreak: 0
  readonly property int effectiveIntervalSec: {
    var base = Math.max(2, refreshIntervalSec)
    if (failureStreak >= 2) return Math.min(60, base * 4)
    if (failureStreak === 1) return Math.min(60, base * 2)
    return base
  }

  readonly property string helperPath: {
    var url = Qt.resolvedUrl("bin/omarchy-sshwatch").toString()
    return url.indexOf("file://") === 0 ? url.substring(7) : url
  }

  property bool _rescanQueued: false
  property string _statusOutput: ""
  property string _focusError: ""

  function applySettings(settings) {
    function intOf(name, fallback, min, max) {
      var raw = settings ? settings[name] : undefined
      var n = parseInt(String(raw === undefined || raw === null ? fallback : raw), 10)
      if (!isFinite(n)) n = fallback
      return Math.max(min, Math.min(max, n))
    }
    refreshIntervalSec = intOf("refreshIntervalSec", 5, 2, 60)
    minAgeSec = intOf("minAgeSec", 3, 0, 60)
    staleAfterHours = intOf("staleAfterHours", 4, 0, 48)
    recentCount = intOf("recentCount", 5, 0, 20)
    var sf = settings ? settings.showForwards : undefined
    showForwards = sf === undefined || sf === null ? true : sf === true
  }

  function rescan() {
    if (statusProcess.running) {
      _rescanQueued = true
      return
    }
    _statusOutput = ""
    statusProcess.command = [helperPath, "status", "--min-age", String(minAgeSec)]
    statusProcess.running = true
    if (!scanWatchdog.running) scanWatchdog.start()
  }

  // Focus is the user's explicit action, so it supersedes a pending scan
  // rather than waiting behind it (§8.5).
  function focusSession(session) {
    if (!session || !session.focusable) return
    if (statusProcess.running) {
      statusProcess.running = false
      _rescanQueued = true
    }
    if (focusProcess.running) return
    _focusError = ""
    focusProcess.command = [helperPath, "focus", String(session.key)]
    focusProcess.running = true
  }

  function copySshCommand(session) {
    var text = Model.copyCommand(session)
    if (text === "") return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(text) + " | wl-copy"])
  }

  function handleStatus(text) {
    var parsed
    try {
      parsed = JSON.parse(text)
    } catch (e) {
      handleFailure("helper returned invalid JSON")
      return
    }
    if (!parsed || parsed.ok !== true) {
      handleFailure(parsed && parsed.lastError ? String(parsed.lastError) : "scan failed")
      return
    }

    // Diff by key: present last scan, absent now ⇒ the session ended and
    // moves to RECENT. Keys are pid:starttime_ticks, so pid reuse cannot
    // resurrect a dead entry.
    var gone = {}
    for (var i = 0; i < sessions.length; i++) gone[sessions[i].key] = sessions[i]
    var next = parsed.sessions || []
    for (var j = 0; j < next.length; j++) delete gone[next[j].key]

    var ended = []
    for (var key in gone) {
      var s = gone[key]
      ended.push({
        key: s.key,
        label: s.label || s.target,
        target: s.target,
        user: s.user,
        endedAt: parsed.generatedAt,
        lasted: Math.max(0, parsed.generatedAt - s.startedAt)
      })
    }
    if (ended.length > 0) {
      ended.sort(function(a, b) { return b.lasted - a.lasted })
      // Hard cap at the schema maximum; the view slices to recentCount so a
      // settings change applies retroactively without a scan.
      recent = ended.concat(recent).slice(0, 20)
    }

    sessions = next
    generatedAt = parsed.generatedAt
    nowSec = Date.now() / 1000
    ok = true
    lastError = ""
    failureStreak = 0
  }

  // A blip must not blank the panel: the previous good list is kept and only
  // the icon flips to its error state (§6.1).
  function handleFailure(message) {
    ok = false
    lastError = message
    failureStreak = Math.min(3, failureStreak + 1)
  }

  Timer {
    id: scanTimer
    interval: root.effectiveIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.rescan()
  }

  Timer {
    id: tick
    interval: 1000
    repeat: true
    running: root.count > 0 || root.recent.length > 0
    onTriggered: root.nowSec = Date.now() / 1000
  }

  Timer {
    // A helper that never exits would silently stop the refresh loop for
    // good, because rescan() skips while the process is running. Reap it
    // well inside the maximum backoff interval.
    id: scanWatchdog
    interval: 15000
    repeat: false
    onTriggered: {
      if (statusProcess.running) {
        statusProcess.running = false
        root.handleFailure("helper timed out")
      }
    }
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: statusStdout
      waitForEnd: true
      onStreamFinished: root._statusOutput = text
    }
    onExited: function(exitCode) {
      scanWatchdog.stop()
      var out = String(statusStdout.text || root._statusOutput || "")
      if (out !== "") root.handleStatus(out)
      else root.handleFailure("helper produced no output (exit " + exitCode + ")")
      if (root._rescanQueued) {
        root._rescanQueued = false
        root.rescan()
      }
    }
  }

  Process {
    id: focusProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: focusStdout
      waitForEnd: true
      onStreamFinished: root._focusError = ""
    }
    onExited: function(exitCode) {
      // Focus failures are non-fatal; surface them through lastError so the
      // panel footer shows why nothing happened.
      if (exitCode !== 0) {
        var message = "focus failed"
        try {
          var parsed = JSON.parse(String(focusStdout.text || ""))
          if (parsed && parsed.lastError) message = String(parsed.lastError)
        } catch (e) {}
        root.lastError = message
      }
      if (root._rescanQueued) {
        root._rescanQueued = false
        root.rescan()
      }
    }
  }
}
