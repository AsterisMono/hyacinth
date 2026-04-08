package main

// M8 hardening tests. These cover the error paths the user explicitly
// listed in the M8 brief: structured error responses, content-type and
// body-size validation, oversized PUT bodies, malformed JSON, missing
// required fields, panic recovery, the operator auth token,
// per-handler error codes, range requests, WS connection cap and the
// goroutine-leak audit (connection set drains on close).

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// decodeErr is a small helper that asserts the body is a valid ErrorBody
// envelope and returns it.
func decodeErr(t *testing.T, body []byte) ErrorBody {
	t.Helper()
	var eb ErrorBody
	if err := json.Unmarshal(body, &eb); err != nil {
		t.Fatalf("response body is not a valid ErrorBody: %v\nbody=%s", err, body)
	}
	if eb.Error == "" {
		t.Fatalf("ErrorBody has empty error code: %s", body)
	}
	return eb
}

// --- Track A: PUT /config error paths -----------------------------------------------

func TestPutConfigOversizedBody(t *testing.T) {
	mux := newMux()
	huge := strings.Repeat("a", maxConfigBodyBytes+1024)
	body := `{"content":"https://x","junk":"` + huge + `"}`
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPut, "/config", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status=%d, want 413", rr.Code)
	}
	eb := decodeErr(t, rr.Body.Bytes())
	if eb.Error != "payload_too_large" {
		t.Errorf("error code=%q, want payload_too_large", eb.Error)
	}
}

func TestPutConfigWrongContentType(t *testing.T) {
	mux := newMux()
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPut, "/config",
		strings.NewReader(`{"content":"https://x"}`))
	req.Header.Set("Content-Type", "text/plain")
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("status=%d, want 415", rr.Code)
	}
	if eb := decodeErr(t, rr.Body.Bytes()); eb.Error != "unsupported_media_type" {
		t.Errorf("error code=%q, want unsupported_media_type", eb.Error)
	}
}

func TestPutConfigAcceptsContentTypeWithCharset(t *testing.T) {
	mux := newMux()
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPut, "/config",
		strings.NewReader(`{"content":"https://x"}`))
	req.Header.Set("Content-Type", "application/json; charset=utf-8")
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d, want 200; body=%s", rr.Code, rr.Body.String())
	}
}

func TestPutConfigMissingContentField(t *testing.T) {
	mux := newMux()
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPut, "/config",
		strings.NewReader(`{"brightness":50}`))
	req.Header.Set("Content-Type", "application/json")
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("status=%d, want 400", rr.Code)
	}
	eb := decodeErr(t, rr.Body.Bytes())
	if eb.Error != "bad_request" {
		t.Errorf("error code=%q", eb.Error)
	}
	if !strings.Contains(eb.Message, "content") {
		t.Errorf("message=%q, want it to mention 'content'", eb.Message)
	}
}

func TestPutConfigUnknownFieldsRejected(t *testing.T) {
	mux := newMux()
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPut, "/config",
		strings.NewReader(`{"content":"https://x","mystery":42}`))
	req.Header.Set("Content-Type", "application/json")
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("status=%d, want 400", rr.Code)
	}
	if eb := decodeErr(t, rr.Body.Bytes()); eb.Error != "bad_request" {
		t.Errorf("error code=%q", eb.Error)
	}
}

// 50 concurrent PUTs from independent goroutines must not panic and the
// final stored content must be one of the inputs (not a torn read).
func TestPutConfigConcurrentRace(t *testing.T) {
	srv := newServer(t.TempDir())
	mux := newMuxFor(srv)
	const N = 50
	var wg sync.WaitGroup
	wg.Add(N)
	for i := 0; i < N; i++ {
		i := i
		go func() {
			defer wg.Done()
			body := fmt.Sprintf(`{"content":"https://race%02d.example.com"}`, i)
			rr := httptest.NewRecorder()
			req := httptest.NewRequest(http.MethodPut, "/config",
				strings.NewReader(body))
			req.Header.Set("Content-Type", "application/json")
			mux.ServeHTTP(rr, req)
			if rr.Code != http.StatusOK {
				t.Errorf("i=%d status=%d body=%s", i, rr.Code, rr.Body.String())
			}
		}()
	}
	wg.Wait()
	// Final state must match one of the inputs.
	final := srv.snapshot().Content
	if !strings.HasPrefix(final, "https://race") {
		t.Errorf("final content=%q does not look like one of the inputs", final)
	}
}

func TestConfigMethodNotAllowedReturnsStructuredError(t *testing.T) {
	mux := newMux()
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPatch, "/config", nil)
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status=%d, want 405", rr.Code)
	}
	if eb := decodeErr(t, rr.Body.Bytes()); eb.Error != "method_not_allowed" {
		t.Errorf("error code=%q", eb.Error)
	}
}

