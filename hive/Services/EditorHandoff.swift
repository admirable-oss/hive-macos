import AppKit
import SwiftUI

/// Opens a file at a line in the user's editor: VS Code, Cursor, Zed or Xcode, whichever is
/// installed, falling back to the file's default app.
enum Editor: String, CaseIterable, Identifiable {
    case vscode, cursor, zed, xcode, system

    static let preferenceKey = "hive.editor"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .vscode: "Visual Studio Code"
        case .cursor: "Cursor"
        case .zed: "Zed"
        case .xcode: "Xcode"
        case .system: "Default App"
        }
    }

    private var bundleIdentifier: String? {
        switch self {
        case .vscode: "com.microsoft.VSCode"
        case .cursor: "com.todesktop.230313mzl4w4u92"
        case .zed: "dev.zed.Zed"
        case .xcode: "com.apple.dt.Xcode"
        case .system: nil
        }
    }

    var applicationURL: URL? {
        bundleIdentifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    var isInstalled: Bool { self == .system || applicationURL != nil }

    static var installed: [Editor] { allCases.filter(\.isInstalled) }

    /// The one the user chose in Settings, else the first code editor installed.
    static var preferred: Editor {
        if let raw = UserDefaults.standard.string(forKey: preferenceKey), let editor = Editor(rawValue: raw), editor.isInstalled {
            return editor
        }
        return installed.first ?? .system
    }

    /// Opens `url`, at `line` (1-based) when the editor can jump to one.
    func open(_ url: URL, line: Int? = nil, column: Int = 1) {
        let path = url.path
        switch self {
        case .vscode, .cursor:
            // Both register a `file` handler: vscode://file/<absolute path>:<line>:<column>.
            let scheme = self == .vscode ? "vscode" : "cursor"
            let location = line.map { "\(path):\($0):\(column)" } ?? path
            let encoded = location.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? location
            if let link = URL(string: "\(scheme)://file\(encoded)"), NSWorkspace.shared.open(link) { return }
        case .zed:
            // Zed ships its command-line tool inside the app; it takes path:line:column.
            if let cli = applicationURL?.appendingPathComponent("Contents/MacOS/cli"), FileManager.default.isExecutableFile(atPath: cli.path) {
                run(cli, [line.map { "\(path):\($0):\(column)" } ?? path])
                return
            }
        case .xcode:
            let xed = URL(fileURLWithPath: "/usr/bin/xed")
            if FileManager.default.isExecutableFile(atPath: xed.path) {
                run(xed, (line.map { ["--line", String($0)] } ?? []) + [path])
                return
            }
        case .system:
            break
        }
        if let applicationURL, self != .system {
            NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func run(_ executable: URL, _ arguments: [String]) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { NSWorkspace.shared.open(URL(fileURLWithPath: arguments.last ?? "")) }
    }
}

/// "Open in <editor>" plus an "Open With" submenu of the other installed editors, for context menus.
struct OpenInEditorMenu: View {
    let url: URL
    var line: Int?

    var body: some View {
        let preferred = Editor.preferred
        Button(line.map { "Open in \(preferred.name) at Line \($0)" } ?? "Open in \(preferred.name)") {
            preferred.open(url, line: line)
        }
        let others = Editor.installed.filter { $0 != preferred }
        if !others.isEmpty {
            Menu("Open With") {
                ForEach(others) { editor in
                    Button(editor.name) { editor.open(url, line: line) }
                }
            }
        }
    }
}
