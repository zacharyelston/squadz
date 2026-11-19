//! The Squadz relay: carries a squad's links over the internet when its devices aren't on one
//! network (docs/RELAY.md).
//!
//! It is a pipe and nothing more. A leader's device opens a room for its squad; each member's
//! device opens a link into that room; the relay passes bytes between the two. It never reads
//! what it carries, never decides who is in a squad, and keeps no names, rosters or positions.
//! What it stores is which squads have a room, and the hashes of the secrets that open one.

pub mod store;

use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use axum::body::Bytes;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{ConnectInfo, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::Router;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use futures_util::stream::{SplitSink, SplitStream};
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use serde_json::json;
use sha2::{Digest, Sha256};
use tokio::sync::{mpsc, Notify};
use tokio::time::timeout;

use store::{Limits, Store};

/// The largest message the relay carries: SquadKit's largest frame, its length, and the link number.
pub const MAX_MESSAGE: usize = (1 << 20) + 8;
/// Messages waiting for a slow device before it is dropped.
const QUEUE: usize = 256;

pub struct Config {
    /// The SQLite file, or ":memory:".
    pub db: String,
    /// The one web page that may connect from a browser. Native apps send no `Origin` and are
    /// not affected. With none set, every browser is refused.
    pub web_origin: Option<String>,
    /// Take a device's address from the last `X-Forwarded-For` value. Only behind a proxy that
    /// sets it.
    pub trust_proxy: bool,
    /// Wrong secrets one address may present in `failure_window` before it is turned away.
    pub max_failures: u32,
    pub failure_window: Duration,
    /// Rooms one address may create an hour.
    pub max_creates: u32,
    pub max_squads: usize,
    pub max_devices_per_squad: usize,
    /// Links into one room at a time.
    pub max_links: usize,
    /// A socket that says nothing for this long, not even an answer to a ping, is closed.
    pub idle: Duration,
    pub ping: Duration,
    /// A room whose leader hasn't connected for this long is forgotten.
    pub forget_after: Duration,
}

impl Default for Config {
    fn default() -> Config {
        Config {
            db: "relay.db".into(),
            web_origin: None,
            trust_proxy: false,
            max_failures: 10,
            failure_window: Duration::from_secs(600),
            max_creates: 20,
            max_squads: 10_000,
            max_devices_per_squad: 256,
            max_links: 64,
            idle: Duration::from_secs(60),
            ping: Duration::from_secs(20),
            forget_after: Duration::from_secs(30 * 24 * 3600),
        }
    }
}

enum Out {
    Text(String),
    Binary(Bytes),
    Close,
}

type Tx = mpsc::Sender<Out>;
type Sink = SplitSink<WebSocket, Message>;
type Stream = SplitStream<WebSocket>;

/// A squad whose leader is connected.
struct Room {
    /// Tells this leader's connection from one that replaced it.
    session: u64,
    leader: Tx,
    stop: Arc<Notify>,
    next: u32,
    links: HashMap<u32, Link>,
}

/// One member's device, connected.
struct Link {
    device: String,
    tx: Tx,
    stop: Arc<Notify>,
}

impl Room {
    fn close(self) {
        self.stop.notify_one();
        for link in self.links.into_values() {
            link.stop.notify_one();
        }
    }
}

struct Window {
    start: Instant,
    count: u32,
}

pub struct Relay {
    cfg: Config,
    store: Mutex<Store>,
    rooms: Mutex<HashMap<String, Room>>,
    failures: Mutex<HashMap<IpAddr, Window>>,
    creates: Mutex<HashMap<IpAddr, Window>>,
    sessions: AtomicU64,
}

#[derive(Deserialize)]
#[serde(tag = "t", rename_all = "lowercase")]
enum Hello {
    /// A leader's device opens a room for a new squad.
    Create { squad: String },
    /// A leader's device comes back to its room.
    Lead { squad: String, token: String },
    /// A device with an invite asks for a token of its own.
    Join { squad: String, key: String },
    /// A device with a token opens a link to the leader.
    Member { squad: String, token: String },
}

#[derive(Deserialize)]
#[serde(tag = "t", rename_all = "lowercase")]
enum Control {
    Close {
        conn: u32,
        #[serde(default)]
        refused: bool,
    },
    Invites {
        list: Vec<Invite>,
    },
    Revoke {
        device: String,
    },
    End,
}

#[derive(Deserialize)]
struct Invite {
    /// SHA-256 of the invite's relay key, in hex.
    hash: String,
    /// Seconds since 1970.
    exp: i64,
}

pub fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn random<const N: usize>() -> [u8; N] {
    let mut bytes = [0u8; N];
    getrandom::getrandom(&mut bytes).expect("the system's random numbers");
    bytes
}

fn sha256(bytes: &[u8]) -> Vec<u8> {
    Sha256::digest(bytes).to_vec()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) || !text.is_ascii() {
        return None;
    }
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&text[i..i + 2], 16).ok())
        .collect()
}

