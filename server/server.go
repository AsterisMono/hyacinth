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
  /* Material 3 color tokens — Hyacinth purple primary (#7E57C2). */
  :root {
    --md-sys-color-primary: #6750A4;
    --md-sys-color-on-primary: #FFFFFF;
    --md-sys-color-primary-container: #EADDFF;
    --md-sys-color-on-primary-container: #21005D;
    --md-sys-color-secondary: #625B71;
    --md-sys-color-on-secondary: #FFFFFF;
    --md-sys-color-surface: #FEF7FF;
    --md-sys-color-on-surface: #1D1B20;
    --md-sys-color-surface-variant: #E7E0EC;
    --md-sys-color-on-surface-variant: #49454F;
    --md-sys-color-surface-container: #F3EDF7;
    --md-sys-color-surface-container-high: #ECE6F0;
    --md-sys-color-surface-container-highest: #E6E0E9;
    --md-sys-color-outline: #79747E;
    --md-sys-color-outline-variant: #CAC4D0;
    --md-sys-color-error: #B3261E;
    --md-sys-color-on-error: #FFFFFF;
    --hy-status-good: #2E7D32;
    --hy-status-bad:  #B3261E;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --md-sys-color-primary: #D0BCFF;
      --md-sys-color-on-primary: #381E72;
      --md-sys-color-primary-container: #4F378B;
      --md-sys-color-on-primary-container: #EADDFF;
      --md-sys-color-secondary: #CCC2DC;
      --md-sys-color-on-secondary: #332D41;
      --md-sys-color-surface: #141218;
      --md-sys-color-on-surface: #E6E0E9;
      --md-sys-color-surface-variant: #49454F;
      --md-sys-color-on-surface-variant: #CAC4D0;
      --md-sys-color-surface-container: #211F26;
      --md-sys-color-surface-container-high: #2B2930;
      --md-sys-color-surface-container-highest: #36343B;
      --md-sys-color-outline: #938F99;
      --md-sys-color-outline-variant: #49454F;
      --md-sys-color-error: #F2B8B5;
      --md-sys-color-on-error: #601410;
      --hy-status-good: #81C784;
      --hy-status-bad:  #F2B8B5;
    }
  }
  html, body {
    margin: 0;
    padding: 0;
    background: var(--md-sys-color-surface);
    color: var(--md-sys-color-on-surface);
    font-family: Roboto, system-ui, -apple-system, sans-serif;
    min-height: 100vh;
  }
  main {
    max-width: 640px;
    margin: 0 auto;
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 16px;
  }
  header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    padding: 8px 4px 0 4px;
  }
  header .titles h1 {
    margin: 0;
    font-size: 22px;
    font-weight: 500;
    color: var(--md-sys-color-on-surface);
  }
  header .titles .sub {
    font-size: 12px;
    color: var(--md-sys-color-on-surface-variant);
  }
  .pill {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 6px 12px;
    border-radius: 9999px;
    background: var(--md-sys-color-surface-container-high);
    color: var(--md-sys-color-on-surface);
    font-size: 12px;
    border: 1px solid var(--md-sys-color-outline-variant);
  }
  .pill .dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: var(--hy-status-bad);
  }
  .pill.connected .dot { background: var(--hy-status-good); }
  .card {
    background: var(--md-sys-color-surface-container);
    border-radius: 16px;
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 16px;
    border: 1px solid var(--md-sys-color-outline-variant);
  }
  .card h2 {
    margin: 0;
    font-size: 16px;
    font-weight: 500;
    color: var(--md-sys-color-on-surface);
  }
  .row {
    display: flex;
    align-items: center;
    gap: 12px;
  }
  .row.between { justify-content: space-between; }
  .grow { flex: 1; }
  md-outlined-text-field, md-outlined-select { width: 100%; }
  md-slider { flex: 1; }
  .actions {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
  }
  .log {
    font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
    font-size: 11px;
    background: var(--md-sys-color-surface-container-highest);
    border-radius: 8px;
    padding: 8px;
    max-height: 160px;
    overflow: auto;
    color: var(--md-sys-color-on-surface-variant);
    white-space: pre-wrap;
    word-break: break-all;
  }
  .toast {
    position: fixed;
    left: 50%;
    bottom: 24px;
    transform: translateX(-50%) translateY(40px);
    background: var(--md-sys-color-surface-container-highest);
    color: var(--md-sys-color-on-surface);
    border: 1px solid var(--md-sys-color-outline-variant);
    border-radius: 8px;
    padding: 12px 16px;
    font-size: 14px;
    box-shadow: 0 4px 16px rgba(0,0,0,0.18);
    opacity: 0;
    pointer-events: none;
    transition: opacity 200ms ease, transform 200ms ease;
    z-index: 1000;
    max-width: calc(100vw - 32px);
  }
  .toast.show {
    opacity: 1;
    transform: translateX(-50%) translateY(0);
  }
  .toast.error {
    border-color: var(--md-sys-color-error);
    color: var(--md-sys-color-error);
  }
  .stale-banner {
    display: none;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    padding: 10px 12px;
    border-radius: 8px;
    background: var(--md-sys-color-primary-container);
    color: var(--md-sys-color-on-primary-container);
    font-size: 13px;
  }
  .stale-banner.show { display: flex; }
  .placeholder {
    font-size: 13px;
    color: var(--md-sys-color-on-surface-variant);
    font-style: italic;
  }
