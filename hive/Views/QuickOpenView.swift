import SwiftUI

/// ⌘K: jump to an agent, pane, tab, environment or saved machine.
struct QuickOpenView: View {
    @ObservedObject var viewModel: AppViewModel

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var isSearchFocused: Bool

    private struct Item: Identifiable {
        enum Kind { case agent, pane, tab, environment, machine }

        let id: String
        let kind: Kind
        let title: String
        let detail: String
        let symbol: String
        let tint: Color
        let rank: Int
        let open: () -> Void
    }

    private var items: [Item] {
        let agents = viewModel.agents.sorted { $0.stateRank < $1.stateRank }.map { agent in
            Item(
                id: "agent-\(agent.id)", kind: .agent,
                title: agent.name.isEmpty ? agent.kind : agent.name,
                detail: "\(agent.kind) · \(agent.environmentID) · \(agentStateTitle(agent.state))",
                symbol: "sparkles", tint: agentStateColor(agent.state), rank: agent.stateRank,
                open: { viewModel.openAgent(agent.id) }
            )
        }
        let tabs = viewModel.workspace.tabs.map { tab in
            Item(
                id: "tab-\(tab.id)", kind: .tab,
                title: tab.name, detail: "Tab in \(tab.environmentID) · \(tab.paneIDs.count) pane\(tab.paneIDs.count == 1 ? "" : "s")",
                symbol: "terminal", tint: .secondary, rank: 10,
                open: { viewModel.openHiveTab(tab.id) }
            )
        }
        let environments = viewModel.environments.map { environment in
            Item(
                id: "env-\(environment.id)", kind: .environment,
                title: environment.name.isEmpty ? environment.id : environment.name,
                detail: environment.path, symbol: "folder", tint: .hiveAmber, rank: 20,
                open: { viewModel.openEnvironment(environment.id) }
            )
        }
        let panes = viewModel.workspace.panes.values.map { pane in
            let agent = viewModel.workspace.agent(inPane: pane.id)
            let process = viewModel.workspace.processes[pane.processID]
            let tab = viewModel.workspace.tab(pane.tabID)
            let title = pane.name.flatMap { $0.isEmpty ? nil : $0 }
                ?? agent.map { $0.name.isEmpty ? $0.kind : $0.name }
                ?? process?.command
                ?? "Pane \(pane.id)"
            let tabName = tab?.name ?? "Tab"
            let command = process?.command ?? "Terminal"
            return Item(
                id: "pane-\(pane.id)", kind: .pane,
                title: title,
                detail: "\(pane.environmentID) · \(tabName) · \(command)",
                symbol: "rectangle.split.2x1", tint: agent.map { agentStateColor($0.state) } ?? .secondary,
                rank: agent?.stateRank ?? 11,
                open: { viewModel.openPane(pane.id) }
            )
        }
        let machines = viewModel.machines.map { machine in
            Item(
                id: "machine-\(machine.name)", kind: .machine,
                title: machine.name,
                detail: "\(machine.host) · \(machine.disabled == true ? "Disabled" : "Saved machine")",
                symbol: "server.rack", tint: machine.disabled == true ? .secondary : .hiveAmber, rank: 30,
                open: { viewModel.inspectMachine(machine) }
            )
        }
        let all = agents + panes + tabs + environments + machines
        guard !query.isEmpty else { return all }
        return all
            .compactMap { item in Self.score(query, in: item.title + " " + item.detail).map { (item, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.rank < $1.0.rank }
            .map(\.0)
    }

    var body: some View {
        let results = Array(items.prefix(9))
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Jump to an agent, pane, tab, environment or machine", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($isSearchFocused)
                    .onSubmit { open(results) }
                    .onKeyPress(.downArrow) { move(1, in: results); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: results); return .handled }
                    .onKeyPress(.escape) { viewModel.showingQuickOpen = false; return .handled }
            }
            .padding(.horizontal, 16)
            .frame(height: 50)

            if !results.isEmpty {
                Divider()
                VStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                        row(item, isSelected: index == selection)
                            .contentShape(Rectangle())
                            .onTapGesture { selection = index; open(results) }
                            .onHover { if $0 { selection = index } }
                    }
                }
                .padding(6)
            } else if !query.isEmpty {
                Divider()
                Text("Nothing matches “\(query)”")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            }
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
        .onAppear { isSearchFocused = true }
        .onChange(of: query) { selection = 0 }
    }

    private func row(_ item: Item, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(item.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(item.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.hiveAmber.opacity(0.18) : .clear)
        )
    }

    private func move(_ offset: Int, in results: [Item]) {
        guard !results.isEmpty else { return }
        selection = (selection + offset + results.count) % results.count
    }

    private func open(_ results: [Item]) {
        guard results.indices.contains(selection) else { return }
        viewModel.showingQuickOpen = false
        results[selection].open()
    }

    /// Characters of `query` in order within `text`: higher for a prefix or a run of matches.
    private static func score(_ query: String, in text: String) -> Int? {
        let query = query.lowercased()
        let text = text.lowercased()
        if text.hasPrefix(query) { return 1000 }
        if text.contains(query) { return 500 }
        var score = 0
        var streak = 0
        var remaining = query[...]
        for character in text {
            guard let next = remaining.first else { break }
            if character == next {
                streak += 1
                score += streak
                remaining = remaining.dropFirst()
            } else {
                streak = 0
            }
        }
        return remaining.isEmpty ? score : nil
    }
}
