//! Configuration for Squadz server

use std::env;
use std::path::PathBuf;

#[derive(Debug, Clone)]
pub struct Config {
    pub host: String,
    pub port: u16,
    pub location_ttl_secs: u64,
    pub max_squad_size: usize,
    /// HTTPS listener port. Unset = HTTP only.
    pub tls_port: Option<u16>,
    /// PEM certificate path. Generated (self-signed) if the file is missing.
    pub tls_cert: PathBuf,
    /// PEM private key path. Generated alongside the certificate if missing.
    pub tls_key: PathBuf,
    /// DNS names / IP addresses to put in a generated certificate.
    pub tls_hosts: Vec<String>,
    /// Directory of pre-downloaded map tiles laid out as `{z}/{x}/{y}.png`.
    pub tiles_dir: Option<PathBuf>,
    /// Tile URL template for the mobile page. `none` disables the basemap.
    pub tile_url: Option<String>,
    pub tile_attribution: Option<String>,
    /// Deepest zoom level present in `tiles_dir`; deeper zooms upscale it.
    pub tile_max_native_zoom: Option<u8>,
}

fn var(name: &str) -> Option<String> {
    env::var(name).ok().filter(|v| !v.trim().is_empty())
}

impl Config {
    pub fn from_env() -> Self {
        Self {
            host: var("HOST").unwrap_or_else(|| "0.0.0.0".to_string()),
            port: var("PORT").and_then(|p| p.parse().ok()).unwrap_or(8080),
            location_ttl_secs: var("LOCATION_TTL_SECS")
                .and_then(|t| t.parse().ok())
                .unwrap_or(300), // 5 minutes default
            max_squad_size: var("MAX_SQUAD_SIZE")
                .and_then(|s| s.parse().ok())
                .unwrap_or(50),
            tls_port: var("TLS_PORT").and_then(|p| p.parse().ok()),
            tls_cert: var("TLS_CERT")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("tls/cert.pem")),
            tls_key: var("TLS_KEY")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("tls/key.pem")),
            tls_hosts: var("TLS_HOSTS")
                .map(|h| {
                    h.split(',')
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                        .collect()
                })
                .unwrap_or_else(|| vec!["localhost".to_string(), "127.0.0.1".to_string()]),
            tiles_dir: var("TILES_DIR").map(PathBuf::from),
            tile_url: var("TILE_URL"),
            tile_attribution: var("TILE_ATTRIBUTION"),
            tile_max_native_zoom: var("TILE_MAX_NATIVE_ZOOM").and_then(|z| z.parse().ok()),
        }
    }
}
