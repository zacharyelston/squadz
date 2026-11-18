//! Self-hosted mobile web app
//!
//! The mobile client and its Leaflet dependency are compiled into the binary so
//! a single `squadz-server` can serve everything a phone needs with no internet
//! access (e.g. when running on an OpenMANET mesh node).

use std::sync::Arc;

use axum::{
    extract::State,
    http::{header, HeaderValue},
    response::{IntoResponse, Response},
};
use serde_json::json;

use crate::AppState;

const MOBILE_HTML: &str = include_str!("../../../frontend/public/mobile.html");
const LEAFLET_JS: &str = include_str!("../../../frontend/public/vendor/leaflet/leaflet.js");
const LEAFLET_CSS: &str = include_str!("../../../frontend/public/vendor/leaflet/leaflet.css");
const MARKER_ICON: &[u8] =
    include_bytes!("../../../frontend/public/vendor/leaflet/images/marker-icon.png");
const MARKER_ICON_2X: &[u8] =
    include_bytes!("../../../frontend/public/vendor/leaflet/images/marker-icon-2x.png");
const MARKER_SHADOW: &[u8] =
    include_bytes!("../../../frontend/public/vendor/leaflet/images/marker-shadow.png");
const LAYERS: &[u8] = include_bytes!("../../../frontend/public/vendor/leaflet/images/layers.png");
const LAYERS_2X: &[u8] =
    include_bytes!("../../../frontend/public/vendor/leaflet/images/layers-2x.png");

fn asset(content_type: &'static str, cache: &'static str, body: impl IntoResponse) -> Response {
    let mut res = body.into_response();
    let headers = res.headers_mut();
    headers.insert(header::CONTENT_TYPE, HeaderValue::from_static(content_type));
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static(cache));
    res
}

const NO_CACHE: &str = "no-cache";
const LONG_CACHE: &str = "public, max-age=604800";

pub async fn mobile_page() -> Response {
    asset("text/html; charset=utf-8", NO_CACHE, MOBILE_HTML)
}

pub async fn leaflet_js() -> Response {
    asset("text/javascript; charset=utf-8", LONG_CACHE, LEAFLET_JS)
}

pub async fn leaflet_css() -> Response {
    asset("text/css; charset=utf-8", LONG_CACHE, LEAFLET_CSS)
}

pub async fn marker_icon() -> Response {
    asset("image/png", LONG_CACHE, MARKER_ICON)
}

pub async fn marker_icon_2x() -> Response {
    asset("image/png", LONG_CACHE, MARKER_ICON_2X)
}

pub async fn marker_shadow() -> Response {
    asset("image/png", LONG_CACHE, MARKER_SHADOW)
}

pub async fn layers() -> Response {
    asset("image/png", LONG_CACHE, LAYERS)
}

pub async fn layers_2x() -> Response {
    asset("image/png", LONG_CACHE, LAYERS_2X)
}

/// Runtime configuration for the mobile page.
///
/// Tells the page to call the API on the origin it was loaded from, and where
/// (if anywhere) to get map tiles.
pub async fn client_config(State(state): State<Arc<AppState>>) -> Response {
    let cfg = &state.config;
    let tile_url = match (&cfg.tile_url, &cfg.tiles_dir) {
        (Some(url), _) if url.eq_ignore_ascii_case("none") => None,
        (Some(url), _) => Some(url.clone()),
        (None, Some(_)) => Some("/tiles/{z}/{x}/{y}.png".to_string()),
        // No local tiles configured: fall back to the public OSM servers, which
        // simply fail to load when the network has no internet gateway.
        (None, None) => Some("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png".to_string()),
    };
    let body = json!({
        "apiBase": "",
        "tileUrl": tile_url,
        "tileAttribution": cfg.tile_attribution,
        "tileMaxNativeZoom": cfg.tile_max_native_zoom,
    });
    asset(
        "text/javascript; charset=utf-8",
        NO_CACHE,
        format!("window.SQUADZ_CONFIG = {};\n", body),
    )
}
