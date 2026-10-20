import Testing
@testable import ReverbRoom

private func item(_ artist: String, track: String? = nil, album: String, art: String) -> CoverSearchItem {
    CoverSearchItem(artistName: artist, trackName: track, collectionName: album,
                    artworkUrl100: "https://example.com/\(art)/100x100bb.jpg")
}

@Suite struct CoverSearchTests {
    @Test func searchesTheMacsRegionFirstThenTheUSStore() {
        #expect(CoverSearch.countries(region: "TH") == ["th", "us"])
        #expect(CoverSearch.countries(region: "US") == ["us"])
        #expect(CoverSearch.countries(region: nil) == ["us"])
    }

    @Test func triesAlbumThenSongPerStore() {
        let attempts = CoverSearch.attempts(name: "Tegami", artist: "back number", album: "Encore", region: "TH")
        #expect(attempts.map { "\($0.country) \($0.kind.rawValue)" } == ["th album", "th song", "us album", "us song"])
    }

    @Test func noArtistMeansNoSearch() {
        #expect(CoverSearch.attempts(name: "Tegami", artist: "", album: "Encore", region: "TH").isEmpty)
    }

    @Test func picksTheExactSongByTheRightArtist() {
        // Real shape of a Thai-store song search for "back number Tegami".
        let items = [
            item("Various Artists", track: "Tegami", album: "Letters and Doll", art: "wrong-artist"),
            item("back number", track: "Tegami (Live)", album: "Live at Nissan Stadium", art: "partial"),
            item("back number", track: "Tegami", album: "Encore", art: "right")
        ]
        let url = CoverSearch.bestArtwork(in: items, kind: .song, artist: "back number", title: "Tegami")
        #expect(url == "https://example.com/right/300x300bb.jpg")
    }

    @Test func rejectsResultsByAnotherArtist() {
        let items = [item("Somebody Else", track: "Tegami", album: "Tegami - Single", art: "x")]
        #expect(CoverSearch.bestArtwork(in: items, kind: .song, artist: "back number", title: "Tegami") == nil)
    }

    @Test func albumSearchMatchesOnTheAlbumTitle() {
        let items = [
            item("back number", album: "Magic", art: "other-album"),
            item("back number", album: "Encore", art: "right")
        ]
        let url = CoverSearch.bestArtwork(in: items, kind: .album, artist: "back number", title: "Encore")
        #expect(url == "https://example.com/right/300x300bb.jpg")
    }

    @Test func matchingIgnoresCaseAccentsAndWidth() {
        #expect(CoverSearch.matchScore("BACK NUMBER", "back number") == 2)
        #expect(CoverSearch.matchScore("Beyoncé", "Beyonce") == 2)
        #expect(CoverSearch.matchScore("ＡＢＣ", "ABC") == 2)   // full-width letters
        #expect(CoverSearch.matchScore("Tegami - Single", "Tegami") == 1)
        #expect(CoverSearch.matchScore("Magic", "Encore") == 0)
    }
}
