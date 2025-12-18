# Squadz - GPS Squad Tracking Frontend

## Overview
Squadz is a mobile-first web application for real-time GPS squad location tracking. This is the frontend-only deployment that connects to an external backend server.

## Project Architecture
- **Framework**: Next.js 14 with React 18
- **Styling**: TailwindCSS
- **Maps**: Leaflet with react-leaflet
- **Language**: TypeScript

## Directory Structure
```
frontend/
├── src/
│   ├── app/           # Next.js App Router pages
│   ├── components/    # React components (CreateSquad, JoinSquad, SquadMap, SquadPanel)
│   ├── lib/           # API client utilities
│   └── types/         # TypeScript type definitions
├── public/            # Static assets
├── next.config.js     # Next.js configuration with API proxy
└── package.json       # Dependencies and scripts
```

## Configuration

### Backend Server URL
The app proxies API requests to an external backend. Set the `BACKEND_URL` environment variable to configure where API calls are forwarded:

```
BACKEND_URL=https://your-backend-server.com
```

If not set, defaults to `http://localhost:8080`.

### Development
- Port: 5000
- Host: 0.0.0.0

## Key Features
- Create and join squads with unique join codes
- Real-time location sharing on an interactive map
- Squad member management
- Privacy-focused design

## Recent Changes
- 2024-12-18: Configured for Replit environment with frontend-only deployment
- Added BACKEND_URL environment variable for external API server configuration
