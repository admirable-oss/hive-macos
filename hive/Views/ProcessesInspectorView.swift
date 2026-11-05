import AppKit
import SwiftUI

/// The inspector's Processes panel: background commands in the active environment (dev
/// servers, watchers, test runs), started, stopped and restarted here, with their logs.
struct ProcessesInspectorView: View {
    let environment: HiveEnvironment
    @ObservedObject var viewModel: AppViewModel

    @State private var commandLine = ""
    @State private var isStarting = false
    @State private var error: String?
    @State private var selectedID: String?

    private var processes: [HiveProcess] { viewModel.backgroundProcesses(in: environment.id) }
    private var selected: HiveProcess? { processes.first(where: { $0.id == selectedID }) }

    var body: some View {
        InspectorCard(
            title: "Processes",
            symbol: "gearshape.2",
            detail: environment.name.isEmpty ? environment.id : environment.name,
            onReload: { Task { await viewModel.workspace.refreshPorts() } }
        ) {
            VStack(spacing: 0) {
                starter
                    .padding(12)
                Divider().opacity(0.5)
                if processes.isEmpty {
                    ContentUnavailableView(
                        "No Background Processes",
                        systemImage: "gearshape.2",
                        description: Text("Start a dev server, a watcher or a test run above. It keeps running when you close the app, and its output is kept as a log.")
                    )
                } else {
                    VSplitView {
                        list
                            .frame(minHeight: 120)
                        if let selected {
                            ProcessLogView(process: selected, viewModel: viewModel)
                                .id(selected.id)
                                .frame(minHeight: 160)
                        }
                    }
                }
            }
        }
        .onAppear { if selectedID == nil { selectedID = processes.first?.id } }
        .onChange(of: processes.map(\.id)) { _, ids in
            if selectedID == nil || !ids.contains(selectedID ?? "") { selectedID = ids.first }
        }
    }

    private var starter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("npm run dev, cargo watch -x test…", text: $commandLine)
                    .textFieldStyle(.hive)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit(start)
                Button(action: start) {
                    if isStarting { ProgressView().controlSize(.small) } else { Label("Start", systemImage: "play.fill") }
                }
                .buttonStyle(.hivePrimaryCompact)
                .disabled(isStarting || commandLine.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error { HiveNotice(text: error) }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(processes) { process in
                    ProcessRow(
                        process: process,
                        ports: viewModel.ports(of: process),
                        isSelected: process.id == selectedID,
                        onSelect: { selectedID = process.id },
                        onStop: { viewModel.stopProcess(process.id) },
                        onRestart: { restart(process) }
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(8)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: processes)
        }
    }

    private func start() {
        let line = commandLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        isStarting = true
        error = nil
        Task {
            defer { isStarting = false }
            do {
                let process = try await viewModel.startProcess(in: environment.id, commandLine: line)
                commandLine = ""
                selectedID = process.id
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func restart(_ process: HiveProcess) {
        Task {
            do { selectedID = try await viewModel.restartProcess(process).id }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct ProcessRow: View {
    let process: HiveProcess
    let ports: [ListeningPort]
    let isSelected: Bool
    let onSelect: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void

    @State private var isHovering = false

    private var statusColor: Color {
        if process.isRunning { return .green }
        return (process.exitCode ?? 0) == 0 ? .secondary : .red
    }

    private var statusText: String {
        if process.isRunning { return "running" }
        if let code = process.exitCode, code != 0 { return "exited \(code)" }
        return process.status
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .shadow(color: process.isRunning ? statusColor.opacity(0.6) : .clear, radius: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(process.commandLine)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(statusText)
                    if let started = process.startedAt.flatMap(HiveWorkspaceStore.parseDate) {
                        Text(started, format: .relative(presentation: .named))
                    }
                    ForEach(ports) { port in
                        Button(":\(port.port)") {
                            if let url = URL(string: "http://localhost:\(port.port)") { NSWorkspace.shared.open(url) }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.hiveAmber)
                        .help("Open http://localhost:\(port.port)")
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if isHovering || isSelected {
                HStack(spacing: 2) {
                    Button(action: onRestart) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(HiveIconButtonStyle(size: 22))
                        .help(process.isRunning ? "Restart" : "Run again")
                    if process.isRunning {
                        Button(action: onStop) { Image(systemName: "stop.fill") }
                            .buttonStyle(HiveIconButtonStyle(size: 22))
                            .help("Stop")
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.hiveAmber.opacity(0.12) : Color.primary.opacity(isHovering ? 0.05 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering } }
        .contextMenu {
            Button("Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(process.commandLine, forType: .string)
            }
            Button(process.isRunning ? "Restart" : "Run Again", action: onRestart)
            if process.isRunning { Button("Stop", action: onStop) }
        }
    }
}

/// A process's log, polled while the process runs: stdout or stderr, searchable, copyable.
struct ProcessLogView: View {
    let process: HiveProcess
    @ObservedObject var viewModel: AppViewModel

    @State private var stream: Stream = .stdout
    @State private var text = ""
    @State private var follow = true
    @State private var filter = ""
    @State private var error: String?

    enum Stream: String, CaseIterable { case stdout, stderr }

    private var shown: String {
        guard !filter.isEmpty else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.localizedCaseInsensitiveContains(filter) }
            .joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HiveSegmentedPicker(selection: $stream, options: Stream.allCases, title: { $0 == .stdout ? "Output" : "Errors" })
                TextField("Filter", text: $filter)
                    .textFieldStyle(.hive)
                    .frame(maxWidth: 140)
                Spacer(minLength: 0)
                Toggle("Follow", isOn: $follow)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
                    .help("Keep the newest output in view")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shown, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(HiveIconButtonStyle(size: 22))
                    .help("Copy log")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            Divider().opacity(0.5)

            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    Text(shown.isEmpty ? (error ?? "No output yet.") : shown)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(shown.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(10)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: text) { _, _ in
                    if follow { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
        .background(Color.primary.opacity(0.02))
        .task(id: stream) { await poll() }
    }

    /// Re-reads the log every second while the process runs, then once more when it ends.
    private func poll() async {
        text = ""
        while !Task.isCancelled {
            do {
                let logs = try await viewModel.workspace.processLogs(process.id, stderr: stream == .stderr, tail: 2000)
                if logs != text { text = logs }
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            let running = viewModel.workspace.processes[process.id]?.isRunning ?? false
            if !running { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
