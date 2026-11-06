# Hive Desktop

<p align="center"><img src="hive/Assets.xcassets/HiveMark.imageset/hive-mark.svg" alt="Hive" width="96"></p>

The native macOS command center for [Hive](https://github.com/admirable-oss/hive), the runtime that keeps your coding agents (Claude Code, Codex, OpenCode and others) running in the background. Hive Desktop shows the same workspace as Hive's terminal multiplexer: environments, tabs, split panes and agents. It adds what a Mac does well: notifications you can act on, a menu bar extra, Shortcuts, Spotlight, Finder and your editor.

## Install

Download `Hive-<version>.dmg` from the [latest release](https://github.com/admirable-oss/hive-macos/releases/latest), open it and drag Hive to Applications. Or use Homebrew:

```sh
brew install --cask admirable-oss/tap/hive-desktop
```

On first launch, Hive Desktop looks for the `hive` runtime and offers to install it with the [official installer](https://hive.admir-saheta.com/docs/getting-started/installation), which checks Hive's release signature and checksum before writing to `~/.local/bin`. You can also point it at an existing `hive`.

### Requirements

- macOS 14 Sonoma or later
- Hive 1.x speaking protocol 2, API level 5 or later (any Hive 1.0 release or newer)

## Updates

Hive Desktop updates itself from this repository's GitHub releases (**Hive → Check for Updates…**, and daily if you leave automatic checks on). An update installs only after:

1. the release's `checksums.txt` carries a valid SSH signature from the Hive release key, the same check Hive's own installer makes;
2. the downloaded app matches its checksum there;
3. the new app is signed by the same Developer ID team, notarized and accepted by Gatekeeper.

The version it replaces is kept. If the new version doesn't start, it's put back automatically, and **Restore** in the Updates settings puts it back by hand. Updating never stops your agents: they run in Hive's daemon, not in the app.

## Compatibility policy

- **Versions.** Hive Desktop follows semantic versioning. Every 1.x release works with every Hive 1.x runtime that speaks protocol 2 at API level 5 or later.
- **Mismatches.** When the app and the runtime are on different versions, a banner says so. A feature the runtime doesn't offer yet shows Hive's error instead of failing silently.
- **Newer runtimes.** The app ignores fields and events it doesn't know, so a newer runtime never breaks it. Updating either side never needs the other restarted, and never stops agents.
- **Your settings.** Saved tabs, settings and saved views carry forward through every 1.x release.
- **Removals.** Anything removed in a later 1.x is announced one minor release ahead, in the release notes.
- **macOS.** Each release supports the current macOS and the two before it, back to macOS 14.

## Not sandboxed, by design

Hive Desktop is distributed outside the Mac App Store, signed with Developer ID, notarized and built with the hardened runtime. It isn't App Sandbox restricted. It starts the shells and SSH sessions you open, talks to Hive's Unix socket, runs `hive` and `git`, and sends signals for **Kill Ports**. The App Sandbox would need a privileged helper for all of that, and would add little: the app acts only on what you ask it to, in your account. A Mac App Store edition isn't planned.

## Verifying a download

Each release has `checksums.txt` and its SSH signature, `checksums.txt.sshsig`, made with Hive's release key:

```sh
echo 'hive-release namespaces="hive-release" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILHcqXlEfCE8NSz4faSoF7WWzUrakzdnGNT4fFEWlNm1' > allowed_signers
ssh-keygen -Y verify -f allowed_signers -I hive-release -n hive-release -s checksums.txt.sshsig < checksums.txt
shasum -a 256 -c checksums.txt --ignore-missing
```

## Build from source

Open `hive.xcodeproj` in Xcode 26 or later, choose the `hive` scheme and run it on My Mac. From Terminal:

```sh
xcodebuild -project hive.xcodeproj -scheme hive -destination 'platform=macOS' -skipPackagePluginValidation build
xcodebuild -project hive.xcodeproj -scheme hive -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:hiveTests CODE_SIGNING_ALLOWED=NO test
```

The tests include the performance budgets CI holds: keystroke-to-screen p99, memory and idle CPU with sixteen streaming panes (`hiveTests/PerformanceBudgetTests.swift`). A build from source can't update itself; updates need a signed release.

## Project structure

```text
hive/
  Models/       Hive's workspace as the daemon describes it
  Services/     The socket client and store, the CLI, git, ports, updates, deep links
  ViewModels/   App state and actions
  Views/        SwiftUI interface
  Intents/      Shortcuts, Spotlight, Siri and the Focus filter
Support/        Info.plist additions and export options
scripts/release Build, notarize, package and sign a release (see docs/RELEASING.md)
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and the [roadmap](ROADMAP.md). Hive's runtime, protocol and broader documentation live in the [main Hive repository](https://github.com/admirable-oss/hive).

## Security

Please see [SECURITY.md](SECURITY.md) for reporting vulnerabilities.

## License

Hive Desktop is licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
