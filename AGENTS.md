# AGENTS.md — omarchy-sshwatch

Instructions for coding agents (OpenCode, Claude Code, …) working in this repository.
Read this file completely before writing code. The decisions in it were settled deliberately —
do not re-open them, and do not "improve" them silently.

---

## 1. Project intent

`omarchy-sshwatch` is an **Omarchy shell plugin** (Quickshell/QML) that shows the SSH connections
going *out* of this machine. A colour-coded bar icon carries the state; a panel lists each session
with its destination, its owning process, its port forwards, and how long it has been open. It
warns when a session has outlived a configured threshold.

The plugin is a **read-only observer**. It makes no network connections, writes no files, and never
signals a process.

### Non-goals

- **Not** an incoming-session monitor. `sshd` sessions belong to root; reading them properly needs
  privileges this plugin deliberately does not have and must never ask for.
- **Not** a Waybar module. Omarchy's plugin system is Quickshell-based; there is no Waybar code in
  this repo.
- **Not** a session manager. It does not open, close, kill, or reconnect anything.
- **Not** a connection log. Nothing is persisted to disk, ever.
- **Not** a universal SSH-client monitor. Go/Java/Rust SSH libraries never spawn an `ssh` process
  and are therefore invisible. This is a documented limit, not a bug to fix.
- **Not** a mosh monitor. Mosh runs over UDP after handshake.

---

## 2. Locked decisions

| # | Decision | Value |
|---|---|---|
| 1 | Runtime | Omarchy `quattro` Quickshell plugin — `manifest.json` + QML entry points |
| 2 | Prior art | None exists. GitHub topics `omarchy-plugin` and `quickshell-plugin` were scanned; the nearest neighbours (`omarchy-activity-monitor`, `syncshell`, `omaconnect`) cover unrelated ground. Built fresh; architecture mirrors the sibling `omarchy-pihole` |
| 3 | Direction | **Outgoing only.** Incoming is a hard non-goal (§1) |
| 4 | Detection | **Process-first.** Own-UID `ssh` processes in `/proc`, sockets resolved via fd inodes against `/proc/net/tcp{,6}`. Never a "port 22" socket filter |
| 5 | Row identity | **A row is a process, not a socket.** Socket data is attached when present and omitted when not |
| 6 | Noise floor | Sessions younger than `minAgeSec` (default 3) are hidden, so short-lived `git`/`scp` children never flicker the bar |
| 7 | Attribution | Each row names its owning process via the ppid chain — **`comm` only, never `cmdline`** (see rule 2) |
| 8 | Label resolution | `ssh -G <target>`, cached per target. OpenSSH parses its own config; we own no config parser |
| 9 | Relationships | `-W` child ⇒ fold into parent as `via <hop>`. No socket and no ssh child ⇒ `shared` (multiplexed on a ControlMaster) |
| 10 | Forwards | `-L` / `-R` / `-D` parsed from cmdline and displayed; `-N` / `-f` / `-M` / `-W` recorded as flags |
| 11 | Bar display | **Icon only, colour-coded.** No count, no hostname, no ticking clock on the bar |
| 12 | Icon states | Four: dim (idle) · normal (active) · amber (stale) · red (error) |
| 13 | Actions | **Read-only.** Copy `ssh <target>`, and focus the owning window via `hyprctl`. **No kill, no disconnect, no signal of any kind** |
| 14 | History | In-memory `RECENT` list owned by `Service.qml`, capped at `recentCount`, cleared on shell restart. **Never on disk.** No notifications — a clean `exit` and a dropped link are indistinguishable from `/proc` |
| 15 | Settings | Five keys in `manifest.json` → `barWidget.schema`. **The plugin owns no file on disk** — no config, no cache, no state |
| 16 | Helper | `bin/omarchy-sshwatch` — python3, **stdlib only**, stateless, one JSON object per invocation |
| 17 | Plugin kinds | `service` **and** `bar-widget`. One `Service.qml` owns the scan timer and all state |
| 18 | Duration | Helper returns absolute `startedAt`; QML ticks locally at 1 Hz so a 5 s scan interval still shows a smooth clock |
| 19 | This file | Spec + hard rules + the detection algorithm + phased roadmap with acceptance criteria |

---

