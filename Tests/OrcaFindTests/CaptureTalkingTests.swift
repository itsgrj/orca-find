import XCTest
import AVFoundation
@testable import OrcaFind

/// When Orca decides you've finished talking, and how "Add more" joins new words onto a note.
final class CaptureTalkingTests: XCTestCase {
    func testUnfinishedEndings() {
        for s in ["It looks very sci-fi and", "Sort of pixelated, you know", "I want this for the", "Save it because",
                  "the colours are, um", "it's kind of", "something like,", "So,", "And then"] {
            XCTAssertTrue(CaptureRecorder.soundsUnfinished(s), s)
        }
    }

    func testFinishedEndings() {
        for s in ["", "Pricing thread for Friday’s newsletter.", "Remind me Thursday to write it up",
                  "It looks very sci-fi", "Tag it design", "I love the animation here"] {
            XCTAssertFalse(CaptureRecorder.soundsUnfinished(s), s)
        }
    }

    func testJoinNote() {
        XCTAssertEqual(CaptureController.joinNote("Sort of sci-fi", "and it's for the newsletter"),
                       "Sort of sci-fi. And it's for the newsletter")
        XCTAssertEqual(CaptureController.joinNote("Sort of sci-fi.", "Tag it design"), "Sort of sci-fi. Tag it design")
        XCTAssertEqual(CaptureController.joinNote("Looks great,", "remind me Friday"), "Looks great. Remind me Friday")
        XCTAssertEqual(CaptureController.joinNote("", "  first words "), "first words")
        XCTAssertEqual(CaptureController.joinNote("Kept", ""), "Kept")
    }

    /// Two recordings in the same format Orca writes (AAC .m4a) come out as one, as long as both together.
    func testAudioJoin() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("orca-join-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func tone(_ name: String, seconds: Double) throws -> URL {
            let url = dir.appendingPathComponent(name)
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                           AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000]
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = AVAudioFrameCount(48_000 * seconds)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buf.frameLength = frames
            for i in 0..<Int(frames) { buf.floatChannelData![0][i] = 0.3 * sin(Float(i) * 0.05) }
            try file.write(from: buf)
            return url
        }
        let main = try tone("main.m4a", seconds: 2)
        let piece = try tone("piece.m4a", seconds: 1.5)
        let ok = await AudioJoin.append(piece, to: main)
        XCTAssertTrue(ok)
        let length = try await AVURLAsset(url: main).load(.duration).seconds
        XCTAssertEqual(length, 3.5, accuracy: 0.15)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".joining") }, [])
    }
}
