package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"flag"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"runtime/debug"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
)

const listenAddr = "0.0.0.0:8080"

// maxConfigBodyBytes caps PUT /config request bodies. 64 KiB is two orders of
// magnitude above the realistic payload (a content URL + a few enums) and
// keeps memory bounded if a client sends garbage.
const maxConfigBodyBytes = 64 << 10

// maxWSConnections is the per-server cap on simultaneously connected WS
// clients. Any further /ws upgrade attempts get a 503 BEFORE the upgrade,
// so a flood doesn't pin file descriptors. 64 is generous for the LAN
// "one tablet, a couple of operator browsers" deployment.
const maxWSConnections = 64

// wsWriteTimeout is the per-write deadline applied before every WS write.
// gorilla/websocket has no context-based API, so deadlines are set explicitly.
const wsWriteTimeout = 5 * time.Second

// wsReadTimeout is rolled forward after every successful read so dead clients
// don't pin a goroutine forever. Application-layer pings from the client (and
// any PUT-driven broadcast traffic) reset this implicitly via the read loop.
const wsReadTimeout = 60 * time.Second

// upgrader is the package-level gorilla upgrader. CheckOrigin is permissive
// for LAN-only deployment; M8 will revisit auth/origin policy.
var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	CheckOrigin:     func(r *http.Request) bool { return true },
}

// Config is the in-memory representation of the `/config` payload.
//
// `Brightness` and `ScreenTimeout` are stored as `json.RawMessage` so the
// server preserves whatever shape the operator pushed (`"auto"` / int /
// `"always-on"` / `"30s"`) without having to model the union types up front.
// Equality and marshalling fall out for free this way; the typed enforcement
// happens client-side in M7.
type Config struct {
	Content         string          `json:"content"`
	ContentRevision string          `json:"contentRevision"`
	Brightness      json.RawMessage `json:"brightness"`
	ScreenTimeout   json.RawMessage `json:"screenTimeout"`
}

// wsEnvelope is the wire shape for both directions over /ws. The `Config`
// field is only populated for `config_update` envelopes; clients ignore
// envelope types they don't recognise (forward compat — see plan.md L121).
type wsEnvelope struct {
	Type   string  `json:"type"`
	Config *Config `json:"config,omitempty"`
}

// hyacinthServer owns the mutable config + the set of connected WS clients.
// The two mutexes are deliberately separate: a slow WS write must not block
// `GET /config`, and a `PUT /config` should not be held up by a stuck client.
//
// `packsMu` serializes the entire pack-mutation pipeline (POST/DELETE) so
// the `data/packs/index.json` rewrite is race-free against concurrent
// uploads. Reads (GET) take it as well — the contention is negligible at
// LAN scale and it keeps the model simple.
type hyacinthServer struct {
	cfgMu  sync.RWMutex
	config Config

	connsMu sync.Mutex
	conns   map[*websocket.Conn]struct{}

	dataDir string
	packsMu sync.Mutex

	// authToken, if non-empty, gates every mutating endpoint behind a
	// `Authorization: Bearer <token>` header. Empty (the default) leaves
	// the LAN-friendly open mode in place.
	authToken string
}

// connCount returns the current size of the WS connection set. Test helper.
func (s *hyacinthServer) connCount() int {
	s.connsMu.Lock()
	defer s.connsMu.Unlock()
	return len(s.conns)
}

func newServer(dataDir string) *hyacinthServer {
	return &hyacinthServer{
		config: Config{
			Content:         "https://example.com",
			ContentRevision: "2026-04-07T10:15:00Z",
			Brightness:      json.RawMessage(`"auto"`),
			ScreenTimeout:   json.RawMessage(`"always-on"`),
		},
		conns:   make(map[*websocket.Conn]struct{}),
		dataDir: dataDir,
	}
}

// ErrorBody is the JSON shape returned by every error response. The
// `error` field is a stable code suitable for client-side branching, the
// `message` field is human-readable. Stable codes:
//
//	bad_request, not_found, payload_too_large, unauthorized,
//	internal_error, method_not_allowed, conflict, unsupported_media_type,
//	service_unavailable
type ErrorBody struct {
	Error   string `json:"error"`
	Message string `json:"message"`
}

// writeError emits a JSON error envelope with the given status. Replaces
// every http.Error call site so the client always sees a parseable body.
func writeError(w http.ResponseWriter, status int, code, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(ErrorBody{Error: code, Message: msg})
}

// logError is the shared per-handler error logger. Every error path passes
// through here so the format stays uniform across the codebase.
func logError(r *http.Request, code string, err error) {
	if err == nil {
		log.Printf("ERROR %s %s %s", r.Method, r.URL.Path, code)
		return
	}
	log.Printf("ERROR %s %s %s: %v", r.Method, r.URL.Path, code, err)
}

// recoverMiddleware wraps every handler in a panic recovery. The stack
// trace lands in the server log, the client gets a structured 500.
func recoverMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				log.Printf("PANIC %s %s: %v\n%s",
					r.Method, r.URL.Path, rec, debug.Stack())
				// If the handler already wrote headers, we can't change
				// them — but a JSON body afterward is still better than
				// a half-finished response.
				writeError(w, http.StatusInternalServerError,
					"internal_error", "internal server error")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// authMiddleware enforces the operator token on mutating endpoints when