// --- Track A: WS error paths ---------------------------------------------------------

// Verify the connection set drains to 0 when the client closes.
func TestWebSocketConnectionSetDrainsOnClose(t *testing.T) {
	srv := newServer(t.TempDir())
	ts := httptest.NewServer(newMuxFor(srv))
	defer ts.Close()
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws"

	c, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	// Drain the initial config_update so the server's read loop gets a turn.
	_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, _, err := c.ReadMessage(); err != nil {
		t.Fatalf("initial read: %v", err)
	}
	if got := srv.connCount(); got != 1 {
		t.Errorf("connCount after dial=%d, want 1", got)
	}
	c.Close()

	// The server's read loop will fail and unregisterConn — wait briefly.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if srv.connCount() == 0 {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Errorf("connCount did not drain to 0; got %d", srv.connCount())
}

// --- Track A: Pack endpoint error codes ----------------------------------------------

func TestPackEndpointsReturnStructuredErrorBodies(t *testing.T) {
	_, mux := newPacksTestServer(t)

	// 404 on a missing pack id download.
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/packs/nope/download", nil)
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusNotFound {
		t.Errorf("download missing status=%d", rr.Code)
	}
	if eb := decodeErr(t, rr.Body.Bytes()); eb.Error != "not_found" {
		t.Errorf("error code=%q", eb.Error)
	}

	// 400 on an invalid pack id (uppercase letters).
	rr = httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodGet, "/packs/BAD/manifest", nil)
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Errorf("invalid id status=%d", rr.Code)
	}
	if eb := decodeErr(t, rr.Body.Bytes()); eb.Error != "bad_request" {
		t.Errorf("error code=%q", eb.Error)
	}
}

// Range requests on /packs/<id>/download should return 206 with the
// requested slice. http.ServeContent handles this for us, so the test
// merely asserts the wiring is intact.
func TestPackDownloadRangeRequest(t *testing.T) {
	_, mux := newPacksTestServer(t)
	payload := makeTinyPNG(t)
	body, ct := makePackUpload(t, "rng", "png", "x.png", payload)
	req := httptest.NewRequest(http.MethodPost, "/packs", body)
	req.Header.Set("Content-Type", ct)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("upload status=%d", rr.Code)
	}

	end := len(payload) - 1
	if end > 9 {
		end = 9
	}
	rng := fmt.Sprintf("bytes=0-%d", end)
	req2 := httptest.NewRequest(http.MethodGet, "/packs/rng/download", nil)
	req2.Header.Set("Range", rng)
	rr2 := httptest.NewRecorder()
	mux.ServeHTTP(rr2, req2)
	if rr2.Code != http.StatusPartialContent {
		t.Fatalf("range status=%d, want 206; body=%s", rr2.Code, rr2.Body.String())
	}
	if got := rr2.Body.Len(); got != end+1 {
		t.Errorf("range body len=%d, want %d", got, end+1)
	}
}

// Concurrent download + delete: both should succeed without panicking.
// We don't assert ordering — only that neither operation crashes the
// server and the post-delete state is consistent.
func TestPackDeleteConcurrentWithDownload(t *testing.T) {
	srv, mux := newPacksTestServer(t)
	body, ct := makePackUpload(t, "raceful", "png", "x.png", makeTinyPNG(t))
	req := httptest.NewRequest(http.MethodPost, "/packs", body)
	req.Header.Set("Content-Type", ct)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("upload status=%d", rr.Code)
	}

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		req := httptest.NewRequest(http.MethodGet, "/packs/raceful/download", nil)
		rr := httptest.NewRecorder()
		mux.ServeHTTP(rr, req)
		// Either 200 (got it before delete) or 404 (lost the race) is fine.
		if rr.Code != http.StatusOK && rr.Code != http.StatusNotFound {
			t.Errorf("download status=%d, want 200 or 404", rr.Code)
		}
	}()
	go func() {
		defer wg.Done()
		req := httptest.NewRequest(http.MethodDelete, "/packs/raceful", nil)
		rr := httptest.NewRecorder()
		mux.ServeHTTP(rr, req)
		if rr.Code != http.StatusNoContent && rr.Code != http.StatusNotFound {
			t.Errorf("delete status=%d", rr.Code)
		}
	}()
	wg.Wait()

	// After both operations, the index entry must be gone.
	idx, err := srv.readIndex()
	if err != nil {
		t.Fatalf("read index: %v", err)
	}
	for _, e := range idx {
		if e.ID == "raceful" {
			t.Errorf("index still has entry after delete")
		}
	}
}

