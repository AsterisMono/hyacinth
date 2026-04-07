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

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/config", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(configJSON))
	})

	log.Printf("hyacinth server listening on %s", listenAddr)
	if err := http.ListenAndServe(listenAddr, mux); err != nil {
		log.Fatal(err)
	}
}