// `s.authToken` is non-empty. Read endpoints (GET / HEAD / OPTIONS / WS
// upgrade) bypass the check entirely so the operator UI's `/config` GET
// and the tablet's `/ws` upgrade work without a header.
func (s *hyacinthServer) authMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.authToken == "" {
			next.ServeHTTP(w, r)
			return
		}
		// Read methods are always open. WS upgrades come in as GET so they
		// fall through here as well — by design, the tablet does not need
		// the token to subscribe to broadcasts.
		switch r.Method {
		case http.MethodGet, http.MethodHead, http.MethodOptions:
			next.ServeHTTP(w, r)
			return
		}
		hdr := r.Header.Get("Authorization")
		const prefix = "Bearer "
		if !strings.HasPrefix(hdr, prefix) {
			logError(r, "unauthorized", errors.New("missing bearer"))
			writeError(w, http.StatusUnauthorized,
				"unauthorized", "missing or invalid bearer token")
			return
		}
		got := []byte(hdr[len(prefix):])
		want := []byte(s.authToken)
		if subtle.ConstantTimeCompare(got, want) != 1 {
			logError(r, "unauthorized", errors.New("bad bearer"))
			writeError(w, http.StatusUnauthorized,
				"unauthorized", "missing or invalid bearer token")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// snapshot returns a copy of the current config under the read lock.
func (s *hyacinthServer) snapshot() Config {
	s.cfgMu.RLock()
	defer s.cfgMu.RUnlock()
	return s.config
}

// applyPut replaces the config with `next`, bumping `ContentRevision` to the
// current UTC ISO-8601 timestamp iff `Content` actually changed. Returns the
// stored config (post-mutation) so callers can echo it.
func (s *hyacinthServer) applyPut(next Config) Config {
	s.cfgMu.Lock()
	defer s.cfgMu.Unlock()
	prev := s.config
	if next.Content != prev.Content {
		next.ContentRevision = time.Now().UTC().Format(time.RFC3339Nano)
	} else {
		// Content unchanged: revision MUST stay pinned to prev so the
		// client-side reload guard can short-circuit.
		next.ContentRevision = prev.ContentRevision
	}
	if len(next.Brightness) == 0 {
		next.Brightness = prev.Brightness
	}
	if len(next.ScreenTimeout) == 0 {
		next.ScreenTimeout = prev.ScreenTimeout
	}
	s.config = next
	return s.config
}

// broadcast sends a `config_update` envelope to every connected client.
// Failed writes drop the offending connection. The connection-set mutex is
// held for the entire write loop, which doubles as the per-connection write
// serialization that gorilla/websocket requires (its *Conn is not safe for
// concurrent writes).
func (s *hyacinthServer) broadcast(cfg Config) {
	envelope := wsEnvelope{Type: "config_update", Config: &cfg}
	payload, err := json.Marshal(envelope)
	if err != nil {
		log.Printf("broadcast marshal: %v", err)
		return
	}
	s.connsMu.Lock()
	dead := make([]*websocket.Conn, 0)
	for c := range s.conns {
		_ = c.SetWriteDeadline(time.Now().Add(wsWriteTimeout))
		if err := c.WriteMessage(websocket.TextMessage, payload); err != nil {
			dead = append(dead, c)
		}
	}
	for _, c := range dead {
		delete(s.conns, c)
		_ = c.Close()
	}
	s.connsMu.Unlock()
}

func (s *hyacinthServer) registerConn(c *websocket.Conn) {
	s.connsMu.Lock()
	s.conns[c] = struct{}{}
	s.connsMu.Unlock()
}

func (s *hyacinthServer) unregisterConn(c *websocket.Conn) {
	s.connsMu.Lock()
	delete(s.conns, c)
	s.connsMu.Unlock()
}

func (s *hyacinthServer) handleConfig(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		snap := s.snapshot()
		body, err := json.Marshal(snap)
		if err != nil {
			logError(r, "internal_error", err)
			writeError(w, http.StatusInternalServerError,
				"internal_error", "encode config")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(body)
	case http.MethodPut:
		// Content-Type must be JSON (or unset, for legacy callers).
		ct := r.Header.Get("Content-Type")
		if ct != "" {
			// Strip parameters like "; charset=utf-8".
			base := ct
			if i := strings.Index(ct, ";"); i >= 0 {
				base = strings.TrimSpace(ct[:i])
			}
			if base != "application/json" {
				logError(r, "unsupported_media_type",
					errors.New("content-type "+ct))
				writeError(w, http.StatusUnsupportedMediaType,
					"unsupported_media_type",
					"Content-Type must be application/json")
				return
			}
		}
		// Cap the body so a malicious client can't hand us a 2 GiB JSON.
		r.Body = http.MaxBytesReader(w, r.Body, maxConfigBodyBytes)
		body, err := io.ReadAll(r.Body)
		if err != nil {
			// MaxBytesReader returns a *http.MaxBytesError on overflow on
			// modern Go versions; older versions surface "request body
			// too large". Match either.
			var mbe *http.MaxBytesError
			if errors.As(err, &mbe) ||
				strings.Contains(err.Error(), "request body too large") {
				logError(r, "payload_too_large", err)
				writeError(w, http.StatusRequestEntityTooLarge,
					"payload_too_large", "config body exceeds 64 KiB")
				return
			}
			logError(r, "bad_request", err)
			writeError(w, http.StatusBadRequest,
				"bad_request", "could not read request body")
			return
		}
		var next Config
		dec := json.NewDecoder(strings.NewReader(string(body)))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&next); err != nil {
			logError(r, "bad_request", err)
			writeError(w, http.StatusBadRequest,
				"bad_request", "invalid JSON: "+err.Error())
			return
		}
		if strings.TrimSpace(next.Content) == "" {
			logError(r, "bad_request", errors.New("missing content"))
			writeError(w, http.StatusBadRequest,
				"bad_request", "content field required")
			return
		}
		stored := s.applyPut(next)
		// Broadcast in a goroutine so we don't hold the request open while a
		// slow WS client drains. The handler returning before the broadcast
		// completes is acceptable: the next /config GET still reflects the
		// latest state.
		go s.broadcast(stored)
		out, err := json.Marshal(stored)
		if err != nil {
			logError(r, "internal_error", err)
			writeError(w, http.StatusInternalServerError,
				"internal_error", "encode config")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(out)
	default:
		w.Header().Set("Allow", "GET, PUT")
		writeError(w, http.StatusMethodNotAllowed,
			"method_not_allowed", "method not allowed")
	}
}

func (s *hyacinthServer) handleWS(w http.ResponseWriter, r *http.Request) {
	// Cap the connection set BEFORE upgrading so a flood doesn't pin
	// file descriptors. The check is racy by one connection — that's
	// fine; the cap is a backpressure signal, not a security boundary.
	s.connsMu.Lock()
	if len(s.conns) >= maxWSConnections {
		s.connsMu.Unlock()
		logError(r, "service_unavailable", errors.New("ws cap reached"))
		writeError(w, http.StatusServiceUnavailable,
			"service_unavailable", "ws connection cap reached")
		return
	}
	s.connsMu.Unlock()

	c, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		// gorilla writes the error response itself; we only log.
		log.Printf("ERROR %s %s ws_upgrade: %v", r.Method, r.URL.Path, err)
		return
	}
	defer c.Close()
	s.registerConn(c)
	defer s.unregisterConn(c)

	// Send the current config immediately so a fresh client doesn't have to
	// race a separate GET. We serialize the initial write under connsMu so it
	// can't race with a concurrent broadcast (gorilla *Conn is not safe for
	// concurrent writes).
	initial := s.snapshot()
	{
		envelope := wsEnvelope{Type: "config_update", Config: &initial}
		payload, _ := json.Marshal(envelope)
		s.connsMu.Lock()
		_ = c.SetWriteDeadline(time.Now().Add(wsWriteTimeout))
		writeErr := c.WriteMessage(websocket.TextMessage, payload)
		s.connsMu.Unlock()
		if writeErr != nil {
			return
		}
	}

	// Read loop: only thing we care about is `ping` -> `pong`. Everything
	// else (including unknown envelope types) is dropped. The read deadline
	// is rolled forward after every successful read so a silent client gets
	// reaped.
	_ = c.SetReadDeadline(time.Now().Add(wsReadTimeout))
	for {
		_, data, err := c.ReadMessage()
		if err != nil {
			return
		}
		_ = c.SetReadDeadline(time.Now().Add(wsReadTimeout))
		var env wsEnvelope
		if err := json.Unmarshal(data, &env); err != nil {
			continue
		}
		if env.Type == "ping" {
			pong, _ := json.Marshal(wsEnvelope{Type: "pong"})
			s.connsMu.Lock()
			_ = c.SetWriteDeadline(time.Now().Add(wsWriteTimeout))
			writeErr := c.WriteMessage(websocket.TextMessage, pong)
			s.connsMu.Unlock()
			if writeErr != nil {
				return
			}
		}
	}
}

