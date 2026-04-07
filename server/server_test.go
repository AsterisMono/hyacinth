package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
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

func TestPostConfigReturns405(t *testing.T) {
	mux := newMux()
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/config", nil)
	mux.ServeHTTP(rr, req)

	if rr.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want 405 (M3 will change this)", rr.Code)
	}
}

func TestUnknownPathReturns404(t *testing.T) {
	mux := newMux()
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/no-such-route", nil)
	mux.ServeHTTP(rr, req)

	if rr.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rr.Code)
	}
}
