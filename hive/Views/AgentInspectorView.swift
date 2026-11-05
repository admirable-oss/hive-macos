import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The inspector's Agent panel: what the active tab's agent is doing and why, a way to
/// answer it when it's blocked, and a prompt box.
struct AgentInspectorView: View {
    let agent: HiveAgent
    @ObservedObject var viewModel: AppViewModel

    @State private var explanation: HiveAgentExplanation?
    @State private var prompt = ""
    @State private var waitForAnswer = true
    @State private var isSending = false
    @State private var reply: HivePromptResult?
    @State private var promptError: String?

    private var isBlocked: Bool { agent.state == "blocked" }
    private var isExited: Bool { agent.state == "exited" }

    var body: some View {
        InspectorCard(title: "Agent", symbol: "sparkles", detail: agent.kind, onReload: { Task { await explain() } }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if isBlocked { decision }
                    details
                    if let verdict = explanation?.verdict { why(verdict) }
                    if !isExited { watchRow }
                    if !isExited { composer }
                    if let reply { replyView(reply) }
                    AgentTranscriptView(agent: agent, viewModel: viewModel)
                    footer
                }
                .padding(14)
                .animation(.spring(response: 0.32, dampingFraction: 0.85), value: agent.state)
                .animation(.spring(response: 0.32, dampingFraction: 0.85), value: reply?.outcome)
            }
        }
        .task(id: agent.state) { await explain() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AgentProviderIcon(kind: agent.kind, size: 16)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(agent.name.isEmpty ? agent.kind : agent.name)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Button { viewModel.renaming = .agent(agent.id) } label: { Image(systemName: "pencil") }
                        .buttonStyle(HiveIconButtonStyle(size: 20))
                        .help("Rename agent")
                }
                HStack(spacing: 6) {
                    HiveChip(
                        text: agentStateTitle(agent.state),
                        tint: agent.state == "working" || agent.state == "blocked" || agent.state == "done" ? agentStateColor(agent.state) : nil,
                        symbol: "circle.fill"
                    )
                    Text(agent.environmentID)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var decision: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Waiting for your decision", systemImage: "hand.raised.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(agentStateColor(agent.state))
            if let reason = agent.reason, !reason.isEmpty {
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button { Task { await viewModel.sendKeys(["Enter"], toAgent: agent.id) } } label: { Label("Approve", systemImage: "checkmark") }
                    .buttonStyle(.hivePrimaryCompact)
                    .help("Presses Enter, accepting the highlighted choice")
                Button { Task { await viewModel.sendKeys(["Escape"], toAgent: agent.id) } } label: { Label("Deny", systemImage: "xmark") }
                    .buttonStyle(.hiveCompact)
                    .help("Presses Escape")
            }
        }
        .hiveCard(padding: 12, tint: agentStateColor(agent.state))
        .transition(.scale(scale: 0.97).combined(with: .opacity))
    }

    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
            if let since = agent.since.flatMap(Self.parseDate) {
                row("Since") { Text(since, format: .relative(presentation: .named)) }
            }
            if !isBlocked, let reason = agent.reason, !reason.isEmpty {
                row("Status") { Text(reason).fixedSize(horizontal: false, vertical: true) }
            }
            if let sessionID = agent.sessionID, !sessionID.isEmpty {
                row("Session") {
                    HStack(spacing: 4) {
                        Text(sessionID)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(sessionID, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(HiveIconButtonStyle(size: 18))
                        .help("Copy session ID")
                    }
                }
            }
            if let detected = explanation?.detected, !detected.isEmpty {
                row("Detected") { Text(detected) }
            }
        }
        .font(.system(size: 12))
        .hiveCard(padding: 12)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            content()
        }
    }

    private func why(_ verdict: HiveAgentExplanation.Verdict) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HiveSectionTitle(title: "Why \(agentStateTitle(verdict.state).lowercased())", symbol: "lightbulb")
            Text(verdict.description.flatMap { $0.isEmpty ? nil : $0 } ?? "Rule \(verdict.rule) of the \(explanation?.manifest ?? agent.kind) manifest matched.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let text = verdict.text, !text.isEmpty {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .hiveCard(padding: 8)
            }
        }
    }

    /// "Notify me when…": a watch on this agent that ends in a notification.
    private var watchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: viewModel.agentWatches[agent.id] == nil ? "bell" : "bell.badge.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(viewModel.agentWatches[agent.id] == nil ? Color.secondary : Color.hiveAmber)
                .contentTransition(.symbolEffect(.replace))
            if let watch = viewModel.agentWatches[agent.id] {
                Text("You’ll be notified when it \(watch.title).")
                    .font(.system(size: 12))
                Spacer()
                Button("Cancel") { viewModel.cancelWatch(agent: agent.id) }
                    .buttonStyle(.hiveCompact)
            } else {
                Text("Notify me when it…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    AgentWatchMenu(agent: agent, viewModel: viewModel)
                } label: {
                    Text("Choose")
                }
                .menuStyle(.button)
                .buttonStyle(.hiveCompact)
                .fixedSize()
            }
        }
        .hiveCard(padding: 10, tint: viewModel.agentWatches[agent.id] == nil ? nil : .hiveAmber)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: viewModel.agentWatches[agent.id])
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HiveSectionTitle(title: "Prompt", symbol: "text.bubble")
            TextEditor(text: $prompt)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 70, maxHeight: 140)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .disabled(isBlocked)
            HStack {
                Toggle("Wait for the answer", isOn: $waitForAnswer)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
                Spacer()
                if isSending { ProgressView().controlSize(.small) }
                Button(action: send) { Label("Send", systemImage: "paperplane.fill") }
                    .buttonStyle(.hivePrimaryCompact)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isBlocked || isSending || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send  ⌘↩")
            }
            if isBlocked {
                HiveNotice(text: "Hive won’t send a prompt while the agent is waiting for a decision.", kind: .info)
            }
            if let promptError {
                HiveNotice(text: promptError)
            }
        }
    }

    private func replyView(_ reply: HivePromptResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HiveSectionTitle(title: "Answer · \(reply.outcome)", symbol: "text.bubble.fill")
            if let output = reply.output, !output.isEmpty {
                Text(output.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .hiveCard(padding: 10)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button { viewModel.openAgent(agent.id) } label: { Label("Show Pane", systemImage: "terminal") }
                .buttonStyle(.hiveCompact)
            Menu {
                Button("Show in TUI") { viewModel.showAgentInTUI(agent.id) }
                Menu("Mark As") {
                    ForEach(["working", "blocked", "idle", "done"], id: \.self) { state in
                        Button(agentStateTitle(state)) { viewModel.reportAgent(agent.id, state: state) }
                    }
                }
                Divider()
                Button("Copy Agent ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(agent.id, forType: .string)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .buttonStyle(HiveIconButtonStyle(size: 24))
            .fixedSize()
            .help("More")
            Spacer()
            if isExited {
                Button { Task { await viewModel.resumeAgent(agent.id) } } label: { Label("Resume Agent", systemImage: "play.fill") }
                    .buttonStyle(.hivePrimaryCompact)
            } else {
                Button("Stop Agent", role: .destructive) { Task { await viewModel.stopAgent(agent.id) } }
                    .buttonStyle(.hiveCompact)
            }
        }
    }

    private func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSending = true
        promptError = nil
        reply = nil
        Task {
            defer { isSending = false }
            do {
                let result = try await viewModel.workspace.prompt(agent: agent.id, text: text, wait: waitForAnswer)
                prompt = ""
                if waitForAnswer { reply = result }
            } catch {
                promptError = error.localizedDescription
            }
        }
    }

    private func explain() async {
        explanation = try? await viewModel.workspace.explain(agent: agent.id)
    }

    nonisolated private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

/// What the agent shows, as plain text: its screen, or the screen and what scrolled off it.
/// Loaded on request, since a long history is a lot to pull for every glance.
private struct AgentTranscriptView: View {
    let agent: HiveAgent
    @ObservedObject var viewModel: AppViewModel

    enum Source: String, CaseIterable {
        case visible, recent = "recent-unwrapped", history

        var title: String {
            switch self {
            case .visible: "Screen"
            case .recent: "Recent"
            case .history: "History"
            }
        }
    }

    @State private var isExpanded = false
    @State private var source: Source = .recent
    @State private var lines: [String] = []
    @State private var isLoading = false
    @State private var error: String?

    private var text: String { lines.joined(separator: "\n") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isExpanded.toggle() }
            } label: {
                HStack {
                    HiveSectionTitle(title: "Transcript", symbol: "text.alignleft")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                HStack(spacing: 6) {
                    HiveSegmentedPicker(selection: $source, options: Source.allCases, title: \.title)
                    Spacer(minLength: 0)
                    if isLoading { ProgressView().controlSize(.small) }
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(HiveIconButtonStyle(size: 22))
                        .help("Read again")
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(HiveIconButtonStyle(size: 22))
                        .disabled(lines.isEmpty)
                        .help("Copy")
                    Button(action: save) { Image(systemName: "square.and.arrow.down") }
                        .buttonStyle(HiveIconButtonStyle(size: 22))
                        .disabled(lines.isEmpty)
                        .help("Save as a text file")
                }
                ScrollView {
                    Text(lines.isEmpty ? (error ?? "Nothing to show.") : text)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(lines.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
                .hiveCard(padding: 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .task(id: source) { await load() }
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            lines = try await viewModel.workspace.readAgent(agent.id, source: source.rawValue, lines: 2000)
            error = nil
        } catch {
            lines = []
            self.error = error.localizedDescription
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(agent.name.isEmpty ? agent.kind : agent.name)-transcript.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