// newMux builds the HTTP mux for the Hyacinth server. Exposed so tests can
// drive it via httptest.NewRecorder/NewServer without binding to a real
// port. Keep route registration here and only here so the test surface
// stays accurate.
// newMux returns the wrapped handler chain (recovery + auth + routes).
// Tests use this so they exercise the same middleware stack as production.
func newMux() http.Handler {
	srv := newServer("./data")
	return newMuxFor(srv)
}

func newMuxFor(srv *hyacinthServer) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/config", srv.handleConfig)
	mux.HandleFunc("/screen", srv.handleScreen)
	mux.HandleFunc("/ws", srv.handleWS)
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	})
	mux.HandleFunc("/packs", srv.handlePacks)
	mux.HandleFunc("/packs/", srv.handlePackByID)
	mux.HandleFunc("/", srv.handleIndex)
	return recoverMiddleware(srv.authMiddleware(mux))
}

// handleScreen accepts POST /screen with body `{"action":"on"|"off"}` and
// broadcasts a `screen_command` envelope to every connected WS client.
// The endpoint is imperative — it does NOT mutate `s.config`, so the next
// config push will not re-flip the screen. M8 authMiddleware gates it on
// POST automatically.
func (s *hyacinthServer) handleScreen(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		writeError(w, http.StatusMethodNotAllowed,
			"method_not_allowed", "method not allowed")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 1<<10)
	var req struct {
		Action string `json:"action"`
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		logError(r, "bad_request", err)
		writeError(w, http.StatusBadRequest,
			"bad_request", "invalid JSON: "+err.Error())
		return
	}
	if req.Action != "on" && req.Action != "off" {
		logError(r, "bad_request", errors.New("action must be on|off"))
		writeError(w, http.StatusBadRequest,
			"bad_request", "action must be \"on\" or \"off\"")
		return
	}
	go s.broadcastScreenCommand(req.Action)
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(`{"ok":true,"action":"` + req.Action + `"}`))
}

// broadcastScreenCommand sends a `screen_command` envelope to every WS
// client. Failed writes drop the offending connection (same pattern as
// broadcast()).
func (s *hyacinthServer) broadcastScreenCommand(action string) {
	payload, err := json.Marshal(struct {
		Type   string `json:"type"`
		Action string `json:"action"`
	}{Type: "screen_command", Action: action})
	if err != nil {
		log.Printf("broadcast screen marshal: %v", err)
		return
	}
	s.connsMu.Lock()
	dead := make([]*websocket.Conn, 0)
	for c := range s.conns {
		_ = c.SetWriteDeadline(time.Now().Add(wsWriteTimeout))
		if err := c.WriteMessage(websocket.TextMessage, payload); err != nil {
			dead = append(dead, c)
		}
	}
	for _, c := range dead {
		delete(s.conns, c)
		_ = c.Close()
	}
	s.connsMu.Unlock()
}

// handleIndex serves the inlined operator UI at GET /. Because "/" is a
// catch-all in http.ServeMux, this handler must 404 anything that isn't
// exactly "/".
func (s *hyacinthServer) handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		writeError(w, http.StatusNotFound, "not_found", "not found")
		return
	}
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		writeError(w, http.StatusMethodNotAllowed,
			"method_not_allowed", "method not allowed")
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write([]byte(indexHTML))
}

// indexHTML is the entire single-page operator UI. Material 3 styling via
// the official @material/web ESM bundle from esm.run, plus a hand-picked
// Hyacinth-purple Material You-style color token palette (light + dark).
// No build step, no framework, plain fetch() + WebSocket.
const indexHTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Hyacinth Operator</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,300;9..144,500;9..144,700;9..144,800&family=Inter:wght@300;400;500;600;700&display=swap" rel="stylesheet">
<!-- Material Symbols Outlined — required by every <md-icon> on the page.
     Without it, md-icon falls back to rendering the icon name as text. -->
<link href="https://fonts.googleapis.com/css2?family=Material+Symbols+Outlined:opsz,wght,FILL,GRAD@20..48,100..700,0..1,-50..200" rel="stylesheet">
<script type="importmap">
{
  "imports": {
    "@material/web/": "https://esm.run/@material/web/"
  }
}
</script>
<script type="module">
  import '@material/web/all.js';
  import {styles as typescaleStyles} from '@material/web/typography/md-typescale-styles.js';
  document.adoptedStyleSheets.push(typescaleStyles.styleSheet);
