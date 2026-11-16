//! Spotify's own lyrics, and what is playing right now, for Track Banner.
//!
//! The public Web API has no lyrics; Spotify's clients read an internal
//! `color-lyrics` endpoint that a developer token cannot reach. This process
//! signs in as a Spotify client through librespot (OAuth, once) and answers
//! the app, which runs it as a child process and talks to it over stdin and
//! stdout. The app falls back to LRCLIB when Spotify has no lyrics.
//!
//! It also follows Spotify Connect, the state Spotify's own apps keep in step
//! with: it joins as a hidden device that cannot play, and Spotify pushes it
//! every play, pause, seek and skip on any of the account's devices as it
//! happens. That is where the app gets a playback position exact enough to
//! follow lyrics line by line.
//!
//! Usage:
//!   lyrics-sidecar --login     # one-time OAuth in the browser; saves credentials
//!   lyrics-sidecar             # serve until stdin closes
//!
//! Protocol (one line each way, JSON out):
//!   in   lyrics <base62 track id>
//!   out  {"type":"ready","user":"…"}
//!        {"type":"lyrics","id":"…","status":200,"body":{…color-lyrics…}}   (404: none, 503: failed)
//!        {"type":"now","linked":true,"playback":{…}|null}                  (on every change)
//!
//! Exit status 2 means there are no usable credentials: log in again.
//!
//! Env: LYRICS_CACHE_DIR (credentials dir, default data/spotify),
//!      CONNECT_WATCH=0 to leave Spotify Connect alone (then "now" says it is not linked).

use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, Context, Result};
use futures_util::StreamExt;
use librespot_core::{
    authentication::Credentials, cache::Cache, dealer::protocol::Message, error::ErrorKind,
    Session, SessionConfig, SpotifyId,
};
use librespot_protocol::connect::{
    Capabilities, Cluster, ClusterUpdate, Device, DeviceInfo, MemberType, PutStateReason,
    PutStateRequest,
};
use protobuf::{EnumOrUnknown, Message as _, MessageField};
use std::io::Write as _;

use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::sync::{watch, Mutex};

// Spotify's desktop ("keymaster") client id, the one librespot authenticates
// as; its OAuth app registers this loopback redirect.
const CLIENT_ID: &str = "65b708073fc0480ea92a077233ca87bd";
const REDIRECT_URI: &str = "http://127.0.0.1:8898/login";

fn cache_dir() -> PathBuf {
    std::env::var_os("LYRICS_CACHE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("data/spotify"))
}

fn open_cache() -> Result<Cache> {
    let dir = cache_dir();
    std::fs::create_dir_all(&dir).ok();
    Cache::new(Some(dir.as_path()), None, None, None).context("open credentials cache")
}

/// What the browser shows once Spotify has sent it back here.
const LOGIN_DONE_PAGE: &str = r#"<!doctype html><meta charset="utf-8"><title>Track Banner</title>
<body style="font: 16px -apple-system, sans-serif; text-align: center; margin-top: 20vh">
<h2>Track Banner</h2><p>Spotify 로그인이 끝났습니다. 이 탭은 닫아도 됩니다.</p>
<p style="color: #888">Signed in to Spotify. You can close this tab.</p></body>"#;

/// The saved credentials are missing or Spotify no longer accepts them.
#[derive(Debug)]
struct LoginRequired;

impl std::fmt::Display for LoginRequired {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("login required")
    }
}

impl std::error::Error for LoginRequired {}

/// One-time OAuth: authorise in a browser, then save reusable credentials.
async fn login() -> Result<()> {
    let cache = open_cache()?;
    let client =
        librespot_oauth::OAuthClientBuilder::new(CLIENT_ID, REDIRECT_URI, vec!["streaming"])
            .open_in_browser()
            .with_custom_message(LOGIN_DONE_PAGE)
            .build()
            .map_err(|e| anyhow!("oauth setup: {e}"))?;
    let token = client
        .get_access_token_async()
        .await
        .map_err(|e| anyhow!("oauth: {e}"))?;
    let session = Session::new(SessionConfig::default(), Some(cache));
    session
        .connect(Credentials::with_access_token(token.access_token), true)
        .await
        .map_err(|e| anyhow!("connect: {e}"))?;
    println!("Logged in as {}. Credentials saved.", session.username());
    Ok(())
}

