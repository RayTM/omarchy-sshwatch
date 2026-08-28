// Pure formatting and derivation. No Quickshell imports, no I/O, no side
// effects — input in, string/object out. This is what keeps the display
// logic testable without Omarchy (hard rule 9).

// "7:42:11" above an hour, "4:31" below, "0:07" under a minute.
function formatDuration(seconds) {
  var total = Math.max(0, Math.floor(seconds))
  var h = Math.floor(total / 3600)
  var m = Math.floor((total % 3600) / 60)
  var s = total % 60
  function pad(n) { return n < 10 ? "0" + n : String(n) }
  if (h > 0) return h + ":" + pad(m) + ":" + pad(s)
  return m + ":" + pad(s)
}

// Coarse "ended 5 min ago" wording for the RECENT section.
function formatAgo(seconds) {
  var total = Math.max(0, Math.floor(seconds))
  if (total < 60) return "just now"
  if (total < 3600) return Math.floor(total / 60) + " min ago"
  if (total < 86400) return Math.floor(total / 3600) + " h ago"
  return Math.floor(total / 86400) + " d ago"
}

function isStale(session, nowSec, staleAfterHours) {
  if (!session || !(staleAfterHours > 0)) return false
  return nowSec - session.startedAt > staleAfterHours * 3600
}

function anyStale(sessions, nowSec, staleAfterHours) {
  if (!sessions || !(staleAfterHours > 0)) return false
  for (var i = 0; i < sessions.length; i++) {
    if (isStale(sessions[i], nowSec, staleAfterHours)) return true
  }
  return false
}

// Bar icon state, precedence error > stale > active > idle (§8.1).
function barState(ok, sessions, nowSec, staleAfterHours) {
  if (!ok) return "error"
  var count = sessions ? sessions.length : 0
  if (count === 0) return "idle"
  if (anyStale(sessions, nowSec, staleAfterHours)) return "stale"
  return "active"
}

// Row line 1: label plus its relationship markers, duration rendered
// separately (right-aligned by the view).
function rowTitle(session) {
  var title = session.label || session.target || "unknown"
  if (session.via) title += "  via " + session.via
  if (session.shared) title += "  · shared"
  return title
}

// Row line 2: owning process plus the transport underneath it.
function rowSubtitle(session) {
  var parts = []
  if (session.owner) parts.push(session.owner)
  if (session.shared) parts.push("multiplexed")
  else if (session.peerAddress) {
    var addr = session.peerAddress
    if (session.family === "inet6") addr = "[" + addr + "]"
    parts.push(addr + ":" + session.peerPort)
  }
  return parts.join(" · ")
}

// One display line per forward: "L 5432 → localhost:5432", "D 1080 (SOCKS)".
// Falls back to the raw spec when the numeric parse failed — an unparsed
// tunnel is still a tunnel.
function forwardLine(fwd) {
  if (!fwd) return ""
  if (fwd.kind === "D") {
    var port = fwd.listenPort > 0 ? String(fwd.listenPort) : fwd.spec
    return "D " + port + " (SOCKS)"
  }
  if (fwd.listenPort > 0 && fwd.targetHost) {
    var arrow = fwd.kind === "R" ? " ← " : " → "
    return fwd.kind + " " + fwd.listenPort + arrow + fwd.targetHost + ":" + fwd.targetPort
  }
  return fwd.kind + " " + fwd.spec
}

// Extra flag line under the forwards. The forgotten -N -f tunnels are the
// ones that need labelling.
function flagLine(session) {
  var parts = []
  if (session.noShell) parts.push("no shell (-N)")
  if (session.master) parts.push("master (-M)")
  if (session.background) parts.push("background (-f)")
  return parts.join(" · ")
}

// Hover tooltip (§8.2): count line, one line per session, error when not ok.
function tooltipText(ok, sessions, nowSec, staleAfterHours, lastError) {
  var lines = []
  var count = sessions ? sessions.length : 0
  if (count === 0) lines.push("No outgoing SSH connections")
  else if (count === 1) lines.push("1 outgoing SSH connection")
  else lines.push(count + " outgoing SSH connections")
  for (var i = 0; i < count; i++) {
    var s = sessions[i]
    var mark = isStale(s, nowSec, staleAfterHours) ? "⚠ " : ""
    lines.push(mark + (s.label || s.target) + "  " + formatDuration(nowSec - s.startedAt))
  }
  if (!ok && lastError) lines.push(lastError)
  return lines.join("\n")
}

// RECENT row: "deploy@prod · ended 5 min ago · lasted 2:14:07".
function recentLine(entry, nowSec) {
  return entry.label + " · ended " + formatAgo(nowSec - entry.endedAt)
    + " · lasted " + formatDuration(entry.lasted)
}

// The copy action's payload. Never a raw command line — just the reconnect
// command for the target the user typed.
function copyCommand(session) {
  if (!session || !session.target) return ""
  var target = session.user ? session.user + "@" + session.target : session.target
  return "ssh " + target
}
