# Releasing Hive Desktop

Pushing a tag like `v1.0.0` runs [`.github/workflows/release.yml`](../.github/workflows/release.yml). It:

1. builds and signs the app with Developer ID;
2. notarizes and staples the app;
3. packages a disk image and a zip;
4. notarizes the disk image;
5. writes `checksums.txt` and signs it with the release SSH key;
6. writes the Homebrew cask;
7. publishes a GitHub release with all of it.

A tag with a hyphen (`v1.1.0-rc.1`) is published as a pre-release. The in-app updater and the Homebrew tap skip pre-releases.

## One-time setup

Add these as repository secrets (**Settings → Secrets and variables → Actions**):

| Secret | What it is |
| --- | --- |
| `APPLE_TEAM_ID` | The Apple Developer team ID that owns the Developer ID certificate. |
| `DEVELOPER_ID_P12_BASE64` | The "Developer ID Application" certificate and its private key, exported from Keychain Access as a `.p12`, then `base64 -i cert.p12`. |
| `DEVELOPER_ID_P12_PASSWORD` | The password you gave the `.p12`. |
| `APPLE_ID` | The Apple ID that submits for notarization. |
| `APPLE_APP_PASSWORD` | An [app-specific password](https://support.apple.com/102654) for that Apple ID. |
| `RELEASE_SSH_KEY` | The private half of the Hive release key, as an OpenSSH private key file's contents. |
| `HOMEBREW_TAP_TOKEN` | Optional. A token that can push to the tap repository; without it the cask is only attached to the release. |

The tap repository defaults to `admirable-oss/homebrew-tap`; set the `HOMEBREW_TAP_REPOSITORY` variable to use another.

### The release key

The app installs an update only if `checksums.txt.sshsig` verifies against `HiveReleaseAllowedSigners` in [`Support/Hive-Info.plist`](../Support/Hive-Info.plist). That line holds Hive's release key, the same one Hive's `install.sh` trusts, so one key signs both projects' releases. To use a separate key for the desktop app:

1. Make it: `ssh-keygen -t ed25519 -C hive-desktop-release -f hive-desktop-release`.
2. Put its public half in `HiveReleaseAllowedSigners` as `hive-release namespaces="hive-release" ssh-ed25519 AAAA…`.
3. Ship that build *before* releases are signed with the new key. Copies already installed only trust the key they shipped with.

## Cutting a release

1. Make sure CI is green on `main`, including the performance budgets.
2. Tag and push: `git tag v1.0.0 && git push oss v1.0.0`.
3. Watch the **Release** workflow. When it's done, check the release page for `Hive-1.0.0.dmg`, `Hive-1.0.0.zip`, `checksums.txt`, `checksums.txt.sshsig` and `hive-desktop.rb`.
4. On a Mac running the previous release, **Hive → Check for Updates…** should offer and install it.

The version comes from the tag: `MARKETING_VERSION` in the project is only used for local builds. The build number is the workflow's run number.

## Doing it by hand

Each step is a script you can run locally, in order:

```sh
VERSION=1.0.0 BUILD_NUMBER=1 TEAM_ID=ABCDE12345 scripts/release/build.sh
APPLE_ID=… APPLE_TEAM_ID=… APPLE_APP_PASSWORD=… scripts/release/notarize.sh build/export/Hive.app
VERSION=1.0.0 TEAM_ID=ABCDE12345 scripts/release/package.sh
APPLE_ID=… APPLE_TEAM_ID=… APPLE_APP_PASSWORD=… scripts/release/notarize.sh build/release/Hive-1.0.0.dmg
RELEASE_SSH_KEY=~/.ssh/hive-release scripts/release/checksums.sh build/release
VERSION=1.0.0 scripts/release/cask.sh build/release > build/release/hive-desktop.rb
```

## If an update goes wrong

The updater keeps the replaced version in `~/Library/Application Support/Hive Desktop/Previous/`. If the new version doesn't start within 30 seconds, the helper puts the previous version back on its own. Its log is `~/Library/Application Support/Hive Desktop/update.log`. People can also go back with **Settings → Updates → Restore**.

To pull a bad release, delete it (or mark it a pre-release) on GitHub; the updater only looks at the latest full release. Then publish a fixed version with a higher number.
