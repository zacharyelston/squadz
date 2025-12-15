//! Configuration for Squadz server

use std::env;

#[derive(Debug, Clone)]
pub struct Config {
    pub host: String,
    pub port: u16,
    pub location_ttl_secs: u64,
    pub max_squad_size: usize,
}

impl Config {
    pub fn from_env() -> Self {
        Self {
            host: env::var("HOST").unwrap_or_else(|_| "0.0.0.0".to_string()),
            port: env::var("PORT")
                .ok()
                .and_then(|p| p.parse().ok())
                .unwrap_or(8080),
            location_ttl_secs: env::var("LOCATION_TTL_SECS")
                .ok()
                .and_then(|t| t.parse().ok())
                .unwrap_or(300), // 5 minutes default
            max_squad_size: env::var("MAX_SQUAD_SIZE")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(50),
        }
    }
}
