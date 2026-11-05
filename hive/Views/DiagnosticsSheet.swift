import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What the daemon is and how it's doing: version and API level, the link's round trip, its
/// memory, goroutines and open files (live), and a profile to attach to a bug report.
struct DiagnosticsSheet: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var status: HiveRuntimeStatus?
    @State private var stats: HiveDebugStats?
    @State private var heapHistory: [Double] = []
    @State private var error: String?
    @State private var profiling: String?
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HiveSheetHeader(
                symbol: "stethoscope",
                title: "Diagnostics",
                subtitle: status.map { "Hive \($0.version) · session \($0.session ?? viewModel.sessionName)" },
                onClose: { dismiss() }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    runtime
                    resources
                    profiles
                    if let error { HiveNotice(text: error) }
                    if let notice { HiveNotice(text: notice, kind: .success) }
                }
                .padding(20)
            }

            HStack {
                Button { copyReport() } label: { Label("Copy Report", systemImage: "doc.on.doc") }
                    .buttonStyle(.hive)
                    .help("Copies these details as text, for a bug report")
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.hivePrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color.primary.opacity(0.025))
            .overlay(alignment: .top) { Divider().opacity(0.5) }
        }
        .frame(width: 600, height: 600)
        .task { await poll() }
    }

    private var runtime: some View {
        VStack(alignment: .leading, spacing: 8) {
            HiveSectionTitle(title: "Runtime", symbol: "cpu")
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                row("Status", status.map { $0.status } ?? (viewModel.isConnected ? "…" : "unavailable"))
                row("Version", status.map { "\($0.version) · protocol \($0.protocolVersion) · API level \($0.apiLevel)" } ?? "—")
                row("Process", status.map { "PID \($0.pid)" } ?? "—")
                row("Started", status.flatMap { HiveWorkspaceStore.parseDate($0.startedAt) }.map { $0.formatted(.relative(presentation: .named)) } ?? "—")
                row("Socket", status?.socket ?? "—")
                row("Round trip", viewModel.workspace.roundTrip.map(Self.milliseconds) ?? "—")
                row("Agents survive restarts", status.map { $0.agentsSurviveRestart ? "Yes" : "No" } ?? "—")
            }
            .font(.system(size: 12))
            .hiveCard(padding: 12)
        }
    }

    private var resources: some View {
        VStack(alignment: .leading, spacing: 8) {
            HiveSectionTitle(title: "Resources, live", symbol: "gauge.with.dots.needle.33percent")
            HStack(spacing: 10) {
                metric("Memory in use", stats.map { Self.bytes($0.heapAlloc) } ?? "—", detail: stats.map { "of \(Self.bytes($0.heapSys)) reserved" })
                metric("Goroutines", stats.map { "\($0.goroutines)" } ?? "—")
                metric("Open files", stats.map { "\($0.openFiles)" } ?? "—")
                metric("Collections", stats.map { "\($0.numGC)" } ?? "—")
            }
            if heapHistory.count > 2 {
                Sparkline(values: heapHistory)
                    .stroke(Color.hiveAmber, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(height: 36)
                    .hiveCard(padding: 10)
                    .help("Memory in use over the last minute")
            }
        }
    }

    private var profiles: some View {
        VStack(alignment: .leading, spacing: 8) {
            HiveSectionTitle(title: "Profiles for bug reports", symbol: "waveform.path.ecg")
            HStack(spacing: 8) {
                Button("CPU, 30 seconds…") { capture("cpu", seconds: 30) }
                Button("Memory…") { capture("heap") }
                Button("Goroutines…") { capture("goroutine") }
                Spacer()
                if let profiling {
                    ProgressView().controlSize(.small)
                    Text(profiling).font(.callout).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.hiveCompact)
            .disabled(profiling != nil)
            Text("Saves a pprof file to attach to an issue; read it with `go tool pprof`. A CPU profile takes 30 seconds.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
    }

    private func metric(_ title: String, _ value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            if let detail { Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hiveCard(padding: 10)
    }

    /// Status once; stats every two seconds while the sheet is open.
    private func poll() async {
        do { status = try await viewModel.workspace.runtimeStatus() }
        catch { self.error = error.localizedDescription }
        while !Task.isCancelled {
            if let stats = try? await viewModel.workspace.debugStats() {
                withAnimation(.easeOut(duration: 0.3)) { self.stats = stats }
                heapHistory = Array((heapHistory + [Double(stats.heapAlloc)]).suffix(30))
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func capture(_ profile: String, seconds: Int? = nil) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "hive-\(profile)-\(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))).pprof"
        panel.allowedContentTypes = [UTType(filenameExtension: "pprof") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        profiling = seconds.map { "Recording \($0) s of CPU…" } ?? "Capturing…"
        notice = nil
        Task {
            defer { profiling = nil }
            var args = ["debug", "pprof", "--profile", profile, "-o", url.path]
            if let seconds { args += ["--seconds", String(seconds)] }
            do {
                _ = try await viewModel.cliService.run(args)
                notice = "Saved \(url.lastPathComponent)."
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func copyReport() {
        var lines = ["Hive Desktop diagnostics, \(Date().formatted())"]
        if let status {
            lines += ["Hive \(status.version), protocol \(status.protocolVersion), API level \(status.apiLevel)",
                      "Session \(status.session ?? viewModel.sessionName), PID \(status.pid), started \(status.startedAt)"]
        }
        if let roundTrip = viewModel.workspace.roundTrip { lines.append("Round trip \(Self.milliseconds(roundTrip))") }
        if let stats {
            lines.append("Memory \(Self.bytes(stats.heapAlloc)) of \(Self.bytes(stats.heapSys)), goroutines \(stats.goroutines), open files \(stats.openFiles), GC \(stats.numGC), up \(Int(stats.uptimeSeconds)) s")
        }
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        notice = "Copied."
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .memory)
    }

    static func milliseconds(_ duration: Duration) -> String {
        let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return ms < 1 ? String(format: "%.2f ms", ms) : String(format: "%.1f ms", ms)
    }
}

/// A line through recent values, scaled to its own range.
private struct Sparkline: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, let low = values.min(), let high = values.max() else { return path }
        let span = max(high - low, 1)
        for (index, value) in values.enumerated() {
            let point = CGPoint(
                x: rect.minX + rect.width * CGFloat(index) / CGFloat(values.count - 1),
                y: rect.maxY - rect.height * CGFloat((value - low) / span)
            )
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