## 3. Repo layout

```
manifest.json           Plugin manifest. id/kinds/entryPoints + barWidget settings schema.
Service.qml             kind: service. Scan timer, backoff, RECENT diffing, all Process calls.
Panel.qml               kind: bar-widget. Bar icon, panel UI. Renders Service state.
Model.js                Pure JS: formatting and derivation only. No Quickshell imports, no I/O.
bin/omarchy-sshwatch    python3 helper. ALL /proc parsing, ssh -G, hyprctl, normalisation.
assets/sshwatch.svg     Bar icon, dark theme.
assets/sshwatch-light.svg  Bar icon, light theme.
tests/                  Helper unit tests (python stdlib unittest).
tests/fixtures/         Canned /proc trees, one per hard case.
README.md               User-facing documentation. No agent instructions.
AGENTS.md               This file.
LICENSE                 MIT.
```

Plugin id: `io.github.CHANGEME.sshwatch` <!-- TODO: replace CHANGEME with the GitHub handle that
hosts the repo, before the first `omarchy plugin add`. The `omarchy.` prefix is reserved for
built-ins. -->

Layer rule: **QML renders, python reads.** Every byte of `/proc` and SSH knowledge lives in
`bin/omarchy-sshwatch`.

---

## 4. Hard rules

Violating any of these is a defect, not a style preference.

1. **Own UID only.** Filter with `os.stat("/proc/<pid>").st_uid == os.getuid()` before reading
   anything else. Other users' processes — including root's — are never read and never shown.
2. **Never read a parent process's `cmdline`.** `sshpass -p <password> ssh host` puts a plaintext
   password in the parent's command line. Attribution reads `/proc/<pid>/comm` — the bare program
   name — and nothing else. This rule is the reason attribution is `comm`-based.
3. **Never render a raw command line in the UI, and never put one in the JSON.** From the `ssh`
   process's own cmdline, extract *only* the target token and the forward/flag set. `-o` values,
   `ProxyCommand`, `-i` key paths, and the remote command are parsed past and discarded.
4. **No network access.** No sockets, no DNS, no reverse lookups, no HTTP. The plugin reads kernel
   state about connections that already exist. If a feature seems to need the network, it is out of
   scope.
5. **No files written.** No config file, no cache file, no log, no state file, no temp file. The
   `ssh -G` cache and the `RECENT` list are in-memory only.
6. **Read-only towards processes.** Never call `kill`, `os.kill`, `signal`, or spawn anything that
   terminates a process. The only writes the plugin performs are `hyprctl dispatch focuswindow`, on
   an explicit user action.
7. **python3 stdlib only.** No pip dependencies. `os`, `pathlib`, `json`, `subprocess`, `argparse`,
   `socket`, `struct` are the toolbox.
8. **No `/proc` parsing in QML.** No file reads, no hex decoding, no cmdline handling. If QML needs
   a fact about a session, add it to the status JSON.
9. **`Model.js` stays pure**: input → output, no imports, no side effects. Same for the helper's
   `parse_*` / `format_*` functions. This is what makes the logic testable without Omarchy.
10. **One JSON object per invocation, on stdout.** Exit `0` on success, `1` on a handled error, `2`
    on an unknown action. Errors are reported *inside* the JSON (`ok: false`, `lastError`), and QML
    must never parse stderr.
11. **`/proc/<pid>/stat` is split on the LAST `)`.** Field 2 is `comm` and may contain spaces and
    parentheses. Splitting on whitespace is the classic bug here and will silently corrupt
    `starttime`. Same for `ppid`.
12. **Every `/proc` read is race-tolerant.** A process can exit between `listdir` and `open`. Wrap
    every read for `FileNotFoundError`, `PermissionError`, and `ProcessLookupError`, and skip that
    pid — never abort the scan.
13. **Every key in the status JSON is always present.** Unknown numbers are `0`, unknown strings
    `""`, unknown lists `[]`, unknown booleans `false`. QML must never handle `undefined`.
14. **`ssh -G` is cached per target and timed out** (2 s). It is a subprocess that runs the user's
    own config; calling it once per session per scan is unacceptable.
15. **Bounded reads.** Cap `cmdline` at 64 KiB, cap the scanned pid count, cap `hyprctl` output at
    1 MiB. Never read an unbounded file into memory.
