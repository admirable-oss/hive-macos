import SwiftUI

struct HiveIntegrationStatus: Decodable, Identifiable {
    let id: String
    let name: String
    let path: String
    let state: String
    let hooks: Int
    let want: Int
    let backup: String?
}

struct IntegrationHooksView: View {
    let hiveURL: URL
    @State private var integrations: [HiveIntegrationStatus] = []
    @State private var pending: (id: String, install: Bool)?
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Agent hooks").font(.headline)
                Spacer()
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh integration status")
            }
            Text("Hive can add state-reporting hooks to supported agent settings. It backs up the original file and removes only Hive’s hooks when uninstalled.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Hooks report session start, prompt activity, tool use, permission waits, and turn completion to Hive.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(integrations) { integration in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(integration.name).font(.callout.weight(.medium))
                            Text("\(integration.state) · \(integration.hooks)/\(integration.want) hooks")
                                .font(.caption).foregroundStyle(integration.state == "installed" ? .green : .secondary)
                        }
                        Spacer()
                        Button(integration.state == "installed" ? "Uninstall" : "Install") {
                            pending = (integration.id, integration.state == "installed")
                        }
                        .controlSize(.small)
                    }
                    Text(integration.id == "claude"
                         ? "Reports session start, prompts, tool use, permission waits, and turn completion."
                         : "Reports session start, prompts, tool use, and turn completion.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(integration.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                    if let backup = integration.backup { Text("Backup: \(backup)").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            if isWorking { ProgressView().controlSize(.small) }
            if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red) }
        }
        .task { await reload() }
        .confirmationDialog(
            pending?.install == true ? "Uninstall Hive hooks?" : "Install Hive hooks?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            if let pending {
                Button(pending.install ? "Uninstall Hooks" : "Install Hooks", role: pending.install ? .destructive : nil) {
                    Task { await change(id: pending.id, install: !pending.install) }
                    self.pending = nil
                }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            if let integration = integrations.first(where: { $0.id == pending?.id }) {
                Text("\(pending?.install == true ? "Hive removes its hooks from" : "Hive adds state-reporting hooks to") \(integration.path). \(pending?.install == true ? "The backup is retained." : "An existing settings file is backed up before changes.")")
            }
        }
    }

    @MainActor
    private func reload() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let json = try await HiveCLIService(executableURL: hiveURL).run(["--json", "integration", "status"])
            integrations = try JSONDecoder().decode([HiveIntegrationStatus].self, from: Data(json.utf8))
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    private func change(id: String, install: Bool) async {
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await HiveCLIService(executableURL: hiveURL).run(["--json", "integration", install ? "install" : "uninstall", id])
            await reload()
        } catch { errorMessage = error.localizedDescription }
    }
}
