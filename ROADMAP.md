# Hive Desktop Roadmap

> **Hive Desktop** — the native macOS command center for work running in Hive.  
> Site: [https://hive.admir-saheta.com](https://hive.admir-saheta.com)

This roadmap tracks the native macOS app against the Hive terminal multiplexer (the TUI) and the
runtime documented at [hive.admir-saheta.com/docs](https://hive.admir-saheta.com/docs). Each
milestone ships a tagged release with clear acceptance criteria, so you always know when it's truly
done.

The aim is to make Hive the native command center for work running in Hive: keep the TUI and desktop
in sync, make multi-agent work easier to supervise, and use macOS where it improves the workflow.
Parity is the floor. The later milestones focus on a personal workspace, agent delegation, and a
clear path from parallel work to reviewed changes.

### At a glance

| Milestone | Release | Status |
|---|---|---|
| M1 Foundation & Native Socket Client | `v0.1` | ✅ Live |
| M2 TUI Parity: Workspace & Agents | `v0.2` | ✅ Live |
| M3 Agent Workflows | `v0.3` | ✅ Live |
| M4 Remote & Multi-Machine | `v0.4` | ✅ Live |
| M5 Settings, Sessions & Upkeep | `v0.5` | ✅ Live |
| M6 Review Cockpit & Changes | `v0.6` | ✅ Live |
| M7 Personal Command Center | `v0.7` | ✅ Live |
| M8 Parity: Workspace Control | `v0.8` | 🟡 In progress (6 of 7) |
| M9 Parity: Environments, Processes & Agents | `v0.9` | ✅ Built (2026-11-05) |
| M10 Parity: Web, Runtime & Onboarding | `v0.10` | Proposed |
| M11 macOS Automation & Handoff | `v0.11` | Proposed |
| M12 Extensibility & Plugin Surfaces | `v0.12` | Skipped for now |
| M13 Desktop 1.0 & Trusted Distribution | `v1.0` | Proposed |

M8–M10 come from the [parity audit of 2026-11-05](#parity-audit--2026-11-05), which compared the app with
`hive` 1.3.0-rc.3 (API level 12). They close the gaps between the desktop and the CLI/TUI before the
macOS-only work in M11.

Legend: ✅ shipped · 🟡 partial · ❌ missing — Priority **P0** (highest) → **P2** (later) — Size **S / M / L**

---

## ✅ M1 · Foundation & Native Socket Client — `v0.1` — **LIVE**

The app stops shelling out and talks to the daemon directly. Everything else builds on this.

1. **`HiveSocketClient`** — protocol 2 over the Unix socket: hello/welcome, requests matched by ID,
   base64 pipes. Replaces three `hive` processes started on each refresh.
2. **`HiveWorkspaceStore`** — one observable store of machines → sessions → environments → tabs →
   panes → processes/agents. Snapshot on connect, then events applied as they arrive. Reconnects with
   backoff and starts the daemon if it isn't running.
3. **Terminal attach over the socket** — agent tabs use `terminal.attach` and `terminal.resize`
   instead of spawning `hive agent attach` inside a pseudo-terminal, so there is one PTY, not two.
4. **Restore desktop state on relaunch** — open tabs (and each shell's last folder), the sidebar
   sections, the inspector panel and the window frame.
5. **No polling.** The 8 s poll and its three processes are gone; state updates arrive the moment
   they happen.

**Follow-ups**

- The protocol 1 fallback isn't implemented. Every daemon at API level 5 or later speaks protocol 2.
- `pane.closed` and unknown events trigger a debounced re-snapshot rather than an exact update.
- `machine add` still goes through the CLI, which has no socket method yet.
- Unknown methods and fields are ignored, so the app keeps working across 1.x releases.

**✅ Acceptance:** the app connects to the daemon socket, mirrors the whole workspace from the
`events` stream with no polling, and restores its windows, tabs and panels on relaunch.

---

## ✅ M2 · TUI Parity: Workspace & Agents — `v0.2` — **LIVE**

Desktop tabs are Hive tabs, so the app and the TUI always show the same workspace — and macOS makes
blocked agents actionable without leaving what you're doing.

1. **Hive tabs and panes, natively (P0, L)** — desktop tabs are Hive tabs; each pane is its own
   SwiftTerm view inside a native split view. Split, close, zoom, resize, move focus and rename all
   go through the `tab` and `pane` APIs.
2. **Notifications that let you act (P0, M)** — notify on `blocked` and `done` according to
   `[notify]`. The notification has *Approve*, *Deny* and *Open* buttons that send keys to the agent,
   plus a Dock badge with the number of blocked agents and a bounce when something needs you.
3. **Quick switcher ⌘K (P0, S)** — fuzzy search across agents, panes, tabs, environments and machines
   (the desktop version of `Ctrl+B w`).
4. **Overview (P1, M)** — a grid of live, read-only pane thumbnails for every agent, grouped by
   environment and sorted with blocked first. Click one to jump to it.
5. **Paste images into agents (P0, M)** — ⌘V with an image on the clipboard, or dragging an image
   onto a pane, uses Hive's image paste.
6. **Agent inspector (P1, M)** — a third inspector panel next to Files and Changes:
   - the state and why (`agent explain`), the reason text and the session ID;
   - resume and stop buttons;
   - a prompt box (`agent prompt`, with an optional "wait for the answer").
7. **Menu bar extra (P0, M)** — every agent's state at a glance, plus one-click approve/deny for
   blocked agents. The icon tints amber when something needs you and stays connected after the main
   window closes.
8. **Drag and drop (P1, S)** — drop a folder on the sidebar to create an environment, files into a
   terminal to type their paths, and an image onto an agent to paste it.

**✅ Acceptance:** you can run your day from the app. The workspace matches the TUI pane for pane,
blocked agents are actionable from a notification, the menu bar or the inspector, and ⌘K finds any
agent, pane, tab, environment or machine.

---

## ✅ M3 · Agent Workflows — `v0.3` — **LIVE**

Make parallel work first-class: an agent per branch, plans you can approve, and the plumbing that
keeps states precise.

1. **Worktrees (P1, M)** — *New Worktree…* from an environment's right-click menu: pick a branch,
   create the worktree and its environment, and optionally start an agent in it. The sidebar groups
   worktree environments under their repository.
2. **Tasks and plans (P1, L)**
   - open or drop a plan file to run it;
   - show the task graph with live states;
   - approve, deny, cancel or retry a task in place;
   - the report view shows per-task outcome, changed files and a summary, with click-through into
     the Changes diff.
3. **Agent integrations (P1, S)** — one-click hook installs in Settings and onboarding
   (`integration install`), showing what each one changes and how to uninstall it.
4. **Layouts (P1, M)** — export the current workspace as a layout file, and apply one with a preview
   sheet.

**✅ Acceptance:** from the app you can spin up a worktree, start an agent in it, run a plan, approve
or retry tasks in place, and read the report — without opening a terminal.

---

## ✅ M4 · Remote & Multi-Machine — `v0.4` — **LIVE**

Go beyond one machine: every saved machine and its agents, in the same sidebar.

1. **Machines in the sidebar (P1, L)** — each saved machine has its own section with connection
   status and its agents. Right-click to reconnect, disable, rename or remove.
2. **Discover and pair (P1, M)** — a Bonjour-style *Nearby* list (`machine discover`). Pairing shows
   the runtime's identity to confirm before trusting it, and paired machines can be revoked.
3. **Run anywhere (P1, M)** — create environments and start agents on a saved machine, inspect remote
   agents, attach to remote agent terminals through the machine proxy, and open an SSH shell.
4. **Observers (P2, M)** — create, revoke and audit read-only credentials, and open the web observer.

**✅ Acceptance:** a remote machine appears in the sidebar, its agents show live state, and you can
create environments, run agents and attach remote terminals from the app with the same trust model as
the CLI.

---

## ✅ M5 · Settings, Sessions & Upkeep — `v0.5` — **LIVE**

The app manages the runtime it depends on, instead of sending you back to the terminal.

1. **Settings window for `config.toml`** — General, Terminal, Notifications, Theme, Remote, Worktrees
   and Plugins tabs edit their TOML sections, validate before saving and keep a backup.
2. **Sessions** — switch the active workspace session, save a snapshot, restore lost panes, or
   restore with `--fresh`.
3. **Upkeep** — a dashboard version-mismatch banner, runtime status, daemon start/stop, Hive update,
   and garbage collection with a dry-run preview.

**✅ Acceptance:** every config section the desktop relies on is editable and validated in the app, and
sessions and runtime upkeep work without dropping to the CLI.

---

## ✅ M6 · Review Cockpit & Changes — `v0.6` — **LIVE**

Close the loop from parallel work to reviewed, committed changes.

1. **Diffs in the Changes panel (P1, M).** Readable inline diffs cover staged, unstaged and
   untracked text changes. Quick Look covers new files.
2. **Stage and commit.** Stage or unstage files and hunks from the Changes panel or the review
   cockpit, then commit with an explicit review step that names the environment and branch.
3. **Review cockpit (P1, M).** Bring a worktree's task report, changed files, diff, test output and
   agent summary together, and show which environment and branch each action affects.
4. **Terminal polish (P1, S).** Hive theme colours and Nerd Font fallback are in place, with ⌘F find
   in scrollback, ⌘-click to open links and file paths, and secure keyboard entry.

**✅ Acceptance:** a blocked or done agent leads to a review you can finish in the app — read the
diff, stage the hunks you want, and commit — with the affected environment and branch always visible.

---

## ✅ M7 · Personal Command Center — `v0.7` — **LIVE**

Build on the completed parity, remote and task foundations to make Hive feel like *your* workspace.

1. **Hive Inbox (P1, M).** One queue across environments and machines for blocked agents, completed
   tasks, failed runs and review requests. Group related updates, show the reason and source, and
   offer the next safe action inline.
2. **Saved workspace views (P1, M).** Add built-in terminal, overview and status-board views. Let
   people choose visible sections, grouping, density and inspector defaults, then save the result as
   a named workspace view.
3. **Agent-directed view editing (P1, M).** Let a user ask Hive's agent to adjust a saved view or
   theme. Store the result as declarative local configuration; preview, compare, undo and restore
   defaults before applying it. Do not execute arbitrary view scripts.
4. **Agent delegation and report-back (P1, L).** Start helper agents or test runs from an agent,
   attach them to the parent task, steer or stop them, and return their reports to the parent agent
   and the Hive Inbox. Show parent/child relationships and keep each helper's permissions visible.
5. **Activity and session history (P2, M).** Browse state changes, prompts, task outcomes and prior
   sessions by agent, environment and machine; resume a previous session from the timeline.
6. **Usage and capacity view (P2, S).** Show provider usage or quota only where the provider exposes
   a reliable source; label the source and last refresh, and avoid guessing from terminal output.
7. **Shareable workspace recipes (P2, M).** Export and import versioned declarative workspace views
   with a preview and compatibility check. Start with a small set of first-party recipes; leave
   community publishing and executable mods out until a separate permission and maintenance model is
   designed.

**✅ Acceptance:** a user can see everything that needs attention in one inbox, delegate a task to a
helper agent and get the report back, and save, preview and share a workspace view without any
executable extension.

---

## 🟡 M8 · Parity: Workspace Control — `v0.8` — **IN PROGRESS**

Everything you can do to tabs and panes in the TUI, you can do in the app, and you can find it in a
menu.

**Status (2026-11-05):** items 1–6 are built; item 7 (run, send and wait in panes) is next. Item
headings carry ✅ when done.

**Notes from building it**

- Hive refuses `pane.move` within a pane's own tab ("use swap"). Dropping a pane on another pane's
  edge in the same tab therefore moves it through a stopover tab and straight back. The stopover
  closes itself once empty, and the app keeps the pane on screen meanwhile, so it glides into place.
- Popups aren't in a tab's layout. They come in the tab's `popups` list (`pane`, `width_pct`,
  `height_pct`), and Hive focuses a new popup.

1. ✅ **Rename tabs and panes (P0, S).** `HiveWorkspaceStore.renameTab` and `renamePane` exist but
   nothing calls them.
   - Double-click a tab pill, or right-click → *Rename Tab…*, edits the name inline (`tab.rename`).
   - Pane right-click menu → *Rename Pane…* (`pane.rename`).
   - Tab pills show the tab's name, with its number as the ⌘1–9 hint, instead of only `>_ 1`.
   - A split pane shows its name in a slim title strip when it has one.
2. ✅ **Real menus for tabs and panes (P0, S).** Today the shortcuts are hidden buttons, so they can't
   be found or remapped in System Settings. Add *Tab* and *Pane* menus to the menu bar that cover:
   - **Tab:** New Tab ⌘T, Rename Tab ⇧⌘R, Next/Previous Tab ⌃⇥/⌃⇧⇥ (⌃⇧←/→ still work), Go to Tab
     ⌘1–9, Close Tab ⇧⌘W;
   - **Pane:** Split ⌘D/⇧⌘D, Zoom ⇧⌘M, Move Focus ⌥⌘←↑→↓, Swap With Next/Previous ⌃⌘]/⌃⌘[,
     Move to New Tab, Rename Pane ⌥⌘R, Open Popup Shell ⌥⌘P, Run in Popup ⌥⇧⌘P, Close Pane ⌘W;
   - **View:** Go to Agent or Pane ⌘K, Overview ⇧⌘O and Inbox ⇧⌘I.

   Add *Help → Keyboard Shortcuts* (⌘/) with a sheet that lists every binding, the desktop's
   `prefix ?`. Beside each one it shows the TUI key, read live from `hive config keys`.
3. ✅ **Sync the active tab with Hive (P1, S).** Switching tabs in the app calls `tab.focus`, so the
   TUI and other clients follow. A setting turns this off for people who run the app and the TUI
   side by side.
4. ✅ **Swap and move panes (P1, M).**
   - Drag a pane's title strip onto another pane to swap them (`pane.swap`).
   - Drop it on the edge of a pane to move it there (`pane.move` with `target` and `direction`).
   - *Move to Tab ▸* and *Move to New Tab* in the pane menu (`pane.move` with `tab_id`).
   - *Move to Environment ▸* re-homes a pane (`environment_id`).
   - Panes glide to their new places with the existing layout animation.
5. ✅ **Popups (P1, M).** Run a command in a floating pane over the tab (`pane.popup` with `spec`,
   `width_pct` and `height_pct`), the TUI's popup for tools like `lazygit`. It is a centered, rounded
   overlay that closes with Esc or when its command exits, and it never resizes the panes beneath it.
6. ✅ **Your own commands (P2, M).** Read `[[keys.command]]` from `config.toml` and list the `popup`,
   `pane` and `shell` entries in a *Commands* menu, each with its key as a ⌃⌥ shortcut. A `shell`
   command runs in the background and shows its last line in the status area. `plugin_action`
   entries wait for M12.
7. **Run and send to panes (P2, S).**
   - *Run Command…* types a command into a pane and runs it (`pane.run`).
   - *Send Text to Panes…* sends one input to several selected panes (`pane.send_text`, with
     `paste` for multi-line text): the desktop take on synchronized panes.
   - *Wait for Output* notifies when a pane prints a pattern (`pane.wait_output`), useful for "tell
     me when the dev server is ready".

**✅ Acceptance:** with the TUI attached to the same session, every tab and pane action in the TUI has
a menu item in the app with a shortcut. Renames, swaps, moves, popups and tab focus show up in both
at once.

---

## ✅ M9 · Parity: Environments, Processes & Agents — `v0.9` — **BUILT**

The environment and agent commands of the CLI, without leaving the app.

**Notes from building it**

- **No rename.** Hive has no way to rename an environment or change its path; `environment.update`
  only sets and unsets variables. The settings sheet shows the name, ID and path read-only.
- **Variables and background processes.** In Hive 1.3, an environment's variables reach panes and
  agents but not processes started without a terminal (`hive process start`). Passing `env` to
  `process.start` doesn't help either: Hive records it but doesn't apply it. The app wraps
  background commands in `/usr/bin/env K=V…` so they get the variables, and keeps sending `env`
  for when Hive applies it. This should be reported upstream.
- **Logs are polled.** Processes without a terminal send no `process.output` events, so the logs
  viewer polls `process.logs` every second while the process runs.
- **Metadata events.** Titles and tokens arrive as `metadata.changed` events. Reporters stop by
  letting their TTL lapse, so the app also drops expired entries itself.

1. ✅ **Environment settings (P1, M).** An *Environment Settings…* sheet from the sidebar:
   - its ID, branch and path, read-only (Hive can't rename an environment);
   - edit the variables every new process gets (`hive environment set/unset KEY=VALUE`), with values
     masked by default and a warning that running processes keep their old values.
2. ✅ **Processes and logs (P1, L).** A fourth inspector panel, *Processes*. Hive runs more than agents, and the app shows none of it.
   - A *Processes* section per environment (`process.list`), kept live from the `process.started`,
     `process.exited` and `process.recovered` events the store already decodes.
   - *Start Process…* starts a command with or without a terminal, for dev servers and watchers
     (`process.start`).
   - A logs viewer with follow, stdout/stderr filters and search (`process.logs` with `follow`,
     `stream` and `tail`, or `process.logs.stream`).
   - Stop and restart (`process.stop`).
   - Each process shows the ports it listens on, and a click opens them in the browser.
3. ✅ **Titles and tokens (P1, M).** The roadmap listed these as shipped, but the app never reads
   them.
   - Read `metadata.list` and follow its updates.
   - Show pane titles and tokens (branch, PR, test status, cost) as chips on pane title strips, tab
     pills and sidebar environments, the way the TUI's status line does.
   - `metadata.report` lets the app clear stale tokens.
4. ✅ **Agent tools (P1, M).** In the agent inspector and the sidebar's agent menu.
   - *Rename Agent…* (`agent.rename`).
   - *Transcript* in the agent inspector: the agent's recent output as text, with copy and save
     (`agent.read` with `lines` and `source`).
   - *Notify me when…* done, idle, blocked or stalled for N minutes, for one agent
     (`agent.wait` with `until` and `stall_ms`).
   - *Show in TUI* (`agent.focus`).
   - *Mark as…* sets an agent's state by hand when its hooks aren't installed (`agent.report`).
5. ✅ **Worktree lifecycle (P1, M).** A *Worktrees…* sheet from any repository environment. Today the app only creates worktrees, and removing their
   environment leaves the checkout on disk.
   - List a repository's worktrees, including ones without an environment (`worktree.list`).
   - Open an existing checkout as an environment (`worktree.open`).
   - *Remove Worktree…* shows uncommitted changes before deleting the checkout, and offers `force`
     (`worktree.remove`).

**✅ Acceptance:** you can set an environment's variables, run and watch a dev server's logs, see
every pane's tokens, read an agent's transcript, get notified when an agent stalls, and remove a
worktree cleanly — all without the CLI.

---

## M10 · Parity: Web, Runtime & Onboarding — `v0.10` — **PROPOSED**

The rest of the CLI surface: sharing, diagnostics and getting started.

1. **Web observer, fully (P1, M).** The app reads `hive web status` and nothing else.
   - *Share…* creates a one-time sign-in link with a QR code (`web share`). It sets uses, link
     expiry and access expiry, and whether screens and history are shown.
   - A *Grants* list shows who has access and when it ends, with revoke (`web grants`,
     `web revoke`).
   - Start and stop the observer (`web serve`, `web runtime`).
   - Manage phone and browser notifications (`web push`).
   - A live activity feed (`observer.activity`) and a token checker (`observer.validate`).
2. **Ad-hoc remote hosts (P2, M).** *Connect to Host…* runs against any SSH host without saving it
   first (`--remote host`). When Hive is missing there, a consent sheet says what will be installed
   before it runs with `--yes`. A *Save as Machine* button turns it into a saved machine.
3. **Sessions in the window (P2, S).**
   - A session switcher in the sidebar footer, instead of only in Settings.
   - `session remove` and `session stop`, with a confirmation that names the agents that stop.
4. **Diagnostics (P2, M).**
   - Native runtime status and ping in the connection indicator (`runtime.status`, `runtime.ping`),
     replacing the CLI round trips.
   - A *Diagnostics* window showing memory, goroutines and per-process resource use
     (`debug.stats`).
   - *Capture Profile…* saves a `pprof` bundle for bug reports (`debug.pprof`).
   - The app reports its round-trip time (`client.report`) so the runtime can size frame and image
     budgets for remote terminals.
5. **Terminal fidelity (P2, M).**
   - Show inline images that agents draw with the kitty or sixel protocols (`terminal.graphics`).
   - Replay a restored pane's history from `terminal.snapshot` with `scrollback`, which finishes the
     🟡 history-replay item.
   - *Copy Screen* and *Save Scrollback…* in the pane menu.
6. **Getting started (P2, S).**
   - *Try the Demo* in onboarding and the empty state opens four demo agents (`hive demo`).
   - *Connect Agents to Hive* in Settings → Integrations:
     - shows and installs the MCP server entry (`hive mcp`) for Claude Code, Codex and OpenCode;
     - installs Hive's skill (`hive --skill`) where those agents read skills.

**✅ Acceptance:** you can share a read-only link to your agents and revoke it, run against an unsaved
SSH host with explicit consent, diagnose a slow runtime and attach a profile to a bug report, and a
new user can try Hive and connect their agents to its MCP server from the app.

---

## M11 · macOS Automation & Handoff — `v0.11` — **PROPOSED**

Meet people where they already work: Shortcuts, Spotlight, Finder and their editor.

1. **Shortcuts and App Intents (P1, M).** Actions: *Start agent*, *Prompt agent*, *Wait for agent*,
   *List blocked agents*, *Open environment*. Works from Shortcuts, Spotlight and Siri.
2. **Deep links and Finder actions (P2, S).** `hive://` links for agents, tabs, panes and
   environments, plus Finder Services "Open in Hive" and "New Hive Environment Here".
3. **Editor handoff (P2, S).** From Files and Changes, open a file or diff at the right line in VS
   Code, Cursor, Xcode or Zed.
4. **Focus-aware alerts (P2, S).** Mute or summarize selected environments and machines during a
   macOS Focus mode, using local notification rules that work alongside Focus.

**✅ Acceptance:** a user can start and steer agents from Shortcuts and Spotlight, deep-link into any
agent or pane, and open a changed file at the right line in their editor.

---

## M12 · Extensibility & Plugin Surfaces — `v0.12` — **SKIPPED FOR NOW**

The layer that makes Hive customizable while keeping permissions legible.

> Skipped per user request (2026-11-04). Executable extensions stay out of scope until a separate
> permission and maintenance model is designed. This is the largest remaining gap with the CLI:
> `hive plugin` has 30 subcommands (install, search, update, rollback, grant, revoke, doctor, logs,
> config, …) and the API has 12 `plugin.*` methods. The app uses none of them. The `[plugins]`
> policy section is editable in Settings.

1. **Plugin palette ⌘⇧P (P1, M).** Runs plugin actions and palette entries; async actions show
   progress.
2. **Plugin UI contributions (P1, M).** Sidebar cards render as native card views, tab-bar indicators
   appear on tab pills, and contextual actions appear in the right-click menus. Dynamic links open in
   the app.
3. **App Store (P2, L).** Browse, install, update and roll back plugins. Before installing, a native
   consent sheet lists the plugin's required and optional capabilities.
4. **Plugin lifecycle (P2, S).** A health view shows `starting/ready/degraded/failed/disabled`, plus
   `doctor` output and reload.

**✅ Acceptance:** the two reference plugins from the runtime work in the app (a "PR status" sidebar
token and "spawn reviewer on worktree.created"), and installing a plugin shows and enforces its
capability consent.

---

## M13 · Desktop 1.0 & Trusted Distribution — `v1.0` — **PROPOSED**

The app leaves preview and becomes something to install without a second thought.

1. **Signed distribution.** Developer ID signing and notarization, a `.app` in a DMG, and a Homebrew
   cask. Attach packages to each release with `checksums.txt` and its signature.
2. **In-app updates.** The app's own updater, from GitHub Releases. An update installs only after its
   checksum and signature are checked, keeps the previous version, and rolls back if the app does not
   start. Updating the app never stops agents.
3. **Compatibility policy.** Cover the app's surfaces with the runtime's compatibility policy and
   remove the preview label.
4. **Performance budgets in the native app.** Measure keystroke-to-screen p99, idle CPU and memory
   with 16 streaming panes, and hold the budgets in CI.
5. **Sandboxing decision.** The app is not sandboxed today (it needs to spawn shells, read the Hive
   socket and send signals for Kill Ports). Mac App Store distribution would need a helper tool.
   Decide before shipping 1.0.

**✅ Acceptance:** a signed app installs and updates itself only to verified releases, rolls back a
failed update, and meets the latency, CPU and memory budgets — with the acceptance of M1–M11 still
holding.

---

## Where the app is today

| Area | Status | Notes |
| --- | --- | --- |
| First launch: find, verify or install `hive` | ✅ | Runs the install script and remembers the binary |
| Onboarding | ✅ | |
| Sidebar: environments and agents with live state | ✅ | Socket API snapshot plus the `events` stream; no polling |
| Create environments and worktrees | ✅ | Folder drop, existing folders, and Hive-managed worktrees |
| Start / stop / resume agents; approve blocked agents | ✅ | Sidebar, inspector, notifications, and menu bar |
| Remove environment (with confirmation) | ✅ | |
| Hive terminal tabs and split panes | ✅ | Shared with the TUI, up to 4 panes per tab: rename, swap, move, popups, right-click menu |
| Files panel following the shell's `cd`, Quick Look previews | ✅ | Desktop only |
| Changes panel: diffs, staging, commits | ✅ | Stage or unstage files and hunks, commit with a review step |
| Kill listening ports per environment | ✅ | Desktop only |
| Remote machines and observers | ✅ | Pairing, status, remote terminals, and observer credentials |
| Settings and runtime upkeep | ✅ | Validated config editing, sessions, updates, daemon controls, and GC |
| Environment variables and settings | ✅ | Variables, title and tokens; Hive has no rename |
| Background processes and logs | ✅ | Processes inspector panel with logs and ports |
| Web observer sharing and grants | ❌ | Status only; M10 |
| Plugins | ❌ | M12, skipped for now |
| Menu bar, actionable notifications, Dock badge, drag and drop | ✅ | Native desktop integrations |

---

## Parity checklist against the TUI and runtime

### Workspace (tabs, panes, layouts)

| TUI / runtime feature | Desktop | Priority | Size |
| --- | --- | --- | --- |
| Hive tabs as the source of truth (`tab create/list/rename/focus/close`) | ✅ | P0 | L |
| Split right / down (`Ctrl+B %` / `"`), `pane split` | ✅ | P0 | L |
| Move focus, resize panes, drag borders | ✅ | P0 | M |
| Zoom and close panes | ✅ | P0 | S |
| Jump to tab 1–9, next/previous tab | ✅ | P0 | S |
| Rename tabs and panes (`tab rename`, `pane rename`) | ✅ M8 | P0 | S |
| Pane and environment titles and tokens (`metadata`) | ✅ M9 | P1 | M |
| Popups (`pane popup`), floating panes | ✅ M8 | P1 | M |
| Move a pane to another tab or environment, swap panes (`pane move`, `pane swap`) | ✅ M8 | P1 | M |
| Active tab follows between clients (`tab focus`) | ✅ M8 | P1 | S |
| Your own commands on keys (`[[keys.command]]`: popup, pane, shell) | ✅ M8 | P2 | M |
| Run or send text into panes, wait for output (`pane run`, `send-text`, `wait-output`) | ❌ M8 | P2 | S |
| Layout export / apply (JSON) | ✅ | P1 | M |
| Overview (`Ctrl+B O`) | ✅ | P1 | M |
| Find an agent or pane (`Ctrl+B w`) | ✅ | P0 | S |

### Agents

| TUI / runtime feature | Desktop | Priority | Size |
| --- | --- | --- | --- |
| States: working, blocked, done, idle, exited | ✅ | — | — |
| Live updates (`events` stream) instead of polling | ✅ | — | — |
| Notifications on state changes (`[notify]`) with approve / deny / open | ✅ | P0 | M |
| Explain a state (`agent explain`: rule matched, reports, screen) | ✅ | P1 | S |
| Send a prompt, optionally wait for the answer (`agent prompt`, `wait`) | ✅ | P1 | M |
| Send keys (approve / deny a blocked agent: `y`, Enter, Esc) | ✅ | P0 | S |
| Install agent hooks for precise state and resume (`integration install`) | ✅ | P1 | S |
| Resume a conversation (session ID or latest) | ✅ | P1 | S |
| Rename an agent (`agent rename`) | ✅ M9 | P2 | S |
| Read an agent's output as text (`agent read`) | ✅ M9 | P1 | S |
| Wait for a state or a stall (`agent wait --until`, `stall_ms`) | ✅ M9 | P1 | S |
| Report a state by hand (`agent report`), focus in the TUI (`agent focus`) | ✅ M9 | P2 | S |
| Paste or drop an image into an agent | ✅ | P0 | M |
| Agent manifests (which CLIs Hive knows) | ✅ | P2 | S |

### Environments and processes

| TUI / runtime feature | Desktop | Priority | Size |
| --- | --- | --- | --- |
| Create and remove environments | ✅ | P0 | S |
| Set and unset an environment's variables (`environment update/set/unset`) | ✅ M9 | P1 | M |
| List, start and stop processes (`process list/start/stop`) | ✅ M9 | P1 | M |
| Process logs, following (`process logs --follow`) | ✅ M9 (polled) | P1 | M |

### Worktrees and tasks

| TUI / runtime feature | Desktop | Priority | Size |
| --- | --- | --- | --- |
| Worktree create (an agent per branch) | ✅ | P1 | M |
| Worktree list / open / remove (`worktree list/open/remove`) | ✅ M9 | P1 | M |
| Tasks: run a plan, approve, cancel, retry, wait, report | ✅ | P1 | L |
| Plan report: per-task outcome, changed files, summary | ✅ | P1 | M |

### Persistence and sessions

| TUI / runtime feature | Desktop | Priority | Size |
| --- | --- | --- | --- |
| Survives detach / daemon restart (shims) | ✅ Inherited from the runtime | — | — |
| Restore desktop tabs on relaunch | ✅ | — | — |
| Session save / restore / restore `--fresh` | ✅ | P2 | S |
| Several sessions (separate daemons) | ✅ | P2 | M |
| History replay after restore (`session.replay_history`) | 🟡 M10 | P2 | S |
| Remove or stop a session (`session remove/stop`) | ❌ M10 | P2 | S |
| Garbage collection (`gc`, `--dry-run`) | ✅ | P2 | S |

### Remote machines

| TUI / runtime feature | Desktop | Priority | Size |
| --- | --- | --- | --- |
| Saved machines in the sidebar with their agents | ✅ | P1 | L |
| Machine status / reconnect / enable / disable / rename / remove | ✅ | P1 | S |
| Discover runtimes on the local network, pair, revoke | ✅ | P1 | M |
| Create remote environments, run agents, attach terminals, SSH shell | ✅ | P1 | M |
| Observer credentials (create, revoke, audit) | ✅ | P2 | M |
| Web observer: share links, grants, serve, Web Push (`web share/grants/revoke/serve/push`) | ❌ M10 | P1 | M |
| Ad-hoc SSH hosts without saving them (`--remote host`) | ❌ M10 | P2 | M |

### Runtime and onboarding

| TUI / runtime feature | Desktop | Priority | Size |
| --- | --- | --- | --- |
| Status, ping, start/stop the daemon, update, `gc` | ✅ through the CLI; native in M10 | P1 | S |
| Resource use and profiles (`debug stats`, `debug pprof`) | ❌ M10 | P2 | M |
| Inline terminal graphics (`terminal.graphics`) | ❌ M10 | P2 | M |
| Demo tab (`hive demo`) | ❌ M10 | P2 | S |
| MCP server setup (`hive mcp`) and the agent skill (`hive --skill`) | ❌ M10 | P2 | S |

### Extensibility

| TUI / runtime feature | Desktop | Priority | Size |
| --- | --- | --- | --- |
| Plugin palette (`Ctrl+B :` / `P`) | ❌ | P1 | M |
| Plugin actions, contextual actions, palette entries | ❌ | P1 | M |
| Sidebar cards, tab-bar indicators, dynamic links | ❌ | P2 | M |
| App Store: browse, install, update, roll back, capability consent | ❌ | P2 | L |
| Plugin lifecycle (`starting/ready/degraded/failed/disabled`), doctor, reload | ❌ | P2 | S |

### Configuration

| TUI / runtime feature | Desktop | Priority | Size |
| --- | --- | --- | --- |
| `[terminal]` shell, size, scrollback | ✅ | P1 | S |
| `[notify]` which states notify, per-agent rules | ✅ | P0 | S |
| `[theme]` (also used for the desktop terminals) | ✅ | P1 | M |
| `[keys]` prefix and bindings | n/a | — | — |
| `[remote]` frame / image budgets, `[retention]`, `[worktrees].directory` | ✅ | P2 | S |
| `[plugins]` policy (allow/deny capabilities) | ✅ | P2 | S |
| Version check and `hive update` | ✅ | P1 | S |

`[keys]` is TUI-only. The desktop app uses standard Mac shortcuts instead (see the keyboard map below).

---

## Desktop-only features

These use macOS to make Hive easier to supervise and control. Statuses reflect the current app.

1. **Menu bar extra (P0, M). Complete.** Every agent's state at a glance, plus one-click
   approve/deny for blocked agents. The icon tints amber when something needs you and stays
   connected after the main window closes.
2. **Actionable notifications and Dock badge (P0, M). Complete.** Approve or deny a blocked agent
   without leaving the app you're in.
3. **Changes panel (P1, M). Complete.** Readable inline diffs cover staged, unstaged and untracked
   text changes; stage or unstage files and hunks, then commit with a review step. Quick Look covers
   new files.
4. **Drag and drop (P1, S). Complete.** Drop a folder on the sidebar to create an environment, files
   into a terminal to type their paths, a plan file to run it, and an image on an agent to paste it.
5. **Shortcuts and App Intents (P1, M). M11.** Works from Spotlight, Siri and the Shortcuts app.
6. **Finder integration (P2, S). M11.** A Services menu or Finder extension item, "Open in Hive" /
   "New Hive Environment Here", and a `hive://` URL scheme for deep links to agents and panes.
7. **Open in editor (P2, S). M11.** From Files and Changes, open in the user's editor (VS Code,
   Cursor, Xcode, Zed) at the right line.
8. **Terminal polish (P1, S). Complete.** Hive theme colours, Nerd Font fallback, ⌘F find in
   scrollback, ⌘-click to open links and file paths, secure keyboard entry, and a right-click menu.
9. **Focus filters (P2, S). M11.** Mute notifications from chosen environments during a Focus mode.

---

## Product comparison: Herdr and Hive

Herdr's current pitch is that agents can reshape the app itself. Its homepage invites users to ask an
agent for a different interface, and stores layouts and JavaScript mods as local files described by
an in-app `AGENTS.md`. Its guide shows prompt-driven boards, tab timers, theme changes, and community
layouts/mods. The homepage listed 150 layouts and 289 mods when checked on 2026-11-04. Herdr also
shows a helper-agent loop: start a reviewer or test runner, steer it while it works, and have its
report returned to the requesting agent. [Herdr](https://herdr.dev/), [Guide](https://herdr.dev/guide/),
[Gallery](https://herdr.dev/gallery/?type=mods).

Hive already has deeper Hive-native controls to build on: shared tabs and panes, multi-machine
operations, remote terminals, worktrees, task plans, and agent-aware desktop notifications. The gap
is the layer that makes these tools feel personal and makes parallel work easy to review. Herdr's
core also emphasizes durable terminals and agents that can start, steer, wait for, and read helper
agents. [Herdr core](https://herdr.dev/core/).

The opportunity is to make Hive feel customizable while keeping its permissions legible: start with
editable, declarative layouts and views, and keep executable extensions out of scope while M12
remains skipped.

---

## Keyboard map (desktop equivalents)

The *Today* column is what the app binds now; M8 adds the missing ones and puts every binding in a
menu.

| Action | TUI | Desktop | Today |
| --- | --- | --- | --- |
| New tab | `Ctrl+B c` | ⌘T | ✅ |
| Split right / down | `Ctrl+B %` / `"` | ⌘D / ⇧⌘D | ✅ |
| Move between panes | `Ctrl+B ←↑→↓` | ⌥⌘←↑→↓ | ✅ |
| Next / previous tab | `Ctrl+B n` / `p` | ⌃⇥ / ⌃⇧⇥ (or ⌃⇧→ / ⌃⇧←) | ✅ |
| Jump to tab 1–9 | `Ctrl+B 1–9` | ⌘1–⌘9 | ✅ |
| Zoom pane | `Ctrl+B z` | ⇧⌘M | ✅ |
| Close pane | `Ctrl+B x` | ⌘W | ✅ |
| Rename tab / pane | `Ctrl+B ,` / `.` | ⇧⌘R / ⌥⌘R, or double-click the tab / pane title | ✅ |
| Swap pane with next / previous | `Ctrl+B }` / `{` | ⌃⌘] / ⌃⌘[, or drag the pane's title strip | ✅ |
| Move a pane to another tab | `hive pane move` | Pane menu → Move To, or drag onto a pane's edge | ✅ |
| Popup shell / run in popup | `Ctrl+B f` | ⌥⌘P / ⌥⇧⌘P | ✅ |
| Your `[[keys.command]]` entries | `Ctrl+B` + their key | ⌃⌥ + their key, Commands menu | ✅ |
| Find agent or pane | `Ctrl+B w` | ⌘K | ✅ |
| Overview | `Ctrl+B O` | ⇧⌘O | ✅ |
| Inbox | — | ⇧⌘I | ✅ desktop only |
| Show / hide sidebar | `Ctrl+B b` | ⌃⌘S | ✅ |
| Find in scrollback | `Ctrl+B [` then `/` | ⌘F | ✅ |
| Plugin palette | `Ctrl+B :` / `P` | ⇧⌘P | ❌ M12, skipped |
| Copy mode / paste | `Ctrl+B [` / `]` | Native selection, ⌘C / ⌘V | ✅ |
| Paste image into agent | `Ctrl+B I` | ⌘V with an image on the clipboard | ✅ |
| Detach | `Ctrl+B d` | Close the window; agents keep running | ✅ |
| Show key bindings | `Ctrl+B ?` | Help → Keyboard Shortcuts (⌘/) | ✅ |

The TUI keys in this table are the defaults from `hive config keys`; `[keys]` remaps them, and the
app's Keyboard Shortcuts sheet shows your own. A row that shows a CLI command has no default TUI key.

---

## Parity audit — 2026-11-05

The app was compared with `hive` 1.3.0-rc.3, whose daemon publishes 103 API methods at API level 12
(`hive api schema`). Every CLI command group's subcommands were listed too.

**API coverage.** The app calls 38 of the 103 methods over the socket and reaches a few more through
the CLI (sessions, `gc`, daemon start and stop, machines, integrations, `web status`). Of the methods
it doesn't call:

- **Covered another way, not a gap (~25):** `*.get` and `*.list` for agents, tabs, panes, environments
  and processes come from `api.snapshot` and the events stream. `api.schema`, `task.wait` and
  `terminal.input` aren't needed because the terminal writes straight to its pipe. Plugin-side calls
  (`plugin.ready`, `plugin.request`, `plugin.card`, `plugin.status`, `agent.reload`) are made by
  plugins, not by clients.
- **Real gaps:** listed below with their milestone.

| Area | Methods / commands not used | Milestone |
| --- | --- | --- |
| Tabs and panes | `tab.focus`, `pane.move`, `pane.swap`, `pane.popup`, `pane.run`, `pane.send_text`, `pane.send_keys`, `pane.wait_output`; `tab.rename` and `pane.rename` have code but no UI | M8 |
| Environments | `environment.update`, `environment set/unset` | M9 |
| Processes | `process.start`, `process.stop`, `process.logs`, `process.logs.stream` | M9 |
| Metadata | `metadata.list`, `metadata.report` | M9 |
| Agents | `agent.rename`, `agent.read`, `agent.wait`, `agent.focus`, `agent.report` | M9 |
| Worktrees | `worktree.list`, `worktree.open`, `worktree.remove` | M9 |
| Web and observers | `web share/grants/revoke/serve/runtime/push`, `observer.activity`, `observer.validate` | M10 |
| Runtime | `runtime.status`, `runtime.ping` (through the CLI today), `debug.stats`, `debug.pprof`, `client.report`, `session remove/stop` | M10 |
| Terminal | `terminal.graphics`, `terminal.snapshot` | M10 |
| CLI only | `hive demo`, `hive mcp`, `hive --skill`, `--remote host` | M10 |
| Plugins | all 12 `plugin.*` methods and 30 `hive plugin` subcommands | M12 (skipped) |

**Corrections to earlier statuses.** These were marked shipped but aren't in the code:

- tab and pane renaming, which has store methods but no caller;
- pane titles and tokens (`metadata`);
- renaming an agent;
- worktree list, open and remove;
- the ⌘T and ⌃Tab shortcuts and Help → Keyboard Shortcuts.

Two items marked partial or next have since shipped: Changes staging and commits, and terminal polish.

**Out of scope.** `hive completion`, `hive proxy`, `hive events`, `--template` and `[keys]` remapping
are for shells and scripts, and have no desktop equivalent.

---

## Open questions

- **Tab ownership.** Should every desktop tab become a Hive tab (shared with the TUI), or should
  quick throwaway shells stay local to the app? Recommendation: Hive tabs by default, with a
  "scratch shell" that isn't persisted.
- **Socket client.** The Go SDK can't be used from Swift. Should we write and maintain a Swift
  client from the protocol reference, or generate one from `hive api schema`? Recommendation:
  generate the types and hand-write the transport.
- **Remote terminals.** Should remote panes stream through `machine proxy` started per machine, or
  through one multiplexed connection? This depends on how the frame and image budgets behave from
  a GUI client.
- **Sandboxing.** The app isn't sandboxed (it needs to spawn shells, read the Hive socket and send
  signals for Kill Ports). Mac App Store distribution would need a helper tool. Decide before M13.

---

## Roadmap Principles

- **Parity is the floor.** The desktop app stays in sync with the TUI and the runtime, not a fork of
  them.
- **Ship value early.** Prioritize capabilities that are already built and close to release.
- **macOS where it helps.** Use native integrations to make multi-agent work easier to supervise,
  never to hide what Hive is doing.
- **Legible permissions.** Keep plugin, remote and credential boundaries explicit; keep executable
  extensions out of scope until a permission model exists.
- **Acceptance criteria over promises.** Each milestone ships a tagged release with verifiable
  outcomes and documented limitations.