16. **Don't reintroduce removed scope.** No incoming sessions, no kill action, no on-disk history,
    no mosh, no notifications — unless this file is updated first.

---

## 5. Settings model

One store. `manifest.json` → `barWidget.schema`. Omarchy renders the settings UI from it
automatically. There are no secrets and no connection details, so — unlike `omarchy-pihole` —
there is **no plugin config file**.

| Key | Type | Default | Range | Meaning |
|---|---|---|---|---|
| `refreshIntervalSec` | integer | `5` | 2–60, step 1 | Scan interval |
| `minAgeSec` | integer | `3` | 0–60, step 1 | Hide sessions younger than this. `0` shows everything |
| `staleAfterHours` | integer | `4` | 0–48, step 1 | Amber threshold. `0` disables the warning |
| `recentCount` | integer | `5` | 0–20, step 1 | Rows in `RECENT`. `0` hides the section |
| `showForwards` | boolean | `true` | — | List `-L`/`-R`/`-D` under each row |

`minAgeSec` is applied by the **helper** (so the JSON is already clean); `staleAfterHours`,
`recentCount` and `showForwards` are applied by **QML** (so changing them takes effect without
waiting for a scan). The helper accepts `--min-age` for this reason.

---

## 6. Helper CLI contract

```
bin/omarchy-sshwatch <action> [args...]
```

| Action | Args | Effect |
|---|---|---|
| `status` | `[--min-age N]` | Scan and emit the session list. The poll action. |
| `focus` | `<key>` | Re-resolve the session's owning window and `hyprctl dispatch focuswindow`. Re-resolves rather than trusting a cached address, which may be stale. |
| `check` | — | Environment probe: `/proc` readable, `ssh` present, `hyprctl` present. Cheap. |

### 6.1 Status JSON (the contract QML depends on)

```json
{
  "ok": true,
  "generatedAt": 1756384000.12,
  "count": 3,
  "sessions": [
    {
      "key": "4711:830245",
      "pid": 4711,
      "startedAt": 1756375993.44,
      "target": "prod-web-01",
      "user": "deploy",
      "hostname": "10.0.0.5",
      "port": 2222,
      "label": "deploy@prod-web-01",
      "peerAddress": "10.0.0.5",
      "peerPort": 2222,
      "family": "inet",
      "via": "bastion",
      "shared": false,
      "master": false,
      "noShell": false,
      "background": false,
      "owner": "alacritty",
      "ownerPid": 4690,
      "ownerKind": "terminal",
      "focusable": true,
      "windowAddress": "0x55d3f2a1b0",
      "forwards": [
        { "kind": "L", "spec": "5432:localhost:5432",
          "bind": "", "listenPort": 5432,
          "targetHost": "localhost", "targetPort": 5432 }
      ]
    }
  ],
  "lastError": ""
}
```

Rules for this shape:

- `key` is `"<pid>:<starttime_ticks>"`. This is the **session identity** QML diffs on. PIDs are
  reused; the raw start time in ticks makes the key unique. Never key on pid alone.
- `startedAt` is an **absolute** unix timestamp, never a duration. QML computes and ticks the
  elapsed time locally.
- `via` is `""` when there is no jump host, otherwise the hop's resolved hostname.
- `shared: true` means the session is multiplexed on an existing ControlMaster and owns no TCP
  socket; `peerAddress` / `peerPort` are then `""` / `0`. This is normal, not an error.
- `ownerKind` is one of `terminal` · `tmux` · `editor` · `service` · `unknown`. `focusable` is
  `true` only for `terminal`, and only when `hyprctl` resolved a window.
- `forwards` keeps the raw `spec` **and** a best-effort parse. When the parse fails, the numeric
  fields are `0` and the UI falls back to showing `spec`. Never drop a forward because it did not
  parse — an unparsed tunnel is still a tunnel.
- On failure: `ok: false`, `lastError` set to a short human message, `sessions: []`, `count: 0`.
  `Service.qml` keeps the previous good list and only swaps the icon to its error state — a blip
  must not blank the panel.

---

## 7. Detection algorithm

This section is the domain knowledge. Implement it exactly; each step has a footgun.

### 7.1 Clock base

