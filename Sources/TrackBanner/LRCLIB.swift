import Foundation

/// 공개 가사 저장소 LRCLIB(https://lrclib.net)에서 싱크 가사를 찾는다. 로그인이 필요 없다.
enum LRCLIB {
    struct Item: Decodable {
        var trackName: String? = nil
        let duration: Double?
        let instrumental: Bool?
        let syncedLyrics: String?
    }

    enum LookupError: Error {
        /// 404가 아닌 실패. "가사 없음"이 아니므로 결과를 캐시하면 안 된다.
        case unavailable
    }

    private static let base = "https://lrclib.net/api"
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        config.httpAdditionalHeaders = ["User-Agent": "TrackBanner/\(version)"]
        return URLSession(configuration: config)
    }()

    /// 곡의 싱크 가사. LRCLIB에 없거나 연주곡이면 nil, 물어보지 못했으면 던진다.
    static func lines(for track: Track) async throws -> [LyricLine]? {
        // 여러 아티스트가 ", "로 이어져 오면 LRCLIB은 첫 아티스트 이름으로 찾는다.
        let artist = track.artist.components(separatedBy: ", ")[0]
        guard !track.name.isEmpty, !artist.isEmpty else { return nil }
        let seconds = track.durationMs.map { Int((Double($0) / 1000).rounded()) }

        var exact = ["track_name": track.name, "artist_name": artist]
        if !track.album.isEmpty { exact["album_name"] = track.album }
        if let seconds { exact["duration"] = String(seconds) }
        if let item: Item = try await get("get", exact) {
            if item.instrumental == true { return nil }
            if let lines = item.syncedLyrics.flatMap(LyricsParser.lrc) { return lines }
        }

        // 앨범 이름과 길이는 서비스마다 조금씩 다르고, 정확히 맞는 항목에 싱크 가사가 없을 수도 있다: 검색으로 넘어간다.
        let found: [Item] = try await get("search", ["track_name": track.name, "artist_name": artist]) ?? []
        if let lines = pick(found, seconds: seconds)?.syncedLyrics.flatMap(LyricsParser.lrc) { return lines }

        // Spotify는 계정 언어에 맞춰 아티스트 이름을 바꿔 주기도 한다(Fall Out Boy → フォール・アウト・ボーイ).
        // 그러면 위의 두 조회가 모두 빗나간다. 아티스트 대신 앨범으로, 그래도 없으면 제목만으로 찾되,
        // 다른 곡을 집지 않도록 길이를 알 때만, 제목이 같고 길이가 거의 같은 것만 받는다.
        guard let seconds else { return nil }
        var queries = [["track_name": track.name]]
        if !track.album.isEmpty { queries.insert(["track_name": track.name, "album_name": track.album], at: 0) }
        for query in queries {
            let found: [Item] = try await get("search", query) ?? []
            let sameTitle = found.filter { $0.trackName?.compare(track.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            if let lines = pick(sameTitle, seconds: seconds, tolerance: 2)?.syncedLyrics.flatMap(LyricsParser.lrc) { return lines }
        }
        return nil
    }

    /// 검색 결과 중 싱크 가사가 있고 길이가 가장 가까운 것. 길이가 `tolerance`초 넘게 다르면 다른 녹음으로 본다.
    static func pick(_ items: [Item], seconds: Int?, tolerance: Double = 4) -> Item? {
        let synced = items.filter { $0.syncedLyrics?.isEmpty == false }
        guard let seconds else { return synced.first }
        func distance(_ item: Item) -> Double { abs((item.duration ?? .infinity) - Double(seconds)) }
        return synced.filter { distance($0) <= tolerance }.min { distance($0) < distance($1) }
    }

    /// 404면 nil.
    private static func get<T: Decodable>(_ path: String, _ query: [String: String]) async throws -> T? {
        // URLComponents는 "+"를 그대로 두는데 서버는 이를 공백으로 읽는다. 직접 인코딩한다.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = query.sorted { $0.key < $1.key }.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }
        guard let url = URL(string: "\(base)/\(path)?\(encoded.joined(separator: "&"))") else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse
        else { throw LookupError.unavailable }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200, let value = try? JSONDecoder().decode(T.self, from: data) else {
            throw LookupError.unavailable
        }
        return value
    }
}
