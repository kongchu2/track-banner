import Foundation

/// 한 소스가 본 재생 상태.
enum PlaybackState: Equatable {
    case playing(Track)
    /// 일시정지. 같은 곡을 다시 틀어도 새 곡으로 보지 않는다.
    case paused
    /// 정지·광고·종료. 같은 곡을 다시 틀면 새 곡으로 본다.
    case stopped

    var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }

    // 소스마다 제목·아티스트 표기가 조금 달라도 같은 곡이면 같은 상태다.
    static func == (lhs: PlaybackState, rhs: PlaybackState) -> Bool {
        switch (lhs, rhs) {
        case let (.playing(a), .playing(b)): return a.id == b.id
        case (.paused, .paused), (.stopped, .stopped): return true
        default: return false
        }
    }
}

/// 공식 클라이언트 알림과 Web API 폴링이 각자 본 상태를 하나로 합쳐 "지금 재생 중인 곡"을 정한다.
/// 소스는 변화가 아니라 현재 상태를 그대로 알리고, 중복 제거와 배너 여부는 여기서만 판단한다.
@MainActor
final class PlaybackCoordinator {
    /// 합친 상태가 바뀌었을 때. `isNewTrack`이면 배너를 띄울 차례다.
    var onChange: ((_ state: PlaybackState, _ isNewTrack: Bool) -> Void)?
    /// 공식 클라이언트의 재생이 바뀌어 Web API가 준 상태를 더는 믿을 수 없을 때. 폴링을 새로 시작하게 한다.
    var onWebStateInvalidated: (() -> Void)?

    private(set) var current: PlaybackState = .stopped
    /// 공식 클라이언트가 상태를 알린 횟수. 오래 걸린 조회가 그사이 온 알림을 덮어쓰지 않게 하는 데 쓴다.
    private(set) var clientReportCount = 0

    private var client: PlaybackState = .stopped
    /// nil이면 아직 모른다(연결 전, 첫 응답 전, 무효화 직후).
    private var web: PlaybackState?
    /// 마지막으로 재생 중이라고 알린 곡. 정지되면 지운다.
    private var lastTrackID: String?

    /// 공식 클라이언트의 알림. 즉시 오므로 재생 중이면 Web API보다 우선한다.
    func clientReported(_ state: PlaybackState) {
        clientReportCount += 1
        setClient(state, announce: true)
    }

    /// 앱을 켠 시점에 이미 재생 중이던 곡. 새 곡이 아니므로 배너는 띄우지 않는다.
    func clientWasAlreadyPlaying(_ track: Track) {
        setClient(.playing(track), announce: false)
    }

    /// Web API 폴링 결과. 매번 현재 상태를 그대로 넘긴다.
    func webReported(_ state: PlaybackState) {
        // 모르던 상태에서 처음 본 곡은 이미 재생 중이던 곡이다.
        let announce = web != nil
        web = state
        resolve(announce: announce)
    }

    /// Web API 연결이 끊겼다.
    func webDisconnected() {
        web = nil
        resolve(announce: false)
    }

    private func setClient(_ state: PlaybackState, announce: Bool) {
        guard state != client else { return }
        let involvesPlayback = client.isPlaying || state.isPlaying
        client = state
        // 폴링 결과는 몇 초 늦다. 클라이언트의 재생이 바뀌었으면 그 전에 받은(또는 받는 중인) 응답은 옛 상태다.
        if involvesPlayback, web != nil {
            web = nil
            onWebStateInvalidated?()
        }
        resolve(announce: announce)
    }

    private var merged: PlaybackState {
        if client.isPlaying { return client }
        guard let web else { return client }
        if web.isPlaying { return web }
        return client == .paused || web == .paused ? .paused : .stopped
    }

    private func resolve(announce: Bool) {
        let state = merged
        guard state != current else { return }
        current = state
        switch state {
        case .playing(let track):
            let isNewTrack = announce && track.id != lastTrackID
            lastTrackID = track.id
            onChange?(state, isNewTrack)
        case .paused:
            onChange?(state, false)
        case .stopped:
            lastTrackID = nil
            onChange?(state, false)
        }
    }
}
