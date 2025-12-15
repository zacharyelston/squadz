# Squadz - GPS Squad Tracking

Real-time GPS location sharing for squads/teams. Built on omni-core patterns.

## Features

- **Create Squads** - Start a squad and get a 6-character join code
- **Join Squads** - Enter a join code to join an existing squad
- **Real-time Location** - Share your GPS location with squad members
- **Interactive Map** - See all squad members on a Leaflet map
- **Stale Detection** - Visual indication when a member's location is outdated

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Frontend (Next.js)                      │
│                         Port 3000                            │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │ CreateSquad │  │  JoinSquad  │  │      SquadMap       │  │
│  └─────────────┘  └─────────────┘  │  (Leaflet + React)  │  │
│                                     └─────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ HTTP REST API
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Backend (Rust/Axum)                       │
│                         Port 8080                            │
│  ┌─────────────────┐  ┌─────────────────────────────────┐   │
│  │  SquadManager   │  │       LocationStore             │   │
│  │  - create/join  │  │  - update/query locations       │   │
│  │  - leave/delete │  │  - TTL-based stale detection    │   │
│  └─────────────────┘  └─────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## API Endpoints

### Health
- `GET /api/v1/health` - Health check

### Squads
- `POST /api/v1/squads` - Create a new squad
- `GET /api/v1/squads` - List all squads
- `GET /api/v1/squads/:id` - Get squad details
- `DELETE /api/v1/squads/:id` - Delete a squad (leader only)
- `POST /api/v1/squads/:id/join` - Join a squad
- `POST /api/v1/squads/:id/leave` - Leave a squad

### Locations
- `POST /api/v1/locations` - Update member location
- `GET /api/v1/squads/:id/locations` - Get all squad member locations

## Development

### Backend

```bash
cd backend
cargo run
```

### Frontend

```bash
cd frontend
npm install
npm run dev
```

### Docker

```bash
docker-compose up --build
```

## Configuration

### Backend Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| HOST | 0.0.0.0 | Server bind address |
| PORT | 8080 | Server port |
| LOCATION_TTL_SECS | 300 | Location staleness threshold (5 min) |
| MAX_SQUAD_SIZE | 50 | Maximum members per squad |

### Frontend Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| NEXT_PUBLIC_API_URL | http://localhost:8080 | Backend API URL |

## Tech Stack

- **Backend**: Rust, Axum, Tokio
- **Frontend**: Next.js 14, React 18, TypeScript, Tailwind CSS
- **Map**: Leaflet, react-leaflet
- **Patterns**: Based on omni-core architecture

## License

MIT
