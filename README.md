# Hive for macOS

<p align="center"><img src="hive/Assets.xcassets/HiveMark.imageset/hive-mark.svg" alt="Hive" width="96"></p>

The native macOS companion for [Hive](https://github.com/admirable-oss/hive), the agent runtime. This repository is the SwiftUI app foundation; it will connect to the existing Hive runtime so environments and agents can be managed from a native Mac app.

## Status

Early development. The project currently provides a native SwiftUI shell, an MVVM structure, and the runtime client boundary. Runtime operations are not connected yet.

## Requirements

- macOS 26.2 or later
- Xcode 26.4 or later

## Build and run

Open `hive.xcodeproj` in Xcode, choose the `hive` scheme, and run it on My Mac. To build from Terminal:

```sh
xcodebuild -project hive.xcodeproj -scheme hive -destination 'platform=macOS' build
```

## Project structure

```text
hive/
  Models/       App sections and runtime state
  Services/     Runtime client boundary
  ViewModels/   App state and actions
  Views/        SwiftUI interface
  Assets.xcassets/
```

Views use observable view models, and runtime access is kept behind `RuntimeClient` so the transport can be added without coupling the interface to daemon details.

## First launch

The app looks for a working `hive` executable on launch and runs `hive version` to confirm it. If it cannot confirm one, it offers to install Hive using the [official installer](https://hive.admir-saheta.com/docs/getting-started/installation), or lets you select an existing executable. The installer verifies release signatures and checksums before writing to `~/.local/bin` by default.

The app is not App Sandbox restricted so the user initiated installer can write to that per-user location. The installer runs only after selecting **Install Hive for me**.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Hive's runtime, protocol, and broader documentation live in the [main Hive repository](https://github.com/admirable-oss/hive).

## Security

Please see [SECURITY.md](SECURITY.md) for reporting vulnerabilities.

## License

Hive for macOS is licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
