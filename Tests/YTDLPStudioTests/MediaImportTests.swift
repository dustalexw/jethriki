import XCTest
@testable import YTDLPStudio

final class MediaImportTests: XCTestCase {
    func stream(_ i: Int, _ type: String, _ codec: String, picture: Bool = false) -> ProbedStream {
        ProbedStream(index: i, type: type, codec: codec, attachedPicture: picture)
    }

    func testMKVToMP4ConvertsWhatMP4CannotHold() throws {
        let media = ProbedMedia(streams: [stream(0, "video", "hevc"), stream(1, "audio", "vorbis"),
                                          stream(2, "subtitle", "ass"), stream(3, "subtitle", "hdmv_pgs_subtitle"),
                                          stream(4, "attachment", "ttf")], duration: 10)
        let plan = try MediaImport.plan(input: "/v/Show.mkv", media: media, request: ImportRequest(action: .remuxMP4),
                                        outputDirectory: "/v") { _ in false }
        XCTAssertEqual(plan.output, "/v/Show.mp4")
        let a = plan.arguments.joined(separator: " ")
        XCTAssertTrue(a.contains("-map 0:0 -map 0:1 -map 0:2 -map_metadata 0 -map_chapters 0 -c copy"), a)
        XCTAssertTrue(a.contains("-tag:0 hvc1"), a)
        XCTAssertTrue(a.contains("-c:1 aac -b:1 256k"), a)
        XCTAssertTrue(a.contains("-c:2 mov_text"), a)
        XCTAssertFalse(a.contains("0:3") || a.contains("0:4"), a)
        XCTAssertEqual(plan.notes.count, 3)
    }

    func testMP4ToMKVAndNoOverwrite() throws {
        let media = ProbedMedia(streams: [stream(0, "video", "h264"), stream(1, "audio", "aac"),
                                          stream(2, "subtitle", "mov_text"), stream(3, "video", "mjpeg", picture: true),
                                          stream(4, "data", "bin_data")], duration: 10)
        let plan = try MediaImport.plan(input: "/v/Clip.mp4", media: media, request: ImportRequest(action: .remuxMKV),
                                        outputDirectory: "/v") { $0 == "/v/Clip.mkv" }
        XCTAssertEqual(plan.output, "/v/Clip (2).mkv")
        XCTAssertTrue(plan.arguments.joined(separator: " ").contains("-c:2 srt"))
        XCTAssertFalse(plan.arguments.contains("0:3"))
    }

    func testExtractAudio() throws {
        let media = ProbedMedia(streams: [stream(0, "video", "h264"), stream(1, "audio", "opus"), stream(2, "audio", "aac")], duration: 5)
        let copy = try MediaImport.plan(input: "/v/a.webm", media: media, request: ImportRequest(action: .extractAudio), outputDirectory: "/v") { _ in false }
        XCTAssertEqual(copy.output, "/v/a.opus")
        XCTAssertTrue(copy.arguments.joined(separator: " ").contains("-map 0:1 -vn -sn -dn -map_metadata 0 -c:a copy"))
        XCTAssertEqual(copy.notes, ["Extracted the first of 2 audio tracks."])
        let mp3 = try MediaImport.plan(input: "/v/a.webm", media: media, request: ImportRequest(action: .extractAudio, audioFormat: .mp3), outputDirectory: "/out") { _ in false }
        XCTAssertEqual(mp3.output, "/out/a.mp3")
        XCTAssertThrowsError(try MediaImport.plan(input: "/v/a.mp4", media: ProbedMedia(streams: [stream(0, "video", "h264")], duration: 1),
                                                  request: ImportRequest(action: .extractAudio), outputDirectory: "/v"))
    }

    func testRefusesVideoMP4CannotHold() {
        let media = ProbedMedia(streams: [stream(0, "video", "vp8"), stream(1, "audio", "vorbis")], duration: 1)
        XCTAssertThrowsError(try MediaImport.plan(input: "/v/a.webm", media: media, request: ImportRequest(action: .remuxMP4), outputDirectory: "/v"))
        XCTAssertNoThrow(try MediaImport.plan(input: "/v/a.webm", media: media, request: ImportRequest(action: .remuxMKV), outputDirectory: "/v") { _ in false })
    }
}
