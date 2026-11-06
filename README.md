<p align="center">
  <img src="https://9lv0ptfqwc.ufs.sh/f/Ct83ioyjHOfENMZX8ewdYpswjne6l2VQiGOf7z53XWRtkTUu" alt="Hive" width="160px" />
</p>
<p align="center">
  <img src="https://9lv0ptfqwc.ufs.sh/f/Ct83ioyjHOfEnlhYREXGahkPT9wIcdlGmYZKCQMWiD6ESrU0" alt="Hive" width="100px" />
</p>
<h3 align="center">The native command center for Hive agents</h3>
<p align="center">Your agents keep working. You get a Mac app to see what they’re doing.</p>

<p align="center">
  <a href="https://github.com/admirable-oss/hive-macos/releases/latest"><img src="https://img.shields.io/github/v/release/admirable-oss/hive-macos?color=%23F5B942" alt="Latest release" /></a>
  <a href="https://github.com/admirable-oss/hive-macos/commits/main"><img src="https://img.shields.io/github/last-commit/admirable-oss/hive-macos" alt="Last commit" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache%202.0-%23F5B942" alt="Apache 2.0 license" /></a>
</p>

Hive Desktop is the native macOS companion to [Hive](https://github.com/admirable-oss/hive), the runtime that keeps coding agents alive in the background. See environments, tabs, split panes and agent activity in one place, then jump in when an agent needs you.

## What you can do

- **See your workspace at a glance.** Browse environments, tabs, split panes and live agent terminals from one dashboard.
- **Pick up where agents are working.** Follow agent state, read and export transcripts, and review Git changes with diffs and staging.
- **Keep Hive close.** Check agent status and take common actions from the menu bar; get actionable notifications and a Dock badge when an agent is blocked.
- **Move between tools.** Open workspaces in Finder or your editor, and use Shortcuts, Spotlight and configurable keyboard shortcuts.
- **Connect to remote Hive runtimes.** Work with agents running on another machine over SSH.
- **Keep agents running through app updates.** Hive Desktop connects to the separate Hive daemon, so closing or updating the app does not stop agents.

## Install

Download `Hive-<version>.dmg` from the [latest release](https://github.com/admirable-oss/hive-macos/releases/latest), open it and drag Hive to Applications. Or install with Homebrew:

```sh
brew install --cask admirable-oss/tap/hive-desktop
```

On first launch, Hive Desktop looks for the `hive` runtime and offers to install it with the [official installer](https://hive.admir-saheta.com/docs/getting-started/installation). The installer verifies the runtime's release signature and checksum before writing to `~/.local/bin`. You can also select an existing `hive` executable.

### Requirements

- macOS 14 Sonoma or later
- Hive 1.x speaking protocol 2, API level 5 or later

## Updates and compatibility

Hive Desktop checks this repository's GitHub releases for updates (**Hive → Check for Updates…**, and daily when automatic checks are enabled). It installs only a release whose signed checksum manifest verifies, whose app checksum matches, and whose Developer ID signature and notarization pass Gatekeeper.

The updater keeps the replaced app. If the new version does not start within 30 seconds, it restores the previous version automatically; you can also choose **Settings → Updates → Restore**. Updating the desktop app never stops agents because they run in Hive's daemon.

Hive Desktop follows semantic versioning. Every 1.x release works with Hive 1.x runtimes that speak protocol 2 at API level 5 or later. When the app and runtime differ, the app shows a compatibility notice; unsupported runtime features report an error instead of failing silently. New fields and events are ignored, and updating either side does not require restarting the other.

## Security model

Hive Desktop is distributed outside the Mac App Store, signed with Developer ID, notarized and built with the hardened runtime. It is not restricted by App Sandbox: it starts shells and SSH sessions you open, talks to Hive's Unix socket, runs `hive` and `git`, and sends signals for **Kill Ports**. The app acts on your account and on actions you request. A Mac App Store edition is not planned.

### Verify a download

Each release includes `checksums.txt` and its SSH signature, `checksums.txt.sshsig`, made with Hive's release key:

```sh
echo 'hive-release namespaces="hive-release" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILHcqXlEfCE8NSz4faSoF7WWzUrakzdnGNT4fFEWlNm1' > allowed_signers
ssh-keygen -Y verify -f allowed_signers -I hive-release -n hive-release -s checksums.txt.sshsig < checksums.txt
shasum -a 256 -c checksums.txt --ignore-missing
```

## Build from source

Use Xcode 26.4 or later on macOS 26.2 or later. Open `hive.xcodeproj`, choose the `hive` scheme and run it on My Mac. From Terminal:

```sh
xcodebuild -project hive.xcodeproj -scheme hive -destination 'platform=macOS' -skipPackagePluginValidation build
xcodebuild -project hive.xcodeproj -scheme hive -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:hiveTests CODE_SIGNING_ALLOWED=NO test
```

The tests include CI performance budgets for keystroke-to-screen latency, memory and idle CPU with sixteen streaming panes (`hiveTests/PerformanceBudgetTests.swift`). A source build cannot update itself; updates require a signed release.

## Project structure

```text
hive/
  Models/       Hive's workspace as the daemon describes it
  Services/     Socket client, store, CLI, Git, ports, updates and deep links
  ViewModels/   App state and actions
  Views/        SwiftUI interface
  Intents/      Shortcuts, Spotlight, Siri and Focus filter
Support/        Info.plist additions and export options
scripts/release Build, notarize, package and sign a release
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and the [roadmap](ROADMAP.md). Hive's runtime, protocol and broader documentation live in the [main Hive repository](https://github.com/admirable-oss/hive). For release steps, see [docs/RELEASING.md](docs/RELEASING.md).

## Security

Please see [SECURITY.md](SECURITY.md) for reporting vulnerabilities.

## License

Hive Desktop is licensed under the [Apache License, Version 2.0](LICENSE).
