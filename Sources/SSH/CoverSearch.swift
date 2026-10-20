//
//  CoverSearch.swift
//  The online cover fallback: which iTunes Search queries to try, and which result
//  to believe. Used when Music has no artwork for a song, which is common for
//  songs streamed from the catalogue rather than kept in the library.
//
//  - Store region matters: the API searches the US store unless told otherwise,
//    and many artists (e.g. Japanese or Thai ones) are only listed in other stores.
//    So the Mac's region is searched first, then the US store.
//  - Album search first, then song search: singles and live releases often don't
//    match by album name.
//  - A result must match the artist and the album or song title. Taking the first
//    result picked covers from unrelated releases.
//

import Foundation

struct CoverSearchItem: Decodable, Equatable {
    var artistName: String?
    var trackName: String?
    var collectionName: String?
    var artworkUrl100: String?
}

enum CoverSearch {
    enum Kind: String {
        case album, song
    }

    /// One query to try: its URL and what the result has to match.
    struct Attempt {
        let url: URL
        let kind: Kind
        let country: String
        let artist: String
        let title: String
    }

    struct Response: Decodable {
        let results: [CoverSearchItem]
    }

    /// Store regions to search, in order: the Mac's region, then the US store.
    static func countries(region: String?) -> [String] {
        var countries: [String] = []
        if let region = region?.lowercased(), region.count == 2 { countries.append(region) }
        if !countries.contains("us") { countries.append("us") }
        return countries
    }

    /// Most specific first: for each store, the album, then the song.
    static func attempts(name: String, artist: String, album: String, region: String?) -> [Attempt] {
        guard !artist.isEmpty else { return [] }
        var attempts: [Attempt] = []
        for country in countries(region: region) {
            if !album.isEmpty, let url = searchURL(term: "\(artist) \(album)", entity: "album", country: country) {
                attempts.append(Attempt(url: url, kind: .album, country: country, artist: artist, title: album))
            }
            if !name.isEmpty, let url = searchURL(term: "\(artist) \(name)", entity: "song", country: country) {
                attempts.append(Attempt(url: url, kind: .song, country: country, artist: artist, title: name))
            }
        }
        return attempts
    }

    private static func searchURL(term: String, entity: String, country: String) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "limit", value: "10")
        ]
        return components?.url
    }

    /// The 300 × 300 artwork URL of the best believable match, or nil. The artist
    /// must match, and so must the album title (album search) or song title (song
    /// search). Exact matches beat partial ones; ties keep the API's order.
    static func bestArtwork(in items: [CoverSearchItem], kind: Kind, artist: String, title: String) -> String? {
        var best: (score: Int, url: String)?
        for item in items {
            guard let small = item.artworkUrl100 else { continue }
            let artistScore = matchScore(item.artistName, artist)
            let titleScore = matchScore(kind == .album ? item.collectionName : item.trackName, title)
            guard artistScore > 0, titleScore > 0 else { continue }
            let score = artistScore + titleScore
            if score > (best?.score ?? 0) {
                best = (score, small.replacingOccurrences(of: "100x100bb", with: "300x300bb"))
            }
        }
        return best?.url
    }

    /// 2 for the same text (ignoring case, accents and width), 1 when one contains
    /// the other, 0 otherwise.
    static func matchScore(_ candidate: String?, _ wanted: String) -> Int {
        guard let candidate else { return 0 }
        let a = normalized(candidate), b = normalized(wanted)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 2 }
        return a.contains(b) || b.contains(a) ? 1 : 0
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
