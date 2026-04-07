package main

import (
	"log"
	"net/http"
)

const listenAddr = "0.0.0.0:8080"

// M0: hardcoded /config payload. Will become dynamic in later milestones.
const configJSON = `{
  "content": "https://example.com",
  "contentRevision": "2026-04-07T10:15:00Z",
  "brightness": "auto",
  "screenTimeout": "always-on"
}
`

// newMux builds the HTTP mux for the Hyacinth server. Exposed so tests can
// drive it via httptest.NewRecorder without binding to a real port. Keep
// route registration here and only here so the test surface stays accurate.
func newMux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/config", func(w http.ResponseWriter, r *http.Request) {
		// M2.5: only GET is supported. POST/PUT will arrive in M3 along
		// with the WebSocket reload guard, but until then we explicitly
		// reject them so client-side bugs don't silently no-op.
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", http.MethodGet)
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(configJSON))
	})
	// M2: simple liveness endpoint for the client's HealthCheck and
	// fallback "Test connection" button. Deliberately minimal.
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
