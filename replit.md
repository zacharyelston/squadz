# Squadz - GPS Squad Tracking

## Overview

Squadz is a real-time GPS squad tracking application with a Rust backend and Next.js frontend.

## Deployment URLs

| Service | URL |
|---------|-----|
| Backend (Server) | https://sqdz-s-dev.replit.app |
| Frontend (Client) | https://sqdz-c-dev.replit.app |

## Tech Stack

### Backend
- **Language**: Rust
- **Web Framework**: Axum
- **Runtime**: Tokio (async)
- **Port**: 5000

### Frontend
- **Framework**: Next.js 14 with React 18
- **Styling**: TailwindCSS
- **Maps**: Leaflet with react-leaflet
- **Port**: 3000

## Configuration

### Backend Environment Variables
- `PORT` - Server port (default: 5000)
- `HOST` - Server host (default: 0.0.0.0)
- `LOCATION_TTL_SECS` - Location expiry time (default: 300)
- `MAX_SQUAD_SIZE` - Maximum squad members (default: 50)

### Frontend Environment Variables
- `BACKEND_URL` - Backend API URL (default: http://localhost:8080)

## API Endpoints

### Health
- `GET /api/v1/health` - Health check

### Squads
- `POST /api/v1/squads` - Create a squad (returns api_key)
- `GET /api/v1/squads` - List all squads
- `GET /api/v1/squads/:squad_id` - Get squad details
- `POST /api/v1/squads/:squad_id/join` - Join a squad (returns api_key)
- `POST /api/v1/squads/:squad_id/leave` - Leave a squad (auth required)
- `DELETE /api/v1/squads/:squad_id` - Delete a squad (auth required)

### Locations
- `POST /api/v1/locations` - Update location (auth required)
- `GET /api/v1/squads/:squad_id/locations` - Get squad member locations

## Authentication

Protected routes require `Authorization: Bearer <api_key>` header.
API keys are returned when creating or joining a squad.

## Development

### Backend
```bash
cd backend
cargo run --release
```

### Frontend
```bash
cd frontend
npm install
npm run dev
```

## Mobile Web App

A standalone mobile-friendly HTML page is available at:
- `/frontend/public/mobile.html`
- Polls every 10 seconds for location updates
- Works in any mobile browser
