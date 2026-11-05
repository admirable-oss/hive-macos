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
        VStack(alignment: .leading, spacing: 0) {
            HiveSheetHeader(
                symbol: "clock.arrow.circlepath",
                title: "Activity & sessions",
                subtitle: "Recorded by Hive Desktop in this session.",
                onClose: { dismiss() }
            ) {
                Button("Clear Log", role: .destructive) { commandCenter.clearActivity() }
                    .buttonStyle(.hiveCompact)
                    .disabled(commandCenter.activity.isEmpty)
            }

            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("Filter by agent, environment or machine", text: $search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .frame(maxWidth: 320)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))

                HiveSegmentedPicker(
                    selection: $kind,
                    options: [nil] + ActivityEntry.Kind.allCases.map { Optional($0) },
                    title: { $0?.title ?? "All" }
                )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Divider().opacity(0.5) }
        }
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
                                HiveSectionTitle(title: group.day.formatted(date: .abbreviated, time: .omitted), symbol: "calendar", count: group.entries.count)
                                ForEach(group.entries) { entry in
                                    entryRow(entry)
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                        }
                    }
                    .padding(16)
                    .animation(.spring(response: 0.32, dampingFraction: 0.85), value: filtered.map(\.id))
                }
            }
        }
    }

    private func entryRow(_ entry: ActivityEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.kind.symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.hiveAmber)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.hiveAmber.opacity(0.13)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
                    if let machine = entry.machine {
                        HiveChip(text: machine, symbol: "server.rack")
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
        .hiveCard(padding: 10, interactive: true)
    }

    private var sessionsPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HiveSectionTitle(title: "Sessions", symbol: "square.stack.3d.up", count: sessions.count)
                Spacer()
                if loadingSessions { ProgressView().controlSize(.small) }
                Button { Task { await loadSessions() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(HiveIconButtonStyle())
                    .help("Refresh sessions")
            }
            if sessions.isEmpty {
                Text("No sessions reported.").font(.system(size: 12)).foregroundStyle(.tertiary)
            } else {
                ForEach(sessions) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(session.running ? Color.green : Color.secondary.opacity(0.5))
                                .frame(width: 6, height: 6)
                            Text(session.name).font(.system(size: 12.5, weight: session.current ? .semibold : .medium))
                            if session.current {
                                HiveChip(text: "current", tint: .hiveAmber)
                            }
                        }
                        Text(session.running ? "Running · PID \(session.pid ?? 0)" : "Stopped")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Button("Switch") { switchTo(session) }
                                .buttonStyle(.hiveCompact)
                                .disabled(session.current)
                            Button("Restore") { Task { await restore(session) } }
                                .buttonStyle(.hiveCompact)
                        }
                    }
                    .hiveCard(padding: 10, isSelected: session.current)
                }
            }
            if let sessionMessage {
                HiveNotice(text: sessionMessage, kind: .info)
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
