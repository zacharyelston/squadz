//! Authentication middleware for Squadz
//! Based on omni-core auth patterns

use axum::{
    body::Body,
    extract::State,
    http::{Request, StatusCode},
    middleware::Next,
    response::Response,
};
use std::sync::Arc;

use crate::AppState;
use super::session::MemberSession;

/// Extension to store validated session in request
#[derive(Clone)]
pub struct AuthenticatedMember {
    pub session: MemberSession,
}

/// Extract API key from Authorization header
fn extract_api_key(request: &Request<Body>) -> Option<String> {
    request
        .headers()
        .get("Authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(|s| s.to_string())
}

/// Auth middleware - validates API key and adds session to request extensions
pub async fn auth_middleware(
    State(state): State<Arc<AppState>>,
    mut request: Request<Body>,
    next: Next,
) -> Result<Response, StatusCode> {
    let api_key = extract_api_key(&request).ok_or(StatusCode::UNAUTHORIZED)?;

    let session = state
        .session_store
        .validate(&api_key)
        .ok_or(StatusCode::UNAUTHORIZED)?;

    // Add authenticated member to request extensions
    request.extensions_mut().insert(AuthenticatedMember { session });

    Ok(next.run(request).await)
}

/// Optional auth - doesn't fail if no auth, just doesn't add session
pub async fn optional_auth_middleware(
    State(state): State<Arc<AppState>>,
    mut request: Request<Body>,
    next: Next,
) -> Response {
    if let Some(api_key) = extract_api_key(&request) {
        if let Some(session) = state.session_store.validate(&api_key) {
            request.extensions_mut().insert(AuthenticatedMember { session });
        }
    }

    next.run(request).await
}