/// Compares without stopping at the first difference.
fn same(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// A squad's ID as the relay keys it: a UUID in lower case.
fn squad_id(text: &str) -> Option<String> {
    let ok = text.len() == 36
        && text.bytes().enumerate().all(|(i, b)| match i {
            8 | 13 | 18 | 23 => b == b'-',
            _ => b.is_ascii_hexdigit(),
        });
    ok.then(|| text.to_ascii_lowercase())
}

/// A secret a device presents: 16 to 64 bytes, base64 for URLs.
fn secret(text: &str) -> Option<Vec<u8>> {
    URL_SAFE_NO_PAD.decode(text).ok().filter(|b| (16..=64).contains(&b.len()))
}

fn refused(why: Option<&str>) -> Out {
    Out::Text(match why {
        Some(why) => json!({"t": "refused", "why": why}).to_string(),
        None => json!({"t": "refused"}).to_string(),
    })
}

impl Relay {
    pub fn new(cfg: Config) -> rusqlite::Result<Arc<Relay>> {
        let store = Store::open(&cfg.db)?;
        Ok(Arc::new(Relay {
            cfg,
            store: Mutex::new(store),
            rooms: Mutex::new(HashMap::new()),
            failures: Mutex::new(HashMap::new()),
            creates: Mutex::new(HashMap::new()),
            sessions: AtomicU64::new(1),
        }))
    }

    pub fn router(self: &Arc<Relay>) -> Router {
        Router::new()
            .route("/v1/link", get(upgrade))
            .route("/healthz", get(|| async { "ok" }))
            .with_state(self.clone())
    }

    /// Forgets expired invites and rooms nobody has led for a long time.
    pub fn sweep(&self) {
        let now = now();
        let _ = self.store.lock().unwrap().sweep(now, now - self.cfg.forget_after.as_secs() as i64);
    }

    fn limits(&self) -> Limits {
        Limits {
            squads: self.cfg.max_squads,
            devices_per_squad: self.cfg.max_devices_per_squad,
        }
    }

    fn address(&self, peer: SocketAddr, headers: &HeaderMap) -> IpAddr {
        if self.cfg.trust_proxy {
            let forwarded = headers
                .get("x-forwarded-for")
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.rsplit(',').next())
                .and_then(|v| v.trim().parse().ok());
            if let Some(ip) = forwarded {
                return ip;
            }
        }
        peer.ip()
    }

    /// Counts one more in `ip`'s window. True while the count is within `max`.
    fn count(map: &Mutex<HashMap<IpAddr, Window>>, ip: IpAddr, window: Duration, max: u32, add: u32) -> bool {
        let mut map = map.lock().unwrap();
        let now = Instant::now();
        if map.len() > 50_000 {
            map.retain(|_, w| now.duration_since(w.start) < window);
        }
        let w = map.entry(ip).or_insert(Window { start: now, count: 0 });
        if now.duration_since(w.start) >= window {
            *w = Window { start: now, count: 0 };
        }
        w.count = w.count.saturating_add(add);
        w.count <= max
    }

    /// Has this address presented too many wrong secrets lately?
    fn blocked(&self, ip: IpAddr) -> bool {
        // Checking adds nothing; the count is full once it has reached the limit.
        !Self::count(
            &self.failures,
            ip,
            self.cfg.failure_window,
            self.cfg.max_failures.saturating_sub(1),
            0,
        )
    }

    fn failed(&self, ip: IpAddr) {
        Self::count(&self.failures, ip, self.cfg.failure_window, self.cfg.max_failures, 1);
    }

    async fn socket(self: Arc<Relay>, socket: WebSocket, ip: IpAddr) {
        let (sink, mut stream) = socket.split();
        let (tx, rx) = mpsc::channel(QUEUE);
        let mut writer = tokio::spawn(write(sink, rx, self.cfg.ping));
        let never = Notify::new();

        let hello = match timeout(Duration::from_secs(10), next(&mut stream, self.cfg.idle, &never)).await {
            Ok(Some(Message::Text(text))) => serde_json::from_str::<Hello>(text.as_str()).ok(),
            _ => None,
        };
        match hello {
            None => {}
            Some(_) if self.blocked(ip) => {
                let _ = tx.send(refused(Some("slow"))).await;
            }
            Some(hello) => self.serve(hello, ip, &tx, &mut stream).await,
        }

        // Whatever is queued goes first, then the close.
        let _ = timeout(Duration::from_secs(5), tx.send(Out::Close)).await;
        if timeout(Duration::from_secs(5), &mut writer).await.is_err() {
            writer.abort();
        }
    }

    async fn serve(self: &Arc<Relay>, hello: Hello, ip: IpAddr, tx: &Tx, stream: &mut Stream) {
        let refuse = |why: Option<&'static str>| async move {
            let _ = tx.send(refused(why)).await;
        };
        match hello {
            Hello::Create { squad } => {
                let Some(squad) = squad_id(&squad) else { return refuse(None).await };
                if !Self::count(&self.creates, ip, Duration::from_secs(3600), self.cfg.max_creates, 1) {
                    return refuse(Some("slow")).await;
                }
                let token = random::<32>();
                let made = self
                    .store
                    .lock()
                    .unwrap()
                    .create_squad(&squad, &sha256(&token), now(), &self.limits());
                if !matches!(made, Ok(true)) {
                    return refuse(None).await;
                }
                let _ = tx
                    .send(Out::Text(
                        json!({"t": "created", "token": URL_SAFE_NO_PAD.encode(token)}).to_string(),
                    ))
                    .await;
                self.lead(&squad, tx, stream).await;
            }
            Hello::Lead { squad, token } => {
                let known = match (squad_id(&squad), secret(&token)) {
                    (Some(squad), Some(token)) => {
                        let hash = self.store.lock().unwrap().leader_hash(&squad).ok().flatten();
                        hash.filter(|h| same(h, &sha256(&token))).map(|_| squad)
                    }
                    _ => None,
                };
                let Some(squad) = known else {
                    self.failed(ip);
                    return refuse(None).await;
                };
                let _ = tx.send(Out::Text(json!({"t": "ok"}).to_string())).await;
                self.lead(&squad, tx, stream).await;
            }
            Hello::Join { squad, key } => {
                let open = match (squad_id(&squad), secret(&key)) {
                    (Some(squad), Some(key)) => {
                        let open = self.store.lock().unwrap().invite_open(&squad, &sha256(&key), now());
                        matches!(open, Ok(true)).then_some(squad)
                    }
                    _ => None,
                };
                // One answer whatever was wrong: no such squad, a wrong key, an invite that has closed.
                let Some(squad) = open else {
                    self.failed(ip);
                    return refuse(None).await;
                };
                let device = hex(&random::<8>());
                let token = random::<32>();
                let added = self
                    .store
                    .lock()
                    .unwrap()
                    .add_device(&squad, &device, &sha256(&token), now(), &self.limits());
                if !matches!(added, Ok(true)) {
                    return refuse(Some("full")).await;
                }
                let _ = tx
                    .send(Out::Text(
                        json!({"t": "joined", "device": device, "token": URL_SAFE_NO_PAD.encode(token)}).to_string(),
                    ))
                    .await;
            }
            Hello::Member { squad, token } => {
                let known = match (squad_id(&squad), secret(&token)) {
                    (Some(squad), Some(token)) => {
                        let found = self.store.lock().unwrap().device(&sha256(&token)).ok().flatten();
                        found.filter(|(s, _)| *s == squad).map(|(_, device)| (squad, device))
                    }
                    _ => None,
                };
                let Some((squad, device)) = known else {
                    self.failed(ip);
                    return refuse(None).await;
                };
                self.member(&squad, device, tx, stream).await;
            }
        }
    }

    /// A leader's device is connected: its room is open until it goes.
    async fn lead(self: &Arc<Relay>, squad: &str, tx: &Tx, stream: &mut Stream) {
        let session = self.sessions.fetch_add(1, Ordering::Relaxed);
        let stop = Arc::new(Notify::new());
        let room = Room {
            session,
            leader: tx.clone(),
            stop: stop.clone(),
            next: 0,
            links: HashMap::new(),
        };
        // The newest connection is the leader. An older one, likely dead, is closed with its links.
        if let Some(old) = self.rooms.lock().unwrap().insert(squad.to_string(), room) {
            old.close();
        }
        let _ = self.store.lock().unwrap().touch(squad, now());

        while let Some(message) = next(stream, self.cfg.idle, &stop).await {
            match message {
                Message::Binary(bytes) => {
                    if bytes.len() < 4 {
                        break;
                    }
                    let conn = u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
                    let link = {
                        let rooms = self.rooms.lock().unwrap();
                        rooms
                            .get(squad)
                            .filter(|r| r.session == session)
                            .and_then(|r| r.links.get(&conn))
                            .map(|l| l.tx.clone())
                    };
                    // A member's device that can't keep up is dropped; it will connect again.
                    if let Some(link) = link {
                        if link.try_send(Out::Binary(bytes.slice(4..))).is_err() {
                            self.drop_link(squad, session, conn, false);
                        }
                    }
                }
                Message::Text(text) => match serde_json::from_str::<Control>(text.as_str()) {
                    Ok(Control::Close { conn, refused }) => self.drop_link(squad, session, conn, refused),
                    Ok(Control::Invites { list }) => {
                        let invites: Vec<(Vec<u8>, i64)> = list
                            .iter()
                            .take(16)
                            .filter_map(|i| unhex(&i.hash).filter(|h| h.len() == 32).map(|h| (h, i.exp)))
                            .collect();
                        let _ = self.store.lock().unwrap().set_invites(squad, &invites);
                    }
                    Ok(Control::Revoke { device }) => {
                        let _ = self.store.lock().unwrap().remove_device(squad, &device);
                        let conns: Vec<u32> = {
                            let rooms = self.rooms.lock().unwrap();
                            rooms
                                .get(squad)
                                .filter(|r| r.session == session)
                                .map(|r| r.links.iter().filter(|(_, l)| l.device == device).map(|(c, _)| *c).collect())
                                .unwrap_or_default()
                        };
                        for conn in conns {
                            self.drop_link(squad, session, conn, true);
                        }
                    }
                    Ok(Control::End) => {
                        let _ = self.store.lock().unwrap().remove_squad(squad);
                        break;
                    }
                    Err(_) => {}
                },
                _ => {}
            }
        }

        let mine = {
            let mut rooms = self.rooms.lock().unwrap();
            if rooms.get(squad).map(|r| r.session) == Some(session) {
                rooms.remove(squad)
            } else {
                None
            }
        };
        if let Some(room) = mine {
            let _ = self.store.lock().unwrap().touch(squad, now());
            room.close();
        }
    }

    /// The leader's device closed a link, or the relay dropped it.
    fn drop_link(&self, squad: &str, session: u64, conn: u32, was_refused: bool) {
        let link = {
            let mut rooms = self.rooms.lock().unwrap();
            rooms
                .get_mut(squad)
                .filter(|r| r.session == session)
                .and_then(|r| r.links.remove(&conn))
        };
        if let Some(link) = link {
            if was_refused {
                let _ = link.tx.try_send(refused(None));
            }
            link.stop.notify_one();
        }
    }

    /// A member's device is connected: a link to the leader's device, if it is here.
    async fn member(self: &Arc<Relay>, squad: &str, device: String, tx: &Tx, stream: &mut Stream) {
        let stop = Arc::new(Notify::new());
        let nonce = URL_SAFE_NO_PAD.encode(random::<32>());
        let opened = {
            let mut rooms = self.rooms.lock().unwrap();
            match rooms.get_mut(squad) {
                Some(room) if room.links.len() < self.cfg.max_links => {
                    room.next += 1;
                    room.links.insert(
                        room.next,
                        Link {
                            device: device.clone(),
                            tx: tx.clone(),
                            stop: stop.clone(),
                        },
                    );
                    Some((room.session, room.next, room.leader.clone()))
                }
                _ => None,
            }
        };
        // The leader's device isn't connected (or its room is full): try again later.
        let Some((session, conn, leader)) = opened else {
            let _ = tx.send(Out::Text(json!({"t": "away"}).to_string())).await;
            return;
        };

        let open = json!({"t": "open", "conn": conn, "device": device, "nonce": nonce}).to_string();
        if leader.send(Out::Text(open)).await.is_ok() {
            let _ = tx.send(Out::Text(json!({"t": "open", "nonce": nonce}).to_string())).await;
            while let Some(message) = next(stream, self.cfg.idle, &stop).await {
                if let Message::Binary(bytes) = message {
                    let mut framed = Vec::with_capacity(4 + bytes.len());
                    framed.extend_from_slice(&conn.to_be_bytes());
                    framed.extend_from_slice(&bytes);
                    // A leader's device that can't keep up holds its members back.
                    if !matches!(timeout(self.cfg.idle, leader.send(Out::Binary(framed.into()))).await, Ok(Ok(()))) {
                        break;
                    }
                }
            }
        }

        let was_open = {
            let mut rooms = self.rooms.lock().unwrap();
            rooms
                .get_mut(squad)
                .filter(|r| r.session == session)
                .and_then(|r| r.links.remove(&conn))
                .is_some()
        };
        if was_open {
            let closed = json!({"t": "closed", "conn": conn}).to_string();
            let _ = timeout(Duration::from_secs(5), leader.send(Out::Text(closed))).await;
        }
    }
}

