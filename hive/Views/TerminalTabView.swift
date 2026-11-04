import AppKit
import Combine
import Darwin
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers

struct TerminalLaunch {
    let executable: String
    let arguments: [String]
    /// argv[0]; a leading "-" makes a shell start as a login shell.
    let execName: String?
    let directory: String
}

/// One terminal on screen. Outlives the SwiftUI views that display it, so switching
/// tabs never restarts a shell or detaches from a pane. Subclasses decide where the
/// bytes come from: a local process, or a pane on the Hive daemon.
@MainActor
class TerminalSession: NSObject, ObservableObject {
    let terminalView: TerminalView

    @Published fileprivate(set) var isRunning = false
    /// What to say once the terminal has ended; nil while it runs.
    @Published fileprivate(set) var endedMessage: String?
    /// Where the terminal's shell is working right now; follows `cd`.
    @Published fileprivate(set) var currentDirectory: String

    var restartTitle: String { "Restart" }
    var closeTitle: String { "Close Tab" }

    private var directoryTimer: Timer?

    fileprivate init(terminalView: TerminalView, directory: String) {
        self.terminalView = terminalView
        currentDirectory = directory
        super.init()
        terminalView.font = Self.font
        terminalView.optionAsMetaKey = true
        // Shells don't report their directory (OSC 7) by default, so ask the kernel.
        directoryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCurrentDirectory() }
        }
    }

    func start() {}

    func terminate() {
        directoryTimer?.invalidate()
    }

    /// The process whose working directory the session follows.
    fileprivate var trackedPID: pid_t? { nil }

    fileprivate func ended(_ message: String) {
        isRunning = false
        endedMessage = message
    }

    private func refreshCurrentDirectory() {
        guard isRunning, let pid = trackedPID, pid > 0,
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

    /// Prompt themes (Powerlevel10k, Starship) draw icons from Nerd Fonts, so use one when it's installed.
    /// Otherwise SF Mono, falling back to the Nerd Font symbols font for those glyphs if that's present.
    static let font: NSFont = {
        let size: CGFloat = 12.5
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
    }()

    /// One terminal cell in points, measured the way SwiftTerm measures it.
    static func cellSize(scale: CGFloat) -> CGSize {
        let font = Self.font
        let height = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
        var character: [UniChar] = [0x57] // W
        var glyph: [CGGlyph] = [0]
        let width = CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
            ? font.advancement(forGlyph: NSGlyph(glyph[0])).width
            : font.maximumAdvancement.width
        return CGSize(width: max(1, (width * scale).rounded() / scale), height: max(1, ceil(height * scale) / scale))
    }
}

/// A local login shell: the desktop's scratch tabs, for work outside any environment.
final class ShellTerminalSession: TerminalSession, LocalProcessTerminalViewDelegate {
    let launch: TerminalLaunch
    private let processView: LocalProcessTerminalView
    private var hasStarted = false

    init(launch: TerminalLaunch) {
        self.launch = launch
        processView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        super.init(terminalView: processView, directory: launch.directory)
        processView.processDelegate = self
        start()
    }

    override fileprivate var trackedPID: pid_t? { processView.process?.shellPid }

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
        super.terminate()
        guard isRunning else { return }
        processView.terminate()
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

/// A terminal view that hands pasted images to Hive instead of dropping them.
final class HivePaneTerminalView: TerminalView {
    /// Gets a PNG when the clipboard holds an image and no text or files.
    var onPasteImage: ((Data) -> Void)?

    override func paste(_ sender: Any) {
        if let png = Self.pastedImage(), let onPasteImage {
            onPasteImage(png)
            return
        }
        super.paste(sender)
    }

    private static func pastedImage() -> Data? {
        let pasteboard = NSPasteboard.general
        // Copied text and Finder files paste as text and paths, as before.
        if pasteboard.string(forType: .string) != nil || pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return nil
        }
        if let png = pasteboard.data(forType: .png) { return png }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// A pane on the Hive daemon, viewed over the socket (`terminal.attach`): the pipe
/// brings painted screen updates and takes keystrokes, and resizes go through
/// `terminal.resize`. Closing the view leaves the pane's process running.
final class PaneTerminalSession: TerminalSession, TerminalViewDelegate {
    let paneID: String
    private let workspace: HiveWorkspaceStore
    private var pipe: HivePipe?
    private var processID: String?
    private var viewID: String?
    private var streamTask: Task<Void, Never>?
    private var hasStarted = false

    override var restartTitle: String { "Reattach" }
    override var closeTitle: String { "Close Pane" }

    init(paneID: String, directory: String, workspace: HiveWorkspaceStore) {
        self.paneID = paneID
        self.workspace = workspace
        let view = HivePaneTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        super.init(terminalView: view, directory: directory)
        view.terminalDelegate = self
        view.onPasteImage = { [weak self] png in self?.pasteImage(png) }
        start()
    }

    override fileprivate var trackedPID: pid_t? {
        // The daemon runs on this Mac, so its pane processes are ours to inspect.
        workspace.process(forPane: paneID).map { pid_t($0.pid) }
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
        super.terminate()
        streamTask?.cancel()
        pipe?.close()
    }

