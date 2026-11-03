import AppKit
import SwiftUI

struct HiveOnboardingView: View {
    @StateObject private var viewModel: OnboardingViewModel
    @AppStorage("hive.appearance") private var appearance = "system"
    let onFinish: () -> Void

    init(hiveURL: URL, onFinish: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: OnboardingViewModel(hiveURL: hiveURL))
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                pageContent
                    .frame(maxWidth: 670, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 44)
                    .padding(.vertical, 34)
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 760, minHeight: 560)
        .task {
            await viewModel.loadMachines()
            await viewModel.loadMigrationPreview()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image("HiveBee")
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: 34, height: 34)
            Text("Welcome to Hive")
                .font(.headline)
            Text("SETUP")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .overlay(Capsule().strokeBorder(.quaternary))
            Spacer()
            Text("\(viewModel.page + 1) of 4")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch viewModel.page {
        case 0: welcomePage
        case 1: machinesPage
        case 2: migrationPage
        default: readyPage
        }
    }

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("A calmer home for your agents.")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("Hive keeps your workspaces and agents running through its local runtime. You can add remote machines and bring over familiar settings in a moment.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Appearance")
                    .font(.headline)
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                Text("You can change this later in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))

            Label("Your existing Hive runtime and agents stay where they are.", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var machinesPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            pageHeading("Bring your machines together", subtitle: "Hive connects to remote runtimes over SSH, using the hosts, keys, and options in your OpenSSH config.")

            VStack(spacing: 0) {
                if viewModel.isLoadingMachines && viewModel.machines.isEmpty {
                    ProgressView("Loading saved machines…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                } else if viewModel.machines.isEmpty {
                    Label("No remote machines saved yet", systemImage: "desktopcomputer")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                } else {
                    ForEach(viewModel.machines) { machine in
                        HStack(spacing: 12) {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(machine.name).font(.body.weight(.medium))
                                Text(machine.host).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(machine.disabled == true ? "Paused" : "Saved")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button {
                                Task { await viewModel.checkMachine(machine) }
                            } label: {
                                if viewModel.checkingMachine == machine.name {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("Check")
                                }
                            }
                            .disabled(viewModel.checkingMachine != nil)
                        }
                        .padding(14)
                        if machine.id != viewModel.machines.last?.id { Divider() }
                    }
                }

                Divider()
                HStack(spacing: 10) {
                    TextField("Name", text: $viewModel.machineName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                    TextField("SSH host or user@host", text: $viewModel.machineHost)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await viewModel.addMachine() } }
                    Button {
                        Task { await viewModel.addMachine() }
                    } label: {
                        if viewModel.isAddingMachine { ProgressView().controlSize(.small) }
                        else { Label("Add", systemImage: "plus") }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.96, green: 0.70, blue: 0.25))
                    .disabled(viewModel.machineName.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.machineHost.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isAddingMachine)
                }
                .padding(14)
            }
            .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))

            Text("Add saves the SSH destination through `hive machine add`. Check connects through `hive machine status`.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let machineMessage = viewModel.machineMessage {
                Label(machineMessage, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            feedback
        }
    }

    private var migrationPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            pageHeading("Make Hive feel familiar", subtitle: "Hive can import compatible settings and keybindings from your existing Herd config. The Hive CLI reports what maps and what has no equivalent.")

            if viewModel.legacyConfigAvailable {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Herd settings found", systemImage: "arrow.left.arrow.right")
                        .font(.headline)
                    Text("The CLI will read ~/.config/herdr/config.toml and write compatible settings to Hive’s config. If a Hive config already exists, the CLI keeps a backup beside it.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if viewModel.isLoadingMigrationPreview {
                        ProgressView("Checking settings with Hive…").controlSize(.small)
                    } else if let preview = viewModel.migrationPreview {
                        Text("\(preview.mapped?.count ?? 0) setting(s) can be carried over · \(preview.skipped?.count ?? 0) need manual review")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Use Herd’s familiar default keybindings", isOn: $viewModel.keepHerdrKeys)
                    Button {
                        Task { await viewModel.importHerdrSettings() }
                    } label: {
                        Label("Import settings", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.96, green: 0.70, blue: 0.25))
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                feedback
            } else {
                Label("No Herd config found", systemImage: "checkmark.circle")
                    .font(.headline)
                Text("You can still set up Hive from scratch. Runtime settings live in ~/.config/hive/config.toml; check them with `hive config show`.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let migrationMessage = viewModel.migrationMessage {
                    Text(migrationMessage).font(.callout).foregroundStyle(.secondary)
                }
            }

            Label("Your agents keep running while you finish setup.", systemImage: "bolt.horizontal.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var readyPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            pageHeading("Ready when you are.", subtitle: "The native app and Hive’s command line share the same runtime. Start in the app, or use the CLI from any terminal.")

            VStack(alignment: .leading, spacing: 12) {
                commandRow("hive", detail: "Open the terminal workspace")
                Divider()
                commandRow("hive status", detail: "Check the local runtime")
                Divider()
                commandRow("hive machine list", detail: "See saved remote machines")
            }
            .padding(18)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))

            Text("Hive stores its runtime data in ~/.hive and its settings in ~/.config/hive/config.toml. The app uses the installed Hive CLI to reach that runtime.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func commandRow(_ command: String, detail: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(command).font(.system(.body, design: .monospaced).weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            .buttonStyle(.bordered)
        }
    }

    private var feedback: some View {
        Group {
            if let message = viewModel.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let message = viewModel.migrationMessage {
                Label(message, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pageHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 28, weight: .semibold, design: .rounded))
            Text(subtitle).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 7) {
                ForEach(0..<4) { index in
                    Capsule()
                        .fill(index == viewModel.page ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: index == viewModel.page ? 20 : 7, height: 7)
                }
            }
            Spacer()
            if viewModel.page > 0 {
                Button("Back") { viewModel.page -= 1 }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 8)
            }
            Button {
                if viewModel.page == 3 { onFinish() }
                else { viewModel.page += 1 }
            } label: {
                Label(viewModel.page == 3 ? "Open Hive" : "Next", systemImage: viewModel.page == 3 ? "arrow.up.right" : "arrow.right")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.96, green: 0.70, blue: 0.25))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}
