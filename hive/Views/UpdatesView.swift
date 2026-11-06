import AppKit
import SwiftUI

/// Software update: this version, the latest release and its notes, installing it, and putting
/// the previous version back. Shown in its own window and in Settings.
struct UpdatesView: View {
    @ObservedObject private var updater = AppUpdater.shared
    @AppStorage(AppUpdater.automaticChecksKey) private var automaticChecks = true
    @State private var confirmingRestore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image("HiveMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hive Desktop \(updater.currentVersion)")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text(statusLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
                Spacer()
                Button("Check Now") { Task { await updater.check() } }
                    .buttonStyle(.hive)
                    .disabled(isBusy)
            }

            content

            Divider().opacity(0.5)

            Toggle("Check for updates automatically", isOn: $automaticChecks)
            Text("Updates come from Hive’s GitHub releases. Each one is checked against the Hive release key, its checksum and its Developer ID signature before it installs. Updating restarts the app, not your agents: they keep running in Hive’s daemon.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let previous = updater.previousVersion {
                HStack {
                    Text("Version \(previous) is kept in case you need it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore \(previous)…") { confirmingRestore = true }
                        .buttonStyle(.hiveCompact)
                }
            }
        }
        .padding(20)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: updater.state)
        .confirmationDialog("Go back to version \(updater.previousVersion ?? "")?", isPresented: $confirmingRestore, titleVisibility: .visible) {
            Button("Restore and Relaunch") { updater.restorePreviousVersion() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hive Desktop quits, the previous version takes its place, and it opens again. Your agents keep running.")
        }
    }

    private var isBusy: Bool {
        switch updater.state {
        case .checking, .downloading, .verifying, .installing: true
        default: false
        }
    }

    private var statusLine: String {
        switch updater.state {
        case .idle: updater.lastChecked.map { "Last checked \($0.formatted(.relative(presentation: .named)))" } ?? "Not checked yet"
        case .checking: "Checking…"
        case .upToDate: "You’re up to date."
        case .available(let release): "Version \(release.version) is available."
        case .downloading(let release, _): "Downloading \(release.version)…"
        case .verifying(let release): "Checking \(release.version)’s signatures…"
        case .installing(let release): "Installing \(release.version)…"
        case .failed: "Something went wrong."
        }
    }

    @ViewBuilder
    private var content: some View {
        switch updater.state {
        case .available(let release):
            releaseCard(release)
        case .downloading(_, let fraction):
            ProgressView(value: fraction)
        case .verifying, .installing:
            ProgressView().controlSize(.small)
        case .failed(let message):
            HiveNotice(text: message)
        default:
            EmptyView()
        }
    }

    private func releaseCard(_ release: AppUpdater.Release) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                Text((try? AttributedString(markdown: release.notes.isEmpty ? "No release notes." : release.notes,
                                            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(release.notes))
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 180)
            .hiveCard(padding: 10)

            if let blocker = updater.installBlocker {
                HiveNotice(text: blocker, kind: .info)
            }
            HStack {
                Button("Release Page") { NSWorkspace.shared.open(release.pageURL) }
                    .buttonStyle(.hive)
                Spacer()
                if updater.installBlocker == nil {
                    Button { Task { await updater.install(release) } } label: {
                        Label("Install and Relaunch", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.hivePrimary)
                } else {
                    Button { NSWorkspace.shared.open(release.pageURL) } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.hivePrimary)
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// Hive → Check for Updates…: opens the Software Update window and checks.
struct CheckForUpdatesCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Check for Updates…") {
            openWindow(id: "updates")
            Task { await AppUpdater.shared.check() }
        }
    }
}
