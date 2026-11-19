import XCTest
@testable import ApuMusic

final class MusicModelTests: XCTestCase {
    func testSearchAndImportedPlaylistTracksDecodeStringAndNumericIdentifiers() throws {
        let json = Data(#"[{"id":2138,"platform":"tencent","song":"Hello","singer":"Adele","source_id":"002Il7Ya1tZ6UZ","playable":true},{"id":"1","platform":"kugou","song":"First song","singer":"Artist","status":"matched"},{"id":"335","platform":"","song":"Unavailable","singer":"Artist","status":"missing"}]"#.utf8)

        let tracks = try JSONDecoder().decode([Track].self, from: json)

        XCTAssertEqual(tracks.map(\.id), ["2138", "1", "335"])
        XCTAssertEqual(tracks[0].sourceId, "002Il7Ya1tZ6UZ")
        XCTAssertTrue(tracks[0].canPlay)
        XCTAssertFalse(tracks[2].canPlay)
    }

    func testPlaybackRequestUsesServerFieldNames() throws {
        let request = PlaybackRequest(platform: "netease", query: "Song", selectedId: "35847388")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])

        XCTAssertEqual(json["selected_id"] as? String, "35847388")
        XCTAssertEqual(json["include_cover"] as? Bool, true)
        XCTAssertEqual(json["quality"] as? String, "high")
    }

    func testAPIEndpointPreservesQueryAndStaysUnderConfiguredBasePath() throws {
        XCTAssertEqual(
            try MusicAPI.endpoint("search?q=hello world").absoluteString,
            "https://kenmusic.kdns.fr/api/v1/search?q=hello%20world"
        )
        XCTAssertThrowsError(try MusicAPI.endpoint("/other-endpoint"))
    }

    func testImportedPlaylistItemEnvelopeDecodes() throws {
        let json = Data(#"{"id":"spotify-liked","name":"Spotify 喜欢的歌曲","cover":"","items":[{"id":"1","platform":"kugou","song":"Song","singer":"Artist","status":"matched"}]}"#.utf8)

        let playlist = try JSONDecoder().decode(PlaylistDetail.self, from: json)

        XCTAssertEqual(playlist.id, "spotify-liked")
        XCTAssertEqual(playlist.items.first?.song, "Song")
    }

    func testPlaylistQueueFollowsOrderAndRepeatsFromStart() {
        var queue = PlaybackQueue(tracks: [track("one"), track("two")], startingAt: track("one"))

        XCTAssertEqual(queue.advance()?.id, "two")
        XCTAssertNil(queue.advance())
        XCTAssertEqual(queue.advance(repeatsPlaylist: true)?.id, "one")
    }

    func testPlaylistQueueAllowsSelectingShuffleItemAndSkipsUnavailableTracks() {
        var unavailable = track("unavailable")
        unavailable.playable = false
        var queue = PlaybackQueue(tracks: [track("one"), unavailable, track("three")], startingAt: track("one"))

        XCTAssertEqual(queue.tracks.map(\.id), ["one", "three"])
        XCTAssertEqual(queue.advance(shuffledIndex: 1)?.id, "three")
    }

    func testPlaylistQueueCanReorderAndKeepsCurrentSongSelected() {
        var queue = PlaybackQueue(tracks: [track("one"), track("two"), track("three")], startingAt: track("two"))

        queue.move(from: IndexSet(integer: 1), to: 3)

        XCTAssertEqual(queue.tracks.map(\.id), ["one", "three", "two"])
        XCTAssertEqual(queue.current?.id, "two")
        XCTAssertEqual(queue.index, 2)
    }

    func testTimedLyricWordsDecodeAndFollowTimestamp() throws {
        let json = Data(#"{"available":true,"plain":"hello","words":[{"start":1,"end":2,"words":[[1,1.4,"Hel"],[1.4,2,"lo"]]}]}"#.utf8)
        let lyrics = try JSONDecoder().decode(Lyrics.self, from: json)

        XCTAssertEqual(lyrics.timedLines.first?.text, "Hello")
        XCTAssertTrue(lyrics.available)
    }

    func testLRCPlainTextProducesTimestampedScrollingLines() throws {
        let json = Data(#"{"available":true,"plain":"[00:10.200]First lyric\n[00:12.500]Second lyric"}"#.utf8)
        let lyrics = try JSONDecoder().decode(Lyrics.self, from: json)

        XCTAssertEqual(lyrics.timedLines.map(\.text), ["First lyric", "Second lyric"])
        XCTAssertEqual(lyrics.timedLines[0].start, 10.2, accuracy: 0.001)
        XCTAssertEqual(lyrics.timedLines[0].end, 12.48, accuracy: 0.001)
    }

    private func track(_ id: String) -> Track {
        Track(id: id, platform: "netease", song: id, singer: "Artist", playable: true)
    }
}
