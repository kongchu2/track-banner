import AppKit
import CryptoKit
import Security

/// Spotify Web API 로그인(Authorization Code + PKCE). 클라이언트 시크릿이 필요 없다.
/// Client ID는 사용자가 Spotify Developer Dashboard에서 직접 만든 앱의 것을 쓴다.
@MainActor
final class SpotifyAuth {
    static let redirectURI = "trackbanner://callback"
    private static let clientIDKey = "SpotifyClientID"
    private static let scope = "user-read-currently-playing"
    private static let keychainService = "com.kongchu2.trackbanner"
    private static let keychainAccount = "SpotifyRefreshToken"

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Double
        let refresh_token: String?
    }

    var clientID: String? {
        get { UserDefaults.standard.string(forKey: Self.clientIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.clientIDKey) }
    }

    enum CallbackResult {
        case connected
        /// 사용자가 Spotify 동의 화면에서 취소했다.
        case cancelled
        /// 이 앱이 시작한 로그인의 응답이 아니다(다른 곳에서 연 URL, 앱의 다른 사본으로 온 응답 등).
        case ignored
        case failed
        /// 로그인은 됐지만 리프레시 토큰을 키체인에 저장하지 못했다.
        case keychainFailed
    }

    private enum TokenResult {
        case token(TokenResponse)
        /// 서버가 요청을 거절했다(리프레시 토큰이 취소되거나 만료됨).
        case rejected
        case failed
    }

    var isConnected: Bool { refreshToken != nil }
    /// 연결 상태가 바뀌었을 때(로그인 완료, 연결 해제, 토큰 만료).
    var onChange: (() -> Void)?

    /// 키체인에 있는 값의 사본. 메뉴를 열 때마다 메인 스레드에서 키체인을 읽지 않도록 메모리에 둔다.
    private var refreshToken: String?
    private var accessToken: String?
    private var expiry = Date.distantPast
    private var pendingVerifier: String?
    private var pendingState: String?

    init() {
        // 연결을 시도한 적이 없으면 키체인을 건드리지 않는다.
        if UserDefaults.standard.string(forKey: Self.clientIDKey) != nil {
            refreshToken = Self.readRefreshToken()
        }
    }

    /// 브라우저에서 Spotify 로그인 화면을 연다. 끝나면 `trackbanner://callback`으로 돌아온다.
    func beginLogin() {
        guard let clientID, !clientID.isEmpty else { return }
        let verifier = Self.randomString(byteCount: 48)
        let state = Self.randomString(byteCount: 16)
        pendingVerifier = verifier
        pendingState = state

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
            URLQueryItem(name: "state", value: state),
        ]
        NSWorkspace.shared.open(components.url!)
    }

    /// `trackbanner://callback?code=...&state=...`를 받아 토큰으로 바꾼다.
    func handleCallback(_ url: URL) async -> CallbackResult {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        // 아무 앱이나 웹 페이지가 이 URL을 열 수 있으므로, 진행 중인 로그인의 state와 맞을 때만 받는다.
        guard url.scheme == "trackbanner", url.host == "callback",
              let verifier = pendingVerifier, let state = value("state"), state == pendingState,
              let clientID else { return .ignored }
        pendingVerifier = nil
        pendingState = nil

        if let error = value("error") { return error == "access_denied" ? .cancelled : .failed }
        guard let code = value("code") else { return .failed }

        let result = await requestToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
        guard case .token(let token) = result, let refresh = token.refresh_token else { return .failed }
        // 저장하지 못하면 다음 실행 때 조용히 끊기므로 연결된 것으로 치지 않는다.
        guard Self.saveRefreshToken(refresh) else { return .keychainFailed }
        refreshToken = refresh
        accessToken = token.access_token
        expiry = Date().addingTimeInterval(token.expires_in)
        onChange?()
        return .connected
    }

    /// 유효한 액세스 토큰. 만료됐으면 리프레시 토큰으로 새로 받는다.
    func validAccessToken() async -> String? {
        if let accessToken, expiry > Date().addingTimeInterval(30) { return accessToken }
        guard let refresh = refreshToken, let clientID else { return nil }
        let result = await requestToken(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID])
        // 기다리는 사이 연결을 해제했거나 다시 로그인했으면 이 응답은 버린다.
        guard refreshToken == refresh else { return nil }
        switch result {
        case .token(let token):
            accessToken = token.access_token
            expiry = Date().addingTimeInterval(token.expires_in)
            if let rotated = token.refresh_token {
                // Spotify는 리프레시 토큰을 새로 바꿔 준다. 키체인 저장에 실패해도 이번 실행 동안은 메모리의 새 토큰으로 계속 쓴다.
                refreshToken = rotated
                Self.saveRefreshToken(rotated)
            }
            return accessToken
        case .rejected:
            // 다시 로그인해야 한다.
            disconnect()
            return nil
        case .failed:
            return nil
        }
    }

    /// 서버가 401을 줬을 때 캐시한 토큰을 버려서 다음에 새로 받게 한다.
    func invalidateAccessToken() { accessToken = nil }

    func disconnect() {
        accessToken = nil
        refreshToken = nil
        Self.deleteRefreshToken()
        onChange?()
    }

    private func requestToken(_ form: [String: String]) async -> TokenResult {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return .failed }
        if http.statusCode == 400 { return .rejected }
        guard http.statusCode == 200, let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else { return .failed }
        return .token(token)
    }

    // MARK: - PKCE

    private static func randomString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Keychain

    private static var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private static func readRefreshToken() -> String? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func saveRefreshToken(_ token: String) -> Bool {
        let data = Data(token.utf8)
        var status = SecItemUpdate(keychainQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = keychainQuery
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    private static func deleteRefreshToken() {
        SecItemDelete(keychainQuery as CFDictionary)
    }
}
