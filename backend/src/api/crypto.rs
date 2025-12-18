//! Crypto test endpoints for omni-core-lite validation
//!
//! Uses AES-256-GCM which is compatible with WebCrypto API

use axum::{
    http::StatusCode,
    Json,
};
use base64::Engine;
use serde::{Deserialize, Serialize};

/// Shared secret for demo (in production, use proper key exchange)
const DEMO_SECRET: &[u8; 32] = b"omni-core-lite-demo-key-32bytes!";

/// Request with encrypted payload
#[derive(Debug, Deserialize)]
pub struct EncryptedRequest {
    /// Base64-encoded nonce (12 bytes for AES-GCM)
    pub nonce: String,
    /// Base64-encoded ciphertext
    pub ciphertext: String,
}

/// Response with encrypted payload
#[derive(Debug, Serialize)]
pub struct EncryptedResponse {
    /// Base64-encoded nonce
    pub nonce: String,
    /// Base64-encoded ciphertext
    pub ciphertext: String,
    /// Plaintext echo (for debugging - remove in production)
    pub debug_plaintext: Option<String>,
}

/// Health check for crypto endpoint
#[derive(Debug, Serialize)]
pub struct CryptoHealthResponse {
    pub status: String,
    pub algorithm: String,
    pub key_hint: String,
}

/// GET /api/v1/crypto/health - Check crypto endpoint availability
pub async fn crypto_health() -> Json<CryptoHealthResponse> {
    Json(CryptoHealthResponse {
        status: "ok".to_string(),
        algorithm: "AES-256-GCM".to_string(),
        key_hint: "omni-core-lite-demo-key-32bytes!".to_string(),
    })
}

/// POST /api/v1/crypto/echo - Decrypt, echo back encrypted
pub async fn crypto_echo(
    Json(req): Json<EncryptedRequest>,
) -> Result<Json<EncryptedResponse>, (StatusCode, String)> {
    use aes_gcm::{
        aead::{Aead, KeyInit},
        Aes256Gcm, Nonce,
    };

    let b64 = base64::engine::general_purpose::STANDARD;

    // Decode nonce
    let nonce_bytes: [u8; 12] = b64
        .decode(&req.nonce)
        .map_err(|e| (StatusCode::BAD_REQUEST, format!("Invalid nonce: {}", e)))?
        .try_into()
        .map_err(|_| (StatusCode::BAD_REQUEST, "Nonce must be 12 bytes".to_string()))?;

    // Decode ciphertext
    let ciphertext = b64
        .decode(&req.ciphertext)
        .map_err(|e| (StatusCode::BAD_REQUEST, format!("Invalid ciphertext: {}", e)))?;

    // Decrypt
    let cipher = Aes256Gcm::new_from_slice(DEMO_SECRET)
        .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, "Invalid key".to_string()))?;
    
    let nonce = Nonce::from_slice(&nonce_bytes);
    let plaintext = cipher
        .decrypt(nonce, ciphertext.as_ref())
        .map_err(|_| (StatusCode::BAD_REQUEST, "Decryption failed".to_string()))?;

    let plaintext_str = String::from_utf8_lossy(&plaintext).to_string();

    // Re-encrypt with new nonce
    let mut new_nonce_bytes = [0u8; 12];
    getrandom::getrandom(&mut new_nonce_bytes).unwrap();
    let new_nonce = Nonce::from_slice(&new_nonce_bytes);

    let response_plaintext = format!("Echo: {}", plaintext_str);
    let new_ciphertext = cipher
        .encrypt(new_nonce, response_plaintext.as_bytes())
        .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, "Encryption failed".to_string()))?;

    Ok(Json(EncryptedResponse {
        nonce: b64.encode(new_nonce_bytes),
        ciphertext: b64.encode(new_ciphertext),
        debug_plaintext: Some(response_plaintext),
    }))
}

/// POST /api/v1/crypto/encrypt - Encrypt plaintext (for testing)
#[derive(Debug, Deserialize)]
pub struct EncryptRequest {
    pub plaintext: String,
}

pub async fn crypto_encrypt(
    Json(req): Json<EncryptRequest>,
) -> Result<Json<EncryptedResponse>, (StatusCode, String)> {
    use aes_gcm::{
        aead::{Aead, KeyInit},
        Aes256Gcm, Nonce,
    };

    let b64 = base64::engine::general_purpose::STANDARD;

    let cipher = Aes256Gcm::new_from_slice(DEMO_SECRET)
        .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, "Invalid key".to_string()))?;

    let mut nonce_bytes = [0u8; 12];
    getrandom::getrandom(&mut nonce_bytes).unwrap();
    let nonce = Nonce::from_slice(&nonce_bytes);

    let ciphertext = cipher
        .encrypt(nonce, req.plaintext.as_bytes())
        .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, "Encryption failed".to_string()))?;

    Ok(Json(EncryptedResponse {
        nonce: b64.encode(nonce_bytes),
        ciphertext: b64.encode(ciphertext),
        debug_plaintext: Some(req.plaintext),
    }))
}

/// POST /api/v1/crypto/decrypt - Decrypt ciphertext (for testing)
pub async fn crypto_decrypt(
    Json(req): Json<EncryptedRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, String)> {
    use aes_gcm::{
        aead::{Aead, KeyInit},
        Aes256Gcm, Nonce,
    };

    let b64 = base64::engine::general_purpose::STANDARD;

    let nonce_bytes: [u8; 12] = b64
        .decode(&req.nonce)
        .map_err(|e| (StatusCode::BAD_REQUEST, format!("Invalid nonce: {}", e)))?
        .try_into()
        .map_err(|_| (StatusCode::BAD_REQUEST, "Nonce must be 12 bytes".to_string()))?;

    let ciphertext = b64
        .decode(&req.ciphertext)
        .map_err(|e| (StatusCode::BAD_REQUEST, format!("Invalid ciphertext: {}", e)))?;

    let cipher = Aes256Gcm::new_from_slice(DEMO_SECRET)
        .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, "Invalid key".to_string()))?;
    
    let nonce = Nonce::from_slice(&nonce_bytes);
    let plaintext = cipher
        .decrypt(nonce, ciphertext.as_ref())
        .map_err(|_| (StatusCode::BAD_REQUEST, "Decryption failed".to_string()))?;

    let plaintext_str = String::from_utf8_lossy(&plaintext).to_string();

    Ok(Json(serde_json::json!({
        "plaintext": plaintext_str
    })))
}
