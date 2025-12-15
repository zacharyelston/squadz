//! Authentication service using omni-core crypto and sessions.

use omni_core::{ServerKeyPair, SessionStore, EncryptedMessage, CryptoError};
use std::sync::Arc;

/// Authentication manager using omni-core components
pub struct AuthManager {
    /// Server keypair for encryption
    keypair: Arc<ServerKeyPair>,
    /// Session store for managing authenticated sessions
    sessions: SessionStore,
}

impl AuthManager {
    /// Create a new auth manager
    pub fn new() -> Self {
        Self {
            keypair: Arc::new(ServerKeyPair::generate()),
            sessions: SessionStore::with_ttl(86400), // 24 hour sessions
        }
    }

    /// Get server's public key (for clients to encrypt messages)
    pub fn public_key(&self) -> String {
        self.keypair.public_key_hex()
    }

    /// Create a session for a member
    pub fn create_session(&self, member_id: &str) -> String {
        let session = self.sessions.create(member_id);
        session.session_id
    }

    /// Validate a session
    pub fn validate_session(&self, session_id: &str) -> Option<String> {
        self.sessions.validate(session_id).map(|s| s.client_id)
    }

    /// Revoke a session
    pub fn revoke_session(&self, session_id: &str) -> bool {
        self.sessions.revoke(session_id)
    }

    /// Encrypt a message for a client (using their public key)
    pub fn encrypt_for_client(
        &self,
        plaintext: &[u8],
        client_public_key: &str,
    ) -> Result<EncryptedMessage, CryptoError> {
        let shared_secret = self.keypair.derive_shared_secret_hex(client_public_key)?;
        EncryptedMessage::encrypt(plaintext, &shared_secret)
    }

    /// Decrypt a message from a client
    pub fn decrypt_from_client(
        &self,
        message: &EncryptedMessage,
        client_public_key: &str,
    ) -> Result<Vec<u8>, CryptoError> {
        let shared_secret = self.keypair.derive_shared_secret_hex(client_public_key)?;
        message.decrypt(&shared_secret)
    }
}

impl Default for AuthManager {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use omni_core::ClientKeyPair;

    #[test]
    fn test_session_lifecycle() {
        let auth = AuthManager::new();
        
        // Create session
        let session_id = auth.create_session("member-123");
        
        // Validate
        let member_id = auth.validate_session(&session_id);
        assert_eq!(member_id, Some("member-123".to_string()));
        
        // Revoke
        assert!(auth.revoke_session(&session_id));
        assert!(auth.validate_session(&session_id).is_none());
    }

    #[test]
    fn test_encryption() {
        let auth = AuthManager::new();
        let client = ClientKeyPair::generate();
        
        let plaintext = b"Secret location data";
        let encrypted = auth.encrypt_for_client(plaintext, &client.public_key_hex()).unwrap();
        let decrypted = auth.decrypt_from_client(&encrypted, &client.public_key_hex()).unwrap();
        
        assert_eq!(plaintext.to_vec(), decrypted);
    }
}
