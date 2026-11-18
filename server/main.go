// squadz-server shares squad members' positions with their phones, with no
// internet needed: it is built to run on one node of an OpenMANET mesh.
//
// Phones pair by scanning a QR code and from then on talk to the server
// over TLS pinned to its key (PairKit; see docs/MOBILE_CLIENT.md).
package main

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"fmt"
	"html/template"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	pairkit "github.com/zacharyelston/pairkit/go"
)

const app = "squadz"

type Config struct {
	Port, TLSPort     int
	TLSHosts          []string
	DataDir, TilesDir string
	TileMaxZoom       int
	TileAttribution   string
	StaleAfter        time.Duration
	MaxSquadSize      int
	DashboardPassword string
}

func env(name, def string) string {
	if v := strings.TrimSpace(os.Getenv(name)); v != "" {
		return v
	}
	return def
}

func envInt(name string, def int) int {
	if n, err := strconv.Atoi(env(name, "")); err == nil {
		return n
	}
	return def
}

func configFromEnv() Config {
	var hosts []string
	for _, h := range strings.Split(env("TLS_HOSTS", "localhost,127.0.0.1"), ",") {
		if h = strings.TrimSpace(h); h != "" {
			hosts = append(hosts, h)
		}
	}
	return Config{
		Port: envInt("PORT", 8090), TLSPort: envInt("TLS_PORT", 8443), TLSHosts: hosts,
		DataDir: env("DATA_DIR", "data"), TilesDir: env("TILES_DIR", ""),
		TileMaxZoom: envInt("TILE_MAX_ZOOM", 0), TileAttribution: env("TILE_ATTRIBUTION", "© OpenStreetMap"),
		StaleAfter:   time.Duration(envInt("LOCATION_TTL_SECS", 300)) * time.Second,
		MaxSquadSize: envInt("MAX_SQUAD_SIZE", 50), DashboardPassword: env("DASHBOARD_PASSWORD", ""),
	}
}

