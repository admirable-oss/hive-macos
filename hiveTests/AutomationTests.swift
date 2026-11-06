import Foundation
import Testing
@testable import hive

struct DeepLinkTests {
    @Test func roundTripsEveryKind() {
        let links: [DeepLink] = [
            .agent("a1b2"), .pane("p7"), .tab("t9"), .environment("api"),
            .open(path: "/Users/me/code/my api"), .newEnvironment(path: "/tmp/x"),
        ]
        for link in links {
            #expect(DeepLink(url: link.url) == link)
        }
    }

    @Test func readsHandWrittenLinks() {
        #expect(DeepLink(url: URL(string: "hive://agent/a1b2")!) == .agent("a1b2"))
        #expect(DeepLink(url: URL(string: "hive://env/api")!) == .environment("api"))
        #expect(DeepLink(url: URL(string: "HIVE://Pane/p7")!) == .pane("p7"))
        #expect(DeepLink(url: URL(string: "hive://open?path=/Users/me/code%20base")!) == .open(path: "/Users/me/code base"))
    }

    @Test func rejectsOtherLinks() {
        #expect(DeepLink(url: URL(string: "https://agent/a1")!) == nil)
        #expect(DeepLink(url: URL(string: "hive://agent")!) == nil)
        #expect(DeepLink(url: URL(string: "hive://open")!) == nil)
        #expect(DeepLink(url: URL(string: "hive://nonsense/x")!) == nil)
    }

    @Test func makesEnvironmentIDsFromFolderNames() {
        #expect(HiveEnvironment.id(fromFolderName: "My API (v2)") == "My-API--v2")
        #expect(HiveEnvironment.id(fromFolderName: "...") == "workspace")
    }
}

struct DiffLineNumberTests {
    @Test func numbersLinesInTheNewFile() {
        let hunk = DiffHunk(id: 0, header: "@@ -10,4 +12,5 @@ func run()", lines: [" keep", "-old", "+new", "+added", " keep", "\\ No newline at end of file"])
        #expect(hunk.newStart == 12)
        #expect(hunk.newLineNumbers == [12, 13, 13, 14, 15, nil])
    }

    @Test func readsOneLineHunkHeaders() {
        #expect(DiffHunk(id: 0, header: "@@ -1 +1 @@", lines: []).newStart == 1)
    }
}

@MainActor
struct FocusFilterTests {
    @Test func quietEnvironmentsAndDecisions() {
        defer { FocusFilterSettings.save(quietEnvironments: [], onlyDecisions: false) }

        FocusFilterSettings.save(quietEnvironments: ["api"], onlyDecisions: false)
        #expect(!FocusFilterSettings.allows(state: "blocked", environmentID: "api"))
        #expect(FocusFilterSettings.allows(state: "done", environmentID: "web"))

        FocusFilterSettings.save(quietEnvironments: [], onlyDecisions: true)
        #expect(FocusFilterSettings.allows(state: "blocked", environmentID: "web"))
        #expect(!FocusFilterSettings.allows(state: "done", environmentID: "web"))
    }
}

struct OutputPatternTests {
    @Test func literalTextMatchesOnlyItself() throws {
        let pattern = OutputPattern(text: "port 3000 (ready) [ok] a.b+c?*|d \\w", isRegex: false)
        let regex = try NSRegularExpression(pattern: pattern.regex)
        func matches(_ line: String) -> Bool { regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil }
        #expect(matches("server: port 3000 (ready) [ok] a.b+c?*|d \\w now"))
        #expect(!matches("port 3000 ready [ok] aXb+c?*|d \\w"))
        #expect(pattern.label == "“port 3000 (ready) [ok] a.b+c?*|d \\w”")
    }

    @Test func regexMustCompile() {
        #expect(OutputPattern(text: "(passed|failed)", isRegex: true).isValid)
        #expect(!OutputPattern(text: "(unclosed", isRegex: true).isValid)
        #expect(!OutputPattern(text: "", isRegex: false).isValid)
    }
}
