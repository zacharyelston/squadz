# Squadz Backend Server

GPS squad tracking backend built with Rust and Axum.

## Overview

This is the backend API server for the Squadz GPS tracking application. It provides REST APIs for squad management and location sharing.

## Tech Stack

- **Language**: Rust
- **Web Framework**: Axum
- **Runtime**: Tokio (async)

## Configuration

Environment variables:
- `PORT` - Server port (default: 5000)
- `HOST` - Server host (default: 0.0.0.0)
- `LOCATION_TTL_SECS` - Location expiry time (default: 300)
- `MAX_SQUAD_SIZE` - Maximum squad members (default: 50)

## API Endpoints

### Health
- `GET /api/v1/health` - Health check

### Squads
- `POST /api/v1/squads` - Create a squad
- `GET /api/v1/squads` - List all squads
- `GET /api/v1/squads/:squad_id` - Get squad details
- `POST /api/v1/squads/:squad_id/join` - Join a squad
- `POST /api/v1/squads/:squad_id/leave` - Leave a squad (auth required)
- `DELETE /api/v1/squads/:squad_id` - Delete a squad (auth required)

### Locations
- `POST /api/v1/locations` - Update location (auth required)
- `GET /api/v1/squads/:squad_id/locations` - Get squad member locations

## Development

Run the server:
```bash
cargo run --release
```

Build:
```bash
cargo build --release
```

## Project Structure

```
backend/
  src/
    api/           - HTTP handlers
    services/      - Business logic
    config.rs      - Configuration
    main.rs        - Entry point
    models.rs      - Data models
```