async fn upgrade(
    ws: WebSocketUpgrade,
    State(relay): State<Arc<Relay>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
) -> Response {
    // A browser says which page it is running. Only the web client's page may connect.
    if let Some(origin) = headers.get(header::ORIGIN) {
        if relay.cfg.web_origin.as_deref().map(str::as_bytes) != Some(origin.as_bytes()) {
            return StatusCode::FORBIDDEN.into_response();
        }
    }
    let ip = relay.address(peer, &headers);
    ws.max_message_size(MAX_MESSAGE)
        .max_frame_size(MAX_MESSAGE)
        .on_upgrade(move |socket| relay.socket(socket, ip))
}

/// The next text or binary message, or `None` when the socket closes, goes quiet, or is stopped.
async fn next(stream: &mut Stream, idle: Duration, stop: &Notify) -> Option<Message> {
    loop {
        let message = tokio::select! {
            _ = stop.notified() => return None,
            m = timeout(idle, stream.next()) => m,
        };
        match message {
            Ok(Some(Ok(m @ (Message::Text(_) | Message::Binary(_))))) => return Some(m),
            Ok(Some(Ok(Message::Close(_)))) => return None,
            Ok(Some(Ok(_))) => continue, // a ping, or an answer to ours
            _ => return None,
        }
    }
}

