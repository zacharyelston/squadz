use std::net::SocketAddr;
use std::time::Duration;

use squadz_relay::{certificate_pin, own_certificate, serve, Config, Relay};

const USAGE: &str = "squadz-relay: carries a squad's links over the internet.

Settings come from the environment:
  RELAY_LISTEN       address to listen on (default 0.0.0.0:8443)
  RELAY_DB           SQLite file (default relay.db)
  RELAY_TLS_CERT     certificate chain, PEM. With RELAY_TLS_KEY, the relay serves TLS itself.
  RELAY_TLS_KEY      private key, PEM
  RELAY_TLS_DIR      instead of the two above: a folder the relay keeps a certificate of its own
                     making in (cert.pem, key.pem), made on first start and never replaced.
                     For a mesh node or a machine reached by address
  RELAY_TLS_HOSTS    names and addresses for that certificate, separated by commas
  RELAY_WEB_ORIGIN   the one web page that may connect from a browser, like https://app.example
  RELAY_TRUST_PROXY  1 when a proxy in front sets X-Forwarded-For

`squadz-relay pin <cert.pem>` prints the fingerprint to give the app for that certificate.

Without a certificate it serves plain WebSocket, for a host that adds TLS in front. Phones only
connect over TLS.";

fn var(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if let [command, file] = args.as_slice() {
        if command == "pin" {
            // What to give the app, without digging through a log for it.
            let pin = certificate_pin(&std::fs::read_to_string(file)?).ok_or("that file holds no certificate")?;
            println!("{pin}");
            return Ok(());
        }
    }
    if !args.is_empty() {
        println!("{USAGE}");
        return Ok(());
    }
    let listen: SocketAddr = var("RELAY_LISTEN").unwrap_or_else(|| "0.0.0.0:8443".into()).parse()?;
    let cfg = Config {
        db: var("RELAY_DB").unwrap_or_else(|| "relay.db".into()),
        web_origin: var("RELAY_WEB_ORIGIN"),
        trust_proxy: var("RELAY_TRUST_PROXY").is_some_and(|v| v == "1"),
        ..Config::default()
    };
    let relay = Relay::new(cfg)?;

    let sweeper = relay.clone();
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(3600));
        loop {
            tick.tick().await;
            sweeper.sweep();
        }
    });

    let files = match (var("RELAY_TLS_CERT"), var("RELAY_TLS_KEY"), var("RELAY_TLS_DIR")) {
        (None, None, Some(dir)) => {
            let hosts: Vec<String> = var("RELAY_TLS_HOSTS")
                .map(|h| h.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect())
                .unwrap_or_default();
            let (cert, key) = own_certificate(std::path::Path::new(&dir), &hosts)?;
            (Some(cert.to_string_lossy().into_owned()), Some(key.to_string_lossy().into_owned()))
        }
        (_, _, Some(_)) => return Err("set RELAY_TLS_DIR, or RELAY_TLS_CERT and RELAY_TLS_KEY, not both".into()),
        (cert, key, None) => (cert, key),
    };
    match files {
        (Some(cert), Some(key)) => {
            let _ = rustls::crypto::ring::default_provider().install_default();
            let pin = certificate_pin(&std::fs::read_to_string(&cert)?).ok_or("RELAY_TLS_CERT holds no certificate")?;
            let tls = axum_server::tls_rustls::RustlsConfig::from_pem_file(&cert, &key).await?;
            let listener = std::net::TcpListener::bind(listen)?;
            listener.set_nonblocking(true)?;
            println!("listening on {} with TLS", listener.local_addr()?);
            println!("relay_pin {pin}");
            axum_server::from_tcp_rustls(listener, tls)
                .serve(relay.router().into_make_service_with_connect_info::<SocketAddr>())
                .await?;
        }
        (None, None) => {
            let listener = tokio::net::TcpListener::bind(listen).await?;
            println!("listening on {} without TLS: put a TLS proxy in front", listener.local_addr()?);
            serve(listener, relay).await?;
        }
        _ => return Err("set both RELAY_TLS_CERT and RELAY_TLS_KEY, or neither".into()),
    }
    Ok(())
}