</script>
<style>
  /* Material 3 color tokens — Hyacinth purple primary seed. Light scheme. */
  :root {
    --md-sys-color-primary: #6750A4;
    --md-sys-color-on-primary: #FFFFFF;
    --md-sys-color-primary-container: #EADDFF;
    --md-sys-color-on-primary-container: #21005D;
    --md-sys-color-secondary: #625B71;
    --md-sys-color-on-secondary: #FFFFFF;
    --md-sys-color-secondary-container: #E8DEF8;
    --md-sys-color-on-secondary-container: #1D192B;
    --md-sys-color-tertiary: #7D5260;
    --md-sys-color-on-tertiary: #FFFFFF;
    --md-sys-color-background: #FEF7FF;
    --md-sys-color-on-background: #1D1B20;
    --md-sys-color-surface: #FEF7FF;
    --md-sys-color-on-surface: #1D1B20;
    --md-sys-color-surface-variant: #E7E0EC;
    --md-sys-color-on-surface-variant: #49454F;
    --md-sys-color-surface-dim: #DED8E1;
    --md-sys-color-surface-bright: #FEF7FF;
    --md-sys-color-surface-container-lowest: #FFFFFF;
    --md-sys-color-surface-container-low: #F7F2FA;
    --md-sys-color-surface-container: #F3EDF7;
    --md-sys-color-surface-container-high: #ECE6F0;
    --md-sys-color-surface-container-highest: #E6E0E9;
    --md-sys-color-outline: #79747E;
    --md-sys-color-outline-variant: #CAC4D0;
    --md-sys-color-inverse-surface: #322F35;
    --md-sys-color-inverse-on-surface: #F5EFF7;
    --md-sys-color-inverse-primary: #D0BCFF;
    --md-sys-color-error: #B3261E;
    --md-sys-color-on-error: #FFFFFF;
    --md-sys-color-error-container: #F9DEDC;
    --md-sys-color-on-error-container: #410E0B;
    --md-outlined-text-field-container-color: var(--md-sys-color-surface-container-highest);
    --md-outlined-select-text-field-container-color: var(--md-sys-color-surface-container-highest);
    --hy-status-good: #2E7D32;
    --hy-status-bad:  #B3261E;
    --hy-font-display: 'Fraunces', 'Times New Roman', serif;
    --hy-font-body:    'Inter', system-ui, -apple-system, sans-serif;
    --hy-ease-emph:    cubic-bezier(0.05, 0.7, 0.1, 1);
    --hy-shadow-2:     0 1px 2px rgba(0,0,0,0.10), 0 2px 6px rgba(0,0,0,0.08);
    --hy-shadow-3:     0 4px 8px rgba(0,0,0,0.12), 0 1px 3px rgba(0,0,0,0.10);
  }
  @media (prefers-color-scheme: dark) {
    :root {
      /* M3 baseline dark scheme, Hyacinth purple seed. */
      --md-sys-color-primary: #D0BCFF;
      --md-sys-color-on-primary: #381E72;
      --md-sys-color-primary-container: #4F378B;
      --md-sys-color-on-primary-container: #EADDFF;
      --md-sys-color-secondary: #CCC2DC;
      --md-sys-color-on-secondary: #332D41;
      --md-sys-color-secondary-container: #4A4458;
      --md-sys-color-on-secondary-container: #E8DEF8;
      --md-sys-color-tertiary: #EFB8C8;
      --md-sys-color-on-tertiary: #492532;
      --md-sys-color-background: #141218;
      --md-sys-color-on-background: #E6E0E9;
      --md-sys-color-surface: #141218;
      --md-sys-color-on-surface: #E6E0E9;
      --md-sys-color-surface-variant: #49454F;
      --md-sys-color-on-surface-variant: #CAC4D0;
      --md-sys-color-surface-dim: #141218;
      --md-sys-color-surface-bright: #3B383E;
      --md-sys-color-surface-container-lowest: #0F0D13;
      --md-sys-color-surface-container-low: #1D1B20;
      --md-sys-color-surface-container: #211F26;
      --md-sys-color-surface-container-high: #2B2930;
      --md-sys-color-surface-container-highest: #36343B;
      --md-sys-color-outline: #938F99;
      --md-sys-color-outline-variant: #49454F;
      --md-sys-color-inverse-surface: #E6E0E9;
      --md-sys-color-inverse-on-surface: #322F35;
      --md-sys-color-inverse-primary: #6750A4;
      --md-sys-color-error: #F2B8B5;
      --md-sys-color-on-error: #601410;
      --md-sys-color-error-container: #8C1D18;
      --md-sys-color-on-error-container: #F9DEDC;
      --hy-status-good: #81C784;
      --hy-status-bad:  #F2B8B5;
      --hy-shadow-2:    0 1px 2px rgba(0,0,0,0.40), 0 2px 6px rgba(0,0,0,0.30);
      --hy-shadow-3:    0 4px 10px rgba(0,0,0,0.50), 0 1px 3px rgba(0,0,0,0.40);
    }
  }
  * { box-sizing: border-box; }
  html, body {
    margin: 0;
    padding: 0;
    background: var(--md-sys-color-surface-container-lowest);
    color: var(--md-sys-color-on-surface);
    font-family: var(--hy-font-body);
    font-weight: 400;
    min-height: 100vh;
    -webkit-font-smoothing: antialiased;
    text-rendering: optimizeLegibility;
    /* Defensive: clip horizontal overflow at the document root so a
       single offending child element (e.g. a long status URL or a
       native control with locale-dependent intrinsic width) can't
       turn the whole page into a horizontally-scrolling mess. */
    overflow-x: clip;
  }
  /* Material Web text fields and selects are inline-flex by default
     and won't stretch to fill a grid/flex column without an explicit
     width. Without this, the Pack ID field on a phone keeps its
     intrinsic min-width and pushes the parent card past the viewport. */
  md-outlined-text-field,
  md-outlined-select {
    width: 100%;
  }

  /* ----- Sticky status bar ----- */
  .status-bar {
    position: sticky;
    top: 0;
    z-index: 10;
    display: flex;
    align-items: center;
    gap: 16px;
    padding: 10px 20px;
    background: var(--md-sys-color-surface-container-high);
    border-bottom: 1px solid var(--md-sys-color-outline-variant);
    box-shadow: var(--hy-shadow-2);
    backdrop-filter: saturate(180%) blur(6px);
  }
  .status-bar .host {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    font-size: 12px;
    font-weight: 500;
    color: var(--md-sys-color-on-surface-variant);
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
  }
  .status-bar .host .dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: var(--hy-status-bad);
    box-shadow: 0 0 0 3px color-mix(in oklab, var(--hy-status-bad) 25%, transparent);
    transition: background-color 200ms var(--hy-ease-emph),
                box-shadow 200ms var(--hy-ease-emph);
  }
  .status-bar.connected .host .dot {
    background: var(--hy-status-good);
    box-shadow: 0 0 0 3px color-mix(in oklab, var(--hy-status-good) 25%, transparent);
  }
  .status-bar .now-showing {
    flex: 1;
    min-width: 0;
    font-size: 12px;
    color: var(--md-sys-color-on-surface-variant);
    display: flex;
    align-items: center;
    gap: 8px;
    justify-content: center;
  }
  .status-bar .now-showing .label {
    text-transform: uppercase;
    letter-spacing: 0.08em;
    font-size: 10px;
    font-weight: 600;
    color: var(--md-sys-color-on-surface-variant);
    opacity: 0.7;
  }
  .status-bar .now-showing .value {
    font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
    font-size: 12px;
    color: var(--md-sys-color-on-surface);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    max-width: 100%;
    font-variant-numeric: tabular-nums;
  }
  .status-bar .spacer { flex: 0 0 auto; }

  /* ----- Page header ----- */
  .page-header {
    max-width: 1280px;
    margin: 0 auto;
    padding: 40px 24px 24px 24px;
  }
  .page-header h1 {
    margin: 0;
    font-family: var(--hy-font-display);
    font-weight: 800;
    font-size: clamp(36px, 6vw, 56px);
    letter-spacing: -0.02em;
    line-height: 1.02;
    color: var(--md-sys-color-on-surface);
    font-optical-sizing: auto;
  }
  .page-header .subtitle {
    margin-top: 8px;
    font-family: var(--hy-font-body);
    font-weight: 300;
    font-size: 14px;
    color: var(--md-sys-color-on-surface-variant);
    font-variant-numeric: tabular-nums;
  }

  /* ----- Grid of sections ----- */
  .grid {
    max-width: 1280px;
    margin: 0 auto;
    padding: 8px 24px 64px 24px;
    display: grid;
    grid-template-columns: 1fr;
    gap: 24px;
  }
  @media (min-width: 720px) {
    .grid {
      grid-template-columns: 1fr 1fr;
      grid-template-areas:
        "display packs"
        "power   packs"
        "live    packs";
    }
    .sect-display { grid-area: display; }
    .sect-power   { grid-area: power; }
    .sect-packs   { grid-area: packs; }
    .sect-live    { grid-area: live; }
  }
  @media (min-width: 1100px) {
    .grid {
      grid-template-columns: 1fr 1fr 1.4fr;
      grid-template-areas:
        "display power packs"
        "display live  packs";
    }
  }

  /* ----- Section cards ----- */
  .card {
    background: var(--md-sys-color-surface-container);
    border-radius: 20px;
    padding: 24px;
    display: flex;
    flex-direction: column;
    gap: 18px;
    min-width: 0;
    opacity: 0;
    transform: translateY(8px);
    animation: hy-rise 400ms var(--hy-ease-emph) forwards;
  }
  .sect-display { background: var(--md-sys-color-surface-container-high); animation-delay: 0ms; }
  .sect-power   { animation-delay: 60ms; }
  .sect-packs   { animation-delay: 120ms; }
  .sect-live    { animation-delay: 180ms; }
  @keyframes hy-rise {
    to { opacity: 1; transform: none; }
  }
  @media (prefers-reduced-motion: reduce) {
    .card { animation: none; opacity: 1; transform: none; }
  }
  .card .card-head {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: 12px;
  }
  .card h2 {
    margin: 0;
    font-family: var(--hy-font-display);
    font-weight: 500;
    font-size: 22px;
    letter-spacing: -0.01em;
    color: var(--md-sys-color-on-surface);
    font-optical-sizing: auto;
  }
  .card .card-hint {
    font-size: 11px;
    font-weight: 400;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: var(--md-sys-color-on-surface-variant);
  }

  /* ----- Form rows ----- */
  .row {
    display: flex;
    align-items: center;
    gap: 12px;
  }
  .row.between { justify-content: space-between; }
  .col { display: flex; flex-direction: column; gap: 10px; }
  .grow { flex: 1; min-width: 0; }
  md-outlined-text-field, md-outlined-select { width: 100%; }
  md-slider { flex: 1; }
  .actions {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
  }
  .field-label {
    font-size: 13px;
    font-weight: 500;
    color: var(--md-sys-color-on-surface-variant);
    letter-spacing: 0.01em;
  }
  .muted {
    font-size: 12px;
    color: var(--md-sys-color-on-surface-variant);
  }
  .brightness-row {
    display: flex;
    align-items: center;
    gap: 16px;
  }
  .brightness-value {
    font-family: var(--hy-font-body);
    font-weight: 600;
    font-size: 18px;
    font-variant-numeric: tabular-nums;
    min-width: 64px;
    text-align: right;
    color: var(--md-sys-color-on-surface);
    transition: color 200ms var(--hy-ease-emph);
  }
  .brightness-value.is-auto {
    font-family: var(--hy-font-display);
    font-weight: 700;
    font-size: 13px;
    letter-spacing: 0.12em;
    color: var(--md-sys-color-primary);
    text-transform: uppercase;
  }

  /* ----- Power section ----- */
  .power-buttons {
    display: flex;
    gap: 12px;
    flex-wrap: wrap;
  }
  .chip {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 6px 12px;
    border-radius: 9999px;
    background: var(--md-sys-color-secondary-container);
    color: var(--md-sys-color-on-secondary-container);
    font-size: 11px;
    font-weight: 500;
    letter-spacing: 0.02em;
    width: max-content;
    max-width: 100%;
  }

  /* ----- Live updates ----- */
  .conn-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
  }
  .conn-pill {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 6px 12px;
    border-radius: 9999px;
    background: var(--md-sys-color-surface-container-highest);
    color: var(--md-sys-color-on-surface);
    font-size: 12px;
    font-weight: 500;
  }
  .conn-pill .dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: var(--hy-status-bad);
    transition: background-color 200ms var(--hy-ease-emph);
  }
  .conn-pill.connected .dot { background: var(--hy-status-good); }
  .retry-hint {
    font-size: 11px;
    color: var(--md-sys-color-on-surface-variant);
    font-variant-numeric: tabular-nums;
  }
  .log {
    font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
    font-size: 11px;
    line-height: 1.5;
    background: var(--md-sys-color-surface-container-lowest);
    border: 1px solid var(--md-sys-color-outline-variant);
    border-radius: 12px;
    padding: 12px;
    max-height: 180px;
    overflow: auto;
    color: var(--md-sys-color-on-surface-variant);
    white-space: pre-wrap;
    word-break: break-all;
  }
  .log.empty {
    font-family: var(--hy-font-body);
    font-style: italic;
    color: var(--md-sys-color-on-surface-variant);
    opacity: 0.8;
  }

  /* ----- Packs ----- */
  .upload-form {
    display: grid;
    grid-template-columns: 1fr 140px;
    gap: 12px;
  }
  @media (max-width: 520px) {
    .upload-form { grid-template-columns: 1fr; }
  }
  .file-input-wrap {
    grid-column: 1 / -1;
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 12px 14px;
    border: 1px dashed var(--md-sys-color-outline-variant);
    border-radius: 12px;
    background: var(--md-sys-color-surface-container-low);
    color: var(--md-sys-color-on-surface-variant);
    font-size: 13px;
    cursor: pointer;
    min-width: 0;
  }
  .file-input-wrap:hover {
    background: var(--md-sys-color-surface-container);
  }
  .file-input-wrap md-icon {
    flex: 0 0 auto;
    color: var(--md-sys-color-primary);
  }
  .file-input-wrap .file-label {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  /* The native input is hidden but still functional — clicking the
     wrapping <label> opens the file picker, and our JS reads .files. */
  .file-input-wrap input[type="file"] {
    position: absolute;
    width: 1px;
    height: 1px;
    padding: 0;
    margin: -1px;
    overflow: hidden;
    clip: rect(0, 0, 0, 0);
    border: 0;
  }
  md-list#pack-list {
    --md-list-container-color: transparent;
    background: transparent;
    padding: 0;
    border-radius: 12px;
    overflow: hidden;
    border: 1px solid var(--md-sys-color-outline-variant);
  }
  md-list#pack-list md-list-item {
    --md-list-item-container-color: var(--md-sys-color-surface-container-low);
  }
  .pack-empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 8px;
    padding: 28px 16px;
    border: 1px dashed var(--md-sys-color-outline-variant);
    border-radius: 12px;
    color: var(--md-sys-color-on-surface-variant);
    background: var(--md-sys-color-surface-container-low);
  }
  /* The class rule above sets display:flex which would otherwise win
     against the user-agent [hidden]{display:none}. Restore the hidden
     semantics explicitly. Same defensive override for md-list. */
  .pack-empty[hidden],
  md-list[hidden] {
    display: none !important;
  }
  .pack-empty md-icon {
    font-size: 28px;
    --md-icon-size: 28px;
    opacity: 0.7;
  }
  .pack-empty .pack-empty-text {
    font-size: 13px;
    font-weight: 400;
  }

  /* ----- Toast ----- */
  .toast {
    position: fixed;
    right: 24px;
    bottom: 24px;
    min-width: 220px;
    max-width: calc(100vw - 48px);
    background: var(--md-sys-color-inverse-surface);
    color: var(--md-sys-color-inverse-on-surface);
    border-radius: 12px;
    padding: 14px 18px;
    font-size: 14px;
    font-weight: 500;
    box-shadow: var(--hy-shadow-3);
    opacity: 0;
    transform: translateY(24px);
    pointer-events: none;
    transition: opacity 300ms var(--hy-ease-emph),
                transform 300ms var(--hy-ease-emph);
    z-index: 1000;
  }
  .toast.show {
    opacity: 1;
    transform: translateY(0);
  }
  .toast.error {
    background: var(--md-sys-color-error-container);
    color: var(--md-sys-color-on-error-container);
  }
  @media (max-width: 520px) {
    .toast {
      left: 16px;
      right: 16px;
      bottom: 16px;
    }
  }

  /* ----- Stale / reload inline affordance ----- */
  .stale-reload {
    display: none;
  }
  .stale-reload.show { display: inline-flex; }
