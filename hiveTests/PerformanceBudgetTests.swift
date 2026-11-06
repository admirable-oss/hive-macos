import AppKit
import Darwin
import QuartzCore
import SwiftTerm
import XCTest

/// Hive Desktop's performance budgets, held in CI: sixteen panes streaming agent output while
/// you type in one of them. A frame here is everything the main thread does between two screen
/// updates: the fifteen streams arrive, a keystroke echoes in the sixteenth, and the window draws.
/// A keystroke waits for at most one such frame, so the p99 frame time bounds keystroke-to-screen.
final class PerformanceBudgetTests: XCTestCase {
    /// p99 time from a keystroke arriving to every pane being drawn.
    static let keystrokeToScreenP99: Double = 0.050
    /// Memory sixteen panes take after 5,000 lines of output each, scrollback included.
    static let memoryForSixteenPanes: Double = 400 * 1_048_576
    /// CPU sixteen idle panes add once output stops, as a share of one core. The test runs inside
    /// the app, so the app's own idle CPU is measured first and taken off.
    static let idleCPU: Double = 0.03

    private static let paneCount = 16
    private static let frames = 300

    @MainActor
    func testSixteenStreamingPanes() throws {
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1600, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000))
        window.contentView = container
        window.orderFrontRegardless()
        defer { window.close() }

        let hostIdle = Self.idleCPU(for: 3)
        let before = Self.footprint()
        let panes = (0..<Self.paneCount).map { index -> TerminalView in
            let view = TerminalView(frame: NSRect(x: CGFloat(index % 4) * 400, y: CGFloat(index / 4) * 250, width: 400, height: 250))
            container.addSubview(view)
            return view
        }
        window.displayIfNeeded()

        var frameTimes: [Double] = []
        frameTimes.reserveCapacity(Self.frames)
        for frame in 0..<Self.frames {
            let start = CACurrentMediaTime()
            for (index, pane) in panes.enumerated().dropFirst() {
                pane.feed(byteArray: Self.output(frame: frame, pane: index)[...])
            }
            panes[0].feed(text: frame % 60 == 59 ? "\r\n$ " : "x")
            window.displayIfNeeded()
            panes.forEach { $0.display() }
            frameTimes.append(CACurrentMediaTime() - start)
        }
        let p99 = Self.percentile(frameTimes, 0.99)
        let used = Double(Self.footprint() - before)

        // Output has stopped; the panes shouldn't keep working.
        let idle = max(0, Self.idleCPU(for: 3) - hostIdle)

        // The streams really arrived: the last pane shows the last frame's output.
        panes[Self.paneCount - 1].selectAll(nil)
        XCTAssertTrue(panes[Self.paneCount - 1].getSelection()?.contains("frame \(Self.frames - 1)") == true, "the panes didn’t receive their output")

        let report = String(format: "keystroke-to-screen p99 %.1f ms (median %.1f ms), memory %.0f MB for %d panes, idle CPU %.1f%% (app alone %.1f%%)",
                            p99 * 1000, Self.percentile(frameTimes, 0.5) * 1000, used / 1_048_576, Self.paneCount, idle * 100, hostIdle * 100)
        print("Performance: \(report)")
        let attachment = XCTAttachment(string: report)
        attachment.name = "Performance budgets"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertLessThanOrEqual(p99, Self.keystrokeToScreenP99, "keystroke-to-screen p99 is over budget: \(report)")
        XCTAssertLessThanOrEqual(used, Self.memoryForSixteenPanes, "sixteen panes use more memory than budgeted: \(report)")
        XCTAssertLessThanOrEqual(idle, Self.idleCPU, "the app keeps working while idle: \(report)")
    }

    /// One frame's worth of agent-like output for a pane: coloured, wrapped, with some Unicode.
    private static func output(frame: Int, pane: Int) -> [UInt8] {
        var text = ""
        for line in 0..<17 {
            switch line % 4 {
            case 0: text += "\u{1b}[1;32m✓\u{1b}[0m frame \(frame) pane \(pane) · read src/module_\(line).swift (\(line * 37) lines)\r\n"
            case 1: text += "\u{1b}[38;5;245m  │ \(String(repeating: "let value = compute(input) ", count: 3))\u{1b}[0m\r\n"
            case 2: text += "\u{1b}[33m⚠\u{1b}[0m warning: unused variable ‘tmp’ at line \(frame * 3 + line) — 中文 测试 🐝\r\n"
            default: text += "\u{1b}[2K\u{1b}[36m⠋\u{1b}[0m Thinking… \(frame)/\(line)\r"
            }
        }
        return Array(text.utf8)
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }

    /// Memory the process is charged for, as Activity Monitor shows it.
    private static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    /// The share of one core the process uses while the run loop idles for `seconds`.
    private static func idleCPU(for seconds: TimeInterval) -> Double {
        let cpuBefore = cpuTime()
        let start = CACurrentMediaTime()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        return (cpuTime() - cpuBefore) / (CACurrentMediaTime() - start)
    }

    /// User and system CPU time used by the process so far, in seconds.
    private static func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
