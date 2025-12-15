//! Squadz Server - GPS Squad Tracking Backend
//!
//! Built on omni-core patterns for secure, real-time location sharing.

use std::sync::Arc;
use axum::{Router, routing::{get, post, delete}};
use tokio::sync::RwLock;
use tower_http::cors::{Any, CorsLayer};
use tower_http::trace::TraceLayer;
use tracing::info;

mod api;
mod config;
mod models;
mod services;

use config::Config;
use services::squad_manager::SquadManager;
use services::location_store::LocationStore;

/// Application state shared across handlers
pub struct AppState {
    pub config: Config,
    pub squad_manager: RwLock<SquadManager>,
    pub location_store: RwLock<LocationStore>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Initialize tracing
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_default_env()
                .add_directive("squadz=debug".parse()?)
                .add_directive("tower_http=debug".parse()?),
        )
        .init();

    // Load configuration
    dotenvy::dotenv().ok();
    let config = Config::from_env();

    info!("Starting Squadz server on {}:{}", config.host, config.port);

    // Initialize state
    let state = Arc::new(AppState {
        config: config.clone(),
        squad_manager: RwLock::new(SquadManager::new()),
        location_store: RwLock::new(LocationStore::new()),
    });

    // Build router
    let app = Router::new()
        // Health
        .route("/api/v1/health", get(api::health::health_check))
        // Squads
        .route("/api/v1/squads", post(api::squads::create_squad))
        .route("/api/v1/squads", get(api::squads::list_squads))
        .route("/api/v1/squads/:squad_id", get(api::squads::get_squad))
        .route("/api/v1/squads/:squad_id", delete(api::squads::delete_squad))
        .route("/api/v1/squads/:squad_id/join", post(api::squads::join_squad))
        .route("/api/v1/squads/:squad_id/leave", post(api::squads::leave_squad))
        // Locations
        .route("/api/v1/locations", post(api::locations::update_location))
        .route("/api/v1/squads/:squad_id/locations", get(api::locations::get_squad_locations))
        // Middleware
        .layer(TraceLayer::new_for_http())
        .layer(
            CorsLayer::new()
                .allow_origin(Any)
                .allow_methods(Any)
                .allow_headers(Any),
        )
        .with_state(state);

    // Start server
    let addr = format!("{}:{}", config.host, config.port);
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    info!("Squadz server listening on {}", addr);

    axum::serve(listener, app).await?;

    Ok(())
}
