# Squadz Build & Deployment Notes

## Deployment URLs

| Environment | Service | URL |
|-------------|---------|-----|
| **Production** | Backend (Server) | https://sqdz-s-dev.replit.app |
| **Production** | Frontend (Client) | https://sqdz-c-dev.replit.app |
| **Local** | Backend | http://localhost:8081 |
| **Local** | Frontend | http://localhost:3000 |

---

## Mobile Web App

A standalone mobile-friendly HTML page is available at:
- **Local**: http://localhost:3000/mobile.html
- **Production**: https://sqdz-c-dev.replit.app/mobile.html

### Features
- Create or join squads with 6-character codes
- Real-time GPS tracking with 10-second polling
- Leaflet map with member markers
- Works in any mobile browser (iOS Safari, Android Chrome)
- Persists session in localStorage

### Configuration
The mobile app auto-detects environment:
- If running on localhost → uses `http://localhost:8081`
- Otherwise → uses `https://sqdz-s-dev.replit.app`

---

## Backend Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `HOST` | `0.0.0.0` | Server bind address |
| `PORT` | `8080` | Server port |
| `LOCATION_TTL_SECS` | `300` | Location staleness threshold (5 min) |
| `MAX_SQUAD_SIZE` | `50` | Maximum members per squad |

### Running Locally

```bash
cd backend
PORT=8081 cargo run --bin squadz-server
```

---

## Frontend Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NEXT_PUBLIC_API_URL` | (empty) | Backend API URL (uses proxy if empty) |

### Running Locally

```bash
cd frontend
npm install
npm run dev
```

---

## API Authentication

### Session Flow
1. **Create Squad** → Returns `api_key` (format: `sqz_xxx...`)
2. **Join Squad** → Returns `api_key`
3. **Protected Routes** → Require `Authorization: Bearer <api_key>`

### Protected Routes (require auth)
- `POST /api/v1/locations` - Update location
- `POST /api/v1/squads/:id/leave` - Leave squad
- `DELETE /api/v1/squads/:id` - Delete squad

### Public Routes (no auth)
- `GET /api/v1/health` - Health check
- `POST /api/v1/squads` - Create squad
- `GET /api/v1/squads` - List squads
- `GET /api/v1/squads/:id` - Get squad
- `POST /api/v1/squads/:id/join` - Join squad
- `GET /api/v1/squads/:id/locations` - Get locations

---

## Polling Configuration

Location updates are polled every **10 seconds** (configurable in `mobile.html`):

```javascript
const UPDATE_INTERVAL = 10000; // 10 seconds
```

GPS position is watched continuously and sent on each change.

---

## Replit Deployment

### Backend (sqdz-s-dev)
1. Push to `main` branch
2. Replit auto-deploys from GitHub
3. Ensure `PORT` is set in Replit Secrets

### Frontend (sqdz-c-dev)
1. Push to `main` branch
2. Replit auto-deploys from GitHub
3. Set `NEXT_PUBLIC_API_URL=https://sqdz-s-dev.replit.app` in Secrets

---

## Related Projects

| Project | Role | Repo |
|---------|------|------|
| **Squadz** | GPS tracking input stream | https://github.com/zacharyelston/squadz |
| **Omniscient** | Orchestration layer | https://github.com/zacharyelston/omniscient |
| **Omni-Core** | Auth/crypto backbone | https://github.com/zacharyelston/omni-core |
| **Neurostack** | Decision engine | https://github.com/zacharyelston/neurostack |

---

## Next Steps

- [ ] Add WebSocket streaming for real-time updates
- [ ] Integrate with Omniscient as input stream
- [ ] Add omni-core crypto (X25519/ChaCha20) for encrypted IPC
- [ ] Add push notifications for squad events
