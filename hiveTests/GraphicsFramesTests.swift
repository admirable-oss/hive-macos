import Foundation
import Testing
@testable import hive

/// `terminal.graphics` framing, as captured from Hive 1.3: length, then column << 16 | row.
struct GraphicsFramesTests {
    private func frame(column: Int, row: Int, payload: String) -> Data {
        let bytes = Array(payload.utf8)
        var data = Data()
        for value in [bytes.count, column << 16 | row] {
            data.append(contentsOf: [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) })
        }
        data.append(contentsOf: bytes)
        return data
    }

    @Test func parsesCompleteFrames() {
        var buffer = frame(column: 9, row: 0, payload: "\u{1b}_Gf=100;AAAA\u{1b}\\") + frame(column: 0, row: 3, payload: "\u{1b}_Gf=100;BBBB\u{1b}\\")
        let frames = PaneTerminalSession.graphicsFrames(&buffer)
        #expect(frames.count == 2)
        #expect(frames[0].column == 9 && frames[0].row == 0)
        #expect(frames[1].column == 0 && frames[1].row == 3)
        #expect(String(decoding: frames[1].payload, as: UTF8.self) == "\u{1b}_Gf=100;BBBB\u{1b}\\")
        #expect(buffer.isEmpty)
    }

    @Test func keepsAPartialFrameForTheNextChunk() {
        let whole = frame(column: 2, row: 5, payload: "\u{1b}_Gf=100;CCCC\u{1b}\\")
        var buffer = whole.prefix(12)
        #expect(PaneTerminalSession.graphicsFrames(&buffer).isEmpty)
        #expect(buffer.count == 12)
        buffer.append(whole.dropFirst(12))
        let frames = PaneTerminalSession.graphicsFrames(&buffer)
        #expect(frames.count == 1 && frames[0].column == 2 && frames[0].row == 5)
        #expect(buffer.isEmpty)
    }
}
