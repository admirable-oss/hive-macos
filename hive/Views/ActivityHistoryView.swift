import SwiftUI

/// M7 · Activity and session history. Browse the state changes, task outcomes and delegations this
/// app has recorded, filter them by agent, environment or machine, and restore a prior session.
/// The log is written by this app next to the live workspace; it never invents data the runtime
/// didn't report.
struct ActivityHistoryView: View {
    @ObservedObject var commandCenter: CommandCenterStore
    let hiveURL: URL
    let sessionName: String

    @Environment(\.dismiss) private var dismiss
    @State private var kind: ActivityEntry.Kind?
    @State private var search = ""
    @State private var sessions: [HistorySession] = []
    @State private var sessionMessage: String?
    @State private var loadingSessions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                timeline.frame(minWidth: 380, maxWidth: .infinity)
                Divider()
                sessionsPane.frame(width: 260)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .task { await loadSessions() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(Color.hiveAmber)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Activity & sessions").font(.title3.weight(.semibold))
                    Text("Recorded by Hive Desktop in this session.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear Log", role: .destructive) { commandCenter.clearActivity() }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 8) {
                TextField("Filter by agent, environment or machine", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Picker("Kind", selection: $kind) {
                    Text("All").tag(ActivityEntry.Kind?.none)
                    ForEach(ActivityEntry.Kind.allCases, id: \.self) { item in
                        Text(item.title).tag(ActivityEntry.Kind?.some(item))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
            }
        }
        .padding(16)
    }

    private var timeline: some View {
        Group {
            if filtered.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "clock", description: Text("State changes and task outcomes appear here as they happen."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(groupedByDay, id: \.day) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(group.day.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                ForEach(group.entries) { entry in
                                    entryRow(entry)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private func entryRow(_ entry: ActivityEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.kind.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.hiveAmber)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.title).font(.callout.weight(.medium)).lineLimit(2)
                    if let machine = entry.machine {
                        Text(machine).font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                }
                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                HStack(spacing: 8) {
                    Text(entry.date.formatted(date: .omitted, time: .standard))
                    if let environmentID = entry.environmentID { Text(environmentID) }
                }
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private var sessionsPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sessions").font(.subheadline.weight(.semibold))
                Spacer()
                if loadingSessions { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await loadSessions() } }.controlSize(.small)
            }
            if sessions.isEmpty {
                Text("No sessions reported.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(sessions) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(session.name).font(.callout.weight(session.current ? .semibold : .regular))
                            if session.current {
                                Text("current").font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.hiveAmber.opacity(0.18), in: Capsule())
                            }
                        }
                        Text(session.running ? "Running · PID \(session.pid ?? 0)" : "Stopped")
                            .font(.caption).foregroundStyle(session.running ? .green : .secondary)
                        HStack(spacing: 6) {
                            Button("Switch") { switchTo(session) }
                                .controlSize(.small)
                                .disabled(session.current)
                            Button("Restore") { Task { await restore(session) } }
                                .controlSize(.small)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            if let sessionMessage {
                Text(sessionMessage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
    }

    // MARK: Data

    private var filtered: [ActivityEntry] {
        commandCenter.activity.filter { entry in
            if let kind, entry.kind != kind { return false }
            guard !search.isEmpty else { return true }
            let haystack = [entry.title, entry.detail ?? "", entry.agentID ?? "", entry.environmentID ?? "", entry.machine ?? ""]
                .joined(separator: " ").lowercased()
            return haystack.contains(search.lowercased())
        }
    }

    private var groupedByDay: [(day: Date, entries: [ActivityEntry])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.date) }
        return groups.map { (day: $0.key, entries: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }
    }

    private func switchTo(_ session: HistorySession) {
        UserDefaults.standard.set(session.name, forKey: "hive.session.name")
        commandCenter.recordSession("Switched to session \(session.name)", detail: session.root)
        sessionMessage = "Switched to \(session.name). The workspace reloads for that session."
    }

    private func loadSessions() async {
        loadingSessions = true
        defer { loadingSessions = false }
        do {
            let output = try await HiveCLIService(executableURL: hiveURL, sessionName: sessionName).run(["--json", "session", "list"])
            sessions = try JSONDecoder().decode([HistorySession].self, from: Data(output.utf8))
            sessionMessage = nil
        } catch {
            sessionMessage = error.localizedDescription
        }
    }

    private func restore(_ session: HistorySession) async {
        do {
            let output = try await HiveCLIService(executableURL: hiveURL, sessionName: session.name).run(["--json", "session", "restore"])
            let report = try JSONDecoder().decode(HistoryRestoreReport.self, from: Data(output.utf8))
            let summary = report.panes.isEmpty ? "No lost panes needed restoring." : "Restored \(report.panes.count) pane\(report.panes.count == 1 ? "" : "s")."
            commandCenter.recordSession("Restored session \(session.name)", detail: summary)
            sessionMessage = summary
        } catch {
            sessionMessage = error.localizedDescription
        }
    }
}

private struct HistorySession: Decodable, Identifiable {
    let name: String
    let root: String
    let current: Bool
    let running: Bool
    let pid: Int?
    var id: String { name }
}

private struct HistoryRestoreReport: Decodable {
    struct Pane: Decodable { let pane: String; let environment: String; let error: String?; let resumed: String? }
    let panes: [Pane]
}
