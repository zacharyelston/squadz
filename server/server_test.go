package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	pairkit "github.com/zacharyelston/pairkit/go"
)

// phone is a test client: a device key, a pinned HTTP client and a session.
type phone struct {
	t      *testing.T
	base   string
	http   *http.Client
	key    *ecdsa.PrivateKey
	access string
}

// pinned accepts only a server whose leaf key has this pin, as the apps do.
func pinned(pin string) *http.Client {
	return &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{
		MinVersion:         tls.VersionTLS13,
		InsecureSkipVerify: true, // the pin below is the only check
		VerifyPeerCertificate: func(raw [][]byte, _ [][]*x509.Certificate) error {
			cert, err := x509.ParseCertificate(raw[0])
			if err != nil {
				return err
			}
			pub, ok := cert.PublicKey.(*ecdsa.PublicKey)
			if !ok {
				return errors.New("not an EC key")
			}
			if got, _ := pairkit.Pin(pub); got != pin {
				return errors.New("pin mismatch")
			}
			return nil
		},
	}}}
}

func (p *phone) call(method, path string, body any, out any) (int, string) {
	p.t.Helper()
	raw, _ := json.Marshal(body)
	req, _ := http.NewRequest(method, p.base+path, bytes.NewReader(raw))
	if p.access != "" {
		req.Header.Set("Authorization", "Bearer "+p.access)
	}
	res, err := p.http.Do(req)
	if err != nil {
		p.t.Fatalf("%s %s: %v", method, path, err)
	}
	defer res.Body.Close()
	var e struct{ Code string }
	buf := new(bytes.Buffer)
	_, _ = buf.ReadFrom(res.Body)
	_ = json.Unmarshal(buf.Bytes(), &e)
	if out != nil {
		if err := json.Unmarshal(buf.Bytes(), out); err != nil {
			p.t.Fatalf("%s %s: %v in %q", method, path, err, buf.String())
		}
	}
	return res.StatusCode, e.Code
}

type paired struct {
	DeviceID    string     `json:"device_id"`
	Name        string     `json:"name"`
	Squad       *SquadView `json:"squad"`
	AccessToken string     `json:"access_token"`
}

func (p *phone) pair(qr, name string) (paired, int, string) {
	p.t.Helper()
	payload, err := pairkit.ParsePayload(qr, app)
	if err != nil {
		p.t.Fatalf("payload %q: %v", qr, err)
	}
	p.http = pinned(payload.KeyPin)
	p.key, _ = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	pub, _ := x509.MarshalPKIXPublicKey(&p.key.PublicKey)
	ts := time.Now().Unix()
	digest := sha256.Sum256(pairkit.ProofMessage(app, pairkit.PurposePair, payload.Invite, ts))
	sig, _ := ecdsa.SignASN1(rand.Reader, p.key, digest[:])
	var out paired
	status, code := p.call("POST", pairkit.RedeemPath, pairkit.RedeemRequest{Invite: payload.Invite,
		PublicKey: base64.StdEncoding.EncodeToString(pub), Name: name, Timestamp: ts,
		Signature: base64.StdEncoding.EncodeToString(sig)}, &out)
	p.access = out.AccessToken
	return out, status, code
}

func newTestServer(t *testing.T, dir string) (*Server, *httptest.Server, *httptest.Server) {
	t.Helper()
	id, err := pairkit.LoadOrCreateIdentity(dir, []string{"127.0.0.1"})
	if err != nil {
		t.Fatal(err)
	}
	pair, _ := pairkit.Open(app, filepath.Join(dir, "pairkit.json"))
	state, _ := openState(filepath.Join(dir, "squadz.json"), 3)
	s := &Server{cfg: Config{StaleAfter: 5 * time.Minute, TilesDir: filepath.Join(dir, "tiles")}, pin: id.Pin, pair: pair, state: state}
	api := httptest.NewUnstartedServer(s.api())
	api.TLS = id.TLSConfig()
	api.StartTLS()
	t.Cleanup(api.Close)
	s.cfg.TLSPort = api.Listener.Addr().(*net.TCPAddr).Port
	local := httptest.NewServer(s.local())
	t.Cleanup(local.Close)
	return s, api, local
}

