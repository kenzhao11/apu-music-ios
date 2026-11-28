import XCTest
@testable import ApuMusic

final class MusicModelTests: XCTestCase {
    func testSearchAndImportedPlaylistTracksDecodeStringAndNumericIdentifiers() throws {
        let json = Data(#"[{"id":2138,"platform":"tencent","song":"Hello","singer":"Adele","source_id":"002Il7Ya1tZ6UZ","playable":true},{"id":"1","platform":"kugou","song":"First song","singer":"Artist","status":"matched"},{"id":"335","platform":"","song":"Unavailable","singer":"Artist","status":"missing"},{"id":"9","platform":"netease","song":"Nope","singer":"Artist","playable":false}]"#.utf8)

        let tracks = try JSONDecoder().decode([Track].self, from: json)

        XCTAssertEqual(tracks.map(\.id), ["2138", "1", "335", "9"])
        XCTAssertEqual(tracks[0].sourceId, "002Il7Ya1tZ6UZ")
        XCTAssertTrue(tracks[0].canPlay)
        // A missing import match is still attempted: the backend can resolve it
        // by row id, exactly like the website.
        XCTAssertTrue(tracks[2].canPlay)
        // Only an explicit backend refusal stops the app from asking.
        XCTAssertFalse(tracks[3].canPlay)
    }

    func testSignedArtworkURLsKeepSignatureAndCredentialQueryParametersUnchanged() throws {
        for key in ["x-amz-credential", "x-amz-security-token", "x-goog-credential", "x-goog-security-token"] {
            let raw = "https://p1.music.126.net/a.jpg?param=300y300&\(key)=encoded%2Bcredential"
            XCTAssertEqual(Track.artworkURL(raw, tier: "large")?.absoluteString, raw)
        }
    }

    func testPlaybackRequestUsesServerFieldNames() throws {
        let request = PlaybackRequest(platform: "tencent", query: "Hello", selectedId: "2138", quality: "standard")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])