</style>
</head>
<body>
<main>
  <header>
    <div class="titles">
      <h1>Hyacinth Operator</h1>
      <div class="sub" id="server-sub"></div>
    </div>
    <div class="row" style="gap:8px;">
      <md-text-button id="token-btn" style="--md-text-button-label-text-size:11px;">Token</md-text-button>
      <span class="pill" id="conn-pill"><span class="dot"></span><span id="conn-text">disconnected</span></span>
    </div>
  </header>

  <section class="card">
    <h2>Current Config</h2>
    <div id="stale-banner" class="stale-banner">
      <span>Server changed config since you started editing.</span>
      <md-text-button id="reload-btn">Reload</md-text-button>
    </div>
    <md-outlined-text-field id="content-field" label="Content URL" type="url"></md-outlined-text-field>
    <div>
      <div class="row between">
        <label for="auto-switch" style="font-size:14px;">Brightness</label>
        <div class="row">
          <span style="font-size:12px;color:var(--md-sys-color-on-surface-variant);">Auto</span>
          <md-switch id="auto-switch"></md-switch>
        </div>
      </div>
      <div class="row" style="margin-top:8px;">
        <md-slider id="brightness-slider" min="0" max="100" step="1" labeled value="50"></md-slider>
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

  <section class="card">
    <h2>Live Updates</h2>
    <div class="row between">
      <span style="font-size:13px;color:var(--md-sys-color-on-surface-variant);" id="ws-status">disconnected</span>
      <span style="font-size:11px;color:var(--md-sys-color-on-surface-variant);" id="ws-retry"></span>
    </div>
    <div class="log" id="log">(no events yet)</div>
  </section>

  <section class="card">
    <h2>Resource Packs</h2>
    <div class="row" style="flex-wrap:wrap;gap:8px;">
      <md-outlined-text-field id="pack-id" label="Pack ID (slug)" style="flex:1;min-width:140px;"></md-outlined-text-field>
      <md-outlined-select id="pack-type" label="Type" style="flex:0 0 140px;">
        <md-select-option value="png" selected><div slot="headline">png</div></md-select-option>
        <md-select-option value="jpg"><div slot="headline">jpg</div></md-select-option>
        <md-select-option value="webp"><div slot="headline">webp</div></md-select-option>
        <md-select-option value="gif"><div slot="headline">gif</div></md-select-option>
        <md-select-option value="zip"><div slot="headline">zip</div></md-select-option>
      </md-outlined-select>
    </div>
    <input type="file" id="pack-file" accept="application/zip,image/png,image/jpeg,image/webp,image/gif" />
    <div class="actions">
      <md-filled-button id="pack-upload-btn">Upload</md-filled-button>
    </div>
    <md-list id="pack-list">
      <md-list-item disabled>
        <div slot="headline">No packs yet</div>
        <div slot="supporting-text">Upload an image above to get started.</div>
      </md-list-item>
    </md-list>
  </section>
</main>

<div id="toast" class="toast"></div>