func newID() string {
	b := make([]byte, 9)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

type Server struct {
	cfg   Config
	pin   string
	pair  *pairkit.Service
	state *State
}

// payload is the QR text for an invite, pointing at this server by the
// address the asker used to reach it.
func (s *Server) payload(host, invite string) string {
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	if strings.Contains(host, ":") { // bare IPv6
		host = "[" + host + "]"
	}
	return pairkit.Payload{V: 1, App: app, Server: host + ":" + strconv.Itoa(s.cfg.TLSPort), KeyPin: s.pin, Invite: invite}.String()
}

// api is everything phones call, served over pinned TLS only.
func (s *Server) api() http.Handler {
	mux := http.NewServeMux()
	authed := func(pattern string, h http.HandlerFunc) { mux.Handle(pattern, s.pair.Require(h)) }

	mux.HandleFunc("GET /api/v1/health", func(w http.ResponseWriter, r *http.Request) {
		pairkit.WriteJSON(w, http.StatusOK, map[string]string{"status": "ok", "app": app})
	})
	mux.Handle("POST "+pairkit.RedeemPath, s.pair.RedeemHandler(func(r *http.Request, v pairkit.Invite, d pairkit.Device) (map[string]any, error) {
		squad, err := s.state.AddMember(d.ID, d.Name, v.Subject)
		if err != nil {
			return nil, err
		}
		m, _ := s.state.Member(d.ID)
		return map[string]any{"name": m.Name, "squad": squad}, nil
	}))
	mux.Handle("POST "+pairkit.RefreshPath, s.pair.RefreshHandler())
	mux.Handle("POST "+pairkit.LogoutPath, s.pair.LogoutHandler(func(d pairkit.Device) { _ = s.state.Leave(d.ID, true) }))

	authed("GET /api/v1/me", func(w http.ResponseWriter, r *http.Request) {
		m, _ := s.state.Member(pairkit.DeviceFrom(r.Context()).ID)
		out := map[string]any{"device_id": m.ID, "name": m.Name, "squad": s.state.Squad(m.SquadID),
			"poll_seconds": 10, "stale_seconds": int(s.cfg.StaleAfter / time.Second)}
		if s.cfg.TilesDir != "" {
			tiles := map[string]any{"path": "tiles/{z}/{x}/{y}.png", "attribution": s.cfg.TileAttribution}
			if s.cfg.TileMaxZoom > 0 {
				tiles["max_zoom"] = s.cfg.TileMaxZoom
			}
			out["tiles"] = tiles
		}
		pairkit.WriteJSON(w, http.StatusOK, out)
	})
	authed("POST /api/v1/squads", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Name string `json:"name"`
		}
		if err := pairkit.ReadJSON(w, r, &req); err != nil {
			pairkit.WriteError(w, err)
			return
		}
		squad, err := s.state.CreateSquad(pairkit.DeviceFrom(r.Context()).ID, req.Name)
		if err != nil {
			pairkit.WriteError(w, err)
			return
		}
		pairkit.WriteJSON(w, http.StatusCreated, squad)
	})
	authed("POST /api/v1/squad/invites", func(w http.ResponseWriter, r *http.Request) {
		m, _ := s.state.Member(pairkit.DeviceFrom(r.Context()).ID)
		if m.SquadID == "" {
			pairkit.WriteError(w, refuse(http.StatusConflict, "no_squad", "you are not in a squad"))
			return
		}
		code, inv, err := s.pair.CreateInvite(m.SquadID)
		if err != nil {
			pairkit.WriteError(w, err)
			return
		}
		pairkit.WriteJSON(w, http.StatusCreated, map[string]any{"qr_payload": s.payload(r.Host, code),
			"expires_in": int(time.Until(inv.ExpiresAt) / time.Second)})
	})
	authed("POST /api/v1/squad/leave", func(w http.ResponseWriter, r *http.Request) {
		if err := s.state.Leave(pairkit.DeviceFrom(r.Context()).ID, false); err != nil {
			pairkit.WriteError(w, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	authed("PUT /api/v1/location", func(w http.ResponseWriter, r *http.Request) {
		var p Position
		if err := pairkit.ReadJSON(w, r, &p); err != nil {
			pairkit.WriteError(w, err)
			return
		}
		if err := s.state.SetPosition(pairkit.DeviceFrom(r.Context()).ID, p); err != nil {
			pairkit.WriteError(w, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	authed("GET /api/v1/squad/locations", func(w http.ResponseWriter, r *http.Request) {
		m, _ := s.state.Member(pairkit.DeviceFrom(r.Context()).ID)
		squad := s.state.Squad(m.SquadID)
		if squad == nil {
			pairkit.WriteError(w, refuse(http.StatusConflict, "no_squad", "you are not in a squad"))
			return
		}
		pairkit.WriteJSON(w, http.StatusOK, map[string]any{"squad": squad,
			"locations": s.state.Positions(m.SquadID, s.cfg.StaleAfter)})
	})
	if s.cfg.TilesDir != "" {
		tiles := http.StripPrefix("/tiles/", http.FileServer(http.Dir(s.cfg.TilesDir)))
		authed("GET /tiles/{z}/{x}/{file}", func(w http.ResponseWriter, r *http.Request) {
			if !strings.HasSuffix(r.PathValue("file"), ".png") {
				http.NotFound(w, r)
				return
			}
			w.Header().Set("Cache-Control", "private, max-age=604800")
			tiles.ServeHTTP(w, r)
		})
	}
	return mux
}

var dashboardPage = template.Must(template.New("dashboard").Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Squadz server</title>
<style>
body{font:16px/1.5 system-ui,sans-serif;max-width:34rem;margin:2rem auto;padding:0 1rem;color:#111;background:#fff}
img{width:18rem;max-width:100%;image-rendering:pixelated;border:1px solid #ccc}
code,textarea{font:13px ui-monospace,monospace}textarea{width:100%;height:5rem}
small{color:#555}
</style></head><body>
<h1>Squadz server</h1>
<p>{{.Squads}} squads, {{.Members}} phones paired.</p>
<h2>Pair a phone</h2>
<p>Open the Squadz app, choose <b>Scan a code</b> and point it at this code. It works once and for {{.Minutes}} minutes; reload this page for another.</p>
<p><img alt="Pairing code" src="data:image/png;base64,{{.PNG}}"></p>
<p><small>No camera? Paste this into the app instead:</small></p>
<textarea readonly>{{.Payload}}</textarea>
<p><small>Server key pin: <code>{{.Pin}}</code></small></p>
</body></html>`))

// local is the plain-HTTP side: the operator's page for pairing the first
// phone. It hands out invites, so set DASHBOARD_PASSWORD on a shared network.
func (s *Server) local() http.Handler {
	mux := http.NewServeMux()
	guard := func(h http.HandlerFunc) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			if want := s.cfg.DashboardPassword; want != "" {
				_, got, _ := r.BasicAuth()
				if subtle.ConstantTimeCompare([]byte(got), []byte(want)) != 1 {
					w.Header().Set("WWW-Authenticate", `Basic realm="Squadz"`)
					http.Error(w, "password required", http.StatusUnauthorized)
					return
				}
			}
			w.Header().Set("Cache-Control", "no-store")
			h(w, r)
		}
	}
	mux.HandleFunc("GET /api/v1/health", func(w http.ResponseWriter, r *http.Request) {
		pairkit.WriteJSON(w, http.StatusOK, map[string]string{"status": "ok", "app": app})
	})
	mux.HandleFunc("GET /api/v1/setup-invite", guard(func(w http.ResponseWriter, r *http.Request) {
		code, inv, err := s.pair.CreateInvite("")
		if err != nil {
			pairkit.WriteError(w, err)
			return
		}
		pairkit.WriteJSON(w, http.StatusOK, map[string]any{"qr_payload": s.payload(r.Host, code),
			"expires_in": int(time.Until(inv.ExpiresAt) / time.Second)})
	}))
	mux.HandleFunc("GET /{$}", guard(func(w http.ResponseWriter, r *http.Request) {
		code, _, err := s.pair.CreateInvite("")
		if err != nil {
			http.Error(w, "could not create an invite", http.StatusInternalServerError)
			return
		}
		payload := s.payload(r.Host, code)
		png, err := pairkit.QRPNG(payload)
		if err != nil {
			http.Error(w, "could not draw the code", http.StatusInternalServerError)
			return
		}
		squads, members := s.state.Counts()
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_ = dashboardPage.Execute(w, map[string]any{"Squads": squads, "Members": members, "Pin": s.pin,
			"Payload": payload, "PNG": base64.StdEncoding.EncodeToString(png), "Minutes": int(s.pair.InviteTTL / time.Minute)})
	}))
	return mux
}

func run() error {
	cfg := configFromEnv()
	id, err := pairkit.LoadOrCreateIdentity(cfg.DataDir, cfg.TLSHosts)
	if err != nil {
		return err
	}
	pair, err := pairkit.Open(app, filepath.Join(cfg.DataDir, "pairkit.json"))
	if err != nil {
		return err
	}
	state, err := openState(filepath.Join(cfg.DataDir, "squadz.json"), cfg.MaxSquadSize)
	if err != nil {
		return err
	}
	s := &Server{cfg: cfg, pin: id.Pin, pair: pair, state: state}

	log.Printf("server key pin: %s", id.Pin)
	log.Printf("phones: https://<this-host>:%d (pinned TLS)", cfg.TLSPort)
	log.Printf("pair the first phone at http://<this-host>:%d/", cfg.Port)
	if len(cfg.TLSHosts) > 0 {
		if code, _, err := pair.CreateInvite(""); err == nil {
			if qr, err := pairkit.QRTerminal(s.payload(cfg.TLSHosts[0], code)); err == nil {
				fmt.Fprintf(os.Stderr, "\nPairing code for %s (valid %d minutes, once):\n\n%s\n", cfg.TLSHosts[0], int(pair.InviteTTL/time.Minute), qr)
			}
		}
	}

	errs := make(chan error, 2)
	tlsServer := &http.Server{Addr: fmt.Sprintf(":%d", cfg.TLSPort), Handler: s.api(), TLSConfig: id.TLSConfig(),
		ReadHeaderTimeout: 10 * time.Second, ErrorLog: log.New(os.Stderr, "tls: ", 0)}
	plain := &http.Server{Addr: fmt.Sprintf(":%d", cfg.Port), Handler: s.local(), ReadHeaderTimeout: 10 * time.Second}
	go func() { errs <- tlsServer.ListenAndServeTLS("", "") }()
	go func() { errs <- plain.ListenAndServe() }()
	return <-errs
}

func main() {
	log.SetFlags(log.Ltime)
	if err := run(); err != nil {
		log.Fatal(err)
	}
}