```
btime        = /proc/stat, the "btime <epoch>" line          # boot time, epoch seconds
USER_HZ      = os.sysconf("SC_CLK_TCK")                      # normally 100
starttime    = /proc/<pid>/stat field 22, in clock ticks
startedAt    = btime + starttime / USER_HZ
```

Use `/proc/stat`'s `btime`, not `/proc/uptime` — `btime` is a fixed epoch value, while `uptime`
drifts with suspend and forces a fresh read every scan.

### 7.2 Field extraction from `/proc/<pid>/stat`

```
raw   = contents
tail  = raw[raw.rindex(")") + 2:]     # everything after "…(comm) "
f     = tail.split()
state     = f[0]     # field 3
ppid      = f[1]     # field 4
starttime = f[19]    # field 22
```

**`rindex(")")`, not `index(")")` and not `split()`.** A process named `(ssh) (x` is legal.

### 7.3 Candidate selection

Iterate `/proc/<numeric>`; for each:

1. `os.stat(path).st_uid == os.getuid()` — cheapest filter, apply first.
2. `comm == "ssh"` — **exactly `ssh`**. Do *not* also match `scp`, `sftp`, or `rsync`: those spawn a
   real `ssh` child, so matching them produces duplicate rows for one connection.
3. Read `stat` (→ ppid, starttime) and `cmdline` (NUL-separated, capped).

### 7.4 Socket resolution

```
/proc/<pid>/fd/*  →  readlink  →  "socket:[12345]"  →  inode set
/proc/net/tcp     →  columns: local_address rem_address st … inode
/proc/net/tcp6    →  same
```

- Keep only rows with `st == "01"` (ESTABLISHED).
- IPv4 `rem_address` is `AABBCCDD:PPPP` — the address is **4 bytes little-endian**
  (`0500000A` → `10.0.0.5`), the port is big-endian hex.
- IPv6 is 32 hex chars parsed as **four little-endian 32-bit words**, not one big-endian blob.
- A process may own several sockets (agent forwarding, X11). Take the ESTABLISHED TCP socket whose
  remote address is not loopback; if several remain, take the oldest fd.
- A process may own **none**. That is expected (see 7.6) and is not an error.

### 7.5 Target and flag extraction

Walk `argv[1:]`. Option letters that **take an argument**:

```
B b c D E e F I i J L l m O o p Q R S W w
```

Everything else is boolean, and letters cluster (`-Nf`, `-tt`, `-vvv`). For a token starting with
`-`:

- Scan its letters left to right.
- If an argument-taking letter is **last** in the token, the next argv element is its value.
- If it appears **mid-token**, the remainder of the token is its value (`-p2222`, `-L8080:h:80`).
- `--` ends option parsing.

The **first non-option token is the target** (possibly `user@host`). Everything after it is the
remote command and is discarded.

Record while walking: `-L`/`-R`/`-D` values (forwards), and the presence of `-N` (`noShell`),
`-f` (`background`), `-M` (`master`), `-W` (proxy child marker).

### 7.6 Relationship folding

Two derivable cases, applied after all candidates are collected:

| Case | Detection | Result |
|---|---|---|
| Jump host | Candidate **C** has a candidate **child** carrying `-W`. The child owns the socket; C owns none | One row for **C**, with `via` = the child's resolved hostname and `peerAddress` taken from the child. The child is **removed** from the list |
| Multiplexed | Candidate has no socket **and** no candidate child | `shared: true`, no peer address. A real session riding an existing ControlMaster |

Everything else is a plain row. **Never drop a socketless candidate** — that is exactly how the
naive implementation hides the destination you care about and shows you the bastion instead.

### 7.7 Owner attribution

Walk the ppid chain upward from the ssh pid, skipping ancestors whose `comm` is `ssh`, until pid 1.
The first non-`ssh` ancestor is the owner. Report its **`comm` only** (rule 2).

`ownerKind` classification, in order:

1. `hyprctl clients -j` reports a window whose `pid` is the owner or any ancestor → `terminal`,
   `focusable: true`, `windowAddress` from that window.
2. owner `comm` contains `tmux` → `tmux`.
3. owner `comm` in `{code, codium, node, jetbrains-*}` → `editor`.
4. ancestor chain reaches `systemd` with no window → `service`.
5. otherwise → `unknown`.

