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
| M7 Personal Command Center | `v0.7` | Proposed |
| M8 macOS Automation & Handoff | `v0.8` | Proposed |
| M9 Extensibility & Plugin Surfaces | `v0.9` | Proposed |
| M10 Desktop 1.0 & Trusted Distribution | `v1.0` | Proposed |

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

## M7 · Personal Command Center — `v0.7` — **PROPOSED**

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

## M8 · macOS Automation & Handoff — `v0.8` — **PROPOSED**

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

## M9 · Extensibility & Plugin Surfaces — `v0.9` — **PROPOSED**

The layer that makes Hive customizable while keeping permissions legible.

> Skipped per user request (2026-11-04). Executable extensions stay out of scope until a separate
> permission and maintenance model is designed.

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

## M10 · Desktop 1.0 & Trusted Distribution — `v1.0` — **PROPOSED**

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
failed update, and meets the latency, CPU and memory budgets — with M1–M8's acceptance still holding.

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
| Hive terminal tabs and split panes | ✅ | Shared with the TUI; local scratch shells remain available |
| Files panel following the shell's `cd`, Quick Look previews | ✅ | Desktop only |
| Changes panel with inline diffs | 🟡 | Staged and unstaged diffs, including new text files; staging and commits remain |
| Kill listening ports per environment | ✅ | Desktop only |
| Remote machines and observers | ✅ | Pairing, status, remote terminals, and observer credentials |
| Settings and runtime upkeep | ✅ | Validated config editing, sessions, updates, daemon controls, and GC |
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
| Rename tabs and panes, pane titles and tokens (`metadata`) | ✅ | P1 | S |
| Popups (`pane popup`), floating panes | ❌ | P2 | M |
| Move a pane to another tab or environment, swap panes | 🟡 | P2 | M |
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
| Rename an agent's pane | ✅ | P2 | S |
| Paste or drop an image into an agent | ✅ | P0 | M |
| Agent manifests (which CLIs Hive knows) | ✅ | P2 | S |

### Worktrees and tasks

| TUI / runtime feature | Desktop | Priority | Size |
| --- | --- | --- | --- |
| Worktree create / list / open / remove (an agent per branch) | ✅ | P1 | M |
| Tasks: run a plan, approve, cancel, retry, wait, report | ✅ | P1 | L |
| Plan report: per-task outcome, changed files, summary | ✅ | P1 | M |

### Persistence and sessions

| TUI / runtime feature | Desktop | Priority | Size |
| --- | --- | --- | --- |
| Survives detach / daemon restart (shims) | ✅ Inherited from the runtime | — | — |
| Restore desktop tabs on relaunch | ✅ | — | — |
| Session save / restore / restore `--fresh` | ✅ | P2 | S |
| Several sessions (separate daemons) | ✅ | P2 | M |
| History replay after restore (`session.replay_history`) | 🟡 | P2 | S |
| Garbage collection (`gc`, `--dry-run`) | ✅ | P2 | S |

### Remote machines

| TUI / runtime feature | Desktop | Priority | Size |
| --- | --- | --- | --- |
| Saved machines in the sidebar with their agents | ✅ | P1 | L |
| Machine status / reconnect / enable / disable / rename / remove | ✅ | P1 | S |
| Discover runtimes on the local network, pair, revoke | ✅ | P1 | M |
| Create remote environments, run agents, attach terminals, SSH shell | ✅ | P1 | M |
| Observer credentials (create, revoke, audit), web observer | ✅ | P2 | M |

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
3. **Changes panel diffs (P1, M). Partial.** Readable inline diffs cover staged, unstaged and
   untracked text changes. Next: stage or unstage files and hunks, then commit with a clear review
   step. Quick Look covers new files.
4. **Drag and drop (P1, S). Complete.** Drop a folder on the sidebar to create an environment, files
   into a terminal to type their paths, a plan file to run it, and an image on an agent to paste it.
5. **Shortcuts and App Intents (P1, M). Next.** Works from Spotlight, Siri and the Shortcuts app.
6. **Finder integration (P2, S). Next.** A Services menu or Finder extension item, "Open in Hive" /
   "New Hive Environment Here", and a `hive://` URL scheme for deep links to agents and panes.
7. **Open in editor (P2, S). Next.** From Files and Changes, open in the user's editor (VS Code,
   Cursor, Xcode, Zed) at the right line.
8. **Terminal polish (P1, S). Partial.** Hive theme colours and Nerd Font fallback are in place.
   Next: ⌘F find in scrollback, ⌘-click to open links and file paths, and secure keyboard entry.
9. **Focus filters (P2, S). Next.** Mute notifications from chosen environments during a Focus mode.

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
editable, declarative layouts and views, and keep executable extensions out of scope while M9
remains skipped.

---

## Keyboard map (desktop equivalents)

| Action | TUI | Desktop |
| --- | --- | --- |
| New tab | `Ctrl+B c` | ⌘T |
| Split right / down | `Ctrl+B %` / `"` | ⌘D / ⇧⌘D |
| Move between panes | `Ctrl+B ←↑→↓` | ⌥⌘←↑→↓ |
| Next / previous tab | `Ctrl+B n` / `p` | ⌃Tab / ⌃⇧Tab |
| Jump to tab 1–9 | `Ctrl+B 1–9` | ⌘1–⌘9 |
| Zoom pane | `Ctrl+B z` | ⇧⌘↩ |
| Close pane | `Ctrl+B x` | ⌘W |
| Find agent or pane | `Ctrl+B w` | ⌘K |
| Overview | `Ctrl+B O` | ⇧⌘O |
| Show / hide sidebar | `Ctrl+B b` | ⌃⌘S |
| Plugin palette | `Ctrl+B :` / `P` | ⇧⌘P |
| Copy mode / paste | `Ctrl+B [` / `]` | Native selection, ⌘C / ⌘V |
| Paste image into agent | `Ctrl+B I` | ⌘V with an image on the clipboard |
| Detach | `Ctrl+B d` | Close the window; agents keep running |
| Show key bindings | `Ctrl+B ?` | Help menu → Keyboard Shortcuts |

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
  signals for Kill Ports). Mac App Store distribution would need a helper tool. Decide before M10.

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
