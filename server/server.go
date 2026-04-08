package main

import (
	"context"
	"crypto/subtle"
	_ "embed"
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

// indexHTML is the operator UI HTML, embedded at build time from operator.html
// so server.go reads as Go and the HTML can be edited as HTML. See plan.md M14.
//
//go:embed operator.html
var indexHTML string

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
