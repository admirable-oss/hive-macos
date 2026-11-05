import AppKit
import SwiftUI

struct ObserverManagerView: View {
    let workspace: HiveWorkspaceStore
    let cli: HiveCLIService
    @Environment(\.dismiss) private var dismiss
    @State private var observers: HiveObserverList?
    @State private var audit: [HiveObserverAuditEntry] = []
    @State private var name = ""
    @State private var ttlHours = 24
    @State private var screens = false
    @State private var allEnvironments = true
    @State private var selectedEnvironments: Set<String> = []
    @State private var created: HiveObserverCreated?
    @State private var webURL: String?
    @State private var errorMessage: String?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HiveSheetHeader(
                symbol: "eye",
                title: "Web observers",
                subtitle: "Read-only browser access to selected environments.",
                onClose: { dismiss() }
            ) {
                Button { Task { await openWeb() } } label: { Label("Open Web Observer", systemImage: "safari") }
                    .buttonStyle(.hivePrimary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let created { createdCard(created) }
                    newCredential
                    credentials
                    auditLog
                    if let errorMessage { HiveNotice(text: errorMessage) }
                }
                .padding(20)
                .animation(.spring(response: 0.32, dampingFraction: 0.85), value: created?.token)
                .animation(.spring(response: 0.32, dampingFraction: 0.85), value: allEnvironments)
                .animation(.spring(response: 0.32, dampingFraction: 0.85), value: errorMessage)
            }
        }
        .frame(width: 700, height: 650)
        .task { await reload() }
    }

    private func createdCard(_ created: HiveObserverCreated) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Credential created", systemImage: "checkmark.seal.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green)
            Text("Copy this token now. Hive only shows it once.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(created.token)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(created.token, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(HiveIconButtonStyle(size: 26))
                .help("Copy token")
            }
            Text("Credential: \(created.credential.name) · expires \(created.credential.expiresAt)")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button("I’ve copied the token") { self.created = nil; Task { await reload() } }
                .buttonStyle(.hiveCompact)
        }
        .hiveCard(padding: 14, tint: .green)
        .transition(.scale(scale: 0.97).combined(with: .opacity))
    }

    private var newCredential: some View {
        VStack(alignment: .leading, spacing: 10) {
            HiveSectionTitle(title: "New credential", symbol: "key")
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    TextField("Credential name", text: $name)
                        .textFieldStyle(.hive)
                        .frame(maxWidth: 240)
                    Picker("Expires", selection: $ttlHours) {
                        Text("1 hour").tag(1); Text("24 hours").tag(24); Text("7 days").tag(168); Text("30 days").tag(720)
                    }
                    .frame(width: 150)
                    Spacer(minLength: 0)
                    Button { Task { await create() } } label: { Label("Create", systemImage: "plus") }
                        .buttonStyle(.hivePrimary)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || loading)
                }
                HStack(spacing: 16) {
                    Toggle("Allow screenshots", isOn: $screens).toggleStyle(.switch).controlSize(.mini)
                    Toggle("All environments", isOn: $allEnvironments).toggleStyle(.switch).controlSize(.mini)
                }
                .font(.system(size: 12))
                if !allEnvironments {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(workspace.environments) { environment in
                            Toggle(isOn: Binding(
                                get: { selectedEnvironments.contains(environment.id) },
                                set: { if $0 { selectedEnvironments.insert(environment.id) } else { selectedEnvironments.remove(environment.id) } }
                            )) {
                                HStack(spacing: 8) {
                                    EnvironmentAvatar(name: environment.name.isEmpty ? environment.id : environment.name, size: 16)
                                    Text(environment.name).font(.system(size: 12))
                                    Text(environment.path).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .hiveCard(padding: 14)
        }
    }

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HiveSectionTitle(title: "Credentials", symbol: "person.badge.key", count: observers?.credentials.count)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(HiveIconButtonStyle())
                    .help("Refresh")
            }
            if observers?.enabled == false {
                HiveNotice(text: "Observer credentials are disabled in the runtime configuration.", kind: .info)
            }
            if (observers?.credentials ?? []).isEmpty {
                Text("No credentials yet.").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            ForEach(observers?.credentials ?? []) { credential in
                HStack(spacing: 10) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.hiveAmber)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(credential.name).font(.system(size: 12.5, weight: .medium))
                        Text("expires \(credential.expiresAt) · \(credential.connections ?? 0) connections")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    HiveChip(text: credential.state, tint: credential.state == "active" ? .green : nil)
                    Button("Revoke", role: .destructive) { Task { await revoke(credential.id) } }
                        .buttonStyle(.hiveCompact)
                }
                .hiveCard(padding: 10, interactive: true)
            }
        }
    }

    private var auditLog: some View {
        VStack(alignment: .leading, spacing: 8) {
            HiveSectionTitle(title: "Recent audit activity", symbol: "list.bullet.rectangle")
            if audit.isEmpty {
                Text("Nothing recorded yet.").font(.system(size: 12)).foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(audit.prefix(8))) { entry in
                        HStack(spacing: 8) {
                            Text(entry.action).font(.system(size: 12, weight: .medium))
                            Text(entry.name ?? entry.credential ?? "").font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                            Text(entry.time).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                        if entry.id != audit.prefix(8).last?.id { Divider().opacity(0.5) }
                    }
                }
                .hiveCard(padding: 10)
            }
        }
    }

    private func reload() async {
        loading = true; defer { loading = false }
        do { async let list = workspace.observerList(); async let log = workspace.observerAudit(limit: 50); observers = try await list; audit = try await log; errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    private func create() async {
        do { created = try await workspace.createObserver(name: name.trimmingCharacters(in: .whitespacesAndNewlines), all: allEnvironments, environments: Array(selectedEnvironments), screens: screens, ttlSeconds: ttlHours * 3600); name = "" }
        catch { errorMessage = error.localizedDescription }
    }

    private func revoke(_ id: String) async {
        do { try await workspace.revokeObserver(id); await reload() }
        catch { errorMessage = error.localizedDescription }
    }

    private func openWeb() async {
        do {
            let output = try await cli.run(["--json", "web", "status"])
            let status = try JSONDecoder().decode(WebObserverStatus.self, from: Data(output.utf8))
            guard let url = URL(string: status.publicURL), !status.publicURL.isEmpty else { throw ObserverError.noURL }
            NSWorkspace.shared.open(url); webURL = status.publicURL; errorMessage = nil
        } catch { errorMessage = "\(error.localizedDescription) Start it with `hive web serve` if it is not running." }
    }
}

private enum ObserverError: LocalizedError { case noURL; var errorDescription: String? { "The web observer did not report a public URL." } }
