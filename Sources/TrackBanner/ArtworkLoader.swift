import AppKit

/// 앨범 커버를 Spotify oEmbed API로 찾아 가져온다(인증이나 자동화 권한이 필요 없다).
enum ArtworkLoader {
    private struct OEmbed: Decodable {
        // 일부 곡은 oEmbed 응답에 썸네일이 없다.
        let thumbnail_url: String?
    }

    static func artwork(for track: Track) async -> NSImage? {
        // spotify:track:ID → https://open.spotify.com/track/ID
        let parts = track.id.split(separator: ":")
        guard parts.count == 3, parts[1] == "track" || parts[1] == "episode" else { return nil }

        let pageURL = "https://open.spotify.com/\(parts[1])/\(parts[2])"
        if let url = await oEmbedThumbnail(pageURL: pageURL), let image = await image(at: url) {
            return image
        }
        // oEmbed에 썸네일이 없으면 곡 페이지의 og:image를 쓴다.
        if let url = await openGraphImage(pageURL: pageURL) { return await image(at: url) }
        return nil
    }

    private static func oEmbedThumbnail(pageURL: String) async -> URL? {
        var components = URLComponents(string: "https://open.spotify.com/oembed")!
        components.queryItems = [URLQueryItem(name: "url", value: pageURL)]
        guard let (json, _) = try? await URLSession.shared.data(from: components.url!),
              let oembed = try? JSONDecoder().decode(OEmbed.self, from: json),
              let thumbnail = oembed.thumbnail_url
        else { return nil }
        return URL(string: thumbnail)
    }

    private static func openGraphImage(pageURL: String) async -> URL? {
        guard let url = URL(string: pageURL),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let html = String(data: data, encoding: .utf8),
              let tag = html.range(of: #"<meta property="og:image" content="[^"]+""#, options: .regularExpression),
              let value = html[tag].components(separatedBy: "content=\"").last
        else { return nil }
        return URL(string: value.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
    }

    private static func image(at url: URL) async -> NSImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: data)
    }
}
