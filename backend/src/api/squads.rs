//! Squad management endpoints

use std::sync::Arc;
use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use serde::Deserialize;
use uuid::Uuid;

use crate::models::{CreateSquadRequest, CreateSquadResponse, JoinSquadRequest, JoinSquadResponse, Squad};
use crate::services::squad_manager::SquadError;
use crate::AppState;

/// Create a new squad
pub async fn create_squad(
    State(state): State<Arc<AppState>>,
    Json(req): Json<CreateSquadRequest>,
) -> Result<Json<CreateSquadResponse>, (StatusCode, String)> {
    let mut manager = state.squad_manager.write().await;
    let (squad, member_id) = manager.create_squad(req.name, req.leader_name, req.settings);

    // Create session for the leader (1 hour TTL)
    let session = state.session_store.create(member_id, squad.squad_id, 3600);

    Ok(Json(CreateSquadResponse {
        squad_id: squad.squad_id,
        join_code: squad.join_code,
        member_id,
        api_key: session.api_key,
    }))
}

/// List all squads (debug endpoint)
pub async fn list_squads(
    State(state): State<Arc<AppState>>,
) -> Json<Vec<Squad>> {
    let manager = state.squad_manager.read().await;
    Json(manager.list_squads().into_iter().cloned().collect())
}

/// Get a squad by ID
pub async fn get_squad(
    State(state): State<Arc<AppState>>,
    Path(squad_id): Path<Uuid>,
) -> Result<Json<Squad>, (StatusCode, String)> {
    let manager = state.squad_manager.read().await;
    manager
        .get_squad(&squad_id)
        .cloned()
        .map(Json)
        .ok_or((StatusCode::NOT_FOUND, "Squad not found".to_string()))
}

/// Delete a squad
#[derive(Deserialize)]
pub struct DeleteSquadRequest {
    pub member_id: Uuid,
}

pub async fn delete_squad(
    State(state): State<Arc<AppState>>,
    Path(squad_id): Path<Uuid>,
    Json(req): Json<DeleteSquadRequest>,
) -> Result<StatusCode, (StatusCode, String)> {
    let mut manager = state.squad_manager.write().await;
    manager
        .delete_squad(&squad_id, &req.member_id)
        .map(|_| {
            // Also clean up locations
            drop(manager);
            tokio::spawn(async move {
                // Would clean up location store here
            });
            StatusCode::NO_CONTENT
        })
        .map_err(|e| match e {
            SquadError::SquadNotFound => (StatusCode::NOT_FOUND, e.to_string()),
            SquadError::NotLeader => (StatusCode::FORBIDDEN, e.to_string()),
            _ => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()),
        })
}

/// Join a squad
pub async fn join_squad(
    State(state): State<Arc<AppState>>,
    Path(squad_id): Path<Uuid>,
    Json(req): Json<JoinSquadRequest>,
) -> Result<Json<JoinSquadResponse>, (StatusCode, String)> {
    let mut manager = state.squad_manager.write().await;

    // Verify squad_id matches the join code's squad
    let code_squad = manager.get_squad_by_code(&req.join_code);
    if let Some(s) = code_squad {
        if s.squad_id != squad_id {
            return Err((StatusCode::BAD_REQUEST, "Join code does not match squad".to_string()));
        }
    }

    manager
        .join_squad(&req.join_code, req.display_name)
        .map(|(squad, member_id)| {
            // Create session for the new member (1 hour TTL)
            let session = state.session_store.create(member_id, squad.squad_id, 3600);
            Json(JoinSquadResponse { member_id, squad, api_key: session.api_key })
        })
        .map_err(|e| match e {
            SquadError::InvalidJoinCode => (StatusCode::NOT_FOUND, e.to_string()),
            SquadError::NameTaken => (StatusCode::CONFLICT, e.to_string()),
            _ => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()),
        })
}

/// Leave a squad
#[derive(Deserialize)]
pub struct LeaveSquadRequest {
    pub member_id: Uuid,
}

pub async fn leave_squad(
    State(state): State<Arc<AppState>>,
    Path(squad_id): Path<Uuid>,
    Json(req): Json<LeaveSquadRequest>,
) -> Result<StatusCode, (StatusCode, String)> {
    let mut manager = state.squad_manager.write().await;
    manager
        .leave_squad(&squad_id, &req.member_id)
        .map(|_| StatusCode::NO_CONTENT)
        .map_err(|e| match e {
            SquadError::SquadNotFound => (StatusCode::NOT_FOUND, e.to_string()),
            SquadError::MemberNotFound => (StatusCode::NOT_FOUND, e.to_string()),
            _ => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()),
        })
}
