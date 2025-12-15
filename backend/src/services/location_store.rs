//! Location storage service

use std::collections::HashMap;
use chrono::{DateTime, Utc, Duration};
use uuid::Uuid;

use crate::models::{GeoPoint, MemberLocation};

/// Stores member locations with TTL
pub struct LocationStore {
    /// Map of squad_id -> (member_id -> location)
    locations: HashMap<Uuid, HashMap<Uuid, StoredLocation>>,
    /// TTL for locations in seconds
    ttl_secs: i64,
}

struct StoredLocation {
    member_id: Uuid,
    display_name: String,
    location: GeoPoint,
    updated_at: DateTime<Utc>,
}

impl LocationStore {
    pub fn new() -> Self {
        Self {
            locations: HashMap::new(),
            ttl_secs: 300, // 5 minutes default
        }
    }

    pub fn with_ttl(ttl_secs: i64) -> Self {
        Self {
            locations: HashMap::new(),
            ttl_secs,
        }
    }

    /// Update a member's location
    pub fn update_location(
        &mut self,
        squad_id: Uuid,
        member_id: Uuid,
        display_name: String,
        location: GeoPoint,
    ) {
        let squad_locations = self.locations.entry(squad_id).or_default();
        squad_locations.insert(
            member_id,
            StoredLocation {
                member_id,
                display_name,
                location,
                updated_at: Utc::now(),
            },
        );
    }

    /// Get all locations for a squad
    pub fn get_squad_locations(&self, squad_id: &Uuid) -> Vec<MemberLocation> {
        let now = Utc::now();
        let stale_threshold = now - Duration::seconds(self.ttl_secs);

        self.locations
            .get(squad_id)
            .map(|squad_locs| {
                squad_locs
                    .values()
                    .map(|loc| MemberLocation {
                        member_id: loc.member_id,
                        display_name: loc.display_name.clone(),
                        location: loc.location,
                        updated_at: loc.updated_at,
                        is_stale: loc.updated_at < stale_threshold,
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Remove a member's location (when they leave)
    pub fn remove_member(&mut self, squad_id: &Uuid, member_id: &Uuid) {
        if let Some(squad_locs) = self.locations.get_mut(squad_id) {
            squad_locs.remove(member_id);
        }
    }

    /// Remove all locations for a squad
    pub fn remove_squad(&mut self, squad_id: &Uuid) {
        self.locations.remove(squad_id);
    }

    /// Clean up stale locations (call periodically)
    pub fn cleanup_stale(&mut self) {
        let now = Utc::now();
        let stale_threshold = now - Duration::seconds(self.ttl_secs * 2);

        for squad_locs in self.locations.values_mut() {
            squad_locs.retain(|_, loc| loc.updated_at > stale_threshold);
        }

        // Remove empty squads
        self.locations.retain(|_, locs| !locs.is_empty());
    }
}
