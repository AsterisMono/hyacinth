package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"time"

	"nhooyr.io/websocket"
)

const listenAddr = "0.0.0.0:8080"

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
type hyacinthServer struct {
	cfgMu  sync.RWMutex
	config Config

	connsMu sync.Mutex
	conns   map[*websocket.Conn]struct{}
}

func newServer() *hyacinthServer {
	return &hyacinthServer{
		config: Config{
			Content:         "https://example.com",
			ContentRevision: "2026-04-07T10:15:00Z",
			Brightness:      json.RawMessage(`"auto"`),
			ScreenTimeout:   json.RawMessage(`"always-on"`),
		},
		conns: make(map[*websocket.Conn]struct{}),
	}
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
// Failed writes drop the offending connection.
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
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		if err := c.Write(ctx, websocket.MessageText, payload); err != nil {
			dead = append(dead, c)
		}
		cancel()
	}
	for _, c := range dead {
		delete(s.conns, c)
		_ = c.Close(websocket.StatusInternalError, "write failed")
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
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(s.snapshot())
	case http.MethodPut:
		var next Config
		if err := json.NewDecoder(r.Body).Decode(&next); err != nil {
			http.Error(w, "invalid JSON: "+err.Error(), http.StatusBadRequest)
			return
		}
		stored := s.applyPut(next)
		// Broadcast in a goroutine so we don't hold the request open while a
		// slow WS client drains. The handler returning before the broadcast
		// completes is acceptable: the next /config GET still reflects the
		// latest state.
		go s.broadcast(stored)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(stored)
	default:
		w.Header().Set("Allow", "GET, PUT")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *hyacinthServer) handleWS(w http.ResponseWriter, r *http.Request) {
	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		// LAN-only deployment; OriginPatterns is not enforced. M8 will add
		// proper auth on top.
		InsecureSkipVerify: true,
	})
	if err != nil {
		log.Printf("ws accept: %v", err)
		return
	}
	defer c.Close(websocket.StatusNormalClosure, "bye")
	s.registerConn(c)
	defer s.unregisterConn(c)

	// Send the current config immediately so a fresh client doesn't have to
	// race a separate GET.
	initial := s.snapshot()
	{
		envelope := wsEnvelope{Type: "config_update", Config: &initial}
		payload, _ := json.Marshal(envelope)
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		err := c.Write(ctx, websocket.MessageText, payload)
		cancel()
		if err != nil {
			return
		}
	}

	// Read loop: only thing we care about is `ping` -> `pong`. Everything
	// else (including unknown envelope types) is dropped.
	for {
		_, data, err := c.Read(r.Context())
		if err != nil {
			return
		}
		var env wsEnvelope
		if err := json.Unmarshal(data, &env); err != nil {
			continue
		}
		if env.Type == "ping" {
			pong, _ := json.Marshal(wsEnvelope{Type: "pong"})
			ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
			err := c.Write(ctx, websocket.MessageText, pong)
			cancel()
			if err != nil {
				return
			}
		}
	}
}

// newMux builds the HTTP mux for the Hyacinth server. Exposed so tests can
// drive it via httptest.NewRecorder/NewServer without binding to a real
// port. Keep route registration here and only here so the test surface
// stays accurate.
func newMux() *http.ServeMux {
	srv := newServer()
	return newMuxFor(srv)
}

func newMuxFor(srv *hyacinthServer) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/config", srv.handleConfig)
	mux.HandleFunc("/ws", srv.handleWS)
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	})
	return mux
}

func main() {
	log.Printf("hyacinth server listening on %s", listenAddr)
	if err := http.ListenAndServe(listenAddr, newMux()); err != nil {
		log.Fatal(err)
	}
}
