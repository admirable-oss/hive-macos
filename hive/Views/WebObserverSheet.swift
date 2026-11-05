import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The web observer, all of it: run it, choose what it may show, share sign-in links (with a QR
/// code for a phone), see and revoke who has access, and read the audit log.
struct WebObserverSheet: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    enum Section: String, CaseIterable { case server, share, access, activity }

    @State private var section: Section = .server
    @State private var status: WebObserverStatus?
    @State private var runtimes: [WebObserverRuntime] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var notice: String?

    private var service: WebObserverService { WebObserverService(cli: viewModel.cliService) }

    var body: some View {
        VStack(spacing: 0) {
            HiveSheetHeader(
                symbol: "globe",
                title: "Web Observer",
                subtitle: status.map { "Running at \($0.publicURL) · \($0.viewers) viewer\($0.viewers == 1 ? "" : "s")" } ?? "A read-only view of your agents in a browser",
                onClose: { dismiss() }
            ) {
                HiveSegmentedPicker(selection: $section, options: Section.allCases, title: { $0.rawValue.capitalized })
            }

            Group {
                switch section {
                case .server: serverSection
                case .share: WebShareView(viewModel: viewModel, service: service, runtimes: runtimes, isRunning: status != nil)
                case .access: WebAccessView(viewModel: viewModel, service: service, isRunning: status != nil)
                case .activity: WebActivityView(viewModel: viewModel, service: service, isRunning: status != nil)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if let error {
                HiveNotice(text: error).padding(.horizontal, 20).padding(.bottom, 14)
            } else if let notice {
                HiveNotice(text: notice, kind: .success).padding(.horizontal, 20).padding(.bottom, 14)
            }
        }
        .frame(width: 660, height: 560)
        .task { await reload() }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: section)
    }

    // MARK: Server

    private var serverSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(status == nil ? Color.secondary.opacity(0.5) : .green)
                        .frame(width: 10, height: 10)
                        .shadow(color: status == nil ? .clear : .green.opacity(0.6), radius: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status == nil ? "Not running" : "Running")
                            .font(.system(size: 14, weight: .semibold))
                        Text(status.map { "Listening on \($0.listen)" } ?? "It listens on 127.0.0.1:8484, this Mac only, unless [web] in config.toml says otherwise.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isLoading { ProgressView().controlSize(.small) }
                    if let status {
                        Button("Open") { if let url = URL(string: status.publicURL) { NSWorkspace.shared.open(url) } }
                            .buttonStyle(.hive)
                        Button("Stop", role: .destructive) { Task { await stop() } }
                            .buttonStyle(.hive)
                    } else {
                        Button { start() } label: { Label("Start", systemImage: "play.fill") }
                            .buttonStyle(.hivePrimary)
                    }
                }
                .hiveCard(padding: 14)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        HiveSectionTitle(title: "Runtimes it may show", symbol: "server.rack", count: runtimes.isEmpty ? nil : runtimes.count)
                        Spacer()
                        if !runtimes.contains(where: { $0.session == viewModel.sessionName }) {
                            Button { Task { await allowThisSession() } } label: { Label("Allow This Session", systemImage: "plus") }
                                .buttonStyle(.hiveCompact)
                        }
                    }
                    if runtimes.isEmpty {
                        Text("Nothing yet. Allow this session so a share link has something to show. Screens are shown only to links that allow them too.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .hiveCard(padding: 12)
                    } else {
                        ForEach(runtimes) { runtime in
                            HStack(spacing: 10) {
                                Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(runtime.name).font(.system(size: 12.5, weight: .semibold))
                                    Text(runtimeDetail(runtime)).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let live = status?.runtimes.first(where: { $0.name == runtime.name }), let state = live.state {
                                    HiveChip(text: state)
                                }
                                Button("Remove", role: .destructive) { Task { await remove(runtime) } }
                                    .buttonStyle(.hiveCompact)
                                    .help("Its viewers lose it at once")
                            }
                            .padding(10)
                            .hiveCard(padding: 0)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func runtimeDetail(_ runtime: WebObserverRuntime) -> String {
        var parts = ["session \(runtime.session ?? "default")"]
        if runtime.scope?.all == true { parts.append("every environment") }
        else if let environments = runtime.scope?.environments, !environments.isEmpty { parts.append(environments.joined(separator: ", ")) }
        parts.append(runtime.screens == true ? "screens allowed" : "no screens")
        return parts.joined(separator: " · ")
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let status = service.status()
            async let runtimes = service.runtimes()
            self.status = try await status
            self.runtimes = try await runtimes
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func start() {
        do {
            try service.start()
            notice = "Started. It keeps running after you quit the app; its output goes to \(WebObserverService.logURL.path)."
            error = nil
            Task {
                // It takes a moment to listen.
                for _ in 0..<10 where status == nil {
                    try? await Task.sleep(for: .milliseconds(400))
                    await reload()
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func stop() async {
        await service.stop()
        notice = nil
        try? await Task.sleep(for: .milliseconds(400))
        await reload()
    }

    private func allowThisSession() async {
        do {
            try await service.addRuntime(name: viewModel.sessionName == "default" ? (Host.current().localizedName ?? "this-mac") : viewModel.sessionName, environments: [], screens: true)
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove(_ runtime: WebObserverRuntime) async {
        do {
            try await service.removeRuntime(runtime.name)
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Share

private struct WebShareView: View {
    @ObservedObject var viewModel: AppViewModel
    let service: WebObserverService
    let runtimes: [WebObserverRuntime]
    let isRunning: Bool

    @State private var request = WebShareRequest()
    @State private var everything = true
    @State private var selectedEnvironments: Set<String> = []
    @State private var link: String?
    @State private var grant: WebObserverGrant?
    @State private var isSharing = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !isRunning {
                    HiveNotice(text: "Start the web observer first: links only work while it runs.", kind: .info)
                }
                if let link {
                    shared(link)
                } else {
                    form
                }
                if let error { HiveNotice(text: error) }
            }
            .padding(20)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: link)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            HiveFieldLabel(title: "Label, shown to the viewer and in the audit log") {
                TextField("Pairing with Sam", text: $request.label)
                    .textFieldStyle(.hive)
            }
            HiveFieldLabel(title: "What it shows") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Every environment the runtimes show", isOn: $everything)
                    if !everything {
                        ForEach(viewModel.environments) { environment in
                            Toggle(environment.name.isEmpty ? environment.id : environment.name, isOn: Binding(
                                get: { selectedEnvironments.contains(environment.id) },
                                set: { if $0 { selectedEnvironments.insert(environment.id) } else { selectedEnvironments.remove(environment.id) } }
                            ))
                            .padding(.leading, 16)
                        }
                    }
                    Toggle("Screens", isOn: $request.screens)
                    Toggle("Output history (includes screens)", isOn: $request.history)
                }
            }
            HStack(alignment: .top, spacing: 18) {
                HiveFieldLabel(title: "Browsers") {
                    Stepper("\(request.uses)", value: $request.uses, in: 1...20)
                }
                HiveFieldLabel(title: "Access lasts") {
                    Picker("", selection: $request.expiresHours) {
                        ForEach([1, 2, 8, 24, 72, 168], id: \.self) { hours in
                            Text(hours < 24 ? "\(hours) h" : "\(hours / 24) d").tag(hours)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }
                HiveFieldLabel(title: "Link works for") {
                    Picker("", selection: $request.linkMinutes) {
                        ForEach([5, 15, 60, 240], id: \.self) { minutes in
                            Text(minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h").tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }
            }
            HStack {
                Text("Viewers can’t type into terminals or change anything. `hive web revoke` or the Access tab ends it at once.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: share) {
                    if isSharing { ProgressView().controlSize(.small) } else { Label("Create Link", systemImage: "link") }
                }
                .buttonStyle(.hivePrimary)
                .disabled(!isRunning || runtimes.isEmpty || isSharing || (!everything && selectedEnvironments.isEmpty))
            }
            if runtimes.isEmpty {
                HiveNotice(text: "Allow this session on the Server tab first.", kind: .info)
            }
        }
    }

    private func shared(_ link: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            if let qr = Self.qrCode(link) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 168, height: 168)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white))
                    .help("Scan with a phone")
            }
            VStack(alignment: .leading, spacing: 10) {
                Label("Link ready", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.green)
                Text(link)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .hiveCard(padding: 8)
                if let grant {
                    Text("Works once\(grant.maxUses.map { $0 > 1 ? " for each of \($0) browsers" : "" } ?? "") until \(Self.time(grant.linkExpiresAt)); access lasts until \(Self.time(grant.expiresAt)).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link, forType: .string)
                    } label: { Label("Copy Link", systemImage: "doc.on.doc") }
                        .buttonStyle(.hivePrimaryCompact)
                    Button("Share Another") { self.link = nil; grant = nil }
                        .buttonStyle(.hiveCompact)
                }
            }
        }
        .transition(.scale(scale: 0.97).combined(with: .opacity))
    }

    private func share() {
        var request = request
        request.runtimes = runtimes.map(\.name)
        request.environments = everything ? [] : Array(selectedEnvironments).sorted()
        isSharing = true
        error = nil
        Task {
            defer { isSharing = false }
            do {
                let shared = try await service.share(request)
                grant = shared.grant
                link = shared.link
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    static func time(_ timestamp: String?) -> String {
        guard let date = timestamp.flatMap(HiveWorkspaceStore.parseDate) else { return "—" }
        return date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
    }

    static func qrCode(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

// MARK: - Access

private struct WebAccessView: View {
    @ObservedObject var viewModel: AppViewModel
    let service: WebObserverService
    let isRunning: Bool

    @State private var grants: [WebObserverGrant] = []
    @State private var sessions: [WebObserverSession] = []
    @State private var devices: [WebObserverPushStatus.Device] = []
    @State private var token = ""
    @State private var validation: String?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !isRunning {
                    HiveNotice(text: "Grants and browsers are listed while the web observer runs.", kind: .info)
                }
                HiveSectionTitle(title: "Shared access", symbol: "person.2", count: grants.isEmpty ? nil : grants.count)
                if grants.isEmpty {
                    Text("No links shared.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(grants) { grant in grantRow(grant) }

                if !sessions.isEmpty {
                    HiveSectionTitle(title: "Signed-in browsers", symbol: "macwindow", count: sessions.count)
                    ForEach(sessions) { session in
                        HStack {
                            Text(session.userAgent ?? session.id).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            Text("seen \(WebShareView.time(session.lastSeenAt))").font(.system(size: 11)).foregroundStyle(.secondary)
                            Button("Sign Out", role: .destructive) { Task { await revoke(session.id) } }
                                .buttonStyle(.hiveCompact)
                        }
                        .padding(10)
                        .hiveCard(padding: 0)
                    }
                }

                if !devices.isEmpty {
                    HiveSectionTitle(title: "Devices getting notifications", symbol: "bell.badge", count: devices.count)
                    ForEach(Array(devices.enumerated()), id: \.offset) { _, device in
                        HStack {
                            Text(device.userAgent ?? device.id ?? "Device").font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            if let target = device.session ?? device.grant {
                                Button("Send Test") { Task { await testPush(target) } }
                                    .buttonStyle(.hiveCompact)
                            }
                        }
                        .padding(10)
                        .hiveCard(padding: 0)
                    }
                }

                HiveSectionTitle(title: "Check an observer token", symbol: "key")
                HStack {
                    SecureField("hob_…", text: $token)
                        .textFieldStyle(.hive)
                    Button("Check") { Task { await validate() } }
                        .buttonStyle(.hiveCompact)
                        .disabled(token.isEmpty)
                }
                if let validation { Text(validation).font(.callout).foregroundStyle(.secondary) }
                if let error { HiveNotice(text: error) }
            }
            .padding(20)
        }
        .task { await reload() }
    }

    private func grantRow(_ grant: WebObserverGrant) -> some View {
        let isActive = grant.state == "active"
        return HStack(spacing: 10) {
            Image(systemName: isActive ? "link" : "link.badge.plus")
                .foregroundStyle(isActive ? Color.hiveAmber : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(grant.label.flatMap { $0.isEmpty ? nil : $0 } ?? grant.id)
                    .font(.system(size: 12.5, weight: .semibold))
                Text([
                    "\(grant.uses ?? 0)/\(grant.maxUses ?? 1) used",
                    grant.history == true ? "history" : grant.screens == true ? "screens" : "states only",
                    "until \(WebShareView.time(grant.expiresAt))",
                ].joined(separator: " · "))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer()
            HiveChip(text: grant.state, tint: isActive ? .green : nil)
            if isActive {
                Button("Revoke", role: .destructive) { Task { await revoke(grant.id) } }
                    .buttonStyle(.hiveCompact)
                    .help("Ends this access and signs out its browsers at once")
            }
        }
        .padding(10)
        .hiveCard(padding: 0)
    }

    private func reload() async {
        guard isRunning else { return }
        do {
            let result = try await service.grants()
            grants = result.grants
            sessions = result.sessions
            devices = (try? await service.pushStatus().devices) ?? []
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func revoke(_ id: String) async {
        do { try await service.revoke(id); await reload() }
        catch { self.error = error.localizedDescription }
    }

    private func testPush(_ target: String) async {
        do { try await service.testPush(target) }
        catch { self.error = error.localizedDescription }
    }

    private func validate() async {
        do {
            let result = try await viewModel.workspace.validateObserverToken(token.trimmingCharacters(in: .whitespacesAndNewlines))
            if result.valid, let credential = result.credential {
                validation = "Valid: “\(credential.name)”, until \(WebShareView.time(credential.expiresAt))."
            } else {
                validation = "Not valid: \(result.state)."
            }
        } catch {
            validation = error.localizedDescription
        }
    }
}

// MARK: - Activity

private struct WebActivityView: View {
    @ObservedObject var viewModel: AppViewModel
    let service: WebObserverService
    let isRunning: Bool

    @State private var entries: [WebObserverAuditEntry] = []
    @State private var observers: [HiveObserverActivity.Observer] = []
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HiveSectionTitle(title: "Connected observers", symbol: "eye", count: observers.isEmpty ? nil : observers.count)
                if observers.isEmpty {
                    Text("No observer is connected to this session right now.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(observers) { observer in
                    HStack {
                        Text(observer.name).font(.system(size: 12.5, weight: .medium))
                        Spacer()
                        HiveChip(text: "\(observer.connections) connection\(observer.connections == 1 ? "" : "s")")
                    }
                    .padding(10)
                    .hiveCard(padding: 0)
                }

                HiveSectionTitle(title: "Web access log", symbol: "list.bullet.rectangle", count: entries.isEmpty ? nil : entries.count)
                if !isRunning {
                    Text("The log is read from the running web observer.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(WebShareView.time(entry.time))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                        Text(entry.action).font(.system(size: 12, weight: .semibold))
                        Text([entry.name, entry.detail].compactMap { $0 }.joined(separator: " — "))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Divider().opacity(0.4)
                }
                if let error { HiveNotice(text: error) }
            }
            .padding(20)
        }
        .task {
            observers = (try? await viewModel.workspace.observerActivity().observers) ?? []
            guard isRunning else { return }
            do { entries = try await service.audit(limit: 100).reversed() }
            catch { self.error = error.localizedDescription }
        }
    }
}
