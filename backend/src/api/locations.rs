//! Location tracking endpoints

use std::sync::Arc;
use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use chrono::Utc;
use uuid::Uuid;

use crate::models::{SquadLocationsResponse, UpdateLocationRequest};
use crate::AppState;

/// Update a member's location
pub async fn update_location(
    State(state): State<Arc<AppState>>,
    Json(req): Json<UpdateLocationRequest>,
) -> Result<StatusCode, (StatusCode, String)> {
    // Verify member is in the squad
    let manager = state.squad_manager.read().await;
    let squad = manager
        .get_squad(&req.squad_id)
        .ok_or((StatusCode::NOT_FOUND, "Squad not found".to_string()))?;

    let member = squad
        .members
        .iter()
        .find(|m| m.member_id == req.member_id)
        .ok_or((StatusCode::FORBIDDEN, "Not a member of this squad".to_string()))?;

    let display_name = member.display_name.clone();
    drop(manager);

    // Update location
    let mut store = state.location_store.write().await;
    store.update_location(req.squad_id, req.member_id, display_name, req.location);

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