</style>
</head>
<body>
<div id="status-bar" class="status-bar">
  <div class="host">
    <span class="dot" id="conn-dot"></span>
    <span id="status-host">&mdash;</span>
  </div>
  <div class="now-showing">
    <span class="label">Now showing</span>
    <span class="value" id="status-content" title="">&mdash;</span>
  </div>
  <div class="spacer">
    <md-icon-button id="token-icon-btn" aria-label="Set operator token" title="Set operator token">
      <md-icon>key</md-icon>
    </md-icon-button>
  </div>
</div>

<header class="page-header">
  <h1>Hyacinth Operator</h1>
  <div class="subtitle" id="server-sub">&mdash;</div>
</header>

<main class="grid">
  <section class="card sect-display" aria-labelledby="h-display">
    <div class="card-head">
      <h2 id="h-display">Display</h2>
      <md-text-button id="reload-btn" class="stale-reload">Reload from server</md-text-button>
    </div>
    <md-outlined-text-field id="content-field" label="Content URL" type="url"></md-outlined-text-field>
    <div class="col">
      <div class="row between">
        <span class="field-label">Brightness</span>
        <div class="row" style="gap:8px;">
          <span class="muted">Auto</span>
          <md-switch id="auto-switch"></md-switch>
        </div>
      </div>
      <div class="brightness-row">
        <md-slider id="brightness-slider" min="0" max="100" step="1" labeled value="50"></md-slider>
        <span class="brightness-value" id="brightness-value">50</span>
      </div>
    </div>
    <md-outlined-select id="timeout-select" label="Screen Timeout">
      <md-select-option value="always-on"><div slot="headline">Always on</div></md-select-option>
      <md-select-option value="30s"><div slot="headline">30 seconds</div></md-select-option>
      <md-select-option value="1m"><div slot="headline">1 minute</div></md-select-option>
      <md-select-option value="5m"><div slot="headline">5 minutes</div></md-select-option>
      <md-select-option value="10m"><div slot="headline">10 minutes</div></md-select-option>
      <md-select-option value="30m"><div slot="headline">30 minutes</div></md-select-option>
    </md-outlined-select>
    <div class="actions">
      <md-filled-button id="save-btn">Save</md-filled-button>
    </div>
  </section>

  <section class="card sect-power" aria-labelledby="h-power">
    <div class="card-head">
      <h2 id="h-power">Power</h2>
      <span class="chip">Imperative &mdash; fires once and forgets</span>
    </div>
    <div class="power-buttons">
      <md-filled-button id="screen-on-btn">
        <md-icon slot="icon">light_mode</md-icon>
        Screen on
      </md-filled-button>
      <md-outlined-button id="screen-off-btn">
        <md-icon slot="icon">dark_mode</md-icon>
        Screen off
      </md-outlined-button>
    </div>
    <p class="muted" style="margin:0;">State isn&rsquo;t persisted &mdash; the tablet obeys immediately but the request isn&rsquo;t replayed on reconnect.</p>
  </section>

  <section class="card sect-live" aria-labelledby="h-live">
    <div class="card-head">
      <h2 id="h-live">Live updates</h2>
    </div>
    <div class="conn-row">
      <span class="conn-pill" id="conn-pill"><span class="dot"></span><span id="conn-text">disconnected</span></span>
      <span class="retry-hint" id="ws-retry"></span>
    </div>
    <div class="log empty" id="log">Waiting for the first config push&hellip;</div>
  </section>

  <section class="card sect-packs" aria-labelledby="h-packs">
    <div class="card-head">
      <h2 id="h-packs">Packs</h2>
    </div>
    <div class="upload-form">
      <md-outlined-text-field id="pack-id" label="Pack ID (slug)"></md-outlined-text-field>
      <label class="file-input-wrap">
        <md-icon>upload_file</md-icon>
        <span class="file-label" id="pack-file-label">Choose a file (zip or image)</span>
        <input type="file" id="pack-file" accept="application/zip,image/png,image/jpeg,image/webp,image/gif" />
      </label>
    </div>
    <md-list id="pack-list"></md-list>
    <div id="pack-empty" class="pack-empty" hidden>
      <md-icon>inventory_2</md-icon>
      <div class="pack-empty-text">No packs uploaded yet</div>
    </div>
  </section>