<script type="module">
  // ----- DOM handles -----
  const $ = (id) => document.getElementById(id);
  const contentField = $('content-field');
  const autoSwitch   = $('auto-switch');
  const slider       = $('brightness-slider');
  const timeoutSel   = $('timeout-select');
  const saveBtn      = $('save-btn');
  const connPill     = $('conn-pill');
  const connText     = $('conn-text');
  const wsStatus     = $('ws-status');
  const wsRetry      = $('ws-retry');
  const logEl        = $('log');
  const toastEl      = $('toast');
  const staleBanner  = $('stale-banner');
  const reloadBtn    = $('reload-btn');

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
  $('token-btn').addEventListener('click', () => {
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
  function applyConfigToForm(cfg) {
    contentField.value = cfg.content || '';
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
    staleBanner.classList.remove('show');
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
  contentField.addEventListener('input', markDirty);
  slider.addEventListener('input', markDirty);
  autoSwitch.addEventListener('change', () => {
    slider.disabled = autoSwitch.selected;
    markDirty();
  });
  timeoutSel.addEventListener('change', markDirty);

  // ----- Toast -----
  let toastTimer = null;
  function toast(msg, isError) {
    toastEl.textContent = msg;
    toastEl.classList.toggle('error', !!isError);
    toastEl.classList.add('show');
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toastEl.classList.remove('show'), 2400);
  }

  // ----- Save -----
  saveBtn.addEventListener('click', async () => {
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
    } catch (e) {
      toast('Save failed: ' + e.message, true);
    } finally {
      saveBtn.disabled = false;
    }
  });

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
      connText.textContent = 'connected';
      wsStatus.textContent = 'connected';
      wsRetry.textContent = '';
    } else {
      connPill.classList.remove('connected');
      connText.textContent = 'disconnected';
      wsStatus.textContent = 'disconnected';
      wsRetry.textContent = retrying ? '(retrying...)' : '';
    }
  }

  function pushLog(env) {
    recentEvents.unshift(env);
    if (recentEvents.length > 5) recentEvents.length = 5;
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
          staleBanner.classList.add('show');
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
  const packTypeSel   = $('pack-type');
  const packFileInput = $('pack-file');
  const packUploadBtn = $('pack-upload-btn');
  const packListEl    = $('pack-list');

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

  function renderPackList(packs) {
    packListEl.innerHTML = '';
    if (packs.length === 0) {
      const item = document.createElement('md-list-item');
      item.setAttribute('disabled', '');
      const h = document.createElement('div'); h.setAttribute('slot', 'headline'); h.textContent = 'No packs yet';
      const s = document.createElement('div'); s.setAttribute('slot', 'supporting-text'); s.textContent = 'Upload an image above to get started.';
      item.appendChild(h); item.appendChild(s);
      packListEl.appendChild(item);
      return;
    }
    for (const p of packs) {
      const item = document.createElement('md-list-item');
      const h = document.createElement('div');
      h.setAttribute('slot', 'headline');
      h.textContent = p.id + '  v' + p.version + '  (' + p.type + ')';
      const s = document.createElement('div');
      s.setAttribute('slot', 'supporting-text');
      s.textContent = humanSize(p.size) + '  ·  ' + p.createdAt;
      const trailing = document.createElement('div');
      trailing.setAttribute('slot', 'end');
      trailing.style.display = 'flex';
      trailing.style.gap = '4px';
      const useBtn = document.createElement('md-text-button');
      useBtn.textContent = 'Use as content';
      useBtn.addEventListener('click', () => {
        contentField.value = packSchemeUrl(p);
        markDirty();
        toast('Set content URL — click Save to push.');
      });
      const delBtn = document.createElement('md-text-button');
      delBtn.textContent = 'Delete';
      delBtn.addEventListener('click', async () => {
        if (!confirm('Delete pack "' + p.id + '"?')) return;
        try {
          const r = await fetch('/packs/' + encodeURIComponent(p.id), {method: 'DELETE', headers: authHeaders()});
          if (!r.ok && r.status !== 204) throw new Error('HTTP ' + r.status);
          toast('Deleted ' + p.id);
          loadPackList();
        } catch (e) {
          toast('Delete failed: ' + e.message, true);
        }
      });
      trailing.appendChild(useBtn);
      trailing.appendChild(delBtn);
      item.appendChild(h);
      item.appendChild(s);
      item.appendChild(trailing);
      packListEl.appendChild(item);
    }
  }

  packUploadBtn.addEventListener('click', async () => {
    const id = (packIdField.value || '').trim();
    const type = packTypeSel.value || 'png';
    const file = packFileInput.files && packFileInput.files[0];
    if (!id) { toast('Enter a pack id', true); return; }
    if (!file) { toast('Choose a file', true); return; }
    packUploadBtn.disabled = true;
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
      loadPackList();
    } catch (e) {
      toast('Upload failed: ' + e.message, true);
    } finally {
      packUploadBtn.disabled = false;
    }
  });

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
