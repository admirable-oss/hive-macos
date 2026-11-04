import Foundation
import SwiftUI

struct ConfigSettingsView: View {
    let cli: HiveCLIService
    @State private var path = ""
    @State private var contents = ""
    @State private var selectedCategory: ConfigCategory = .general
    @State private var problems: [String] = []
    @State private var message: String?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hive settings").font(.title2.weight(.semibold))
                    Text(path.isEmpty ? "Loading config path…" : path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button("Reload") { Task { await load() } }
                Button("Save and Validate") { Task { await save() } }.buttonStyle(.borderedProminent).disabled(loading || path.isEmpty)
            }
            Text("Changes are validated before saving. The previous config is kept as config.toml.bak.")
                .font(.callout).foregroundStyle(.secondary)
            TabView(selection: $selectedCategory) {
                ForEach(ConfigCategory.allCases) { category in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(category.description).font(.callout).foregroundStyle(.secondary)
                        TextEditor(text: sectionBinding(for: category))
                            .font(.system(.body, design: .monospaced))
                            .border(Color.secondary.opacity(0.25))
                    }
                    .padding(8)
                    .tabItem { Label(category.title, systemImage: category.symbol) }
                    .tag(category)
                }
            }
            if loading { ProgressView().controlSize(.small) }
            if let message { Text(message).font(.callout).foregroundStyle(problems.isEmpty ? .green : .red) }
            ForEach(problems, id: \.self) { problem in Text(problem).font(.caption).foregroundStyle(.red) }
        }
        .padding(14)
        .task { await load() }
    }

    private func sectionBinding(for category: ConfigCategory) -> Binding<String> {
        Binding(get: { extractSections(from: contents, names: category.sections) }, set: { edited in
            contents = replaceSections(in: contents, names: category.sections, with: edited)
        })
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            let resolved = try await cli.run(["config", "path"]).trimmingCharacters(in: .whitespacesAndNewlines)
            path = resolved
            if FileManager.default.fileExists(atPath: resolved) {
                contents = try String(contentsOfFile: resolved, encoding: .utf8)
            } else {
                contents = try await cli.run(["config", "default"])
            }
            problems = []; message = nil
        } catch { message = error.localizedDescription }
    }

    private func save() async {
        loading = true; defer { loading = false }
        let target = URL(fileURLWithPath: path)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".hive-config-validation.toml")
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: temporary, options: .atomic)
            do { _ = try await cli.run(["config", "validate", temporary.path]) }
            catch {
                problems = [error.localizedDescription]
                message = "Configuration has validation problems; the saved file was left unchanged."
                try? FileManager.default.removeItem(at: temporary)
                return
            }
            if FileManager.default.fileExists(atPath: target.path) {
                let backup = URL(fileURLWithPath: target.path + ".bak")
                if FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.removeItem(at: backup) }
                try FileManager.default.copyItem(at: target, to: backup)
            }
            let data = try Data(contentsOf: temporary)
            try data.write(to: target, options: .atomic)
            try? FileManager.default.removeItem(at: temporary)
            contents = try String(contentsOf: target, encoding: .utf8)
            problems = []; message = "Configuration is valid and saved. Restart the daemon to apply daemon settings."
        } catch { problems = [error.localizedDescription]; message = "Could not save configuration."; try? FileManager.default.removeItem(at: temporary) }
    }
}

private enum ConfigCategory: String, CaseIterable, Identifiable {
    case general, terminal, notifications, theme, remote, worktrees, plugins
    var id: Self { self }
    var title: String {
        switch self { case .general: "General"; case .terminal: "Terminal"; case .notifications: "Notifications"; case .theme: "Theme"; case .remote: "Remote"; case .worktrees: "Worktrees"; case .plugins: "Plugins" }
    }
    var symbol: String {
        switch self { case .general: "gearshape"; case .terminal: "terminal"; case .notifications: "bell"; case .theme: "paintpalette"; case .remote: "network"; case .worktrees: "arrow.triangle.branch"; case .plugins: "puzzlepiece.extension" }
    }
    var sections: Set<String> {
        switch self {
        case .general: ["daemon", "log", "process", "git", "session", "retention", "update"]
        case .terminal: ["terminal", "images", "ui"]
        case .notifications: ["notify", "observers"]
        case .theme: ["theme"]
        case .remote: ["remote", "discovery", "access", "web"]
        case .worktrees: ["worktrees", "branches", "tasks", "workflows"]
        case .plugins: ["plugins"]
        }
    }
    var description: String { "Edit the \(title.lowercased()) sections of config.toml. Other sections stay unchanged." }
}

