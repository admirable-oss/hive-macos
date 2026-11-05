import SwiftUI

/// An environment's settings: the variables every new process in it gets, and the title and
/// tokens reported about it. Hive environments have no editable name or path; those are fixed
/// when the environment is created.
struct EnvironmentSettingsSheet: View {
    let environment: HiveEnvironment
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    private struct Variable: Identifiable, Hashable {
        let id = UUID()
        var key: String
        var value: String
    }

    @State private var variables: [Variable] = []
    @State private var revealed: Set<UUID> = []
    @State private var isSaving = false
    @State private var error: String?

    /// The variables as Hive has them now, which may have changed since the sheet opened.
    private var original: [String: String] {
        let current: HiveEnvironment? = viewModel.environments.first(where: { $0.id == environment.id })
        let variables: [String: String]? = current?.env ?? environment.env
        return variables ?? [:]
    }

    private var edited: [String: String] {
        var result: [String: String] = [:]
        for variable in variables {
            let key = variable.key.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = variable.value }
        }
        return result
    }

    private var invalidKeys: [String] {
        variables.map { $0.key.trimmingCharacters(in: .whitespaces) }.filter { key in
            !key.isEmpty && key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) == nil
        }
    }

    private var duplicateKeys: Bool {
        let keys = variables.map { $0.key.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Set(keys).count != keys.count
    }

    private var hasChanges: Bool { edited != original }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HiveSheetHeader(
                symbol: "slider.horizontal.3",
                title: environment.name.isEmpty ? environment.id : environment.name,
                subtitle: environment.path,
                onClose: { dismiss() }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    details
                    variablesSection
                    metadataSection
                }
                .padding(20)
            }
            .frame(maxHeight: 460)

            footer
        }
        .frame(width: 560)
        .onAppear { load() }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: variables)
    }

    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("ID").foregroundStyle(.secondary)
                Text(environment.id).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            }
            if let branch = environment.git?.branch {
                GridRow {
                    Text("Branch").foregroundStyle(.secondary)
                    Text(branch).font(.system(size: 12, design: .monospaced))
                }
            }
            if let worktree = environment.worktree {
                GridRow {
                    Text("Worktree of").foregroundStyle(.secondary)
                    Text(worktree.repo).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .font(.system(size: 12))
        .hiveCard(padding: 12)
    }

    private var variablesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HiveSectionTitle(title: "Variables", symbol: "curlybraces", count: variables.isEmpty ? nil : variables.count)
                Spacer()
                Button {
                    variables.append(Variable(key: "", value: ""))
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.hiveCompact)
            }

            if variables.isEmpty {
                Text("No variables. Every new process in this environment, agents included, gets the ones you add here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hiveCard(padding: 12)
            } else {
                VStack(spacing: 6) {
                    ForEach($variables) { $variable in
                        variableRow($variable)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }

            if !invalidKeys.isEmpty {
                HiveNotice(text: "Names use letters, digits and underscores, and don’t start with a digit: \(invalidKeys.joined(separator: ", ")).")
            } else if duplicateKeys {
                HiveNotice(text: "Two variables have the same name.")
            }
            HiveNotice(text: "Processes already running keep the values they started with. Restart them, or start agents again, to pick up changes.", kind: .info)
        }
    }

    private func variableRow(_ variable: Binding<Variable>) -> some View {
        let id = variable.wrappedValue.id
        let isRevealed = revealed.contains(id)
        return HStack(spacing: 6) {
            TextField("NAME", text: variable.key)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 170)
            Group {
                if isRevealed {
                    TextField("value", text: variable.value)
                } else {
                    SecureField("value", text: variable.value)
                }
            }
            .font(.system(size: 12, design: .monospaced))
            Button {
                if isRevealed { revealed.remove(id) } else { revealed.insert(id) }
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
            }
            .buttonStyle(HiveIconButtonStyle(size: 22))
            .help(isRevealed ? "Hide value" : "Show value")
            Button {
                variables.removeAll { $0.id == id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(HiveIconButtonStyle(size: 22))
            .help("Remove variable")
        }
        .textFieldStyle(.hive)
    }

    @ViewBuilder
    private var metadataSection: some View {
        let reported = viewModel.workspace.metadata(forEnvironment: environment.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HiveSectionTitle(title: "Title and tokens", symbol: "tag")
                Spacer()
                Button("Clear") { viewModel.clearMetadata(environment: environment.id) }
                    .buttonStyle(.hiveCompact)
                    .disabled(reported.title == nil && reported.tokens.isEmpty)
            }
            if reported.title == nil && reported.tokens.isEmpty {
                Text("Nothing reported. Tools report these with `hive environment report-metadata`, and they show beside the environment in the sidebar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hiveCard(padding: 12)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let title = reported.title {
                        Text(title).font(.system(size: 13, weight: .semibold))
                    }
                    MetadataTokens(tokens: reported.tokens, limit: nil)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .hiveCard(padding: 12)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let error {
                HiveNotice(text: error)
            }
            Spacer()
            if isSaving { ProgressView().controlSize(.small) }
            Button("Cancel") { dismiss() }
                .buttonStyle(.hive)
                .keyboardShortcut(.cancelAction)
            Button(action: save) { Label("Save Variables", systemImage: "checkmark") }
                .buttonStyle(.hivePrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!hasChanges || isSaving || !invalidKeys.isEmpty || duplicateKeys)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.primary.opacity(0.025))
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }

    private func load() {
        variables = original.sorted { $0.key < $1.key }.map { Variable(key: $0.key, value: $0.value) }
    }

    private func save() {
        let new = edited
        let old = original
        let set = new.filter { old[$0.key] != $0.value }
        let unset = old.keys.filter { new[$0] == nil }.sorted()
        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            do {
                try await viewModel.updateVariables(of: environment.id, set: set, unset: unset)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Reported tokens as small chips, `key text`, with the rest counted when there are more.
struct MetadataTokens: View {
    let tokens: [HiveMetadataEntry.Token]
    var limit: Int? = 2

    var body: some View {
        let shown = limit.map { Array(tokens.prefix($0)) } ?? tokens
        HStack(spacing: 4) {
            ForEach(shown, id: \.key) { token in
                HStack(spacing: 3) {
                    Text(token.key).foregroundStyle(.tertiary)
                    Text(token.text).foregroundStyle(.secondary)
                }
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .help("\(token.key): \(token.text)")
            }
            if tokens.count > shown.count {
                Text("+\(tokens.count - shown.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .help(tokens.dropFirst(shown.count).map { "\($0.key): \($0.text)" }.joined(separator: "\n"))
            }
        }
    }
}
