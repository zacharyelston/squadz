//! The relay from the outside: real sockets, one relay per test.

use std::net::SocketAddr;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use squadz_relay::{now, serve, Config, Relay};
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{connect_async, MaybeTlsStream, WebSocketStream};

const SQUAD: &str = "0b7e6a52-9c1d-4f3a-8e2b-5d6f7a8b9c0d";
/// An invite's relay key, as a device presents it (base64 for URLs), and the bytes it stands for.
const KEY: &str = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";

fn key_hash() -> String {
    let bytes: Vec<u8> = (0u8..32).collect();
    Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

async fn relay(cfg: Config) -> SocketAddr {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let relay = Relay::new(cfg).unwrap();
    tokio::spawn(async move { serve(listener, relay).await.unwrap() });
    addr
}

fn memory() -> Config {
    Config {
        db: ":memory:".into(),
        ..Config::default()
    }
}

struct Socket(WebSocketStream<MaybeTlsStream<TcpStream>>);

enum Got {
    Text(Value),
    Binary(Vec<u8>),
    Closed,
}

impl Socket {
    async fn open(addr: SocketAddr) -> Socket {
        Socket(connect_async(format!("ws://{addr}/v1/link")).await.unwrap().0)
    }

    async fn hello(addr: SocketAddr, hello: Value) -> Socket {
        let mut s = Socket::open(addr).await;
        s.say(hello).await;
        s
    }

    async fn say(&mut self, v: Value) {
        self.0.send(Message::Text(v.to_string().into())).await.unwrap();
    }

    async fn bytes(&mut self, b: &[u8]) {
        self.0.send(Message::Binary(b.to_vec().into())).await.unwrap();
    }

    async fn got(&mut self) -> Got {
        loop {
            let next = tokio::time::timeout(Duration::from_secs(5), self.0.next())
                .await
                .expect("the relay said nothing");
            match next {
                Some(Ok(Message::Text(t))) => return Got::Text(serde_json::from_str(t.as_str()).unwrap()),
                Some(Ok(Message::Binary(b))) => return Got::Binary(b.to_vec()),
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => return Got::Closed,
                Some(Ok(_)) => continue,
            }
        }
    }

    async fn text(&mut self) -> Value {
        match self.got().await {
            Got::Text(v) => v,
            Got::Binary(b) => panic!("expected text, got {} bytes", b.len()),
            Got::Closed => panic!("expected text, but the relay closed the socket"),
        }
    }

    async fn binary(&mut self) -> Vec<u8> {
        match self.got().await {
            Got::Binary(b) => b,
            Got::Text(v) => panic!("expected bytes, got {v}"),
            Got::Closed => panic!("expected bytes, but the relay closed the socket"),
        }
    }

    async fn closed(&mut self) {
        match self.got().await {
            Got::Closed => {}
            Got::Text(v) => panic!("expected the socket to close, got {v}"),
            Got::Binary(b) => panic!("expected the socket to close, got {} bytes", b.len()),
        }
    }
}

/// A leader with a room and one open invite. Returns its socket and its token.
async fn leader(addr: SocketAddr) -> (Socket, String) {
    let mut s = Socket::hello(addr, json!({"t": "create", "squad": SQUAD})).await;
    let created = s.text().await;
    assert_eq!(created["t"], "created");
    s.say(json!({"t": "invites", "list": [{"hash": key_hash(), "exp": now() + 900}]}))
        .await;
    (s, created["token"].as_str().unwrap().to_string())
}

/// Joins with the invite, retrying while the leader's `invites` message is still on its way.
async fn join(addr: SocketAddr) -> (String, String) {
    for _ in 0..50 {
        let mut s = Socket::hello(addr, json!({"t": "join", "squad": SQUAD, "key": KEY})).await;
        let answer = s.text().await;
        if answer["t"] == "joined" {
            s.closed().await;
            return (answer["device"].as_str().unwrap().into(), answer["token"].as_str().unwrap().into());
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("the invite never opened");
}

fn framed(conn: u64, bytes: &[u8]) -> Vec<u8> {
    let mut out = (conn as u32).to_be_bytes().to_vec();
    out.extend_from_slice(bytes);
    out
}

#[tokio::test]
async fn bytes_pass_between_a_member_and_the_leader() {
    let addr = relay(memory()).await;
    let (mut lead, _) = leader(addr).await;
    let (device, token) = join(addr).await;

    let mut member = Socket::hello(addr, json!({"t": "member", "squad": SQUAD, "token": token})).await;
    let open = lead.text().await;
    assert_eq!(open["t"], "open");
    assert_eq!(open["device"], device.as_str());
    let conn = open["conn"].as_u64().unwrap();
    let told = member.text().await;
    assert_eq!(told["t"], "open");
    // Both ends get the same value to tie their proof to.
    assert_eq!(told["nonce"], open["nonce"]);
    assert_eq!(told["nonce"].as_str().unwrap().len(), 43);

    member.bytes(b"from the member").await;
    assert_eq!(lead.binary().await, framed(conn, b"from the member"));
    lead.bytes(&framed(conn, b"from the leader")).await;
    assert_eq!(member.binary().await, b"from the leader");

    // Bytes for a link that doesn't exist go nowhere.
    lead.bytes(&framed(conn + 7, b"to nobody")).await;

    // A second device gets its own link.
    let (_, token2) = join(addr).await;
    let mut second = Socket::hello(addr, json!({"t": "member", "squad": SQUAD, "token": token2})).await;
    let open2 = lead.text().await;
    let conn2 = open2["conn"].as_u64().unwrap();
    assert_ne!(conn2, conn);
    assert_ne!(open2["nonce"], open["nonce"]);
    second.text().await;
    lead.bytes(&framed(conn2, b"only the second")).await;
    assert_eq!(second.binary().await, b"only the second");

    // The member leaves: the leader hears.
    drop(member);
    assert_eq!(lead.text().await, json!({"t": "closed", "conn": conn}));

    // The leader closes a link, saying it won't have the device: the device hears that, then the close.
    lead.say(json!({"t": "close", "conn": conn2, "refused": true})).await;
    assert_eq!(second.text().await, json!({"t": "refused"}));
    second.closed().await;
}

#[tokio::test]
async fn joining_takes_the_invites_key_and_every_failure_looks_the_same() {
    let addr = relay(memory()).await;
    let (mut lead, _) = leader(addr).await;
    join(addr).await;

    let wrong = "ZZECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
    let other_squad = "11111111-2222-3333-4444-555555555555";
    for hello in [
        json!({"t": "join", "squad": SQUAD, "key": wrong}),
        json!({"t": "join", "squad": other_squad, "key": KEY}),
        json!({"t": "join", "squad": "nonsense", "key": KEY}),
        json!({"t": "join", "squad": SQUAD, "key": "short"}),
    ] {
        let mut s = Socket::hello(addr, hello).await;
        assert_eq!(s.text().await, json!({"t": "refused"}));
        s.closed().await;
    }

    // An invite past its time is the same as no invite.
    lead.say(json!({"t": "invites", "list": [{"hash": key_hash(), "exp": now() - 1}]}))
        .await;
    // And so is one the leader has closed.
    for _ in 0..50 {
        let mut s = Socket::hello(addr, json!({"t": "join", "squad": SQUAD, "key": KEY})).await;
        if s.text().await == json!({"t": "refused"}) {
            lead.say(json!({"t": "invites", "list": []})).await;
            let mut s = Socket::hello(addr, json!({"t": "join", "squad": SQUAD, "key": KEY})).await;
            assert_eq!(s.text().await, json!({"t": "refused"}));
            return;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("an expired invite still let a device in");
}

#[tokio::test]
async fn an_address_that_keeps_guessing_is_turned_away() {
    let addr = relay(Config {
        max_failures: 3,
        ..memory()
    })
    .await;
    let (_lead, _) = leader(addr).await;
    let (_, token) = join(addr).await;
    let wrong = "ZZECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
    for _ in 0..3 {
        let mut s = Socket::hello(addr, json!({"t": "join", "squad": SQUAD, "key": wrong})).await;
        assert_eq!(s.text().await, json!({"t": "refused"}));
    }
    // Now even the right key is turned away, and so is a good token: the address is the problem.
    let mut s = Socket::hello(addr, json!({"t": "join", "squad": SQUAD, "key": KEY})).await;
    assert_eq!(s.text().await, json!({"t": "refused", "why": "slow"}));
    let mut s = Socket::hello(addr, json!({"t": "member", "squad": SQUAD, "token": token})).await;
    assert_eq!(s.text().await, json!({"t": "refused", "why": "slow"}));
}

#[tokio::test]
async fn tokens_open_only_their_own_room() {
    let addr = relay(memory()).await;
    let (lead, leader_token) = leader(addr).await;
    let (_, token) = join(addr).await;

    // A second room for the same squad can't be made, with the leader connected or not.
    let mut s = Socket::hello(addr, json!({"t": "create", "squad": SQUAD})).await;
    assert_eq!(s.text().await, json!({"t": "refused"}));

    // A member's token doesn't lead, and the leader's token isn't a member's.
    let mut s = Socket::hello(addr, json!({"t": "lead", "squad": SQUAD, "token": token})).await;
    assert_eq!(s.text().await, json!({"t": "refused"}));
    let mut s = Socket::hello(addr, json!({"t": "member", "squad": SQUAD, "token": leader_token})).await;
    assert_eq!(s.text().await, json!({"t": "refused"}));
    // A token is for one squad.
    let mut s = Socket::hello(
        addr,
        json!({"t": "member", "squad": "11111111-2222-3333-4444-555555555555", "token": token}),
    )
    .await;
    assert_eq!(s.text().await, json!({"t": "refused"}));

    // With the leader gone, a member is told to try later.
    drop(lead);
    for _ in 0..50 {
        let mut s = Socket::hello(addr, json!({"t": "member", "squad": SQUAD, "token": token})).await;
        match s.text().await {
            v if v == json!({"t": "away"}) => {
                s.closed().await;
                return;
            }
            _ => tokio::time::sleep(Duration::from_millis(20)).await,
        }
    }
    panic!("a member got a link with no leader connected");
}

#[tokio::test]
async fn a_leader_that_comes_back_replaces_its_old_connection() {
    let addr = relay(memory()).await;
    let (mut old, leader_token) = leader(addr).await;
    let (_, token) = join(addr).await;
    let mut member = Socket::hello(addr, json!({"t": "member", "squad": SQUAD, "token": token})).await;
    old.text().await;
    member.text().await;

    let mut new = Socket::hello(addr, json!({"t": "lead", "squad": SQUAD, "token": leader_token})).await;
    assert_eq!(new.text().await, json!({"t": "ok"}));
    // The old connection and its links close; the member connects again, to the new one.
    old.closed().await;
    member.closed().await;
    let mut member = Socket::hello(addr, json!({"t": "member", "squad": SQUAD, "token": token})).await;
    let open = new.text().await;
    assert_eq!(open["t"], "open");
    member.text().await;
    member.bytes(b"hello again").await;
    assert_eq!(new.binary().await, framed(open["conn"].as_u64().unwrap(), b"hello again"));
}

#[tokio::test]
async fn a_revoked_device_and_an_ended_squad_are_gone() {
    let addr = relay(memory()).await;
    let (mut lead, leader_token) = leader(addr).await;
    let (device, token) = join(addr).await;
    let (_, token2) = join(addr).await;
    let mut member = Socket::hello(addr, json!({"t": "member", "squad": SQUAD, "token": token})).await;
    lead.text().await;
    member.text().await;

    lead.say(json!({"t": "revoke", "device": device})).await;
    assert_eq!(member.text().await, json!({"t": "refused"}));
    member.closed().await;
    let mut s = Socket::hello(addr, json!({"t": "member", "squad": SQUAD, "token": token})).await;
    assert_eq!(s.text().await, json!({"t": "refused"}));
    // The other device is untouched.
    let mut other = Socket::hello(addr, json!({"t": "member", "squad": SQUAD, "token": token2})).await;
    assert_eq!(other.text().await["t"], "open");
    assert_eq!(lead.text().await["t"], "open");

    lead.say(json!({"t": "end"})).await;
    lead.closed().await;
    other.closed().await;
    let mut s = Socket::hello(addr, json!({"t": "lead", "squad": SQUAD, "token": leader_token})).await;
    assert_eq!(s.text().await, json!({"t": "refused"}));
    let mut s = Socket::hello(addr, json!({"t": "member", "squad": SQUAD, "token": token2})).await;
    assert_eq!(s.text().await, json!({"t": "refused"}));
}

#[tokio::test]
async fn rooms_and_tokens_outlive_a_restart() {
    let file = std::env::temp_dir().join(format!("squadz-relay-test-{}.db", std::process::id()));
    let db = file.to_str().unwrap().to_string();
    let _ = std::fs::remove_file(&file);

    let first = relay(Config {
        db: db.clone(),
        ..Config::default()
    })
    .await;
    let (lead, leader_token) = leader(first).await;
    let (_, token) = join(first).await;
    drop(lead);

    // A second relay on the same file stands in for the first one, restarted.
    let second = relay(Config {
        db: db.clone(),
        ..Config::default()
    })
    .await;
    let mut lead = Socket::hello(second, json!({"t": "lead", "squad": SQUAD, "token": leader_token})).await;
    assert_eq!(lead.text().await, json!({"t": "ok"}));
    let mut member = Socket::hello(second, json!({"t": "member", "squad": SQUAD, "token": token})).await;
    assert_eq!(member.text().await["t"], "open");

    // The file holds no secret a device presents: only hashes.
    drop((lead, member));
    let bytes = std::fs::read(&file).unwrap();
    let text = String::from_utf8_lossy(&bytes);
    for secret in [leader_token.as_str(), token.as_str(), KEY] {
        assert!(!text.contains(secret));
    }
    for ext in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{db}{ext}"));
    }
}

#[tokio::test]
async fn only_the_web_clients_page_may_connect_from_a_browser() {
    async fn status(addr: SocketAddr, origin: Option<&str>) -> Result<(), String> {
        let mut request = format!("ws://{addr}/v1/link").into_client_request().unwrap();
        if let Some(origin) = origin {
            request.headers_mut().insert("origin", origin.parse().unwrap());
        }
        connect_async(request).await.map(|_| ()).map_err(|e| e.to_string())
    }

    let closed = relay(memory()).await;
    assert!(status(closed, None).await.is_ok());
    assert!(status(closed, Some("https://anything.example")).await.unwrap_err().contains("403"));

    let open = relay(Config {
        web_origin: Some("https://app.example".into()),
        ..memory()
    })
    .await;
    assert!(status(open, None).await.is_ok());
    assert!(status(open, Some("https://app.example")).await.is_ok());
    assert!(status(open, Some("https://evil.example")).await.unwrap_err().contains("403"));
}

#[tokio::test]
async fn a_socket_that_never_says_who_it_is_gets_nothing() {
    let addr = relay(memory()).await;
    let mut s = Socket::hello(addr, json!({"t": "positions", "squad": SQUAD})).await;
    s.closed().await;
    let mut s = Socket::open(addr).await;
    s.bytes(b"\x00\x00\x00\x01hello").await;
    s.closed().await;
}