private func tomlSectionName(_ line: String) -> String? {
    let value = line.trimmingCharacters(in: .whitespaces)
    if value.hasPrefix("[["), value.hasSuffix("]]"), value.count >= 5 {
        return String(value.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
    }
    guard value.hasPrefix("["), let end = value.firstIndex(of: "]") else { return nil }
    let start = value.index(after: value.startIndex)
    let name = String(value[start..<end]).trimmingCharacters(in: .whitespaces)
    guard !name.hasPrefix("[") else { return nil }
    return name
}

private func belongsToConfigCategory(_ name: String, sections: Set<String>) -> Bool {
    if sections.contains(name) { return true }
    let root = name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
    return sections.contains(root)
}

private func extractSections(from text: String, names: Set<String>) -> String {
    let lines = text.components(separatedBy: .newlines)
    var chunks: [[String]] = []
    var current: [String] = []
    var currentName: String?
    for line in lines {
        if let name = tomlSectionName(line) {
            if !current.isEmpty, let currentName, belongsToConfigCategory(currentName, sections: names) { chunks.append(current) }
            current = [line]; currentName = name
        } else if currentName != nil {
            current.append(line)
        }
    }
    if !current.isEmpty, let currentName, belongsToConfigCategory(currentName, sections: names) { chunks.append(current) }
    return chunks.map { $0.joined(separator: "\n") }.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func replaceSections(in text: String, names: Set<String>, with replacement: String) -> String {
    let lines = text.components(separatedBy: .newlines)
    var prefix: [String] = []
    var chunks: [[String]] = []
    var current: [String] = []
    var currentName: String?
    var inserted = false
    func appendCurrent() {
        guard !current.isEmpty else { return }
        if let name = currentName, belongsToConfigCategory(name, sections: names) {
            if !inserted {
                let replacementLines = replacement.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
                if !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { chunks.append(replacementLines) }
                inserted = true
            }
        } else { chunks.append(current) }
        current = []
    }
    for line in lines {
        if let name = tomlSectionName(line) {
            if currentName == nil { prefix = current; current = [] } else { appendCurrent() }
            current = [line]; currentName = name
        } else if currentName == nil { current.append(line) }
        else { current.append(line) }
    }
    if currentName == nil { prefix = current } else { appendCurrent() }
    if !inserted {
        let replacementLines = replacement.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
        if !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { chunks.append(replacementLines) }
    }
    let body = chunks.flatMap { $0 }.joined(separator: "\n")
    let head = prefix.joined(separator: "\n").trimmingCharacters(in: .newlines)
    return head.isEmpty ? body + "\n" : head + "\n\n" + body + "\n"
}

private struct Phase5Session: Decodable, Identifiable {
    let name: String
    let root: String
    let current: Bool
    let running: Bool
    let pid: Int?
    var id: String { name }
}

private struct Phase5RestoreReport: Decodable {
    struct Pane: Decodable { let pane: String; let environment: String; let error: String?; let resumed: String? }
    let panes: [Pane]
}

struct SessionSettingsView: View {
    let hiveURL: URL
    @Binding var sessionName: String
    @State private var sessions: [Phase5Session] = []
    @State private var report: String?
    @State private var errorMessage: String?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sessions").font(.title2.weight(.semibold))
            Text("Each session has its own daemon, environments and agents. Switching changes the workspace shown by Hive.").foregroundStyle(.secondary)
            Picker("Active session", selection: $sessionName) {
                ForEach(sessions) { session in Text(session.name + (session.running ? " · running" : " · stopped")).tag(session.name) }
            }
            .onChange(of: sessionName) { _, _ in Task { await refresh() } }
            List(sessions) { session in
                HStack {
                    VStack(alignment: .leading) { Text(session.name).fontWeight(session.current ? .semibold : .regular); Text(session.root).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text(session.running ? "Running · PID \(session.pid ?? 0)" : "Stopped").font(.caption).foregroundStyle(session.running ? .green : .secondary)
                }
            }
            .frame(minHeight: 180)
            HStack {
                Button("Refresh") { Task { await refresh() } }
                Button("Save Current Session") { Task { await runSession(["session", "save"], label: "Session snapshot saved.") } }
                Spacer()
                Button("Restore") { Task { await restore(fresh: false) } }
                Button("Restore Fresh…") { Task { await restore(fresh: true) } }
                    .help("Restore lost panes and start agents without resuming their conversations")
            }
            if loading { ProgressView().controlSize(.small) }
            if let report { Text(report).font(.callout).textSelection(.enabled) }
            if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red) }
        }
        .padding(18)
        .task { await refresh() }
    }

    private func refresh() async {
        loading = true; defer { loading = false }
        do { let output = try await HiveCLIService(executableURL: hiveURL, sessionName: sessionName).run(["--json", "session", "list"]); sessions = try JSONDecoder().decode([Phase5Session].self, from: Data(output.utf8)); if !sessions.contains(where: { $0.name == sessionName }) { sessionName = sessions.first(where: \.current)?.name ?? "default" }; errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    private func runSession(_ args: [String], label: String) async {
        do { _ = try await HiveCLIService(executableURL: hiveURL, sessionName: sessionName).run(["--json"] + args); report = label; errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    private func restore(fresh: Bool) async {
        do {
            var args = ["--json", "session", "restore"]
            if fresh { args.append("--fresh") }
            let output = try await HiveCLIService(executableURL: hiveURL, sessionName: sessionName).run(args)
            let result = try JSONDecoder().decode(Phase5RestoreReport.self, from: Data(output.utf8))
            report = result.panes.isEmpty ? "No lost panes needed restoring." : result.panes.map { pane in "\(pane.pane) · \(pane.environment) · \(pane.error ?? (pane.resumed.map { "resumed \($0)" } ?? "restored"))" }.joined(separator: "\n")
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct Phase5GCReport: Decodable {
    let dryRun: Bool
    let processes: [String]
    let files: [String]
    let bytes: Int64
    enum CodingKeys: String, CodingKey { case processes, files, bytes; case dryRun = "dry_run" }
}

struct UpkeepSettingsView: View {
    let hiveURL: URL
    let sessionName: String
    @State private var statusText = "Loading runtime status…"
    @State private var gc: Phase5GCReport?
    @State private var result: String?
    @State private var errorMessage: String?
    @State private var confirmation: UpkeepAction?
    @State private var busy = false

    private enum UpkeepAction: String, Identifiable { case stop, update, collect; var id: String { rawValue } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Runtime upkeep").font(.title2.weight(.semibold))
            Text(statusText).textSelection(.enabled)
            HStack {
                Button("Refresh Status") { Task { await loadStatus() } }
                Button("Start Daemon") { Task { await run(["daemon", "start"], success: "Daemon started.") } }
                Button("Stop Daemon…") { confirmation = .stop }
            }
            Divider()
            HStack {
                Text("Garbage collection").font(.headline)
                Spacer()
                Button("Preview") { Task { await previewGC() } }
                Button("Collect…") { confirmation = .collect }.disabled(gc == nil)
            }
            if let gc {
                Text("Preview: \(gc.processes.count) process records, \(gc.files.count) files, \(ByteCountFormatter.string(fromByteCount: gc.bytes, countStyle: .file))").font(.callout)
                ForEach(Array((gc.processes.map { "process \($0)" } + gc.files).prefix(8)), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
            Divider()
            HStack {
                VStack(alignment: .leading) { Text("Hive update").font(.headline); Text("Update the installed CLI and restart its daemon if needed.").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Update…") { confirmation = .update }
            }
            if busy { ProgressView().controlSize(.small) }
            if let result { Text(result).font(.callout).foregroundStyle(.green).textSelection(.enabled) }
            if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding(18)
        .task { await loadStatus() }
        .confirmationDialog(confirmationTitle, isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            switch confirmation {
            case .stop: Button("Stop Daemon", role: .destructive) { Task { await run(["daemon", "stop"], success: "Daemon stopped.") } }
            case .update: Button("Update Hive") { Task { await run(["update"], success: "Hive update completed.") } }
            case .collect: Button("Remove Previewed Items", role: .destructive) { Task { await run(["gc"], success: "Garbage collection completed."); gc = nil } }
            case nil: EmptyView()
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: {
            Text(confirmation == .collect ? "Hive will remove the items shown in the dry-run preview." : "This action affects the selected Hive session.")
        }
    }

    private var confirmationTitle: String { switch confirmation { case .stop: "Stop the Hive daemon?"; case .update: "Update Hive?"; case .collect: "Run garbage collection?"; case nil: "" } }

    private func loadStatus() async {
        do {
            let output = try await service.run(["--json", "version"])
            let value = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] ?? [:]
            let version = value["version"] as? String ?? "unknown"
            let daemon = value["daemon"] as? [String: Any]
            let daemonVersion = daemon?["version"] as? String
            statusText = daemonVersion.map { "CLI \(version) · daemon \($0)\($0 == version ? "" : " · version mismatch — restart or update Hive")" } ?? "CLI \(version) · daemon not running"
            errorMessage = nil
        } catch { statusText = "Runtime status unavailable"; errorMessage = error.localizedDescription }
    }

    private func previewGC() async {
        do { let output = try await service.run(["--json", "gc", "--dry-run"]); gc = try JSONDecoder().decode(Phase5GCReport.self, from: Data(output.utf8)); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    private func run(_ arguments: [String], success: String) async {
        busy = true; defer { busy = false; confirmation = nil }
        do { let output = try await service.run(["--json"] + arguments); result = output.isEmpty ? success : output; errorMessage = nil; await loadStatus() }
        catch { errorMessage = error.localizedDescription }
    }

    private var service: HiveCLIService { HiveCLIService(executableURL: hiveURL, sessionName: sessionName) }
}