/// Connects using the saved credentials (no browser).
async fn connect_session() -> Result<Session> {
    let cache = open_cache()?;
    let creds = cache.credentials().ok_or(LoginRequired)?;
    let session = Session::new(SessionConfig::default(), Some(cache));
    session.connect(creds, false).await.map_err(|e| {
        // Spotify turned the saved credentials down (revoked, password changed).
        if e.kind == ErrorKind::PermissionDenied || e.kind == ErrorKind::Unauthenticated {
            anyhow!(LoginRequired)
        } else {
            anyhow!("connect: {e}")
        }
    })?;
    Ok(session)
}

struct State {
    /// For lyrics. Spotify Connect is followed on a session of its own (see `follow`).
    session: Mutex<Session>,
}

/// What the active device is playing, as Spotify Connect last reported it.
#[derive(Clone)]
struct Playback {
    /// `spotify:track:…`, `spotify:episode:…`, or anything else Spotify plays (ads, local files).
    uri: String,
    /// Playing, not paused and not buffering: the position moves.
    advancing: bool,
    /// Position at `at`.
    position_ms: i64,
    at: Instant,
    duration_ms: i64,
    /// Podcasts can play faster or slower than 1x.
    speed: f64,
}

impl Playback {
    fn position_now(&self) -> i64 {
        let mut position = self.position_ms;
        if self.advancing {
            position += (self.at.elapsed().as_millis() as f64 * self.speed) as i64;
        }
        if self.duration_ms > 0 {
            position = position.min(self.duration_ms);
        }
        position.max(0)
    }
}

#[derive(Clone, Default)]
struct Live {
    /// False while Spotify Connect is not followed: then nothing is known.
    linked: bool,
    /// None when nothing is playing.
    playback: Option<Playback>,
}

fn unix_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// The playback in a Connect cluster, with its position carried to `received`.
///
/// The playing device reports a position and the (Spotify) time it was at
/// that position; the cluster carries the Spotify time it was sent. Their
/// difference is how long ago the position was true, measured on one clock,
/// so this machine's clock never needs to agree with Spotify's.
fn playback_of(cluster: &Cluster, received: Instant, time_delta_s: i64) -> Option<Playback> {
    if cluster.active_device_id.is_empty() {
        return None;
    }
    let state = cluster.player_state.as_ref()?;
    let uri = state.track.as_ref().map(|t| t.uri.clone()).unwrap_or_default();
    // `is_playing` is false once playback has stopped; a paused track is playing and paused.
    if uri.is_empty() || !state.is_playing {
        return None;
    }
    let speed = if state.playback_speed > 0.0 { state.playback_speed } else { 1.0 };
    let advancing = !state.is_paused && !state.is_buffering;
    let mut position_ms = state.position_as_of_timestamp;
    if advancing && state.timestamp > 0 {
        // Without the cluster's send time, fall back to this clock corrected by the
        // session's offset to Spotify's (whole seconds only, hence the fallback).
        let sent = if cluster.server_timestamp_ms > 0 {
            cluster.server_timestamp_ms
        } else {
            unix_ms() + time_delta_s * 1000
        };
        position_ms += ((sent - state.timestamp).max(0) as f64 * speed) as i64;
    }
    Some(Playback { uri, advancing, position_ms, at: received, duration_ms: state.duration, speed })
}

fn publish(live: &watch::Sender<Live>, cluster: Option<&Cluster>, time_delta_s: i64) {
    let playback = cluster.and_then(|c| playback_of(c, Instant::now(), time_delta_s));
    live.send_modify(|l| {
        l.linked = true;
        l.playback = playback;
    });
}

