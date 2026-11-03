import AppKit
import Combine
import Darwin
import SwiftTerm
import SwiftUI

struct TerminalLaunch {
    let executable: String
    let arguments: [String]
    /// argv[0]; a leading "-" makes a shell start as a login shell.
    let execName: String?
    let directory: String
}

/// One terminal a tab shows. Outlives the SwiftUI views that display it, so switching
/// tabs never restarts a shell or detaches an agent. Subclasses decide where the bytes
/// come from: a local process, or an agent's terminal on the daemon.
@MainActor
class TerminalSession: NSObject, ObservableObject {
    let terminalView: TerminalView

    @Published fileprivate(set) var isRunning = false
    /// What to say once the terminal has ended; nil while it runs.
    @Published fileprivate(set) var endedMessage: String?
    /// Where the terminal is working right now.
    @Published fileprivate(set) var currentDirectory: String

    var restartTitle: String { "Restart" }

    fileprivate init(terminalView: TerminalView, directory: String) {
        self.terminalView = terminalView
        currentDirectory = directory
        super.init()
        terminalView.font = Self.font(size: 12.5)
        terminalView.optionAsMetaKey = true
    }

    func start() {}

    func terminate() {}

    fileprivate func ended(_ message: String) {
        isRunning = false
        endedMessage = message
    }

    /// Prompt themes (Powerlevel10k, Starship) draw icons from Nerd Fonts, so use one when it's installed.
    /// Otherwise SF Mono, falling back to the Nerd Font symbols font for those glyphs if that's present.
    private static func font(size: CGFloat) -> NSFont {
        let nerdFamilies = ["MesloLGS NF", "MesloLGS Nerd Font Mono", "JetBrainsMono Nerd Font Mono", "Hack Nerd Font Mono", "FiraCode Nerd Font Mono"]
        for family in nerdFamilies {
            if let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
                return font
            }
        }
        let base = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let symbols = NSFontDescriptor(fontAttributes: [.family: "Symbols Nerd Font Mono"])
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: [symbols]])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

/// A local login shell in a pseudo-terminal.
final class ShellTerminalSession: TerminalSession, LocalProcessTerminalViewDelegate {
    let launch: TerminalLaunch
    private let processView: LocalProcessTerminalView
    private var hasStarted = false
    private var directoryTimer: Timer?