`hyprctl` is invoked **once per `status` invocation**, not once per session. Its absence or failure
sets `focusable: false` for everything and is **not** an error — `ok` stays `true`.

### 7.8 Filtering

Drop candidates whose age (`generatedAt - startedAt`) is below `--min-age`. Apply this **last**, so
a young `-W` proxy child is still available for folding into its older parent.

---

## 8. Bar and panel behaviour

### 8.1 Bar states (icon only)

| State | Condition | Appearance |
|---|---|---|
| Idle | `ok && count == 0` | Dimmed |
| Active | `ok && count > 0` | Theme's normal colour |
| Stale | `ok && staleAfterHours > 0 && any(age > threshold)` | Amber/warning colour |
| Error | `!ok` | Red/error colour, previous list retained |

Precedence: error > stale > active > idle. Colours come from the active Omarchy theme, never
hard-coded hex. Light and dark icon variants live in `assets/`.

### 8.2 Tooltip (hover)

Line 1: `<n> outgoing SSH connections` (or `No outgoing SSH connections`).
Then one line per session: `<label>  <duration>`, prefixed `⚠` when stale.
Then `lastError` when `!ok`.

### 8.3 Click bindings

| Input | Action |
|---|---|
| Left click | Open/close the panel |
| Middle click | Rescan now |
| Right click | *(unbound — decision 13 forbids a destructive quick action)* |

### 8.4 Panel sections, in order

1. **ACTIVE** — one row per session:
   - line 1: `⚠`(if stale) · `label` · `via <hop>`(if set) · `· shared`(if multiplexed) · duration
     right-aligned, ticking at 1 Hz.
   - line 2: `owner` · `peerAddress:peerPort` (or `multiplexed` when there is no socket).
   - line 3+: forwards, when `showForwards` — `L 5432 → localhost:5432`, `D 1080 (SOCKS)`. Plus
     `no shell (-N)` when set.
   - row actions: `Focus terminal window` (disabled when `!focusable`) · `Copy \`ssh <target>\``.
2. **RECENT** — hidden when `recentCount == 0` or the list is empty. `label · ended <n> ago ·
   lasted <duration>`.
3. **Footer** — `lastError` when present.

Keyboard: `Esc` closes · `r` rescans · arrows move · `Enter` focuses · `y` copies.

### 8.5 State ownership

`Service.qml` is the single source of truth. It:

- runs the scan timer at `refreshIntervalSec` and serialises `Process` calls (one helper invocation
  at a time; a user action supersedes a pending scan),
- keeps the last good `sessions` list,
- **diffs by `key`** each scan: a key present last scan and absent now is pushed onto `RECENT` with
  `endedAt = now` and `lasted = endedAt - startedAt`, capped at `recentCount`,
- owns the 1 Hz tick that advances every displayed duration,
- backs off on repeated failure: `refreshIntervalSec` → ×2 → ×4, capped at 60 s; one success
  resets it.

`Panel.qml` is a pure view over it, so two monitors can never disagree.

---

## 9. Implementation roadmap

Each phase is independently reviewable. Do not start a phase before the previous one meets its
acceptance criterion.