</main>

<div id="toast" class="toast" role="status" aria-live="polite"></div>

<script type="module">
  // ----- DOM handles -----
  const $ = (id) => document.getElementById(id);
  const statusBar    = $('status-bar');
  const statusHost   = $('status-host');
  const statusContent= $('status-content');
  const contentField = $('content-field');
  const autoSwitch   = $('auto-switch');
  const slider       = $('brightness-slider');
  const brightnessValue = $('brightness-value');
  const timeoutSel   = $('timeout-select');
  const saveBtn      = $('save-btn');
  const screenOffBtn = $('screen-off-btn');
  const screenOnBtn  = $('screen-on-btn');
  const connPill     = $('conn-pill');
  const connText     = $('conn-text');
  const wsRetry      = $('ws-retry');
  const logEl        = $('log');
  const toastEl      = $('toast');
  const reloadBtn    = $('reload-btn');
  const tokenBtn     = $('token-icon-btn');

  // Host text appears in both the sticky bar and the header subtitle.
  statusHost.textContent = location.host;
  $('server-sub').textContent = location.host;

  // ----- Operator auth token (M8) -----
  // Stored in localStorage and attached as Authorization: Bearer to every
  // mutating fetch. Read fetches go without — the server only enforces auth
  // on mutating verbs.
  const TOKEN_KEY = 'hyacinth.token';
  function getToken() { return localStorage.getItem(TOKEN_KEY) || ''; }
  function setToken(v) {
    if (v) { localStorage.setItem(TOKEN_KEY, v); }
    else { localStorage.removeItem(TOKEN_KEY); }
  }
  function authHeaders(extra) {
    const t = getToken();
    const h = Object.assign({}, extra || {});
    if (t) h['Authorization'] = 'Bearer ' + t;
    return h;
  }
  tokenBtn.addEventListener('click', () => {
    const cur = getToken();
    const next = window.prompt(
      'Operator token (leave blank to clear):',
      cur,
    );
    if (next === null) return;
    setToken(next.trim());
    toast(next.trim() ? 'Token saved' : 'Token cleared');
  });

  // ----- State -----
  let dirty = false;        // user has edited the form since last load
  let lastServerCfg = null; // most recent config_update payload
  let recentEvents = [];    // last 5 envelopes for the log
  let backoffMs = 1000;
  const BACKOFF_CAP = 10000;

  // ----- Form helpers -----
  function updateBrightnessValueLabel() {
    if (autoSwitch.selected) {
      brightnessValue.textContent = 'Auto';
      brightnessValue.classList.add('is-auto');
    } else {
      brightnessValue.textContent = String(slider.value);
      brightnessValue.classList.remove('is-auto');
    }
  }

  function updateStatusContent(url) {
    const v = url || '';
    statusContent.textContent = v || '\u2014';
    statusContent.title = v;
  }

  function applyConfigToForm(cfg) {
    contentField.value = cfg.content || '';
    updateStatusContent(cfg.content);
    const b = cfg.brightness;
    if (b === 'auto' || b === '"auto"') {
      autoSwitch.selected = true;
      slider.disabled = true;
    } else {
      autoSwitch.selected = false;
      slider.disabled = false;
      const n = typeof b === 'number' ? b : parseInt(b, 10);
      if (!Number.isNaN(n)) slider.value = n;
    }
    timeoutSel.value = (typeof cfg.screenTimeout === 'string')
      ? cfg.screenTimeout
      : 'always-on';
    dirty = false;
    reloadBtn.classList.remove('show');
    updateBrightnessValueLabel();
  }

  function buildPayload() {
    const brightness = autoSwitch.selected ? 'auto' : Number(slider.value);
    return {
      content: contentField.value,
      brightness,
      screenTimeout: timeoutSel.value || 'always-on',
    };
  }

  function markDirty() { dirty = true; }
  contentField.addEventListener('input', () => {
    markDirty();
    updateStatusContent(contentField.value);
  });
  slider.addEventListener('input', () => {
    markDirty();
    updateBrightnessValueLabel();
  });
  autoSwitch.addEventListener('change', () => {
    slider.disabled = autoSwitch.selected;
    markDirty();
    updateBrightnessValueLabel();
  });
  timeoutSel.addEventListener('change', markDirty);

  // ----- Imperative screen on/off (M9.1) -----
  async function sendScreen(action) {
    try {
      const r = await fetch('/screen', {
        method: 'POST',
        headers: authHeaders({'Content-Type': 'application/json'}),
        body: JSON.stringify({action}),
      });
      if (!r.ok) throw new Error('HTTP ' + r.status);
      toast('Screen ' + action + ' sent');
    } catch (e) {
      toast('Failed: ' + e.message, true);
    }
  }
  screenOffBtn.addEventListener('click', () => sendScreen('off'));
  screenOnBtn.addEventListener('click', () => sendScreen('on'));

  // ----- Toast -----
  let toastTimer = null;
  function toast(msg, isError) {
    toastEl.textContent = msg;
    toastEl.classList.toggle('error', !!isError);
    toastEl.classList.add('show');
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toastEl.classList.remove('show'), 3000);
  }

  // ----- Save -----
  // Extracted into a function so the pack-row "Use as content" action
  // can call it directly to push the new content URL without making
  // the operator click Save as a second step.
  async function saveConfig() {
    saveBtn.disabled = true;
    try {
      const r = await fetch('/config', {
        method: 'PUT',
        headers: authHeaders({'Content-Type': 'application/json'}),
        body: JSON.stringify(buildPayload()),
      });
      if (!r.ok) throw new Error('HTTP ' + r.status);
      const stored = await r.json();
      lastServerCfg = stored;
      applyConfigToForm(stored); // resets dirty
      toast('Saved');
      return true;
    } catch (e) {
      toast('Save failed: ' + e.message, true);
      return false;
    } finally {
      saveBtn.disabled = false;
    }
  }
  saveBtn.addEventListener('click', saveConfig);

  // ----- Initial GET /config -----
  async function loadInitial() {
    try {
      const r = await fetch('/config');
      if (!r.ok) throw new Error('HTTP ' + r.status);
      const cfg = await r.json();
      lastServerCfg = cfg;
      applyConfigToForm(cfg);
    } catch (e) {
      toast('Failed to load config: ' + e.message, true);
    }
  }

  // ----- WebSocket with reconnect -----
  let ws = null;
  function setConn(connected, retrying) {
    if (connected) {
      connPill.classList.add('connected');
      statusBar.classList.add('connected');
      connText.textContent = 'connected';
      wsRetry.textContent = '';
    } else {
      connPill.classList.remove('connected');
      statusBar.classList.remove('connected');
      connText.textContent = 'disconnected';
      wsRetry.textContent = retrying ? '(retrying\u2026)' : '';
    }
  }

  function pushLog(env) {
    recentEvents.unshift(env);
    if (recentEvents.length > 5) recentEvents.length = 5;
    logEl.classList.remove('empty');
    logEl.textContent = recentEvents
      .map((e) => JSON.stringify(e).slice(0, 240))
      .join('\n');
  }

  function connectWS() {
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const url = proto + '//' + location.host + '/ws';
    try {
      ws = new WebSocket(url);
    } catch (e) {
      scheduleReconnect();
      return;
    }
    ws.addEventListener('open', () => {
      backoffMs = 1000;
      setConn(true, false);
    });
    ws.addEventListener('close', () => {
      setConn(false, true);
      scheduleReconnect();
    });
    ws.addEventListener('error', () => { /* close handler will fire */ });
    ws.addEventListener('message', (ev) => {
      let env;
      try { env = JSON.parse(ev.data); } catch { return; }
      pushLog(env);
      if (env.type === 'config_update' && env.config) {
        lastServerCfg = env.config;
        if (!dirty) {
          applyConfigToForm(env.config);
        } else {
          reloadBtn.classList.add('show');
          // Don't clobber the user's edits, but keep the sticky bar honest.
          updateStatusContent(env.config.content);
        }
      }
    });
  }

  function scheduleReconnect() {
    setTimeout(() => {
      backoffMs = Math.min(BACKOFF_CAP, backoffMs * 2);
      connectWS();
    }, backoffMs);
  }

  reloadBtn.addEventListener('click', () => {
    if (lastServerCfg) applyConfigToForm(lastServerCfg);
  });

  // ----- Resource Packs (M5) -----
  const packIdField   = $('pack-id');
  // packTypeSel removed in M9.3 — type is now sniffed from the
  // uploaded file's MIME / extension via packTypeFromFile().
  const packFileInput = $('pack-file');
  const packFileLabel = $('pack-file-label');
  // packUploadBtn removed in M9.5 — uploads fire on file selection.
  const packListEl    = $('pack-list');
  const packEmptyEl   = $('pack-empty');

  // M9.5: picking a file triggers the upload immediately. The label
  // is updated transiently inside uploadPack() (Uploading… → reset).
  // The native file input is hidden via CSS so we manage all of its
  // user-facing affordance ourselves.
  packFileInput.addEventListener('change', function() {
    const f = packFileInput.files && packFileInput.files[0];
    if (!f) return;
    uploadPack(f);
  });

  function humanSize(n) {
    if (n < 1024) return n + ' B';
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KiB';
    return (n / (1024 * 1024)).toFixed(2) + ' MiB';
  }

  function packSchemeUrl(p) {
    // Zip packs always have an index.html entry point at the archive
    // root; image packs serve their single content file by name.
    const path = p.type === 'zip' ? 'index.html' : p.filename;
    return 'hyacinth://pack/' + p.id + '/' + path;
  }

  // M9.5: clicking the play_arrow on a pack row sets the content URL
  // AND immediately publishes the config — no second step. Same goes
  // for any other "promote this thing to live" action we might add.
  async function setContentToPackUrl(p) {
    contentField.value = packSchemeUrl(p);
    updateStatusContent(contentField.value);
    const ok = await saveConfig();
    if (ok) toast('Now showing ' + p.id);
  }

  async function deletePack(id) {
    if (!confirm('Delete pack "' + id + '"?')) return;
    try {
      const r = await fetch('/packs/' + encodeURIComponent(id), {method: 'DELETE', headers: authHeaders()});
      if (!r.ok && r.status !== 204) throw new Error('HTTP ' + r.status);
      toast('Deleted ' + id);
      loadPackList();
    } catch (e) {
      toast('Delete failed: ' + e.message, true);
    }
  }

  async function loadPackList() {
    try {
      const r = await fetch('/packs');
      if (!r.ok) throw new Error('HTTP ' + r.status);
      const arr = await r.json();
      renderPackList(arr || []);
    } catch (e) {
      toast('Pack list failed: ' + e.message, true);
    }
  }

  function makeIconButton(iconName, label, onClick) {
    const btn = document.createElement('md-icon-button');
    btn.setAttribute('aria-label', label);
    btn.setAttribute('title', label);
    const icon = document.createElement('md-icon');
    icon.textContent = iconName;
    btn.appendChild(icon);
    btn.addEventListener('click', onClick);
    return btn;
  }

  function renderPackList(packs) {
    packListEl.innerHTML = '';
    if (packs.length === 0) {
      packListEl.hidden = true;
      packEmptyEl.hidden = false;
      return;
    }
    packListEl.hidden = false;
    packEmptyEl.hidden = true;
    for (const p of packs) {
      const item = document.createElement('md-list-item');

      const leading = document.createElement('div');
      leading.setAttribute('slot', 'start');
      const leadingIcon = document.createElement('md-icon');
      leadingIcon.textContent = p.type === 'zip' ? 'folder_zip' : 'image';
      leading.appendChild(leadingIcon);

      const h = document.createElement('div');
      h.setAttribute('slot', 'headline');
      h.textContent = p.id;

      const s = document.createElement('div');
      s.setAttribute('slot', 'supporting-text');
      s.textContent = 'v' + p.version + '  \u00b7  ' + humanSize(p.size);

      const trailing = document.createElement('div');
      trailing.setAttribute('slot', 'end');
      trailing.style.display = 'flex';
      trailing.style.gap = '4px';
      trailing.appendChild(makeIconButton('play_arrow', 'Use as content', () => setContentToPackUrl(p)));
      trailing.appendChild(makeIconButton('delete', 'Delete pack', () => deletePack(p.id)));

      item.appendChild(leading);
      item.appendChild(h);
      item.appendChild(s);
      item.appendChild(trailing);
      packListEl.appendChild(item);
    }
  }

  // M9.3: derive the pack type from the file itself instead of
  // making the operator pick it. We honor the file's MIME first,
  // fall back to the extension.
  function packTypeFromFile(file) {
    var name = (file.name || '').toLowerCase();
    var mime = (file.type || '').toLowerCase();
    if (mime === 'application/zip' || name.endsWith('.zip')) return 'zip';
    if (mime === 'image/png' || name.endsWith('.png')) return 'png';
    if (mime === 'image/jpeg' || name.endsWith('.jpg') || name.endsWith('.jpeg')) return 'jpg';
    if (mime === 'image/webp' || name.endsWith('.webp')) return 'webp';
    if (mime === 'image/gif' || name.endsWith('.gif')) return 'gif';
    return null;
  }

  // M9.5: upload fires immediately on file selection — no separate
  // Upload button. The Pack ID must already be filled; if not, we
  // toast an error and clear the file selection so the user can
  // re-pick after entering an id.
  let uploading = false;
  async function uploadPack(file) {
    if (uploading) return;
    const id = (packIdField.value || '').trim();
    if (!id) {
      toast('Enter a pack id first', true);
      packFileInput.value = '';
      packFileLabel.textContent = 'Choose a file (zip or image)';
      return;
    }
    const type = packTypeFromFile(file);
    if (!type) {
      toast('Unsupported file type — pick a zip or an image', true);
      packFileInput.value = '';
      packFileLabel.textContent = 'Choose a file (zip or image)';
      return;
    }
    uploading = true;
    packFileLabel.textContent = 'Uploading ' + file.name + '\u2026';
    try {
      const fd = new FormData();
      fd.append('id', id);
      fd.append('type', type);
      fd.append('file', file);
      const r = await fetch('/packs', {method: 'POST', body: fd, headers: authHeaders()});
      if (!r.ok) throw new Error('HTTP ' + r.status + ' ' + (await r.text()));
      toast('Uploaded ' + id);
      packIdField.value = '';
      packFileInput.value = '';
      packFileLabel.textContent = 'Choose a file (zip or image)';
      loadPackList();
    } catch (e) {
      toast('Upload failed: ' + e.message, true);
      packFileLabel.textContent = 'Choose a file (zip or image)';
    } finally {
      uploading = false;
    }
  }

  // ----- Boot -----
  loadInitial().then(loadPackList).then(connectWS);
