import AppKit

/// 앨범 커버를 가져온다. URL을 이미 알면 그대로 받고,
/// 모르면 Spotify oEmbed API로 찾는다(인증이나 자동화 권한이 필요 없다).
enum ArtworkLoader {
    private struct OEmbed: Decodable {
        let thumbnail_url: String
    }

    static func artwork(for track: Track) async -> NSImage? {
        if let url = track.artworkURL {
            return await image(at: url)
        }

        // spotify:track:ID → https://open.spotify.com/track/ID
        let parts = track.id.split(separator: ":")
        guard parts.count == 3, parts[1] == "track" || parts[1] == "episode" else { return nil }

        var components = URLComponents(string: "https://open.spotify.com/oembed")!
        components.queryItems = [URLQueryItem(name: "url", value: "https://open.spotify.com/\(parts[1])/\(parts[2])")]

        do {
            let (json, _) = try await URLSession.shared.data(from: components.url!)
            let oembed = try JSONDecoder().decode(OEmbed.self, from: json)
            guard let imageURL = URL(string: oembed.thumbnail_url) else { return nil }
            return await image(at: imageURL)
        } catch {
            return nil
        }
    }

    private static func image(at url: URL) async -> NSImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: data)
    }
}