/// Joins Spotify Connect as a device that is hidden from device pickers and
/// cannot play, only watch; Spotify answers with the current cluster.
async fn announce(session: &Session) -> Result<Cluster> {
    let request = PutStateRequest {
        member_type: EnumOrUnknown::new(MemberType::CONNECT_STATE),
        put_state_reason: EnumOrUnknown::new(PutStateReason::NEW_DEVICE),
        device: MessageField::some(Device {
            device_info: MessageField::some(DeviceInfo {
                can_play: false,
                name: "Track Banner".into(),
                device_id: session.device_id().to_string(),
                client_id: session.client_id(),
                capabilities: MessageField::some(Capabilities {
                    can_be_player: false,
                    hidden: true,
                    is_observable: true,
                    is_controllable: false,
                    supports_gzip_pushes: true,
                    ..Default::default()
                }),
                ..Default::default()
            }),
            ..Default::default()
        }),
        ..Default::default()
    };
    let body = session
        .spclient()
        .put_connect_state_request(&request)
        .await
        .map_err(|e| anyhow!("put connect state: {e}"))?;
    Cluster::parse_from_bytes(&body).map_err(|e| anyhow!("parse cluster: {e}"))
}

/// Follows Spotify Connect on a fresh session until the link drops.
async fn follow(live: &watch::Sender<Live>) -> Result<()> {
    let session = connect_session().await?;
    let dealer = session.dealer();
    // The dealer (Spotify's push socket) names each connection; a device is
    // registered against that name, so it is registered again on every reconnect.
    let mut connections = dealer
        .listen_for("hm://pusher/v1/connections/", |m: Message| {
            m.headers
                .get("Spotify-Connection-Id")
                .cloned()
                .ok_or_else(|| librespot_core::Error::failed_precondition("no connection id"))
        })
        .map_err(|e| anyhow!("listen: {e}"))?;
    let mut updates = dealer
        .listen_for("hm://connect-state/v1/cluster", Message::from_raw::<ClusterUpdate>)
        .map_err(|e| anyhow!("listen: {e}"))?;
    dealer.start().await.map_err(|e| anyhow!("dealer: {e}"))?;

    let mut check = tokio::time::interval(Duration::from_secs(5));
    let result = loop {
        tokio::select! {
            id = connections.next() => match id {
                Some(Ok(id)) => {
                    session.set_connection_id(&id);
                    match announce(&session).await {
                        Ok(cluster) => publish(live, Some(&cluster), session.time_delta()),
                        Err(e) => break Err(e),
                    }
                }
                Some(Err(e)) => eprintln!("[connect] connection id: {e}"),
                None => break Err(anyhow!("dealer closed")),
            },
            update = updates.next() => match update {
                Some(Ok(update)) => publish(live, update.cluster.as_ref(), session.time_delta()),
                Some(Err(e)) => eprintln!("[connect] cluster update: {e}"),
                None => break Err(anyhow!("dealer closed")),
            },
            _ = check.tick() => if session.is_invalid() { break Err(anyhow!("session dropped")) },
        }
    };
    let _ = session.spclient().delete_connect_state_request().await;
    dealer.close().await;
    session.shutdown();
    result
}

/// Keeps following Spotify Connect, reconnecting after a pause whenever the link drops.
async fn watch_connect(live: watch::Sender<Live>) {
    loop {
        if let Err(e) = follow(&live).await {
            eprintln!("[connect] {e:#}");
        }
        live.send_modify(|l| {
            l.linked = false;
            l.playback = None;
        });
        tokio::time::sleep(Duration::from_secs(10)).await;
    }
}

fn json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// Writes one line to the app. When the app is gone the pipe is closed, and so is this process.
fn emit(line: &[u8]) {
    let mut out = std::io::stdout().lock();
    let written = out
        .write_all(line)
        .and_then(|_| out.write_all(b"\n"))
        .and_then(|_| out.flush());
    if written.is_err() {
        std::process::exit(0);
    }
}

