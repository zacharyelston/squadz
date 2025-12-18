//! Session management for Squadz
//! Based on omni-core session patterns

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use uuid::Uuid;

/// A member session tied to a squad
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MemberSession {
    pub session_id: Uuid,
    pub member_id: Uuid,
    pub squad_id: Uuid,
    pub api_key: String,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    pub last_seen: DateTime<Utc>,
}

impl MemberSession {
    pub fn new(member_id: Uuid, squad_id: Uuid, ttl_secs: u64) -> Self {
        let now = Utc::now();
        let api_key = generate_api_key();
        Self {
            session_id: Uuid::new_v4(),
            member_id,
            squad_id,
            api_key,
            created_at: now,
            expires_at: now + chrono::Duration::seconds(ttl_secs as i64),
            last_seen: now,
        }
    }

    pub fn is_expired(&self) -> bool {
        Utc::now() > self.expires_at
    }

    pub fn touch(&mut self) {
        self.last_seen = Utc::now();
    }
}

fn generate_api_key() -> String {
    use base64::Engine;
    use rand::RngCore;

    let mut bytes = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut bytes);
    format!(
        "sqz_{}",
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
    )
}

/// Session store for member sessions
#[derive(Clone, Default)]
pub struct SessionStore {
    /// Map from API key to session
    sessions: Arc<RwLock<HashMap<String, MemberSession>>>,
}

impl SessionStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// Create a new session for a member
    pub fn create(&self, member_id: Uuid, squad_id: Uuid, ttl_secs: u64) -> MemberSession {
        let session = MemberSession::new(member_id, squad_id, ttl_secs);
        let mut sessions = self.sessions.write().unwrap();
        sessions.insert(session.api_key.clone(), session.clone());
        session
    }

    /// Validate an API key and return the session if valid
    pub fn validate(&self, api_key: &str) -> Option<MemberSession> {
        let mut sessions = self.sessions.write().unwrap();
        if let Some(session) = sessions.get_mut(api_key) {
            if session.is_expired() {
                sessions.remove(api_key);
                return None;
            }
            session.touch();
            return Some(session.clone());
        }
        None
    }

    /// Revoke a session
    pub fn revoke(&self, api_key: &str) -> bool {
        let mut sessions = self.sessions.write().unwrap();
        sessions.remove(api_key).is_some()
    }

    /// Revoke all sessions for a member
    pub fn revoke_member(&self, member_id: &Uuid) -> usize {
        let mut sessions = self.sessions.write().unwrap();
        let before = sessions.len();
        sessions.retain(|_, s| &s.member_id != member_id);
        before - sessions.len()
    }

    /// Cleanup expired sessions
    pub fn cleanup_expired(&self) -> usize {
        let mut sessions = self.sessions.write().unwrap();
        let before = sessions.len();
        sessions.retain(|_, s| !s.is_expired());
        before - sessions.len()
    }

    /// Get session count (for metrics)
    pub fn count(&self) -> usize {
        self.sessions.read().unwrap().len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_session_creation() {
        let member_id = Uuid::new_v4();
        let squad_id = Uuid::new_v4();
        let session = MemberSession::new(member_id, squad_id, 3600);

        assert_eq!(session.member_id, member_id);
        assert_eq!(session.squad_id, squad_id);
        assert!(session.api_key.starts_with("sqz_"));
        assert!(!session.is_expired());
    }

    #[test]
    fn test_session_store_validate() {
        let store = SessionStore::new();
        let member_id = Uuid::new_v4();
        let squad_id = Uuid::new_v4();

        let session = store.create(member_id, squad_id, 3600);
        
        let validated = store.validate(&session.api_key);
        assert!(validated.is_some());
        assert_eq!(validated.unwrap().member_id, member_id);

        // Invalid key returns None
        assert!(store.validate("invalid_key").is_none());
    }

    #[test]
    fn test_session_store_revoke() {
        let store = SessionStore::new();
        let member_id = Uuid::new_v4();
        let squad_id = Uuid::new_v4();

        let session = store.create(member_id, squad_id, 3600);
        
        assert!(store.revoke(&session.api_key));
        assert!(store.validate(&session.api_key).is_none());
    }
}
