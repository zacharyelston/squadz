//! Location tracking endpoints

use std::sync::Arc;
use axum::{
    extract::{Path, State, Extension},
    http::StatusCode,
    Json,
};
use chrono::Utc;
use uuid::Uuid;

use crate::models::{GeoPoint, SquadLocationsResponse};
use crate::services::auth::AuthenticatedMember;
use crate::AppState;

/// Request to update location (simplified - uses session for member/squad)
#[derive(Debug, serde::Deserialize)]
pub struct AuthenticatedLocationUpdate {
    pub location: GeoPoint,
}

/// Update a member's location (requires auth)
pub async fn update_location(
    State(state): State<Arc<AppState>>,
    Extension(auth): Extension<AuthenticatedMember>,
    Json(req): Json<AuthenticatedLocationUpdate>,
) -> Result<StatusCode, (StatusCode, String)> {
    let session = auth.session;
    
    // Get member display name from squad
    let manager = state.squad_manager.read().await;
    let squad = manager
        .get_squad(&session.squad_id)
        .ok_or((StatusCode::NOT_FOUND, "Squad not found".to_string()))?;

    let member = squad
        .members
        .iter()
        .find(|m| m.member_id == session.member_id)
        .ok_or((StatusCode::FORBIDDEN, "Not a member of this squad".to_string()))?;

    let display_name = member.display_name.clone();
    drop(manager);

    // Update location
    let mut store = state.location_store.write().await;
    store.update_location(session.squad_id, session.member_id, display_name, req.location);

    Ok(StatusCode::OK)
}

/// Get all member locations for a squad
pub async fn get_squad_locations(
    State(state): State<Arc<AppState>>,
    Path(squad_id): Path<Uuid>,
) -> Result<Json<SquadLocationsResponse>, (StatusCode, String)> {
    // Get squad info
    let manager = state.squad_manager.read().await;
    let squad = manager
        .get_squad(&squad_id)
        .ok_or((StatusCode::NOT_FOUND, "Squad not found".to_string()))?;

    let squad_name = squad.name.clone();
    drop(manager);

    // Get locations
    let store = state.location_store.read().await;
    let locations = store.get_squad_locations(&squad_id);

    Ok(Json(SquadLocationsResponse {
        squad_id,
        squad_name,
        locations,
        updated_at: Utc::now(),
    }))
}
