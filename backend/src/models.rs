//! Data models for Squadz

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Geographic coordinates
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct GeoPoint {
    pub latitude: f64,
    pub longitude: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub altitude: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accuracy: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub heading: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub speed: Option<f64>,
}

/// A squad member
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Member {
    pub member_id: Uuid,
    pub display_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub avatar_url: Option<String>,
    pub joined_at: DateTime<Utc>,
    pub is_leader: bool,
}

/// A squad (group of members sharing locations)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Squad {
    pub squad_id: Uuid,
    pub name: String,
    pub join_code: String,
    pub created_at: DateTime<Utc>,
    pub leader_id: Uuid,
    pub members: Vec<Member>,
    pub settings: SquadSettings,
}

/// Squad configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SquadSettings {
    pub is_public: bool,
    pub require_approval: bool,
    pub share_altitude: bool,
    pub share_speed: bool,
    pub location_update_interval_secs: u32,
}

impl Default for SquadSettings {
    fn default() -> Self {
        Self {
            is_public: false,
            require_approval: false,
            share_altitude: true,
            share_speed: true,
            location_update_interval_secs: 10,
        }
    }
}

/// A member's location update
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MemberLocation {
    pub member_id: Uuid,
    pub display_name: String,
    pub location: GeoPoint,
    pub updated_at: DateTime<Utc>,
    pub is_stale: bool,
}

/// Request to create a new squad
#[derive(Debug, Deserialize)]
pub struct CreateSquadRequest {
    pub name: String,
    pub leader_name: String,
    #[serde(default)]
    pub settings: Option<SquadSettings>,
}

/// Response after creating a squad
#[derive(Debug, Serialize)]
pub struct CreateSquadResponse {
    pub squad_id: Uuid,
    pub join_code: String,
    pub member_id: Uuid,
}

/// Request to join a squad
#[derive(Debug, Deserialize)]
pub struct JoinSquadRequest {
    pub join_code: String,
    pub display_name: String,
}

/// Response after joining a squad
#[derive(Debug, Serialize)]
pub struct JoinSquadResponse {
    pub member_id: Uuid,
    pub squad: Squad,
}

/// Request to update location
#[derive(Debug, Deserialize)]
pub struct UpdateLocationRequest {
    pub member_id: Uuid,
    pub squad_id: Uuid,
    pub location: GeoPoint,
}

/// Response with all squad member locations
#[derive(Debug, Serialize)]
pub struct SquadLocationsResponse {
    pub squad_id: Uuid,
    pub squad_name: String,
    pub locations: Vec<MemberLocation>,
    pub updated_at: DateTime<Utc>,
}