</script>
</body>
</html>
`

// startedAtomic is incremented every time main() actually starts a server.
// Currently only used for log clarity; exported as an atomic so future
// metrics scraping can read it without a mutex.
var startedAtomic atomic.Int64

func main() {
	addr := flag.String("addr", listenAddr, "listen address")
	dataDir := flag.String("data", "./data", "data directory")
	tokenFlag := flag.String("token", "", "operator bearer token (overrides HYACINTH_TOKEN)")
	flag.Parse()

	token := *tokenFlag
	if token == "" {
		token = os.Getenv("HYACINTH_TOKEN")
	}

	srv := newServer(*dataDir)
	srv.authToken = token

	if token == "" {
		log.Printf("WARNING: operator token not set; mutating endpoints are open on the LAN. " +
			"Set HYACINTH_TOKEN or pass -token to lock them down.")
	} else {
		log.Printf("operator token configured (%d bytes)", len(token))
	}

	httpSrv := &http.Server{
		Addr:              *addr,
		Handler:           newMuxFor(srv),
		ReadHeaderTimeout: 5 * time.Second,
		// Pack uploads can take a moment over Wi-Fi, so the body read
		// budget is generous. The 30s ceiling still protects us from
		// slowloris-style attacks holding a connection open for hours.
		ReadTimeout: 30 * time.Second,
		// 60s gives /packs/{id}/download room for ~50 MiB pack writes on
		// a slow LAN. Bump if production exposes a tighter floor.
		WriteTimeout: 60 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	startedAtomic.Add(1)
	log.Printf("hyacinth server listening on %s", *addr)

	// Graceful shutdown on SIGINT/SIGTERM so the WS connection set drains
	// cleanly and in-flight pack writes get a chance to finish.
	idleClosed := make(chan struct{})
	go func() {
		sigCh := make(chan os.Signal, 1)
		signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
		<-sigCh
		log.Printf("shutdown: draining...")
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := httpSrv.Shutdown(ctx); err != nil {
			log.Printf("shutdown error: %v", err)
		}
		close(idleClosed)
	}()

	if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
	<-idleClosed
}