/// `{"type":"now","linked":…,"playback":{…}|null}`, the position as of this moment.
fn live_json(live: &Live) -> String {
    let playback = match &live.playback {
        None => "null".to_string(),
        Some(p) => format!(
            r#"{{"uri":{},"playing":{},"positionMs":{},"durationMs":{},"speed":{}}}"#,
            json_string(&p.uri),
            p.advancing,
            p.position_now(),
            p.duration_ms,
            p.speed
        ),
    };
    format!(r#"{{"type":"now","linked":{},"playback":{}}}"#, live.linked, playback)
}

/// Tells the app about every change in what Spotify Connect reports.
async fn report_live(mut rx: watch::Receiver<Live>) {
    while rx.changed().await.is_ok() {
        let json = live_json(&rx.borrow_and_update());
        emit(json.as_bytes());
    }
}

/// Returns the raw color-lyrics JSON for a track, `None` when Spotify has none.
/// Reconnects once if the session has dropped.
async fn lyrics_json(state: &State, id: &str) -> Result<Option<Vec<u8>>> {
    let track = SpotifyId::from_base62(id).map_err(|_| anyhow!("invalid track id"))?;
    let mut last = anyhow!("unknown error");
    for attempt in 0..2 {
        let session = state.session.lock().await.clone();
        match session.spclient().get_lyrics(&track).await {
            Ok(bytes) => return Ok(Some(bytes.to_vec())),
            Err(e) if e.kind == ErrorKind::NotFound => return Ok(None),
            Err(e) => {
                last = anyhow!("get_lyrics: {e}");
                if attempt == 0 {
                    match connect_session().await {
                        Ok(s) => *state.session.lock().await = s,
                        Err(ce) => return Err(ce.context("reconnect")),
                    }
                }
            }
        }
    }
    Err(last)
}

/// Answers one `lyrics <id>` request.
async fn answer_lyrics(state: &State, id: &str) {
    let (status, body) = match lyrics_json(state, id).await {
        // An empty answer is no lyrics too.
        Ok(Some(bytes)) if !bytes.iter().all(u8::is_ascii_whitespace) => (200, bytes),
        Ok(_) => (404, b"null".to_vec()),
        Err(e) => {
            eprintln!("[lyrics] {e:#}");
            (503, b"null".to_vec())
        }
    };
    let mut line = format!(r#"{{"type":"lyrics","id":{},"status":{},"body":"#, json_string(id), status).into_bytes();
    // A line break can only be whitespace between JSON tokens, never inside a string: keep the answer on one line.
    line.extend(body.into_iter().map(|b| if b == b'\n' || b == b'\r' { b' ' } else { b }));
    line.push(b'}');
    emit(&line);
}

async fn serve() -> Result<()> {
    let session = connect_session().await?;
    emit(format!(r#"{{"type":"ready","user":{}}}"#, json_string(&session.username())).as_bytes());

    let (live, rx) = watch::channel(Live::default());
    if std::env::var("CONNECT_WATCH").as_deref() != Ok("0") {
        tokio::spawn(report_live(rx));
        tokio::spawn(watch_connect(live));
    }
    let state = Arc::new(State { session: Mutex::new(session) });

    // The app closes stdin (or dies) to stop this process.
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    while let Some(line) = lines.next_line().await? {
        if let Some(id) = line.strip_prefix("lyrics ") {
            let state = state.clone();
            let id = id.trim().to_string();
            tokio::spawn(async move { answer_lyrics(&state, &id).await });
        }
    }
    Ok(())
}

#[tokio::main]
async fn main() {
    let login_only = std::env::args().nth(1).as_deref() == Some("--login");
    let result = if login_only { login().await } else { serve().await };
    let code = match result {
        Ok(()) => 0,
        Err(e) if e.downcast_ref::<LoginRequired>().is_some() => {
            eprintln!("no usable credentials; run `lyrics-sidecar --login`");
            2
        }
        Err(e) => {
            eprintln!("{e:#}");
            1
        }
    };
    // Not a return: tasks still following Spotify Connect would keep the runtime waiting.
    std::process::exit(code);
}
