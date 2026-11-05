import AppKit
import Combine
import Foundation

/// A place in Hive a `hive://` link, a Finder service or a Shortcut can open.
///
///     hive://agent/<id>    hive://pane/<id>    hive://tab/<id>    hive://environment/<id>
///     hive://open?path=/Users/me/code/api            an environment there, else a shell there
///     hive://new-environment?path=/Users/me/code/api
enum DeepLink: Equatable {
    case agent(String)
    case pane(String)
    case tab(String)
    case environment(String)
    case open(path: String)
    case newEnvironment(path: String)

    static let scheme = "hive"

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let host = url.host(percentEncoded: false)?.lowercased() else { return nil }
        let id = url.pathComponents.dropFirst().first ?? ""
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value
        switch host {
        case "agent" where !id.isEmpty: self = .agent(id)
        case "pane" where !id.isEmpty: self = .pane(id)
        case "tab" where !id.isEmpty: self = .tab(id)
        case "environment", "env": if id.isEmpty { return nil } else { self = .environment(id) }
        case "open": if let path { self = .open(path: path) } else { return nil }
        case "new-environment": if let path { self = .newEnvironment(path: path) } else { return nil }
        default: return nil
        }
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .agent(let id): components.host = "agent"; components.path = "/" + id
        case .pane(let id): components.host = "pane"; components.path = "/" + id
        case .tab(let id): components.host = "tab"; components.path = "/" + id
        case .environment(let id): components.host = "environment"; components.path = "/" + id
        case .open(let path): components.host = "open"; components.queryItems = [URLQueryItem(name: "path", value: path)]
        case .newEnvironment(let path): components.host = "new-environment"; components.queryItems = [URLQueryItem(name: "path", value: path)]
        }
        return components.url!
    }

    /// Puts the link on the pasteboard, as text and as a URL.
    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}

/// Holds a link until a window can open it: links, services and Shortcuts can arrive before the
/// workspace has connected, or while no window is open.
@MainActor
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()

    @Published var pending: DeepLink?
    /// Whether a workspace window is open to take links; the dashboard keeps it current.
    var hasWindow = false

    func handle(_ url: URL) {
        guard let link = DeepLink(url: url) else { return }
        pending = link
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens a link from inside the app. With no window open, it goes out and back in as a URL,
    /// so the system opens the window that takes it.
    func open(_ link: DeepLink) {
        if hasWindow {
            pending = link
            NSApp.activate(ignoringOtherApps: true)
        } else {
            NSWorkspace.shared.open(link.url)
        }
    }
}

/// The Finder's Services menu: "Open in Hive" and "New Hive Environment Here" for folders.
final class HiveServicesProvider: NSObject {
    static let shared = HiveServicesProvider()

    @objc func openInHive(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let folder = Self.folder(from: pasteboard) else {
            error.pointee = "Choose a folder to open in Hive." as NSString
            return
        }
        Task { @MainActor in DeepLinkRouter.shared.open(.open(path: folder)) }
    }

    @objc func newEnvironmentHere(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let folder = Self.folder(from: pasteboard) else {
            error.pointee = "Choose a folder to make a Hive environment of." as NSString
            return
        }
        Task { @MainActor in DeepLinkRouter.shared.open(.newEnvironment(path: folder)) }
    }

    /// The folder Finder handed over: a selected folder, or the folder of a selected file.
    private static func folder(from pasteboard: NSPasteboard) -> String? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        let path = urls?.first?.path ?? pasteboard.string(forType: .string)
        guard let path else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue ? path : (path as NSString).deletingLastPathComponent
    }
}

extension HiveEnvironment {
    /// An environment ID made from a folder name: letters, digits, dots, dashes and underscores.
    static func id(fromFolderName folderName: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let normalized = String(folderName.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        return String((normalized.isEmpty ? "workspace" : normalized).prefix(64))
    }
}
