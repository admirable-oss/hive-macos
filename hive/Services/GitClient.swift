import Foundation
import SwiftUI

/// A file the working tree reports as changed, in one of the two index areas.
enum GitChangeArea: String, Hashable {
    case staged
    case unstaged
}

struct GitChange: Identifiable, Hashable {
    let path: String
    let code: Character
    let area: GitChangeArea

    var id: String { "\(area.rawValue)-\(path)" }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }

    /// Untracked files show as `U`, matching the rest of Hive's status vocabulary.
    var label: String { code == "?" ? "U" : String(code) }

    var color: Color {
        switch code {
        case "M": .hiveAmber
        case "A", "?": .teal
        case "D": .red
        case "R", "C": .blue
        case "U": .orange
        default: .secondary
        }
    }

    /// Parses `git status --porcelain=v1 -z` output. Paths are relative to the repository root.
    static func parse(_ output: String) -> [GitChange] {
        var changes: [GitChange] = []
        var entries = output.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let entry = entries.next() {
            guard entry.count > 3 else { continue }
            let index = entry[entry.startIndex]
            let worktree = entry[entry.index(after: entry.startIndex)]
            let path = String(entry.dropFirst(3))
            // Renames and copies are followed by their original path.
            if index == "R" || index == "C" { _ = entries.next() }

            if index == "?" {
                changes.append(GitChange(path: path, code: "?", area: .unstaged))
                continue
            }
            if index != " " { changes.append(GitChange(path: path, code: index, area: .staged)) }
            if worktree != " " { changes.append(GitChange(path: path, code: worktree, area: .unstaged)) }
        }
        return changes
    }
}

/// One `@@ … @@` section of a unified diff, with its body lines.
struct DiffHunk: Identifiable, Hashable {
    let id: Int
    let header: String
    /// Body lines, each beginning with `+`, `-`, a space, or `\` for "no newline".
    let lines: [String]

    var body: String { ([header] + lines).joined(separator: "\n") }
    var additionCount: Int { lines.filter { $0.hasPrefix("+") }.count }
    var removalCount: Int { lines.filter { $0.hasPrefix("-") }.count }
}

/// One file's section of a unified diff: the header lines before the first hunk,
/// then every hunk. Enough to rebuild a patch for a subset of hunks.
struct FileDiff: Identifiable {
    let id: Int
    let preamble: [String]
    let hunks: [DiffHunk]

    var isEmpty: Bool { preamble.isEmpty && hunks.isEmpty }
    var path: String? {
        preamble.first { $0.hasPrefix("+++ ") }?
            .dropFirst(4)
            .replacingOccurrences(of: "b/", with: "", options: .anchored)
    }

    /// A patch made of the file header and the selected hunks, ready for `git apply`.
    func patch(selecting selected: [DiffHunk]) -> String {
        guard !selected.isEmpty else { return "" }
        let lines = preamble + selected.flatMap { [$0.header] + $0.lines }
        return lines.joined(separator: "\n") + "\n"
    }

    static func parse(_ diff: String) -> [FileDiff] {
        var text = diff
        if text.hasSuffix("\n") { text.removeLast() }
        let lines = text.isEmpty ? [] : text.components(separatedBy: "\n")

        var files: [FileDiff] = []
        var preamble: [String] = []
        var hunks: [DiffHunk] = []
        var body: [String] = []
        var hunkHeader: String?
        var nextID = 0

        func flushHunk() {
            if let header = hunkHeader {
                hunks.append(DiffHunk(id: nextID, header: header, lines: body))
                nextID += 1
            }
            body = []
            hunkHeader = nil
        }
        func flushFile() {
            flushHunk()
            if !preamble.isEmpty || !hunks.isEmpty {
                files.append(FileDiff(id: files.count, preamble: preamble, hunks: hunks))
            }
            preamble = []
            hunks = []
        }

        for line in lines {
            if line.hasPrefix("@@") {
                flushHunk()
                hunkHeader = line
            } else if hunkHeader != nil {
                body.append(line)
            } else if line.hasPrefix("diff --git ") {
                flushFile()
                preamble = [line]
            } else {
                preamble.append(line)
            }
        }
        flushFile()
        return files
    }
}