    init(launch: TerminalLaunch) {
        self.launch = launch
        processView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        super.init(terminalView: processView, directory: launch.directory)
        processView.processDelegate = self
        start()
        // zsh doesn't report its directory (OSC 7) by default, so ask the kernel instead.
        directoryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCurrentDirectory() }
        }
    }

    override func start() {
        if hasStarted {
            // Clear the previous run's screen (RIS) before restarting in the same view.
            processView.feed(text: "\u{1b}c")
        }
        hasStarted = true
        isRunning = true
        endedMessage = nil
        processView.startProcess(
            executable: launch.executable,
            args: launch.arguments,
            environment: Self.environment,
            execName: launch.execName,
            currentDirectory: currentDirectory
        )
    }

    override func terminate() {
        directoryTimer?.invalidate()
        guard isRunning else { return }
        processView.terminate()
    }

    private func refreshCurrentDirectory() {
        guard isRunning, let pid = processView.process?.shellPid, pid > 0,
              let directory = Self.workingDirectory(of: pid),
              directory != currentDirectory else { return }
        currentDirectory = directory
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { buffer in
            String(cString: buffer.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    private static var environment: [String] {
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("DYLD_") && !key.hasPrefix("__XPC") && !key.hasPrefix("OS_ACTIVITY")
        }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Hive"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        return environment.map { "\($0.key)=\($0.value)" }
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // OSC 7 sends a file:// URL; some shells send a bare path.
        guard let directory else { return }
        let path = URL(string: directory).flatMap { $0.isFileURL ? $0.path : nil } ?? directory
        if !path.isEmpty, path != currentDirectory { currentDirectory = path }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let exitCode, exitCode != 0 else { return ended("Shell exited") }
        ended("Shell exited with code \(exitCode)")
    }
}

/// An agent's terminal on the daemon, viewed over the socket (`terminal.attach`):
/// the pipe brings painted screen updates and takes keystrokes, resizes go through
/// `terminal.resize`. Closing the view leaves the agent running.
final class AgentTerminalSession: TerminalSession, TerminalViewDelegate {
    let agentID: String
    private let workspace: HiveWorkspaceStore
    private var pipe: HivePipe?
    private var processID: String?
    private var viewID: String?
    private var streamTask: Task<Void, Never>?
    private var hasStarted = false

    override var restartTitle: String { "Reattach" }

    init(agentID: String, directory: String, workspace: HiveWorkspaceStore) {
        self.agentID = agentID
        self.workspace = workspace
        super.init(terminalView: TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500)), directory: directory)
        terminalView.terminalDelegate = self
        start()
    }

    override func start() {
        if hasStarted { terminalView.feed(text: "\u{1b}c") }
        hasStarted = true
        isRunning = true
        endedMessage = nil
        streamTask?.cancel()
        streamTask = Task { await attachAndStream() }
    }

    override func terminate() {
        streamTask?.cancel()
        pipe?.close()
    }

    private func attachAndStream() async {
        do {
            // Right after an agent starts, its pane can be a moment behind the agent itself.
            var processID = workspace.processID(forAgent: agentID)
            for _ in 0..<20 where processID == nil {
                try await Task.sleep(for: .milliseconds(150))
                processID = workspace.processID(forAgent: agentID)
            }
            guard let processID else { return ended("This agent has no terminal any more") }

            let size = terminalView.terminalDimensions
            let attached = try await workspace.attach(processID: processID, width: size.cols, height: size.rows)
            self.processID = processID
            viewID = attached.view.viewID
            pipe = attached.pipe

            // The view may have been laid out at another size while attaching.
            let current = terminalView.terminalDimensions
            if current.cols != attached.view.width || current.rows != attached.view.height {
                sendResize(cols: current.cols, rows: current.rows)
            }

            for await chunk in attached.pipe.incoming {
                terminalView.feed(byteArray: [UInt8](chunk)[...])
            }
            guard !Task.isCancelled else { return }
            ended(attached.pipe.closeError?.message ?? "The agent’s terminal closed")
        } catch is CancellationError {
            return
        } catch {
            ended(error.localizedDescription)
        }
    }

    private func sendResize(cols: Int, rows: Int) {
        guard let processID, let viewID, cols > 0, rows > 0 else { return }
        Task { try? await workspace.resize(processID: processID, viewID: viewID, width: cols, height: rows) }
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        pipe?.send(Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        sendResize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@MainActor
final class TerminalStore: ObservableObject {
    private var sessions: [WorkspaceTab.ID: TerminalSession] = [:]

    func session(for tab: WorkspaceTab, make: () -> TerminalSession) -> TerminalSession {
        if let session = sessions[tab.id] { return session }
        let session = make()
        sessions[tab.id] = session
        return session
    }

    /// Where each open shell is, for restoring tabs on the next launch.
    var currentDirectories: [WorkspaceTab.ID: String] {
        sessions.compactMapValues { $0 is ShellTerminalSession ? $0.currentDirectory : nil }
    }

    /// Ends the processes of tabs that were closed.
    func retainSessions(for tabs: [WorkspaceTab]) {
        let open = Set(tabs.map(\.id))
        for (id, session) in sessions where !open.contains(id) {
            session.terminate()
            sessions[id] = nil
        }
    }
}

struct TerminalTabView: View {
    @ObservedObject var session: TerminalSession
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TerminalHostView(session: session, colorScheme: colorScheme)
            .padding(.leading, 12)
            .padding(.top, 6)
            .background(TerminalPalette(colorScheme).background)
            .overlay(alignment: .bottom) {
                if !session.isRunning {
                    exitBanner
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: session.isRunning)
    }

    private var exitBanner: some View {
        HStack(spacing: 12) {
            Text(exitMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(session.restartTitle, action: session.start)
                .buttonStyle(.borderedProminent)
            Button("Close Tab", action: onClose)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(SwiftUI.Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }

    private var exitMessage: String {
        session.endedMessage ?? "Ended"
    }
}

private struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession
    let colorScheme: ColorScheme

    final class Coordinator {
        var appliedScheme: ColorScheme?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        let terminal = session.terminalView
        if terminal.superview !== container {
            terminal.removeFromSuperview()
            terminal.frame = container.bounds
            terminal.autoresizingMask = [.width, .height]
            container.addSubview(terminal)
            DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
        }
        if context.coordinator.appliedScheme != colorScheme {
            context.coordinator.appliedScheme = colorScheme
            TerminalPalette(colorScheme).apply(to: terminal)
        }
    }
}

private struct TerminalPalette {
    let background: SwiftUI.Color
    let nsBackground: NSColor
    let foreground: NSColor

    init(_ colorScheme: ColorScheme) {
        if colorScheme == .dark {
            nsBackground = NSColor(srgbRed: 0.118, green: 0.118, blue: 0.122, alpha: 1)
            foreground = NSColor(srgbRed: 0.89, green: 0.89, blue: 0.9, alpha: 1)
        } else {
            nsBackground = NSColor(srgbRed: 0.995, green: 0.995, blue: 0.995, alpha: 1)
            foreground = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)
        }
        background = SwiftUI.Color(nsColor: nsBackground)
    }

    func apply(to terminal: TerminalView) {
        let amber = NSColor(SwiftUI.Color.hiveAmber)
        terminal.nativeBackgroundColor = nsBackground
        terminal.nativeForegroundColor = foreground
        terminal.caretColor = amber
        terminal.selectedTextBackgroundColor = amber.withAlphaComponent(0.3)
    }
}