    private func attachAndStream() async {
        do {
            // A pane that was just created can be a moment ahead of the snapshot.
            var processID = workspace.panes[paneID]?.processID
            for _ in 0..<20 where processID == nil {
                try await Task.sleep(for: .milliseconds(150))
                processID = workspace.panes[paneID]?.processID
            }
            guard let processID else { return ended("This pane is gone") }

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
            ended(attached.pipe.closeError?.message ?? "The pane’s process ended")
        } catch is CancellationError {
            return
        } catch {
            ended(error.localizedDescription)
        }
    }

    func pasteImage(_ png: Data) {
        guard let processID else { return }
        Task {
            do {
                try await workspace.sendImage(png: png, toProcess: processID, viewID: viewID)
            } catch {
                terminalView.feed(text: "\r\n[Hive couldn’t paste the image: \(error.localizedDescription)]\r\n")
            }
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

/// Every terminal the window shows, kept alive while its tab or pane is open.
@MainActor
final class TerminalStore: ObservableObject {
    private var sessions: [String: TerminalSession] = [:]

    func scratchSession(for tab: WorkspaceTab, make: () -> ShellTerminalSession) -> TerminalSession {
        session(forKey: "scratch:\(tab.id)", make: make)
    }

    func paneSession(_ paneID: String, make: () -> PaneTerminalSession) -> TerminalSession {
        session(forKey: "pane:\(paneID)", make: make)
    }

    func existingPaneSession(_ paneID: String) -> TerminalSession? {
        sessions["pane:\(paneID)"]
    }

    /// Where each open scratch shell is, for restoring tabs on the next launch.
    var scratchDirectories: [WorkspaceTab.ID: String] {
        var directories: [WorkspaceTab.ID: String] = [:]
        for (key, session) in sessions where key.hasPrefix("scratch:") {
            if let id = UUID(uuidString: String(key.dropFirst("scratch:".count))) {
                directories[id] = session.currentDirectory
            }
        }
        return directories
    }

    /// Ends scratch shells whose tab closed and detaches from panes no open tab shows.
    func retain(scratchTabs: [WorkspaceTab.ID], panes: Set<String>) {
        let keep = Set(scratchTabs.map { "scratch:\($0)" } + panes.map { "pane:\($0)" })
        for (key, session) in sessions where !keep.contains(key) {
            session.terminate()
            sessions[key] = nil
        }
    }

    private func session<Session: TerminalSession>(forKey key: String, make: () -> Session) -> TerminalSession {
        if let session = sessions[key] { return session }
        let session = make()
        sessions[key] = session
        return session
    }
}

/// One terminal with its end-of-session banner. Reports clicks so Hive can move its focus.
struct TerminalSurface: View {
    @ObservedObject var session: TerminalSession
    var isFocused = true
    var showsFocusRing = false
    var onFocus: () -> Void = {}
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TerminalHostView(session: session, colorScheme: colorScheme, isFocused: isFocused, onFocus: onFocus)
            .padding(.leading, 10)
            .padding(.top, 6)
            .background(TerminalPalette(colorScheme).background)
            .onDrop(of: [UTType.image.identifier], isTargeted: nil) { providers in
                guard let pane = session as? PaneTerminalSession,
                      let provider = providers.first,
                      !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return false }
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in
                        guard let image = NSImage(data: data),
                              let tiff = image.tiffRepresentation,
                              let bitmap = NSBitmapImageRep(data: tiff),
                              let png = bitmap.representation(using: .png, properties: [:]) else { return }
                        pane.pasteImage(png)
                    }
                }
                return true
            }
            .dropDestination(for: URL.self) { urls, _ in
                let paths = urls.filter(\.isFileURL).map { Self.shellQuoted($0.path) }
                guard !paths.isEmpty else { return false }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(paths.joined(separator: " "), forType: .string)
                session.terminalView.paste(session.terminalView)
                return true
            }
            .overlay {
                if showsFocusRing {
                    Rectangle()
                        .strokeBorder(SwiftUI.Color.hiveAmber.opacity(isFocused ? 0.55 : 0), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if !session.isRunning {
                    exitBanner
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: session.isRunning)
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }

    private static func shellQuoted(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private var exitBanner: some View {
        HStack(spacing: 12) {
            Text(session.endedMessage ?? "Ended")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Button(session.restartTitle, action: session.start)
                .buttonStyle(.borderedProminent)
            Button(session.closeTitle, action: onClose)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(SwiftUI.Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
}

private struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession
    let colorScheme: ColorScheme
    let isFocused: Bool
    let onFocus: () -> Void

    final class Coordinator {
        var appliedScheme: ColorScheme?
        var clickMonitor: Any?
        var onFocus: () -> Void = {}
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let coordinator = context.coordinator
        // SwiftTerm keeps clicks to itself; watch for ones that land in this terminal.
        coordinator.clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak container] event in
            if let container, event.window === container.window,
               container.bounds.contains(container.convert(event.locationInWindow, from: nil)) {
                coordinator.onFocus()
            }
            return event
        }
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.onFocus = onFocus
        let terminal = session.terminalView
        if terminal.superview !== container {
            terminal.removeFromSuperview()
            terminal.frame = container.bounds
            terminal.autoresizingMask = [.width, .height]
            container.addSubview(terminal)
        }
        if isFocused, container.window?.firstResponder !== terminal {
            DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
        }
        if context.coordinator.appliedScheme != colorScheme {
            context.coordinator.appliedScheme = colorScheme
            TerminalPalette(colorScheme).apply(to: terminal)
        }
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.clickMonitor { NSEvent.removeMonitor(monitor) }
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
