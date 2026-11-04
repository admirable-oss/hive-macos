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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Web observers").font(.title2.weight(.semibold))
                    Text("Read-only browser access to selected environments.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Divider()
            if let created {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Credential created", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Copy this token now. Hive only shows it once.").foregroundStyle(.secondary)
                    HStack { Text(created.token).font(.system(.callout, design: .monospaced)).textSelection(.enabled); Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(created.token, forType: .string) } label: { Image(systemName: "doc.on.doc") }.help("Copy token") }
                    Text("Credential: \(created.credential.name) · expires \(created.credential.expiresAt)").font(.caption).foregroundStyle(.secondary)
                    Button("I’ve copied the token") { self.created = nil; Task { await reload() } }
                }
                .padding(12).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                TextField("Credential name", text: $name).frame(maxWidth: 220)
                Picker("Expires", selection: $ttlHours) { Text("1 hour").tag(1); Text("24 hours").tag(24); Text("7 days").tag(168); Text("30 days").tag(720) }.frame(width: 145)
                Toggle("Allow screenshots", isOn: $screens).toggleStyle(.checkbox)
                Button("Create") { Task { await create() } }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || loading)
            }
            Toggle("All environments", isOn: $allEnvironments).toggleStyle(.checkbox)
            if !allEnvironments {
                List(workspace.environments) { environment in
                    Toggle("\(environment.name) · \(environment.path)", isOn: Binding(get: { selectedEnvironments.contains(environment.id) }, set: { if $0 { selectedEnvironments.insert(environment.id) } else { selectedEnvironments.remove(environment.id) } })).toggleStyle(.checkbox)
                }.frame(height: 100)
            }
            Divider()
            HStack { Text("Credentials").font(.headline); Spacer(); Button("Refresh") { Task { await reload() } }; Button("Open Web Observer") { Task { await openWeb() } }.buttonStyle(.borderedProminent) }
            if observers?.enabled == false { Text("Observer credentials are disabled in the runtime configuration.").foregroundStyle(.secondary) }
            List(observers?.credentials ?? []) { credential in
                HStack {
                    VStack(alignment: .leading) { Text(credential.name); Text("\(credential.state) · expires \(credential.expiresAt) · \(credential.connections ?? 0) connections").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Revoke", role: .destructive) { Task { await revoke(credential.id) } }
                }
            }.frame(minHeight: 130)
            Text("Recent audit activity").font(.headline)
            List(audit.prefix(8)) { entry in HStack { Text(entry.action); Text(entry.name ?? entry.credential ?? "").foregroundStyle(.secondary); Spacer(); Text(entry.time).font(.caption).foregroundStyle(.secondary) } }.frame(height: 100)
            if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red) }
        }
        .padding(20).frame(width: 700, height: 650)
        .task { await reload() }
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

private struct WebObserverStatus: Decodable { let publicURL: String; enum CodingKeys: String, CodingKey { case publicURL = "public_url" } }
private enum ObserverError: LocalizedError { case noURL; var errorDescription: String? { "The web observer did not report a public URL." } }