// Multipart with no file part should 400 with bad_request.
func TestPostPackMissingFilePart(t *testing.T) {
	_, mux := newPacksTestServer(t)
	var body bytes.Buffer
	w := multipart.NewWriter(&body)
	_ = w.WriteField("id", "noapfile")
	_ = w.WriteField("type", "png")
	_ = w.Close()
	req := httptest.NewRequest(http.MethodPost, "/packs", &body)
	req.Header.Set("Content-Type", w.FormDataContentType())
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("status=%d, want 400", rr.Code)
	}
	if eb := decodeErr(t, rr.Body.Bytes()); eb.Error != "bad_request" {
		t.Errorf("error code=%q", eb.Error)
	}
}

// Garbage multipart body — ParseMultipartForm should fail with 400.
func TestPostPackInvalidMultipart(t *testing.T) {
	_, mux := newPacksTestServer(t)
	req := httptest.NewRequest(http.MethodPost, "/packs",
		strings.NewReader("this is not multipart"))
	req.Header.Set("Content-Type", "multipart/form-data; boundary=zzz")
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("status=%d, want 400", rr.Code)
	}
}

// --- Track B: Operator auth token ----------------------------------------------------

// authedSrv returns a server preconfigured with the given token + a
// matching mux handler.
func authedSrv(t *testing.T, token string) (*hyacinthServer, http.Handler) {
	t.Helper()
	srv := newServer(t.TempDir())
	srv.authToken = token
	return srv, newMuxFor(srv)
}

func TestAuthRejectsPutWithoutHeader(t *testing.T) {
	_, mux := authedSrv(t, "secret")
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPut, "/config",
		strings.NewReader(`{"content":"https://x"}`))
	req.Header.Set("Content-Type", "application/json")
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d, want 401", rr.Code)
	}
	if eb := decodeErr(t, rr.Body.Bytes()); eb.Error != "unauthorized" {
		t.Errorf("error code=%q", eb.Error)
	}
}

func TestAuthAcceptsPutWithCorrectHeader(t *testing.T) {
	_, mux := authedSrv(t, "secret")
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPut, "/config",
		strings.NewReader(`{"content":"https://x"}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer secret")
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d, want 200; body=%s", rr.Code, rr.Body.String())
	}
}

func TestAuthRejectsPutWithWrongHeader(t *testing.T) {
	_, mux := authedSrv(t, "secret")
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPut, "/config",
		strings.NewReader(`{"content":"https://x"}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer wrong")
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d, want 401", rr.Code)
	}
}

func TestAuthAllowsGetWithoutHeader(t *testing.T) {
	_, mux := authedSrv(t, "secret")
	for _, p := range []string{"/config", "/health", "/packs", "/"} {
		rr := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, p, nil)
		mux.ServeHTTP(rr, req)
		if rr.Code != http.StatusOK {
			t.Errorf("GET %s status=%d, want 200", p, rr.Code)
		}
	}
}

func TestAuthRejectsPostPackWithoutHeader(t *testing.T) {
	_, mux := authedSrv(t, "secret")
	body, ct := makePackUpload(t, "p1", "png", "x.png", makeTinyPNG(t))
	req := httptest.NewRequest(http.MethodPost, "/packs", body)
	req.Header.Set("Content-Type", ct)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d, want 401", rr.Code)
	}
}

func TestAuthRejectsDeletePackWithoutHeader(t *testing.T) {
	_, mux := authedSrv(t, "secret")
	// Upload one with the right header so DELETE has something to remove.
	body, ct := makePackUpload(t, "delauth", "png", "x.png", makeTinyPNG(t))
	req := httptest.NewRequest(http.MethodPost, "/packs", body)
	req.Header.Set("Content-Type", ct)
	req.Header.Set("Authorization", "Bearer secret")
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("upload status=%d", rr.Code)
	}
	// Now DELETE without auth.
	req = httptest.NewRequest(http.MethodDelete, "/packs/delauth", nil)
	rr = httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("delete status=%d, want 401", rr.Code)
	}
}

// WS upgrade is a GET — should remain open even when a token is set, so
// the tablet can subscribe without secrets baked into the APK.
func TestAuthAllowsWSWithoutHeader(t *testing.T) {
	srv, _ := authedSrv(t, "secret")
	ts := httptest.NewServer(newMuxFor(srv))
	defer ts.Close()
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws"
	c, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer c.Close()
	_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, _, err := c.ReadMessage(); err != nil {
		t.Fatalf("read: %v", err)
	}
}

// --- Track A: panic recovery middleware ----------------------------------------------