        XCTAssertEqual(json["selected_id"] as? String, "2138")
        XCTAssertEqual(json["include_cover"] as? Bool, false)
        XCTAssertEqual(json["quality"] as? String, "standard")
        XCTAssertTrue(json.keys.contains("streaming_mode"))
        XCTAssertNil(json["streaming_mode"] as? String)
    }

    func testPlaybackTargetPostsTheRowIDTheWebsitePosts() throws {
        let json = Data(#"{"id":2138,"platform":"tencent","song":"Hello","singer":"Adele","source_id":"002Il7Ya1tZ6UZ"}"#.utf8)
        let track = try JSONDecoder().decode(Track.self, from: json)

        let target = PlaybackTarget(track: track, quality: .high)

        // App.vue: selectedId = track.selected_id || track.source_id, and
        // utils/track.js sets selected_id to the row id the API returned.
        XCTAssertEqual(target.selectedId, "2138")
        XCTAssertEqual(target.query, "Hello")
        XCTAssertEqual(target.platform, "tencent")
        XCTAssertEqual(target.quality.rawValue, "high")
        XCTAssertNil(target.streamingMode)
    }

    func testPlaybackSelectionKeepsThePlatformTrackIDInsteadOfSourceID() throws {
        let json = Data(#"{"id":2138,"platform":"tencent","song":"Hello","singer":"Adele","source_id":"002Il7Ya1tZ6UZ"}"#.utf8)
        let track = try JSONDecoder().decode(Track.self, from: json)

        XCTAssertEqual(track.playbackSelectionID, "2138")
        XCTAssertEqual(track.sourceId, "002Il7Ya1tZ6UZ")
    }

    func testSearchResultsMergeSourcesButKeepDistinctSongsDistinct() throws {
        let tracks = [
            Track(id: "tencent--2138--high", platform: "tencent", song: "Hello", singer: "Adele",
                  duration: 295, sourceId: "provider-1", selectedId: "2138"),
            Track(id: "netease--3--high", platform: "netease", song: " hello ", singer: "ADELE",
                  duration: 296, sourceId: "provider-2", selectedId: "3"),
            Track(id: "kugou--7--high", platform: "kugou", song: "Hello", singer: "Adele",
                  duration: 333, selectedId: "7")
        ]

        let merged = TrackDeduplicator.merge(tracks)

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].metadataSources.count, 2)
        XCTAssertEqual(merged[0].metadataSources.map(\.platform), ["tencent", "netease"])
        // Metadata only: playback always posts the first matched row.
        XCTAssertEqual(merged[0].playbackSelectionID, "2138")
    }

    func testUnplayableTrackNeverGetsAFallbackPlaybackCandidate() throws {
        let data = Data(#"{"id":"unavailable","platform":"tencent","song":"Hello","singer":"Adele","playback_candidates":[],"playable":false}"#.utf8)
        let track = try JSONDecoder().decode(Track.self, from: data)

        XCTAssertFalse(track.canPlay)
        XCTAssertTrue(track.metadataSources.isEmpty)
    }

    func testPlaybackSelectionUsesSelectedIDWhenSearchRowsHavePlaybackMetadataIDs() throws {
        let json = Data(#"{"id":"tencent--2138--high","platform":"tencent","song":"Hello","singer":"Adele","selected_id":"2138","source_id":"002Il7Ya1tZ6UZ"}"#.utf8)
        let track = try JSONDecoder().decode(Track.self, from: json)

        XCTAssertEqual(track.playbackSelectionID, "2138")
        XCTAssertEqual(track.sourceId, "002Il7Ya1tZ6UZ")
    }

    func testCompletedPlaybackAudioURLsAllowBackendRedirectSources() throws {
        let json = Data(#"{"id":2138,"status":"completed","audio_url":"/api/v1/playbacks/2138/audio","alac_source_url":"/api/v1/playbacks/2138/audio/source","quality":"high","format":"flac"}"#.utf8)
        let task = try JSONDecoder().decode(PlaybackTask.self, from: json)

        XCTAssertEqual(task.nativeAudioURL(relativeTo: MusicAPI.base)?.path, "/api/v1/playbacks/2138/audio")
        XCTAssertEqual(task.nativeAudioURL(relativeTo: MusicAPI.base)?.query, "v=2138")
    }

    func testGrowingNativeFlacIsPlayableExactlyLikeTheWebsite() throws {
        let json = Data(#"{"id":"task-1","status":"streaming","audio_url":"/api/v1/playbacks/task-1/audio","quality":"lossless","format":"flac"}"#.utf8)
        let task = try JSONDecoder().decode(PlaybackTask.self, from: json)

        // waitForReady() treats a growing plain FLAC as decodable, so the app
        // may start on it too; a failing decoder falls back to the local
        // transcode path inside the same song (never another source).
        XCTAssertNotNil(task.nativeAudioURL(relativeTo: MusicAPI.base))
    }

    func testLosslessWithoutNativeProgressiveBytesWaitsForCompletedAudio() throws {
        let json = Data(#"{"id":"task-2","status":"streaming","audio_url":"/api/v1/playbacks/task-2/audio","quality":"lossless","format":"m4a"}"#.utf8)
        let task = try JSONDecoder().decode(PlaybackTask.self, from: json)

        XCTAssertNil(task.nativeAudioURL(relativeTo: MusicAPI.base))
    }

    func testPlaybackCreationResponseDecodesWrappedTaskAndALACSources() throws {
        let json = Data(#"{"playback":{"id":"task-1","status":"streaming","streaming_mode":"wasm_alac","streaming_url":"/api/v1/playbacks/task-1/audio/stream","audio_url":"/api/v1/playbacks/task-1/audio"}}"#.utf8)

        let response = try JSONDecoder().decode(PlaybackStatusResponse.self, from: json)

        XCTAssertEqual(response.task.id, "task-1")
        XCTAssertEqual(response.task.streamingMode, "wasm_alac")
        XCTAssertEqual(response.task.streamingURL, "/api/v1/playbacks/task-1/audio/stream")
    }

    func testPlaybackCreationEnvelopeDecodesTaskReturnedByCurrentAPI() throws {
        let json = Data(#"{"playback":{"id":"task-3","status":"processing","quality":"high"}}"#.utf8)

        let response = try JSONDecoder().decode(PlaybackStatusResponse.self, from: json)

        XCTAssertEqual(response.task.id, "task-3")
        XCTAssertEqual(response.task.status, "processing")
    }

    func testPlaybackStatusResponseAlsoDecodesTaskEnvelope() throws {
        let json = Data(#"{"task":{"id":"task-2","status":"completed","audio_url":"/api/v1/playbacks/task-2/audio","alac_source_url":"/api/v1/playbacks/task-2/audio/source"}}"#.utf8)

        let response = try JSONDecoder().decode(PlaybackStatusResponse.self, from: json)

        XCTAssertEqual(response.task.audioURL, "/api/v1/playbacks/task-2/audio")
        XCTAssertEqual(response.task.alacSourceURL, "/api/v1/playbacks/task-2/audio/source")
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

    func testQueueSkipsEightConsecutiveFailuresWithoutLosingPlayableTail() {
        let tracks = (0..<9).map { track("song-\($0)") }
        var queue = PlaybackQueue(tracks: tracks, startingAt: tracks[0])
        var attempted = Set<String>()
        for expected in tracks.dropLast() {
            XCTAssertEqual(queue.current?.id, expected.id)
            attempted.insert(expected.id)
            queue.markUnavailable(expected)
            XCTAssertNotNil(queue.advanceAfterFailure(attemptedIDs: attempted))
        }
        XCTAssertEqual(queue.current?.id, tracks.last?.id)
        XCTAssertEqual(queue.tracks.count, tracks.count)
    }

    func testAllUnavailableQueueTerminatesWithoutWrappingOrReattempting() {
        let tracks = (0..<8).map { track("song-\($0)") }
        var queue = PlaybackQueue(tracks: tracks, startingAt: tracks[0])
        var attempted = Set<String>()
        for expected in tracks {
            XCTAssertEqual(queue.current?.id, expected.id)
            attempted.insert(expected.id)
            queue.markUnavailable(expected)
            let next = queue.advanceAfterFailure(attemptedIDs: attempted)
            if expected.id == tracks.last?.id { XCTAssertNil(next) }
            else { XCTAssertNotNil(next) }
        }
        XCTAssertNil(queue.advanceAfterFailure(attemptedIDs: attempted))
        XCTAssertNil(queue.advanceAfterFailure(attemptedIDs: attempted))
    }

    func testSharedUnavailableIDsAreExcludedWhenRebuildingQueue() {
        let tracks = [track("one"), track("two"), track("three")]
        let queue = PlaybackQueue(tracks: tracks, startingAt: tracks[0], unavailableIDs: ["two"])
        XCTAssertEqual(queue.tracks.map(\.id), ["one", "three"])
        let rejected = PlaybackQueue(tracks: [tracks[1]], startingAt: tracks[1], unavailableIDs: ["two"])
        XCTAssertTrue(rejected.isEmpty)
        var unavailable = track("unavailable")
        unavailable.playable = false
        XCTAssertTrue(PlaybackQueue(tracks: [unavailable], startingAt: unavailable).isEmpty)
    }

    func testTransientFailuresAdvanceWithoutPermanentlyDisablingTracks() {
        let tracks = [track("one"), track("two"), track("three")]
        var queue = PlaybackQueue(tracks: tracks, startingAt: tracks[0])
        XCTAssertEqual(queue.advanceAfterFailure(attemptedIDs: ["one", "two"])?.id, "three")
        XCTAssertNil(queue.advanceAfterFailure(attemptedIDs: Set(tracks.map(\.id))))
        XCTAssertTrue(queue.tracks.allSatisfy(\.canPlay))
    }

    @MainActor
    func testArtworkPreviewReusesActualCachedListPixelsAtEveryScale() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/medium.jpg"))
        let other = try XCTUnwrap(URL(string: "https://example.com/other.jpg"))
        let image = UIImage(systemName: "music.note")!
        for pixels in [84, 126, 116, 174, 300] {
            let cache = ArtworkCache()
            cache.storeImage(image, for: url, pixelSize: pixels)
            XCTAssertTrue(cache.cachedPreviewImage(for: url) === image)
            XCTAssertNil(cache.cachedImage(for: url, pixelSize: 640))
            XCTAssertNil(cache.cachedPreviewImage(for: other))
        }
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
