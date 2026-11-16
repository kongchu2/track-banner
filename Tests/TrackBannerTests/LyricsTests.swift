import XCTest
@testable import TrackBanner

final class LyricsParserTests: XCTestCase {
    func testLrcKeepsTimedLinesAndDropsHeaders() {
        let lines = LyricsParser.lrc("""
        [ar: Someone]
        [00:01.50] first
        [01:02.345]second
        not a line
        """)
        XCTAssertEqual(lines, [LyricLine(t: 1500, text: "first"), LyricLine(t: 62345, text: "second")])
    }

    func testLrcRepeatedTimestampsAreSortedIntoPlace() {
        let lines = LyricsParser.lrc("[00:30.00][00:10.00] chorus\n[00:20.00] verse")
        XCTAssertEqual(lines?.map(\.t), [10000, 20000, 30000])
        XCTAssertEqual(lines?.map(\.text), ["chorus", "verse", "chorus"])
    }

    func testEmptyAndNoteLinesBecomeOneInterlude() {
        let lines = LyricsParser.lrc("[00:01.00] a\n[00:05.00]\n[00:06.00] ♪\n[00:09.00] b")
        XCTAssertEqual(lines, [
            LyricLine(t: 1000, text: "a"), LyricLine(t: 5000, text: ""), LyricLine(t: 9000, text: "b"),
        ])
    }

    func testLyricsWithNothingToSingAreNoLyrics() {
        XCTAssertNil(LyricsParser.lrc("[00:01.00] ♪\n[00:05.00]"))
        XCTAssertNil(LyricsParser.lrc("just text"))
    }

    func testSpotifyLineSynced() {
        let json = #"{"lyrics":{"syncType":"LINE_SYNCED","lines":[{"startTimeMs":"960","words":"one"},{"startTimeMs":"4020","words":"♪"},{"startTimeMs":"9000","words":"two"},{"startTimeMs":"12000","words":""}]},"colors":{"background":-1}}"#
        XCTAssertEqual(LyricsParser.spotify(Data(json.utf8)), [
            LyricLine(t: 960, text: "one"), LyricLine(t: 4020, text: ""),
            LyricLine(t: 9000, text: "two"), LyricLine(t: 12000, text: ""),
        ])
    }

    func testSpotifyUnsyncedIsNotUsable() {
        let json = #"{"lyrics":{"syncType":"UNSYNCED","lines":[{"startTimeMs":"0","words":"one"},{"startTimeMs":"0","words":"two"}]}}"#
        XCTAssertNil(LyricsParser.spotify(Data(json.utf8)))
        XCTAssertNil(LyricsParser.spotify(Data("null".utf8)))
    }

    func testActiveIndex() {
        let lines = [LyricLine(t: 1000, text: "a"), LyricLine(t: 2000, text: "b"), LyricLine(t: 3000, text: "c")]
        XCTAssertEqual(LyricsParser.activeIndex(in: lines, at: 0), -1)
        XCTAssertEqual(LyricsParser.activeIndex(in: lines, at: 1000), 0)
        XCTAssertEqual(LyricsParser.activeIndex(in: lines, at: 2999), 1)
        XCTAssertEqual(LyricsParser.activeIndex(in: lines, at: 99999), 2)
    }

    func testOnlySpotifyTracksHaveLyricIDs() {
        func track(_ id: String) -> Track { Track(id: id, name: "", artist: "", album: "") }
        XCTAssertEqual(track("spotify:track:4cOdK2wGLETKBW3PvgPWqT").spotifyTrackID, "4cOdK2wGLETKBW3PvgPWqT")
        XCTAssertNil(track("spotify:episode:4cOdK2wGLETKBW3PvgPWqT").spotifyTrackID)
        XCTAssertNil(track("spotify:local:a:b:c:123").spotifyTrackID)
        XCTAssertNil(track("spotify:track:../../etc/passwd0000000").spotifyTrackID)
    }
}

final class LRCLIBPickTests: XCTestCase {
    private func item(_ duration: Double, synced: Bool) -> LRCLIB.Item {
        LRCLIB.Item(duration: duration, instrumental: false, syncedLyrics: synced ? "[00:01.00] \(duration)" : nil)
    }

    func testPicksClosestSyncedWithinFourSeconds() {
        let items = [item(200, synced: false), item(203, synced: true), item(201, synced: true), item(230, synced: true)]
        XCTAssertEqual(LRCLIB.pick(items, seconds: 200)?.duration, 201)
    }

    func testAnotherRecordingIsNotUsed() {
        XCTAssertNil(LRCLIB.pick([item(230, synced: true), item(200, synced: false)], seconds: 200))
    }

    func testWithoutADurationTheFirstSyncedOneIsUsed() {
        XCTAssertEqual(LRCLIB.pick([item(1, synced: false), item(2, synced: true)], seconds: nil)?.duration, 2)
    }
}

final class LyricsRomanizerTests: XCTestCase {
    func testJapaneseReadsParticlesAndJoinsEndings() {
        let lines = LyricsRomanizer.romanize(["東京の空は今日も青い", "ずっと好きだった", "Baby", ""])
        XCTAssertEqual(lines, ["toukyou no sora wa kyou mo aoi", "zutto suki datta", "", ""])
    }

    func testChineseIsPinyinByWord() {
        XCTAssertEqual(LyricsRomanizer.romanize(["音乐快乐", "我们的爱 don't cry"]), ["yīnyuè kuàilè", "wǒmen de ài don't cry"])
    }

    func testOtherScriptsAreTransliterated() {
        XCTAssertEqual(LyricsRomanizer.romanize(["Привет, как дела"]), ["Privet, kak dela"])
    }

    func testKoreanAndLatinLyricsAreLeftAlone() {
        XCTAssertNil(LyricsRomanizer.romanize(["사랑해 너를", "Ich wartete auf dich", "Çà et là"]))
    }
}

final class LyricsRubyTests: XCTestCase {
    private typealias Segment = LyricsRomanizer.RubySegment

    func testSegmentsRebuildTheLineAndCarryReadings() {
        let line = "我们的爱, don't cry"
        let segments = LyricsRomanizer.ruby([line, "la la la"])
        XCTAssertEqual(segments?[0].map(\.text).joined(), line)
        XCTAssertEqual(Array(segments?[0].prefix(4) ?? []), [
            Segment(text: "我们", reading: "wǒmen"), Segment(text: "的", reading: "de"),
            Segment(text: "爱", reading: "ài"), Segment(text: ", ", reading: nil),
        ])
        XCTAssertEqual(segments?[1], [])
    }

    func testJapaneseDoubledConsonantStaysWithItsWord() {
        let segments = LyricsRomanizer.ruby(["好きだった"])?[0]
        XCTAssertEqual(segments?.map(\.reading), ["suki", "dat", "ta"])
    }

    func testNothingToAnnotate() {
        XCTAssertNil(LyricsRomanizer.ruby(["사랑해", "hello"]))
    }
}
