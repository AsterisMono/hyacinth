package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestGetConfigReturnsJSON(t *testing.T) {
	mux := newMux()
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/config", nil)
	mux.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
	if ct := rr.Header().Get("Content-Type"); ct != "application/json" {
		t.Fatalf("Content-Type = %q, want application/json", ct)
	}
	var payload map[string]any
	if err := json.Unmarshal(rr.Body.Bytes(), &payload); err != nil {
		t.Fatalf("body is not valid JSON: %v\nbody: %s", err, rr.Body.String())
	}
	for _, key := range []string{"content", "contentRevision", "brightness", "screenTimeout"} {
		if _, ok := payload[key]; !ok {
			t.Errorf("missing key %q in /config payload", key)
		}
	}
}

func TestGetHealthReturnsOK(t *testing.T) {
	mux := newMux()
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	mux.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
	var payload map[string]any
	if err := json.Unmarshal(rr.Body.Bytes(), &payload); err != nil {
		t.Fatalf("body is not valid JSON: %v\nbody: %s", err, rr.Body.String())
	}
	if ok, _ := payload["ok"].(bool); !ok {
		t.Errorf("expected {\"ok\":true}, got %s", rr.Body.String())
	}
}

// PUT with new content bumps the revision and returns the stored config.
func TestPutConfigBumpsRevisionWhenContentChanges(t *testing.T) {
	srv := newServer(t.TempDir())
	mux := newMuxFor(srv)
	prevRev := srv.snapshot().ContentRevision

	body := `{"content":"https://new.example.com","brightness":50,"screenTimeout":"30s"}`
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPut, "/config",
		strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	mux.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rr.Code, rr.Body.String())
	}
	var got Config
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("invalid response JSON: %v", err)
	}
	if got.Content != "https://new.example.com" {
		t.Errorf("content = %q, want updated", got.Content)
	}
	if got.ContentRevision == "" {
		t.Errorf("ContentRevision empty after content change")
	}
	if got.ContentRevision == prevRev {
		t.Errorf("ContentRevision = %q unchanged after content change",
			got.ContentRevision)
	}
	if string(got.Brightness) != "50" {
		t.Errorf("Brightness = %s, want 50", string(got.Brightness))
	}
}

// PUT that only changes brightness MUST NOT bump the content revision —
// this is the server-side half of the M3 reload guard.
func TestPutConfigDoesNotBumpRevisionWhenContentUnchanged(t *testing.T) {
	srv := newServer(t.TempDir())
	mux := newMuxFor(srv)
	initial := srv.snapshot()

	body := `{"content":"` + initial.Content + `","brightness":42,"screenTimeout":"always-on"}`
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPut, "/config",
		strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	mux.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rr.Code, rr.Body.String())
	}
	var got Config
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("invalid response JSON: %v", err)
	}
	if got.ContentRevision != initial.ContentRevision {
		t.Errorf("ContentRevision = %q, want unchanged %q",
			got.ContentRevision, initial.ContentRevision)
	}
	if string(got.Brightness) != "42" {
		t.Errorf("Brightness = %s, want 42", string(got.Brightness))
	}
}

func TestPutConfigInvalidJSON(t *testing.T) {
	mux := newMux()
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPut, "/config",
		strings.NewReader("{not json"))
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rr.Code)
	}
}

func TestConfigRejectsUnknownMethod(t *testing.T) {
	mux := newMux()
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodDelete, "/config", nil)
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want 405", rr.Code)
	}
}

func TestUnknownPathReturns404(t *testing.T) {
	mux := newMux()
	for _, path := range []string{"/no-such-route", "/some/random/path", "/notarealpath"} {
		rr := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, path, nil)
		mux.ServeHTTP(rr, req)
		if rr.Code != http.StatusNotFound {
			t.Errorf("GET %s: status = %d, want 404", path, rr.Code)
		}
	}
}