| Phase | Work | Acceptance criterion |
|---|---|---|
| **P0** | Repo scaffold: `manifest.json` (`kinds: [service, bar-widget]`, entry points, the §5 schema), `LICENSE`, empty QML stubs, icon assets | `omarchy plugin validate .` passes on the Omarchy machine; `omarchy plugin add <path> --enable` installs and the (empty) icon appears |
| **P1** | Helper core: candidate scan (§7.1–7.3), socket resolution (§7.4), `startedAt`, `status` and `check` | `bin/omarchy-sshwatch status \| jq` lists a real open `ssh` with the correct peer IP and a `startedAt` matching `ps -o lstart` |
| **P2** | Cmdline parsing (§7.5) and `ssh -G` resolution with cache | `ssh -p 2222 prod` and `ssh -L 8080:localhost:80 -N prod` both yield the right `label`, `port`, `forwards`, and `noShell` |
| **P3** | Relationship folding (§7.6) | `ssh -J bastion prod` produces **one** row reading `prod via bastion`. A second `ssh prod` over an existing ControlMaster produces a `shared` row, not a missing one |
| **P4** | `Service.qml` scan timer, backoff, `Process` plumbing; `Panel.qml` bar icon with the four §8.1 states; tooltip | Icon goes dim→normal when a session opens and back when it closes; amber after the threshold with `staleAfterHours: 1` |
| **P5** | Panel ACTIVE section, 1 Hz local duration tick, forwards rendering | Durations advance smoothly at a 30 s scan interval; forwards match what was typed |
| **P6** | `RECENT` diffing in `Service.qml` | Closing a session moves it to RECENT with the correct `lasted`; `recentCount: 0` hides the section; restarting the shell clears it |
| **P7** | Owner attribution + `focus` action (§7.7) | Focus jumps to the right terminal; a tmux-owned and an `autossh`-owned session both show the action disabled; the plugin still works with `hyprctl` removed from `PATH` |
| **P8** | `tests/` (python `unittest` over fixture trees), `preview.png`, README polish, publish | Test suite green with no Linux and no live SSH; plugin installs clean from the public repo URL |

---

## 10. Commands

```bash
# Plugin lifecycle (on the Omarchy machine)
omarchy plugin validate .
omarchy plugin add ~/Projects/omarchy-plugins/omarchy-sshwatch --enable
omarchy plugin update io.github.CHANGEME.sshwatch
omarchy plugin remove io.github.CHANGEME.sshwatch
omarchy plugin disable io.github.CHANGEME.sshwatch

# Helper, by hand
bin/omarchy-sshwatch status | jq
bin/omarchy-sshwatch status --min-age 0 | jq '.sessions[] | {label, via, shared, forwards}'
bin/omarchy-sshwatch check | jq
bin/omarchy-sshwatch focus 4711:830245

# Staging the hard cases for manual verification
ssh -J bastion prod                      # → one row, "prod via bastion"
ssh -M -N -f prod && ssh prod            # → one plain row + one "shared" row
ssh -L 5432:localhost:5432 -N -f prod    # → forwards + "no shell (-N)"
tmux new -d 'ssh prod'                   # → focusable: false, ownerKind: tmux

# Tests
tests/run
```

Plugins hot-reload when files under `~/.config/omarchy/plugins/` change.

---

## 11. Open questions

Resolve these with the maintainer before the affected work starts; do not guess.

1. **Dev loop (deferred by the maintainer, blocks P4).** macOS has no `/proc`, no Quickshell and no
   `hyprctl`, so neither half has a local test path yet. The option on the table is a
   `SSHWATCH_PROC_ROOT` env override plus an injectable subprocess runner, which would make 100 %
   of the python half testable on macOS from committed fixture trees — one per §7.6 case. Until
   this is decided, **write the helper so that the `/proc` root and the subprocess runner are
   parameters, not hard-coded constants**, so the decision stays cheap.
2. **Plugin id owner.** `io.github.CHANGEME.sshwatch` needs the real GitHub handle before the first
   install; the id cannot change afterwards without a reinstall.
3. **`-W` as the jump-host marker (§7.6).** Verify on the target OpenSSH version that `ProxyJump`
   really spawns a child carrying `-W`. A `ProxyCommand`-based config will not, and would fall back
   to being an unfolded plain row — acceptable, but confirm before P3.
4. **ControlMaster detection (§7.6).** "No socket and no ssh child" is a heuristic. Verify it does
   not misclassify a genuinely dying connection as `shared`; if it does, check the `ControlPath`
   socket's existence instead.
5. **`hyprctl` cost per scan (§7.7).** One subprocess every `refreshIntervalSec` is assumed
   acceptable. Measure on the real box; if not, resolve windows only when the panel is open.

---

## 12. Working agreements

- Comments and documentation in **English**, including in this German-speaking project.
- Conventional-commit prefixes (`feat:`, `fix:`, `docs:`, `refactor:`, `chore:`, `test:`).
- Bump `version` in `manifest.json` with every user-visible change.
- Every heuristic in §7 gets a fixture-backed regression test once open question 1 is resolved.
- When a decision in §2 turns out wrong, **update this file in the same commit** that changes the
  behaviour. An AGENTS.md that lies is worse than none.
