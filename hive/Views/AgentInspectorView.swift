import AppKit
import SwiftUI

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
        InspectorCard(title: "Agent", detail: agent.kind, onReload: { Task { await explain() } }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if isBlocked { decision }
                    details
                    if let verdict = explanation?.verdict { why(verdict) }
                    if !isExited { composer }
                    if let reply { replyView(reply) }
                    footer
                }
                .padding(14)
            }
        }
        .task(id: agent.state) { await explain() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(agentStateColor(agent.state))
                .frame(width: 10, height: 10)
                .shadow(color: agent.state == "working" ? agentStateColor(agent.state).opacity(0.7) : .clear, radius: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name.isEmpty ? agent.kind : agent.name)
                    .font(.system(size: 15, weight: .semibold))
                Text("\(agentStateTitle(agent.state)) · \(agent.environmentID)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
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
                Button("Approve") { Task { await viewModel.sendKeys(["Enter"], toAgent: agent.id) } }
                    .buttonStyle(.borderedProminent)
                    .help("Presses Enter, accepting the highlighted choice")
                Button("Deny") { Task { await viewModel.sendKeys(["Escape"], toAgent: agent.id) } }
                    .help("Presses Escape")
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(agentStateColor(agent.state).opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                        .buttonStyle(.borderless)
                        .help("Copy session ID")
                    }
                }
            }
            if let detected = explanation?.detected, !detected.isEmpty {
                row("Detected") { Text(detected) }
            }
        }
        .font(.system(size: 12))
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
            Text("Why \(agentStateTitle(verdict.state).lowercased())")
                .font(.system(size: 12, weight: .semibold))
            Text(verdict.description.flatMap { $0.isEmpty ? nil : $0 } ?? "Rule \(verdict.rule) of the \(explanation?.manifest ?? agent.kind) manifest matched.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let text = verdict.text, !text.isEmpty {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt")
                .font(.system(size: 12, weight: .semibold))
            TextEditor(text: $prompt)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 70, maxHeight: 140)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                .disabled(isBlocked)
            HStack {
                Toggle("Wait for the answer", isOn: $waitForAnswer)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                Spacer()
                if isSending { ProgressView().controlSize(.small) }
                Button("Send", action: send)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isBlocked || isSending || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
            if isBlocked {
                Text("Hive won’t send a prompt while the agent is waiting for a decision.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let promptError {
                Text(promptError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }

    private func replyView(_ reply: HivePromptResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Answer · \(reply.outcome)")
                .font(.system(size: 12, weight: .semibold))
            if let output = reply.output, !output.isEmpty {
                Text(output.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Show Pane") { viewModel.openAgent(agent.id) }
            Spacer()
            if isExited {
                Button("Resume Agent") { Task { await viewModel.resumeAgent(agent.id) } }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Stop Agent", role: .destructive) { Task { await viewModel.stopAgent(agent.id) } }
            }
        }
        .controlSize(.small)
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