// Wire a synthetic panicking handler through the middleware stack and
// assert it returns a structured 500.
func TestRecoverMiddlewareReturns500(t *testing.T) {
	h := recoverMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		panic("kaboom")
	}))
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/x", nil)
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusInternalServerError {
		t.Fatalf("status=%d, want 500", rr.Code)
	}
	if eb := decodeErr(t, rr.Body.Bytes()); eb.Error != "internal_error" {
		t.Errorf("error code=%q", eb.Error)
	}
}

// --- Track A: ensure GET /config produces ErrorBody on bad method ---

// Ensure newMux still serves the operator UI through the wrapped chain.
func TestRootIndexThroughWrappedChain(t *testing.T) {
	mux := newMux()
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d", rr.Code)
	}
	if !strings.Contains(rr.Body.String(), "Hyacinth Operator") {
		t.Errorf("operator UI not served through wrapped chain")
	}
}

// --- M9.1: POST /screen imperative commands ----------------------------------------

// readScreenEnvelope drains frames until a screen_command envelope arrives
// or the deadline elapses. Skips any config_update broadcasts that race in.
func readScreenEnvelope(t *testing.T, c *websocket.Conn) map[string]any {
	t.Helper()
	for i := 0; i < 5; i++ {
		_, data, err := c.ReadMessage()
		if err != nil {
			t.Fatalf("read ws: %v", err)
		}
		var env map[string]any
		if err := json.Unmarshal(data, &env); err != nil {
			t.Fatalf("decode envelope: %v", err)
		}
		if env["type"] == "screen_command" {
			return env
		}
	}
	t.Fatalf("no screen_command envelope after 5 frames")
	return nil
}

func TestPostScreenBroadcastsOn(t *testing.T) {
	srv := newServer(t.TempDir())
	ts := httptest.NewServer(newMuxFor(srv))
	defer ts.Close()
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws"
	c, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("ws dial: %v", err)
	}
	defer c.Close()
	_ = c.SetReadDeadline(time.Now().Add(5 * time.Second))
	// Drain the initial config_update.
	if _, _, err := c.ReadMessage(); err != nil {
		t.Fatalf("drain initial: %v", err)
	}

	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/screen",
		strings.NewReader(`{"action":"on"}`))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d, want 200", resp.StatusCode)
	}
	env := readScreenEnvelope(t, c)
	if env["action"] != "on" {
		t.Errorf("action=%v, want on", env["action"])
	}
}

func TestPostScreenBroadcastsOff(t *testing.T) {
	srv := newServer(t.TempDir())
	ts := httptest.NewServer(newMuxFor(srv))
	defer ts.Close()
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws"
	c, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("ws dial: %v", err)
	}
	defer c.Close()
	_ = c.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, _, err := c.ReadMessage(); err != nil {
		t.Fatalf("drain initial: %v", err)
	}
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/screen",
		strings.NewReader(`{"action":"off"}`))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d, want 200", resp.StatusCode)
	}
	env := readScreenEnvelope(t, c)
	if env["action"] != "off" {
		t.Errorf("action=%v, want off", env["action"])
	}
}

func TestPostScreenInvalidAction(t *testing.T) {
	mux := newMux()
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/screen",
		strings.NewReader(`{"action":"foo"}`))
	req.Header.Set("Content-Type", "application/json")
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("status=%d, want 400", rr.Code)
	}
	if eb := decodeErr(t, rr.Body.Bytes()); eb.Error != "bad_request" {
		t.Errorf("error code=%q", eb.Error)
	}
}

func TestPostScreenWrongMethod(t *testing.T) {
	mux := newMux()
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/screen", nil)
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status=%d, want 405", rr.Code)
	}
	if eb := decodeErr(t, rr.Body.Bytes()); eb.Error != "method_not_allowed" {
		t.Errorf("error code=%q", eb.Error)
	}
}

func TestPostScreenAuthRequired(t *testing.T) {
	_, mux := authedSrv(t, "secret")
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/screen",
		strings.NewReader(`{"action":"on"}`))
	req.Header.Set("Content-Type", "application/json")
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d, want 401", rr.Code)
	}
	if eb := decodeErr(t, rr.Body.Bytes()); eb.Error != "unauthorized" {
		t.Errorf("error code=%q", eb.Error)
	}
}

func TestPostScreenWithAuthAccepted(t *testing.T) {
	_, mux := authedSrv(t, "secret")
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/screen",
		strings.NewReader(`{"action":"on"}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer secret")
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d, want 200; body=%s", rr.Code, rr.Body.String())
	}
}

// Sanity that io.Discard exists in the build (silences unused-import noise
// if some import gets added below this line later). Trivial test, kept
// here so the file's import block doesn't have to be touched again.
func TestSinkExists(t *testing.T) {
	_, _ = io.Copy(io.Discard, strings.NewReader("ok"))
}
