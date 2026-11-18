//! Squadz Server - GPS Squad Tracking Backend
//!
//! Built on omni-core patterns for secure, real-time location sharing.

use std::sync::Arc;
use axum::{Router, routing::{get, post, delete}, middleware};
use tokio::sync::RwLock;
use tower_http::cors::{Any, CorsLayer};
use tower_http::services::ServeDir;
use tower_http::trace::TraceLayer;
use tracing::info;

mod api;
mod config;
mod models;
mod services;
mod tls;

use config::Config;
use services::squad_manager::SquadManager;
use services::location_store::LocationStore;
use services::session::SessionStore;

/// Application state shared across handlers
pub struct AppState {
    pub config: Config,
    pub squad_manager: RwLock<SquadManager>,
    pub location_store: RwLock<LocationStore>,
    pub session_store: SessionStore,
    pub dashboard_password: String,
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

    // Get or generate dashboard password
    let dashboard_password = std::env::var("DASHBOARD_PASSWORD").unwrap_or_else(|_| {
        let generated: String = (0..12)
            .map(|_| {
                let idx = rand::random::<usize>() % 36;
                if idx < 10 {
                    (b'0' + idx as u8) as char
                } else {
                    (b'a' + (idx - 10) as u8) as char
                }
            })
            .collect();
        info!("Generated dashboard password: {}", generated);
        generated
    });
    info!("Dashboard available at / (password protected)");

    // Initialize state
    let state = Arc::new(AppState {
        config: config.clone(),
        squad_manager: RwLock::new(SquadManager::new()),
        location_store: RwLock::new(LocationStore::new()),
        session_store: SessionStore::new(),
        dashboard_password,
    });

    // Protected routes (require auth)
    let protected_routes = Router::new()
        .route("/api/v1/locations", post(api::locations::update_location))
        .route("/api/v1/squads/:squad_id/leave", post(api::squads::leave_squad))
        .route("/api/v1/squads/:squad_id", delete(api::squads::delete_squad))
        .layer(middleware::from_fn_with_state(state.clone(), services::auth::auth_middleware));

    // Public routes (no auth required)
    let public_routes = Router::new()
        // Dashboard at root
        .route("/", get(api::dashboard::dashboard_page))
        .route("/api/v1/health", get(api::health::health_check))
        .route("/api/v1/squads", post(api::squads::create_squad))
        .route("/api/v1/squads", get(api::squads::list_squads))
        .route("/api/v1/squads/:squad_id", get(api::squads::get_squad))
        .route("/api/v1/squads/:squad_id/join", post(api::squads::join_squad))
        .route("/api/v1/join", post(api::squads::join_by_code))
        .route("/api/v1/qr.svg", get(api::qr::qr_svg))
        .route("/api/v1/squads/:squad_id/locations", get(api::locations::get_squad_locations))
        // Crypto test endpoints (omni-core-lite)
        .route("/api/v1/crypto/health", get(api::crypto::crypto_health))
        .route("/api/v1/crypto/echo", post(api::crypto::crypto_echo))
        .route("/api/v1/crypto/encrypt", post(api::crypto::crypto_encrypt))
        .route("/api/v1/crypto/decrypt", post(api::crypto::crypto_decrypt))
        // Self-hosted mobile web app (works with no internet access)
        .route("/mobile.html", get(api::webapp::mobile_page))
        .route("/squadz-config.js", get(api::webapp::client_config))
        .route("/vendor/leaflet/leaflet.js", get(api::webapp::leaflet_js))
        .route("/vendor/leaflet/leaflet.css", get(api::webapp::leaflet_css))
        .route("/vendor/leaflet/images/marker-icon.png", get(api::webapp::marker_icon))
        .route("/vendor/leaflet/images/marker-icon-2x.png", get(api::webapp::marker_icon_2x))
        .route("/vendor/leaflet/images/marker-shadow.png", get(api::webapp::marker_shadow))
        .route("/vendor/leaflet/images/layers.png", get(api::webapp::layers))
        .route("/vendor/leaflet/images/layers-2x.png", get(api::webapp::layers_2x));

    // Optional pre-downloaded map tiles: {TILES_DIR}/{z}/{x}/{y}.png
    let public_routes = match &config.tiles_dir {
        Some(dir) => {
            info!("Serving map tiles from {}", dir.display());
            public_routes.nest_service("/tiles", ServeDir::new(dir))
        }
        None => public_routes,
    };

    // Build router
    let app = Router::new()
        .merge(protected_routes)
        .merge(public_routes)
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
    info!("Squadz server listening on http://{}", addr);
    let http = async { axum::serve(listener, app.clone()).await.map_err(anyhow::Error::from) };

    match config.tls_port {
        Some(tls_port) => {
            let tls_config = tls::load_or_generate(&config).await?;
            let tls_addr: std::net::SocketAddr = format!("{}:{}", config.host, tls_port).parse()?;
            info!("Squadz server listening on https://{}", tls_addr);
            info!("Mobile app: https://<this-host>:{}/mobile.html", tls_port);
            let https = async {
                axum_server::bind_rustls(tls_addr, tls_config)
                    .serve(app.clone().into_make_service())
                    .await
                    .map_err(anyhow::Error::from)
            };
            tokio::try_join!(http, https)?;
        }
        None => http.await?,
    }

    Ok(())
}
