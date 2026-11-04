# Hive Desktop Roadmap

This roadmap compares the native macOS app with the Hive terminal multiplexer (the TUI) and the
runtime features documented at [hive.admir-saheta.com/docs](https://hive.admir-saheta.com/docs),
and lays out what to build next, in order.

The aim isn't to redraw the TUI in AppKit. The aim is for the desktop app to do everything the TUI
can, and then do what only a Mac app can: notifications, Quick Look, drag and drop, the menu bar,
Shortcuts.

Legend: ✅ shipped · 🟡 partial · ❌ missing — Priority **P0** (next) → **P2** (later) — Size **S / M / L**

---

## Where the desktop app is today

| Area | Status | Notes |
| --- | --- | --- |
| First launch: find, verify or install `hive` | ✅ | Runs the install script and remembers the binary |
| Onboarding | ✅ | |
| Sidebar: environments and agents with live state | ✅ | Socket API snapshot plus the `events` stream; no polling |
| Create environment from an existing folder | ✅ | Can't create Hive-managed workspaces yet |
| Start / stop agent, kill agent and close pane | ✅ | Right-click menus |
| Remove environment (with confirmation) | ✅ | |
| Terminal tabs (local zsh, or an agent over `terminal.attach`) | 🟡 | SwiftTerm. Restored on relaunch, but they're the app's own tabs, not Hive's |
| Files panel following the shell's `cd`, Quick Look previews | ✅ | Desktop only |
| Changes panel (git status) | 🟡 | Desktop only. Read-only: no diff, stage or commit |
| Kill listening ports per environment | ✅ | Desktop only |
| Add machine | 🟡 | Can add one; can't list, check, switch to or remove machines |
| App appearance (light/dark) | 🟡 | Only setting; `config.toml` isn't editable |

---

## Gaps against the TUI and runtime

### Workspace (tabs, panes, layouts)

| TUI / runtime feature | Desktop | Priority | Size |
| --- | --- | --- | --- |
| Hive tabs as the source of truth (`tab create/list/rename/focus/close`) | ❌ App-local tabs only | P0 | L |
| Split right / down (`Ctrl+B %` / `"`), `pane split` | ❌ | P0 | L |
| Move between panes (`Ctrl+B ←↑→↓`), resize mode, drag borders | ❌ | P0 | M |
| Zoom a pane (`Ctrl+B z`), close a pane (`Ctrl+B x`) | ❌ | P0 | S |
| Jump to tab 1–9, next/previous tab | 🟡 Click only | P0 | S |
| Rename tabs and panes, pane titles and tokens (`metadata`) | ❌ | P1 | S |
| Popups (`pane popup`), floating panes | ❌ | P2 | M |
| Move a pane to another tab or environment, swap panes | ❌ | P2 | M |
| Layout export / apply (JSON) | ❌ | P1 | M |
| Overview (`Ctrl+B O`) | ❌ | P1 | M |
| Find an agent or pane (`Ctrl+B w`) | 🟡 Sidebar search | P0 | S |

### Agents

| TUI / runtime feature | Desktop | Priority | Size |
| --- | --- | --- | --- |
| States: working, blocked, done, idle, exited | ✅ | — | — |
| Live updates (`events` stream) instead of polling | ✅ | — | — |
| Notifications on state changes (`[notify]`) | ❌ | P0 | M |
| Explain a state (`agent explain`: rule matched, reports, screen) | ❌ | P1 | S |
| Send a prompt, optionally wait for the answer (`agent prompt`, `wait`) | ❌ | P1 | M |
| Send keys (approve / deny a blocked agent: `y`, Enter, Esc) | ❌ | P0 | S |
| Install agent hooks for precise state and resume (`integration install`) | ❌ | P1 | S |
| Resume a conversation (session ID or latest) | ❌ | P1 | S |
| Rename an agent's pane | ❌ | P2 | S |
| Paste a clipboard image into an agent (`Ctrl+B I`) | ❌ | P0 | M |
| Agent manifests (which CLIs Hive knows) | 🟡 Start sheet only | P2 | S |

### Worktrees and tasks

| TUI / runtime feature | Desktop | Priority | Size |
| --- | --- | --- | --- |
| Worktree create / list / open / remove (an agent per branch) | ❌ | P1 | M |
| Tasks: run a plan, approve, cancel, retry, wait, report | ❌ | P1 | L |
| Plan report: per-task outcome, changed files, summary | ❌ | P1 | M |

### Persistence and sessions

| TUI / runtime feature | Desktop | Priority | Size |
| --- | --- | --- | --- |
| Survives detach / daemon restart (shims) | ✅ Inherited from the runtime | — | — |
| Restore desktop tabs on relaunch | ✅ | — | — |
| Session save / restore / restore `--fresh` | ❌ | P2 | S |
| Several sessions (separate daemons) | ❌ | P2 | M |
| History replay after restore (`session.replay_history`) | ❌ | P2 | S |
| Garbage collection (`gc`, `--dry-run`) | ❌ | P2 | S |

### Remote machines

| TUI / runtime feature | Desktop | Priority | Size |
| --- | --- | --- | --- |
| Saved machines in the sidebar with their agents | ❌ | P1 | L |
| Machine status / reconnect / enable / disable / rename / remove | ❌ | P1 | S |
| Discover runtimes on the local network, pair, revoke | ❌ | P1 | M |
| One-off commands against a machine (`--machine`, `--remote`) | ❌ | P1 | M |
| Observer credentials (create, revoke, audit), web observer | ❌ | P2 | M |

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
| `[terminal]` shell, size, scrollback | ❌ | P1 | S |
| `[notify]` which states notify, per-agent rules | ❌ | P0 | S |
| `[theme]` (also used for the desktop terminals) | ❌ | P1 | M |
| `[keys]` prefix and bindings | n/a | — | — |
| `[remote]` frame / image budgets, `[retention]`, `[worktrees].directory` | ❌ | P2 | S |
| `[plugins]` policy (allow/deny capabilities) | ❌ | P2 | S |
| Version check and `hive update` | ❌ | P1 | S |

`[keys]` is TUI-only. The desktop app should use standard Mac shortcuts instead (see the end of this file).

---

## Plan

### Phase 0: Foundation ✅

Shipped. Everything else builds on it.

- `HiveSocketClient`: protocol 2 over the Unix socket (hello/welcome, requests matched by ID, base64 pipes).
- `HiveWorkspaceStore`: snapshot on connect, then events applied as they arrive. Reconnects with backoff and
  starts the daemon if it isn't running.
- Agent tabs use `terminal.attach` and `terminal.resize`.
- Desktop tabs (and each shell's last folder), the inspector panel and sidebar sections are restored on relaunch.
- What still uses the CLI: `machine add`, which has no socket method yet.
- Follow-ups:
  - The protocol 1 fallback isn't implemented. Every daemon at API level 5 or later speaks protocol 2.
  - `pane.closed` and unknown events trigger a debounced re-snapshot rather than an exact update.

The original plan:

1. **Native socket client.** Talk to the daemon over its Unix socket (protocol 2, with protocol 1
   as fallback) instead of starting `hive` processes. Model `api snapshot` once, then apply changes
   from the `events` stream.
   - Gets rid of the 8 s polling and the three processes started each time.
   - State updates arrive the moment they happen.
   - Unknown methods and fields are ignored, so the app keeps working across 1.x releases.
2. **One workspace store.** A single observable store of machines → sessions → environments →
   tabs → panes → processes/agents, which every view reads. The tab model in `AppViewModel` moves
   onto it.
3. **Terminal attach over the socket.** Use the `terminal attach` stream instead of spawning
   `hive agent attach` inside a pseudo-terminal. Resizes come from the view, so there is one PTY,
   not two.
4. **Restore desktop state on relaunch.** Open tabs, sidebar sections, the inspector panel and the
   window frame.

### Phase 1: TUI parity for daily use (P0–P1)

**Status: Complete (2026-11-04).**

1. **Hive tabs and panes, natively.** Desktop tabs are Hive tabs, so the TUI and the app always show
   the same workspace.
   - Each pane is its own SwiftTerm view inside a native split view.
   - Split, close, zoom, resize, move focus, and rename all go through the `tab` and `pane` APIs.
2. **Notifications that let you act.** Notify on `blocked` and `done` according to `[notify]`.
   - Buttons on the notification: *Approve*, *Deny*, *Open*, which send keys to the agent.
   - A Dock badge with the number of blocked agents, plus a bounce when something needs you.
3. **Quick switcher (⌘K).** Fuzzy search across agents, panes, tabs, environments and machines.
   This is the desktop version of `Ctrl+B w`.
4. **Overview.** A grid of live, read-only pane thumbnails for every agent, grouped by environment
   and sorted with blocked first. Click one to jump to it.
5. **Paste images into agents.** ⌘V with an image on the clipboard, or dragging an image onto an
   agent pane, uses Hive's image paste.
6. **Agent inspector.** A third inspector panel next to Files and Changes, showing:
   - The state and why (`agent explain`), the reason text, and the session ID.
   - Resume and stop buttons.
   - A prompt box (`agent prompt`, with an optional "wait for the answer").

### Phase 2: Agent workflows (P1)

**Status: Complete (2026-11-04).**

1. **Worktrees.** "New Worktree…" from an environment's right-click menu:
   - Pick a branch, create the worktree and its environment, and optionally start an agent in it.
   - The sidebar groups worktree environments under their repository.
2. **Tasks and plans.**
   - Open or drop a plan file to run it.
   - Show the task graph with live states.
   - Approve, deny, cancel or retry a task in place.
   - The report view shows changed files, with click-through into the Changes diff.
3. **Agent integrations.** One-click hook installs in Settings and in onboarding
   (`integration install`), showing what each one changes and how to uninstall it.
4. **Layouts.** Export the current workspace as a layout file, and apply one with a preview sheet.

### Phase 3: Remote machines (P1)

**Status: Complete (2026-11-04).**

1. **Machines in the sidebar. Complete.**
   - Each saved machine has its own section with connection status and its agents.
   - Right-click: reconnect, disable, rename, remove.
2. **Discover and pair. Complete.** A Bonjour-style "Nearby" list (`machine discover`).
   - Pairing shows the runtime's identity to confirm before trusting it.
   - Paired machines can be revoked.
3. **Run anywhere. Complete.** Create environments and start agents on a saved machine, inspect
   remote agents, attach to remote agent terminals through the machine proxy, and open an SSH shell.
4. **Observers. Complete.** Create, revoke and audit read-only credentials, and open the web observer.

### Phase 4: Extensibility (P1–P2)

1. **Plugin palette (⌘⇧P).** Runs plugin actions and palette entries; async actions show progress.
2. **Plugin UI contributions.**
   - Sidebar cards render as native card views.
   - Tab-bar indicators appear on tab pills.
   - Contextual actions appear in the right-click menus.
3. **App Store.** Browse, install, update and roll back plugins. Before installing, a native
   consent sheet lists the plugin's required and optional capabilities. A plugin health view shows
   lifecycle state and `doctor` output.

### Phase 5: Settings, sessions and upkeep (P1–P2)

1. **Settings window for `config.toml`.** Tabs for General, Terminal, Notifications, Theme, Remote,
   Worktrees and Plugins. Writes back to the file and shows the runtime's validation warnings
   inline.
2. **Sessions.** Switch between sessions, save, restore and restore `--fresh`.
3. **Upkeep.** Version mismatch banner and `hive update`; `gc` with a dry-run preview; daemon
   start, stop and health.

---

## Best desktop-only features

These are what make the app worth opening instead of the TUI, ranked by value for effort.

1. **Menu bar extra (P0, M).** Every agent's state at a glance, plus one-click approve/deny for
   blocked agents. The menu bar icon tints amber when something needs you. It keeps working with
   the main window closed.
2. **Actionable notifications and Dock badge (P0, M).** Described in Phase 1. Approve a blocked
   agent without leaving the app you're in.
3. **Diffs in the Changes panel (P1, M).** Side-by-side or inline diffs, stage or unstage files and
   hunks, and a commit box. Quick Look covers new files.
4. **Drag and drop (P1, S).**
   - Drop a folder on the sidebar to create an environment.
   - Drop files into a terminal to type their paths.
   - Drop a plan file to run it.
   - Drop an image on an agent to paste it.
5. **Shortcuts and App Intents (P1, M).**
   - Actions: *Start agent*, *Prompt agent*, *Wait for agent*, *List blocked agents*,
     *Open environment*.
   - Works from Spotlight, Siri and the Shortcuts app.
6. **Finder integration (P2, S).** A Services menu or Finder extension item, "Open in Hive" /
   "New Hive Environment Here", and a `hive://` URL scheme for deep links to agents and panes.
7. **Open in editor (P2, S).** From Files and Changes, open in the user's editor (VS Code, Cursor,
   Xcode, Zed) at the right line.
8. **Terminal polish (P1, S).**
   - Hive theme colours in the desktop terminals.
   - A bundled Nerd Font symbols fallback, so prompt icons render without installing a font.
   - ⌘F find in scrollback, ⌘-click to open links and file paths, and secure keyboard entry.
9. **Focus filters (P2, S).** Mute notifications from chosen environments during a Focus mode.

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
  signals for Kill Ports). Mac App Store distribution would need a helper tool. Decide before Phase 3.
