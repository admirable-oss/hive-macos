import AppKit
import SwiftUI

/// A repository's worktrees: every checkout, whether it has an environment, and ways to
/// open one as an environment or remove it (its agents, environments and checkout; the
/// branch stays).
struct WorktreesSheet: View {
    /// An environment in the repository; its path names the repository.
    let repository: HiveEnvironment
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var worktrees: [HiveWorktreeInfo] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var busyPath: String?
    @State private var pendingRemoval: HiveWorktreeInfo?
    /// Set when Hive refused a removal because the checkout has uncommitted changes.
    @State private var pendingForce: HiveWorktreeInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HiveSheetHeader(
                symbol: "arrow.triangle.branch",
                title: "Worktrees",
                subtitle: repository.worktree?.repo ?? repository.path,
                onClose: { dismiss() }
            ) {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(HiveIconButtonStyle())
                    .help("Reload")
            }

            Group {
                if isLoading && worktrees.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                } else if worktrees.isEmpty {
                    ContentUnavailableView("No Worktrees", systemImage: "arrow.triangle.branch", description: Text(error ?? "This repository has no worktrees."))
                        .frame(minHeight: 200)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(worktrees) { worktree in
                                row(worktree)
                            }
                        }
                        .padding(16)
                    }
                    .frame(maxHeight: 420)
                }
            }

            if let error, !worktrees.isEmpty {
                HiveNotice(text: error).padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
        .frame(width: 600)
        .task { await load() }
        .confirmationDialog(
            "Remove this worktree?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { worktree in
            Button("Remove Worktree", role: .destructive) { remove(worktree, force: false) }
            Button("Cancel", role: .cancel) {}
        } message: { worktree in
            Text(removalMessage(worktree))
        }
        .confirmationDialog(
            "Discard uncommitted changes?",
            isPresented: Binding(get: { pendingForce != nil }, set: { if !$0 { pendingForce = nil } }),
            titleVisibility: .visible,
            presenting: pendingForce
        ) { worktree in
            Button("Discard Changes and Remove", role: .destructive) { remove(worktree, force: true) }
            Button("Keep Worktree", role: .cancel) {}
        } message: { worktree in
            Text("\(worktree.path) has changes that aren’t committed. Removing it now deletes them for good. The branch \(worktree.branch.map { "“\($0)” " } ?? "")is kept.")
        }
    }

    private func row(_ worktree: HiveWorktreeInfo) -> some View {
        let environments = worktree.environments ?? []
        let environment = environments.first.flatMap { id in viewModel.environments.first(where: { $0.id == id }) }
        let changes = environment.map { ($0.git?.modified ?? 0) + ($0.git?.staged ?? 0) + ($0.git?.untracked ?? 0) } ?? 0
        return HStack(spacing: 10) {
            Image(systemName: worktree.main == true ? "house" : "arrow.triangle.branch")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(worktree.main == true ? Color.secondary : Color.hiveAmber)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(worktree.branch ?? (worktree.detached == true ? "detached HEAD" : "—"))
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    if worktree.main == true { HiveChip(text: "main checkout") }
                    if worktree.locked == true { HiveChip(text: "locked", symbol: "lock.fill") }
                    if changes > 0 { HiveChip(text: "\(changes) changed", tint: .orange) }
                }
                Text(worktree.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(worktree.path)
            }
            Spacer(minLength: 8)
            if busyPath == worktree.path {
                ProgressView().controlSize(.small)
            } else {
                if let environment {
                    Button("Open") { viewModel.openEnvironment(environment.id); dismiss() }
                        .buttonStyle(.hiveCompact)
                        .help("Open its environment, \(environment.id)")
                } else if worktree.bare != true {
                    Button("Add Environment") { open(worktree) }
                        .buttonStyle(.hiveCompact)
                        .help("Give this checkout an environment so agents can run in it")
                }
                Menu {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktree.path)]) }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(worktree.path, forType: .string)
                    }
                    if worktree.main != true && worktree.bare != true {
                        Divider()
                        Button("Remove Worktree…", role: .destructive) { pendingRemoval = worktree }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .buttonStyle(HiveIconButtonStyle(size: 24))
                .fixedSize()
            }
        }
        .padding(10)
        .hiveCard(padding: 0)
    }

    private func removalMessage(_ worktree: HiveWorktreeInfo) -> String {
        let environments = worktree.environments ?? []
        let agents = viewModel.agents.filter { environments.contains($0.environmentID) && $0.state != "exited" }
        var parts = ["Hive deletes the checkout at \(worktree.path)."]
        if !environments.isEmpty { parts.append("Its environment\(environments.count == 1 ? "" : "s") (\(environments.joined(separator: ", "))) go with it.") }
        if !agents.isEmpty { parts.append("\(agents.count) running agent\(agents.count == 1 ? "" : "s") will stop.") }
        parts.append("The branch\(worktree.branch.map { " “\($0)”" } ?? "") is kept.")
        return parts.joined(separator: " ")
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            worktrees = try await viewModel.workspace.worktrees(ofRepository: repository.worktree?.repo ?? repository.path)
                .sorted { ($0.main == true ? 0 : 1, $0.path) < ($1.main == true ? 0 : 1, $1.path) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func open(_ worktree: HiveWorktreeInfo) {
        busyPath = worktree.path
        Task {
            defer { busyPath = nil }
            do {
                try await viewModel.openWorktree(path: worktree.path)
                await load()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func remove(_ worktree: HiveWorktreeInfo, force: Bool) {
        busyPath = worktree.path
        Task {
            defer { busyPath = nil }
            do {
                try await viewModel.removeWorktree(path: worktree.path, force: force)
                withAnimation { worktrees.removeAll { $0.path == worktree.path } }
                error = nil
            } catch {
                // Hive refuses a checkout with uncommitted changes unless told to discard them.
                if !force, error.localizedDescription.localizedCaseInsensitiveContains("uncommitted") {
                    pendingForce = worktree
                } else {
                    self.error = error.localizedDescription
                }
            }
        }
    }
}