func TestGetIndexReturnsHTML(t *testing.T) {
	mux := newMux()
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	mux.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
	ct := rr.Header().Get("Content-Type")
	if !strings.HasPrefix(ct, "text/html") {
		t.Fatalf("Content-Type = %q, want text/html...", ct)
	}
	body := rr.Body.String()
	musts := []string{
		"<title>Hyacinth Operator</title>",
		`<script type="importmap">`,
		"@material/web/",
		"md-filled-button",
		"md-outlined-text-field",
		"md-slider",
		"md-switch",
		"md-outlined-select",
		"md-list",
		"--md-sys-color-primary",
		"fetch('/config'",
		// M9.2 redesign pins: sticky status bar and the display-face font.
		`id="status-bar"`,
		"Fraunces",
	}
	for _, m := range musts {
		if !strings.Contains(body, m) {
			t.Errorf("index HTML missing %q", m)
		}
	}
	// Light + dark token blocks: --md-sys-color-primary defined twice.
	if c := strings.Count(body, "--md-sys-color-primary:"); c < 2 {
		t.Errorf("--md-sys-color-primary defined %d times, want >= 2 (light+dark)", c)
	}
}

func TestGetIndexHasNoStoreCache(t *testing.T) {
	mux := newMux()
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	mux.ServeHTTP(rr, req)
	if got := rr.Header().Get("Cache-Control"); got != "no-store" {
		t.Errorf("Cache-Control = %q, want no-store", got)
	}
}

// End-to-end WS test: connect, expect the initial config_update envelope,
// then trigger a PUT /config from the test and assert the WS client receives
// the second config_update envelope.
func TestWebSocketBroadcastsOnPut(t *testing.T) {
	srv := newServer(t.TempDir())
	ts := httptest.NewServer(newMuxFor(srv))
	defer ts.Close()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws"
	deadline := time.Now().Add(5 * time.Second)

	c, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("ws dial: %v", err)
	}
	defer c.Close()
	_ = c.SetReadDeadline(deadline)
	_ = c.SetWriteDeadline(deadline)

	// 1. Initial envelope.
	_, data, err := c.ReadMessage()
	if err != nil {
		t.Fatalf("first read: %v", err)
	}
	var env wsEnvelope
	if err := json.Unmarshal(data, &env); err != nil {
		t.Fatalf("first envelope JSON: %v", err)
	}
	if env.Type != "config_update" {
		t.Errorf("first envelope type = %q, want config_update", env.Type)
	}
	if env.Config == nil || env.Config.Content == "" {
		t.Errorf("first envelope config missing or empty: %+v", env)
	}

	// 2. Trigger a PUT and expect the broadcast.
	body := `{"content":"https://broadcast.example.com","brightness":"auto","screenTimeout":"always-on"}`
	resp, err := http.DefaultClient.Do(mustNewRequest(t,
		http.MethodPut, ts.URL+"/config", body))
	if err != nil {
		t.Fatalf("put: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("put status = %d", resp.StatusCode)
	}

	_, data, err = c.ReadMessage()
	if err != nil {
		t.Fatalf("second read: %v", err)
	}
	if err := json.Unmarshal(data, &env); err != nil {
		t.Fatalf("second envelope JSON: %v", err)
	}
	if env.Type != "config_update" {
		t.Errorf("second envelope type = %q, want config_update", env.Type)
	}
	if env.Config == nil || env.Config.Content != "https://broadcast.example.com" {
		t.Errorf("second envelope content mismatch: %+v", env.Config)
	}
}

// `ping` envelopes get a `pong` reply.
func TestWebSocketPingPong(t *testing.T) {
	srv := newServer(t.TempDir())
	ts := httptest.NewServer(newMuxFor(srv))
	defer ts.Close()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws"
	deadline := time.Now().Add(5 * time.Second)

	c, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("ws dial: %v", err)
	}
	defer c.Close()
	_ = c.SetReadDeadline(deadline)
	_ = c.SetWriteDeadline(deadline)

	// Drain initial config_update.
	if _, _, err := c.ReadMessage(); err != nil {
		t.Fatalf("drain: %v", err)
	}

	if err := c.WriteMessage(websocket.TextMessage, []byte(`{"type":"ping"}`)); err != nil {
		t.Fatalf("write ping: %v", err)
	}
	_, data, err := c.ReadMessage()
	if err != nil {
		t.Fatalf("read pong: %v", err)
	}
	var env wsEnvelope
	if err := json.Unmarshal(data, &env); err != nil {
		t.Fatalf("pong JSON: %v", err)
	}
	if env.Type != "pong" {
		t.Errorf("envelope type = %q, want pong", env.Type)
	}
}

func mustNewRequest(t *testing.T, method, url, body string) *http.Request {
	t.Helper()
	req, err := http.NewRequest(method, url, strings.NewReader(body))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	return req
}