/// Git operations on one working directory. Every call shells out to `/usr/bin/git`
/// through `HiveCLIService`, so the app never links libgit2 or holds a repo open.
struct GitClient {
    let directory: String

    private let git = HiveCLIService(executableURL: URL(fileURLWithPath: "/usr/bin/git"))

    func root() async throws -> String {
        try await git.run(["-C", directory, "rev-parse", "--show-toplevel"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func branch(root: String) async -> String? {
        let value = try? await git.run(["-C", root, "branch", "--show-current"])
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// `--no-optional-locks` keeps status from rewriting the index, so polling it never
    /// fights a git command in the terminal or wakes a file watcher.
    func status(root: String) async throws -> [GitChange] {
        let output = try await git.run(["--no-optional-locks", "-C", root, "status", "--porcelain=v1", "-z", "--untracked-files=all"])
        return GitChange.parse(output)
    }

    /// The diff for one change: staged, unstaged, or a synthesised one for a new file.
    func diff(root: String, change: GitChange) async throws -> String {
        if change.code == "?" {
            return try untrackedDiff(root: root, path: change.path)
        }
        let arguments = change.area == .staged
            ? ["-C", root, "diff", "--cached", "--no-ext-diff", "--", change.path]
            : ["-C", root, "diff", "--no-ext-diff", "--", change.path]
        return try await git.run(arguments)
    }

    /// Everything staged, as one diff: what a commit would record.
    func stagedDiff(root: String) async throws -> String {
        try await git.run(["-C", root, "diff", "--cached", "--no-ext-diff"])
    }

    func stage(root: String, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await git.run(["-C", root, "add", "--"] + paths)
    }

    func stageAll(root: String) async throws {
        _ = try await git.run(["-C", root, "add", "--all"])
    }

    func unstage(root: String, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        do {
            _ = try await git.run(["-C", root, "restore", "--staged", "--"] + paths)
        } catch {
            // A repository with no commits yet has no HEAD for `restore` to use.
            _ = try await git.run(["-C", root, "rm", "--cached", "-r", "--quiet", "--"] + paths)
        }
    }

    func unstageAll(root: String) async throws {
        do {
            _ = try await git.run(["-C", root, "restore", "--staged", "--", "."])
        } catch {
            _ = try await git.run(["-C", root, "rm", "--cached", "-r", "--quiet", "--", "."])
        }
    }

    /// Writes a patch to the index. `reverse` unstages instead of staging.
    func applyToIndex(root: String, patch: String, reverse: Bool) async throws {
        guard !patch.isEmpty else { return }
        var arguments = ["-C", root, "apply", "--cached", "--whitespace=nowarn"]
        if reverse { arguments.append("--reverse") }
        _ = try await git.run(arguments, input: patch)
    }

    /// Commits what is staged and returns git's summary of the new commit.
    func commit(root: String, message: String) async throws -> String {
        try await git.run(["-C", root, "commit", "-m", message])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds the shaped diff git would show for a file that isn't tracked yet.
    func untrackedDiff(root: String, path: String) throws -> String {
        let fileURL = URL(fileURLWithPath: root).appendingPathComponent(path)
        let data = try Data(contentsOf: fileURL)
        guard let contents = String(data: data, encoding: .utf8) else {
            return "Binary or non-text file; no text diff is available."
        }
        let lines = contents.components(separatedBy: "\n")
        let visibleLines = contents.hasSuffix("\n") ? Array(lines.dropLast()) : lines
        let escapedPath = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\t", with: "\\t")
        let additions = visibleLines.map { "+\($0)" }.joined(separator: "\n")
        return "diff --git a/\(escapedPath) b/\(escapedPath)\nnew file mode 100644\n--- /dev/null\n+++ b/\(escapedPath)\n@@ -0,0 +1,\(visibleLines.count) @@\n\(additions)"
    }
}