async fn write(mut sink: Sink, mut rx: mpsc::Receiver<Out>, ping: Duration) {
    let mut tick = tokio::time::interval_at(tokio::time::Instant::now() + ping, ping);
    loop {
        let sent = tokio::select! {
            out = rx.recv() => match out {
                Some(Out::Text(text)) => sink.send(Message::Text(text.into())).await,
                Some(Out::Binary(bytes)) => sink.send(Message::Binary(bytes)).await,
                Some(Out::Close) | None => break,
            },
            _ = tick.tick() => sink.send(Message::Ping(Bytes::new())).await,
        };
        if sent.is_err() {
            return;
        }
    }
    let _ = sink.send(Message::Close(None)).await;
    let _ = sink.close().await;
}

/// Serves plain WebSocket, for a host that adds TLS in front.
pub async fn serve(listener: tokio::net::TcpListener, relay: Arc<Relay>) -> std::io::Result<()> {
    axum::serve(listener, relay.router().into_make_service_with_connect_info::<SocketAddr>()).await
}

/// What goes in an invite's `relay_pin`: SHA-256 of the first certificate in a PEM file, base64 for URLs.
pub fn certificate_pin(pem: &str) -> Option<String> {
    let body: String = pem
        .lines()
        .skip_while(|l| !l.starts_with("-----BEGIN CERTIFICATE"))
        .skip(1)
        .take_while(|l| !l.starts_with("-----END"))
        .map(str::trim)
        .collect();
    let der = base64::engine::general_purpose::STANDARD
        .decode(body)
        .ok()
        .filter(|d| !d.is_empty())?;
    Some(URL_SAFE_NO_PAD.encode(sha256(&der)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn squad_ids_are_uuids_in_lower_case() {
        assert_eq!(
            squad_id("0B7E6A52-9C1D-4F3A-8E2B-5D6F7A8B9C0D").as_deref(),
            Some("0b7e6a52-9c1d-4f3a-8e2b-5d6f7a8b9c0d")
        );
        assert_eq!(squad_id("not a squad"), None);
        assert_eq!(squad_id("0B7E6A52-9C1D-4F3A-8E2B-5D6F7A8B9C0D0"), None);
        assert_eq!(squad_id("0B7E6A52x9C1D-4F3A-8E2B-5D6F7A8B9C0D"), None);
    }

    #[test]
    fn the_store_has_no_place_for_names_or_positions() {
        let store = Store::open(":memory:").unwrap();
        let schema = store.dump().to_lowercase();
        for word in ["name", "lat", "lon", "position", "member"] {
            assert!(!schema.contains(word), "the schema mentions {word}");
        }
    }

    #[test]
    fn failures_block_an_address_until_the_window_passes() {
        let relay = Relay::new(Config {
            db: ":memory:".into(),
            max_failures: 3,
            failure_window: Duration::from_millis(50),
            ..Config::default()
        })
        .unwrap();
        let ip: IpAddr = "192.0.2.1".parse().unwrap();
        let other: IpAddr = "192.0.2.2".parse().unwrap();
        assert!(!relay.blocked(ip));
        relay.failed(ip);
        relay.failed(ip);
        assert!(!relay.blocked(ip));
        relay.failed(ip);
        assert!(relay.blocked(ip));
        assert!(!relay.blocked(other));
        std::thread::sleep(Duration::from_millis(60));
        assert!(!relay.blocked(ip));
    }
}