func TestSquadLifecycle(t *testing.T) {
	dir := t.TempDir()
	_ = os.MkdirAll(filepath.Join(dir, "tiles", "3", "1"), 0o755)
	_ = os.WriteFile(filepath.Join(dir, "tiles", "3", "1", "2.png"), []byte("png"), 0o644)
	s, api, local := newTestServer(t, dir)

	// The operator's page hands the first phone a setup invite.
	var setup struct {
		QR string `json:"qr_payload"`
	}
	res, err := http.Get(local.URL + "/api/v1/setup-invite")
	if err != nil {
		t.Fatal(err)
	}
	_ = json.NewDecoder(res.Body).Decode(&setup)
	res.Body.Close()

	ana := &phone{t: t, base: api.URL}
	got, status, _ := ana.pair(setup.QR, "  Ana  ")
	if status != 200 || got.Name != "Ana" || got.Squad != nil {
		t.Fatalf("setup pairing: %d %+v", status, got)
	}
	if _, status, code := (&phone{t: t, base: api.URL}).pair(setup.QR, "Eve"); status != 401 {
		t.Fatalf("invite reused: %d %+v", status, code)
	}

	// No session, no data.
	anon := &phone{t: t, base: api.URL, http: pinned(s.pin)}
	if status, _ := anon.call("GET", "/api/v1/me", nil, nil); status != 401 {
		t.Fatalf("anonymous /me: %d", status)
	}
	if status, _ := anon.call("GET", "/tiles/3/1/2.png", nil, nil); status != 401 {
		t.Fatalf("anonymous tile: %d", status)
	}
	// A phone that expects another key refuses the server.
	wrong := pinned(base64.StdEncoding.EncodeToString(make([]byte, 32)))
	if _, err := wrong.Get(api.URL + "/api/v1/health"); err == nil {
		t.Fatal("connected despite a pin mismatch")
	}

	if status, code := ana.call("PUT", "/api/v1/location", Position{Latitude: 1, Longitude: 2}, nil); status != 409 || code != "no_squad" {
		t.Fatalf("position without a squad: %d %s", status, code)
	}
	var squad SquadView
	if status, _ := ana.call("POST", "/api/v1/squads", map[string]string{"name": "Alpha"}, &squad); status != 201 || squad.LeaderID != got.DeviceID {
		t.Fatalf("create squad: %d %+v", status, squad)
	}
	if status, code := ana.call("POST", "/api/v1/squads", map[string]string{"name": "Beta"}, nil); status != 409 || code != "in_squad" {
		t.Fatalf("second squad: %d %s", status, code)
	}

	invite := func() string {
		var out struct {
			QR string `json:"qr_payload"`
		}
		if status, _ := ana.call("POST", "/api/v1/squad/invites", nil, &out); status != 201 {
			t.Fatalf("invite: %d", status)
		}
		return out.QR
	}
	qr := invite()
	if _, status, code := (&phone{t: t, base: api.URL}).pair(qr, "ana"); status != 409 || code != "name_taken" {
		t.Fatalf("duplicate name: %d %s", status, code)
	}
	ben := &phone{t: t, base: api.URL}
	joined, status, _ := ben.pair(qr, "Ben") // the refused attempt did not spend the invite
	if status != 200 || joined.Squad == nil || len(joined.Squad.Members) != 2 {
		t.Fatalf("join: %d %+v", status, joined)
	}

	alt := 120.5
	if status, _ := ana.call("PUT", "/api/v1/location", Position{Latitude: 47.6, Longitude: -122.3, Altitude: &alt}, nil); status != 204 {
		t.Fatalf("position: %d", status)
	}
	if status, code := ben.call("PUT", "/api/v1/location", Position{Latitude: 91}, nil); status != 400 || code != "bad_position" {
		t.Fatalf("bad position: %d %s", status, code)
	}
	var seen struct {
		Squad     SquadView
		Locations []Located
	}
	if status, _ := ben.call("GET", "/api/v1/squad/locations", nil, &seen); status != 200 || len(seen.Locations) != 1 ||
		seen.Locations[0].Name != "Ana" || seen.Locations[0].Stale || *seen.Locations[0].Altitude != alt {
		t.Fatalf("locations: %d %+v", status, seen)
	}
	s.state.now = func() time.Time { return time.Now().Add(6 * time.Minute) }
	ben.call("GET", "/api/v1/squad/locations", nil, &seen)
	if !seen.Locations[0].Stale || seen.Locations[0].Age < 360 {
		t.Fatalf("not stale after 6 minutes: %+v", seen.Locations[0])
	}
	s.state.now = time.Now

	var me struct {
		Squad *SquadView
		Tiles *struct{ Path string }
	}
	if status, _ := ben.call("GET", "/api/v1/me", nil, &me); status != 200 || me.Squad.Name != "Alpha" || me.Tiles == nil {
		t.Fatalf("me: %d %+v", status, me)
	}
	if status, _ := ben.call("GET", "/tiles/3/1/2.png", nil, nil); status != 200 {
		t.Fatalf("tile: %d", status)
	}
	if status, _ := ben.call("GET", "/tiles/3/1/9.png", nil, nil); status != 404 {
		t.Fatalf("missing tile: %d", status)
	}

	// The squad is capped (3 here), and survives its leader leaving.
	(&phone{t: t, base: api.URL}).pair(invite(), "Cy")
	if _, status, code := (&phone{t: t, base: api.URL}).pair(invite(), "Di"); status != 409 || code != "squad_full" {
		t.Fatalf("full squad: %d %s", status, code)
	}
	if status, _ := ana.call("POST", "/api/v1/squad/leave", nil, nil); status != 204 {
		t.Fatalf("leave: %d", status)
	}
	ben.call("GET", "/api/v1/me", nil, &me)
	if me.Squad.LeaderID != joined.DeviceID || len(me.Squad.Members) != 2 {
		t.Fatalf("after the leader left: %+v", me.Squad)
	}

	// Squads and members are on disk.
	reopened, err := openState(filepath.Join(dir, "squadz.json"), 3)
	if err != nil || reopened.Squad(squad.ID) == nil || len(reopened.Squad(squad.ID).Members) != 2 {
		t.Fatalf("reopened state: %v", err)
	}
}
