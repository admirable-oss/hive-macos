# Contributing

Thanks for helping build the native macOS app for Hive.

## Development setup

Use Xcode 26.4 or later on macOS 26.2 or later. Open `hive.xcodeproj`, select the `hive` scheme, and run on My Mac. Its one package dependency, SwiftTerm, comes through Swift Package Manager; from the command line, pass `-skipPackagePluginValidation` so Xcode runs SwiftTerm's build plugin. Run the unit tests, including the performance budgets, before opening a pull request (see the README).

## Changes

- Keep changes focused and follow the existing SwiftUI and MVVM structure.
- Keep daemon and protocol work behind the service layer.
- Include a clear description of user-visible behavior and the steps used to verify it.
- Do not include credentials, local configuration, or generated Xcode files in commits.
- For changes to Hive's runtime protocol, coordinate with the [main Hive repository](https://github.com/admirable-oss/hive) and its compatibility policy.

## Pull requests

Open a pull request with the problem, the approach, and any screenshots for interface changes. Link related issues and call out any protocol or compatibility impact.

By submitting a contribution, you agree that it is provided under the repository's Apache 2.0 license.
