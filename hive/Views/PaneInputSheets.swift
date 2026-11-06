import SwiftUI

/// Types the same thing into one or more panes of a tab: a command to run, or text such as a
/// prompt. The desktop's take on tmux's synchronized panes. Optionally tells you when each pane
/// prints a line you're waiting for.
struct SendToPanesSheet: View {
    @ObservedObject var viewModel: AppViewModel
    let tab: HiveTab
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var selected: Set<String>
    @State private var pressEnter = true
    @State private var notify = false
    @State private var watch = OutputPattern()
    @FocusState private var editorFocused: Bool

    init(viewModel: AppViewModel, tab: HiveTab, paneIDs: [String]) {
        self.viewModel = viewModel
        self.tab = tab
        _selected = State(initialValue: Set(paneIDs))
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { !trimmed.isEmpty && !selected.isEmpty && (!notify || watch.isValid) }

    var body: some View {
        HiveFormSheet(
            symbol: "keyboard",
            title: "Send to Panes",
            subtitle: "Typed into each pane you pick, as if you’d typed it there.",
            actionTitle: selected.count > 1 ? "Send to \(selected.count) Panes" : "Send",
            actionSymbol: "paperplane.fill",
            canSubmit: canSend,
            width: 520,
            onCancel: { dismiss() },
            onSubmit: send
        ) {
            HiveFieldLabel(title: "Command or text") {
                TextEditor(text: $text)
                    .font(.system(size: 12.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 90)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.045)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                    .focused($editorFocused)
            }
            Toggle("Press Enter after it", isOn: $pressEnter)
                .help("On: a command runs. Off: the text waits in the pane for you to finish it.")

            HiveFieldLabel(title: "Panes") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(tab.paneIDs, id: \.self) { id in
                        Toggle(isOn: Binding(
                            get: { selected.contains(id) },
                            set: { if $0 { selected.insert(id) } else { selected.remove(id) } }
                        )) {
                            HStack(spacing: 6) {
                                Text(paneName(id))
                                if id == viewModel.focusedPaneID { HiveChip(text: "focused") }
                            }
                        }
                    }
                    if tab.paneIDs.count > 1 {
                        Button(selected.count == tab.paneIDs.count ? "Only the Focused Pane" : "All Panes in This Tab") {
                            selected = selected.count == tab.paneIDs.count
                                ? Set([viewModel.focusedPaneID].compactMap { $0 })
                                : Set(tab.paneIDs)
                        }
                        .buttonStyle(.hiveCompact)
                        .padding(.top, 2)
                    }
                }
            }

            Toggle("Tell me when it prints…", isOn: $notify.animation())
            if notify {
                OutputPatternField(pattern: $watch)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear { editorFocused = true }
    }

    private func paneName(_ id: String) -> String {
        let name = viewModel.workspace.panes[id]?.name ?? ""
        return name.isEmpty ? "Pane \((tab.paneIDs.firstIndex(of: id) ?? 0) + 1)" : name
    }

    private func send() {
        guard canSend else { return }
        let targets = tab.paneIDs.filter(selected.contains)
        viewModel.send(text.hasSuffix("\n") ? String(text.dropLast()) : text, toPanes: targets, pressEnter: pressEnter,
                       notifyOn: notify ? (watch.regex, watch.label) : nil)
        dismiss()
    }
}

/// "Tell me when this pane prints…": a notification once a line matches.
struct WaitForOutputSheet: View {
    @ObservedObject var viewModel: AppViewModel
    let paneID: String
    @Environment(\.dismiss) private var dismiss

    @State private var pattern = OutputPattern()
    @State private var hours = 1

    var body: some View {
        HiveFormSheet(
            symbol: "bell.badge",
            title: "Wait for Output",
            subtitle: "Only what the pane prints from now on counts.",
            actionTitle: "Start Waiting",
            actionSymbol: "bell",
            canSubmit: pattern.isValid,
            onCancel: { dismiss() },
            onSubmit: {
                viewModel.watchOutput(ofPane: paneID, pattern: pattern.regex, label: pattern.label, timeout: .seconds(hours * 3600))
                dismiss()
            }
        ) {
            OutputPatternField(pattern: $pattern)
            HiveFieldLabel(title: "Give up after") {
                Picker("", selection: $hours) {
                    ForEach([1, 2, 6, 24], id: \.self) { Text("\($0) hour\($0 == 1 ? "" : "s")").tag($0) }
                }
                .labelsHidden()
                .frame(width: 120)
            }
        }
    }
}

/// What a line must contain or match; literal text is escaped into a regular expression.
struct OutputPattern {
    var text = ""
    var isRegex = false

    var isValid: Bool {
        guard !text.isEmpty else { return false }
        return !isRegex || (try? NSRegularExpression(pattern: text)) != nil
    }

    /// Hive matches Go regular expressions; escaping literal text works the same in both.
    var regex: String { isRegex ? text : NSRegularExpression.escapedPattern(for: text) }
    var label: String { isRegex ? "/\(text)/" : "“\(text)”" }
}

private struct OutputPatternField: View {
    @Binding var pattern: OutputPattern

    var body: some View {
        HiveFieldLabel(title: pattern.isRegex ? "A line matching" : "A line containing") {
            HStack(spacing: 8) {
                TextField(pattern.isRegex ? "(passed|failed)" : "ready on port", text: $pattern.text)
                    .textFieldStyle(.hive)
                    .font(.system(size: 12.5, design: .monospaced))
                Toggle("Regex", isOn: $pattern.isRegex)
                    .toggleStyle(.checkbox)
                    .help("Treat it as a regular expression")
            }
        }
        if pattern.isRegex, !pattern.text.isEmpty, !pattern.isValid {
            HiveNotice(text: "That isn’t a valid regular expression.")
        }
    }
}
