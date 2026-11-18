//! QR codes for squad invite links
//!
//! Rendered on the server so the mobile page needs no QR library and works
//! with no internet access.

use axum::{
    extract::Query,
    http::{header, StatusCode},
    response::{IntoResponse, Response},
};
use qrcode::{render::svg, EcLevel, QrCode};
use serde::Deserialize;

/// Longest link we will encode. Invite links are well under 200 characters;
/// the cap keeps this from being a general-purpose QR service.
const MAX_DATA_LEN: usize = 512;

#[derive(Debug, Deserialize)]
pub struct QrQuery {
    pub data: String,
}

/// Render an http(s) link as an SVG QR code.
pub async fn qr_svg(Query(q): Query<QrQuery>) -> Result<Response, (StatusCode, String)> {
    let data = q.data.trim();
    let is_link = data.starts_with("https://") || data.starts_with("http://");
    if !is_link || data.len() > MAX_DATA_LEN || data.chars().any(|c| c.is_control()) {
        return Err((
            StatusCode::BAD_REQUEST,
            format!("data must be an http(s) link of at most {MAX_DATA_LEN} characters"),
        ));
    }

    let code = QrCode::with_error_correction_level(data.as_bytes(), EcLevel::M)
        .map_err(|e| (StatusCode::BAD_REQUEST, e.to_string()))?;
    let image = code
        .render::<svg::Color>()
        .min_dimensions(240, 240)
        .quiet_zone(true)
        .dark_color(svg::Color("#000000"))
        .light_color(svg::Color("#ffffff"))
        .build();

    Ok((
        [
            (header::CONTENT_TYPE, "image/svg+xml"),
            (header::CACHE_CONTROL, "private, max-age=3600"),
        ],
        image,
    )
        .into_response())
}
