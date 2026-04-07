package main

// HTTP-level tests for the M5 resource-pack endpoints. We exercise the
// real handlers via httptest, against a per-test temp data dir, with no
// network or external state.

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// makeTinyPNG returns a deterministic 4x4 RGBA PNG. Used as the upload
// payload in the happy-path tests.
func makeTinyPNG(t *testing.T) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 4, 4))
	for x := 0; x < 4; x++ {
		for y := 0; y < 4; y++ {
			img.Set(x, y, color.RGBA{R: uint8(x * 60), G: uint8(y * 60), B: 128, A: 255})
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatalf("png encode: %v", err)
	}
	return buf.Bytes()
}

// makePackUpload builds a multipart body with id/type/file fields. Returns
// the body, the content-type header, and the bytes that ended up in the
// `file` part (so callers can compare on round-trip).
func makePackUpload(t *testing.T, id, packType, filename string, payload []byte) (*bytes.Buffer, string) {
	t.Helper()
	var body bytes.Buffer
	w := multipart.NewWriter(&body)
	if err := w.WriteField("id", id); err != nil {
		t.Fatalf("write id: %v", err)
	}
	if err := w.WriteField("type", packType); err != nil {
		t.Fatalf("write type: %v", err)
	}
	fw, err := w.CreateFormFile("file", filename)
	if err != nil {
		t.Fatalf("create file: %v", err)
	}
	if _, err := fw.Write(payload); err != nil {
		t.Fatalf("write file: %v", err)
	}
	if err := w.Close(); err != nil {
		t.Fatalf("close writer: %v", err)
	}
	return &body, w.FormDataContentType()
}

func newPacksTestServer(t *testing.T) (*hyacinthServer, *http.ServeMux) {
	t.Helper()
	srv := newServer(t.TempDir())
	return srv, newMuxFor(srv)
}

func TestPostPackImageHappyPath(t *testing.T) {
	srv, mux := newPacksTestServer(t)

	payload := makeTinyPNG(t)
	body, ct := makePackUpload(t, "neko", "png", "cat.png", payload)
	req := httptest.NewRequest(http.MethodPost, "/packs", body)
	req.Header.Set("Content-Type", ct)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rr.Code, rr.Body.String())
	}
	var got PackManifest
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("response JSON: %v", err)
	}
	if got.ID != "neko" || got.Version != 1 || got.Type != "png" || got.Filename != "image.png" {
		t.Errorf("manifest mismatch: %+v", got)
	}
	if got.Size != int64(len(payload)) {
		t.Errorf("size = %d, want %d", got.Size, len(payload))
	}
	want := sha256.Sum256(payload)
	if got.SHA256 != hex.EncodeToString(want[:]) {
		t.Errorf("sha256 mismatch")
	}
	if got.CreatedAt == "" {
		t.Errorf("CreatedAt empty")
	}

	// File on disk.
	contentPath := filepath.Join(srv.dataDir, "packs", "neko", "1", "content", "image.png")
	if _, err := os.Stat(contentPath); err != nil {
		t.Errorf("content file not on disk: %v", err)
	}
	manifestPath := filepath.Join(srv.dataDir, "packs", "neko", "1", "manifest.json")
	if _, err := os.Stat(manifestPath); err != nil {
		t.Errorf("manifest not on disk: %v", err)
	}

	// Index contains it.
	idx, err := srv.readIndex()
	if err != nil {
		t.Fatalf("read index: %v", err)
	}
	if len(idx) != 1 || idx[0].ID != "neko" {
		t.Errorf("index = %+v", idx)
	}
}

// makeZip builds a zip in memory from name->bytes pairs. Used by all the
// M6 zip tests.
func makeZip(t *testing.T, files map[string][]byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	// Iterate in a stable order so test failures are deterministic.
	names := make([]string, 0, len(files))
	for n := range files {
		names = append(names, n)
	}
	// no sort.Strings to keep deps minimal — order doesn't matter for tests.
	for _, n := range names {
		fw, err := zw.Create(n)
		if err != nil {
			t.Fatalf("zip create %q: %v", n, err)
		}
		if _, err := fw.Write(files[n]); err != nil {
			t.Fatalf("zip write %q: %v", n, err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatalf("zip close: %v", err)
	}
	return buf.Bytes()
}

func TestPostPackZipHappyPath(t *testing.T) {
	srv, mux := newPacksTestServer(t)
	zipBytes := makeZip(t, map[string][]byte{
		"index.html": []byte("<html><body>hi</body></html>"),
		"style.css":  []byte("body{color:red}"),
	})
	body, ct := makePackUpload(t, "site", "zip", "site.zip", zipBytes)
	req := httptest.NewRequest(http.MethodPost, "/packs", body)
	req.Header.Set("Content-Type", ct)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	var got PackManifest
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.Type != "zip" || got.Filename != "index.html" || got.Version != 1 {
		t.Errorf("manifest = %+v", got)
	}
	want := sha256.Sum256(zipBytes)
	if got.SHA256 != hex.EncodeToString(want[:]) {
		t.Errorf("sha256 mismatch: got %s", got.SHA256)
	}
	if got.Size != int64(len(zipBytes)) {
		t.Errorf("size = %d want %d", got.Size, len(zipBytes))
	}
	base := filepath.Join(srv.dataDir, "packs", "site", "1")
	for _, p := range []string{
		filepath.Join(base, "manifest.json"),
		filepath.Join(base, "source.zip"),
		filepath.Join(base, "content", "index.html"),
		filepath.Join(base, "content", "style.css"),
	} {
		if _, err := os.Stat(p); err != nil {
			t.Errorf("expected %s: %v", p, err)
		}
	}
	// staging dir must NOT linger
	if _, err := os.Stat(base + ".staging"); !os.IsNotExist(err) {
		t.Errorf("staging dir still exists: %v", err)
	}
	idx, _ := srv.readIndex()
	if len(idx) != 1 || idx[0].ID != "site" || idx[0].Type != "zip" {
		t.Errorf("index = %+v", idx)
	}
}

func TestPostPackZipMissingIndexHtml(t *testing.T) {
	_, mux := newPacksTestServer(t)
	zipBytes := makeZip(t, map[string][]byte{
		"main.js": []byte("console.log(1)"),
	})
	body, ct := makePackUpload(t, "noidx", "zip", "x.zip", zipBytes)
	req := httptest.NewRequest(http.MethodPost, "/packs", body)
	req.Header.Set("Content-Type", ct)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
}

func TestPostPackZipPathTraversal(t *testing.T) {
	_, mux := newPacksTestServer(t)
	// Build a zip whose first entry tries to escape the extraction root.
	// We MUST include index.html so the only failure path is the
	// traversal check, not the missing-index check.
	for _, evilName := range []string{
		"../evil.txt",
		"a/../../escape.txt",
		"/abs.txt",
		"sub\\back.txt",
	} {
		zb := makeZip(t, map[string][]byte{
			"index.html": []byte("ok"),
			evilName:     []byte("bad"),
		})
		body, ct := makePackUpload(t, "trav", "zip", "x.zip", zb)
		req := httptest.NewRequest(http.MethodPost, "/packs", body)
		req.Header.Set("Content-Type", ct)
		rr := httptest.NewRecorder()
		mux.ServeHTTP(rr, req)
		if rr.Code != http.StatusBadRequest {
			t.Errorf("name=%q status=%d body=%s", evilName, rr.Code, rr.Body.String())
		}
	}
}

func TestPostPackZipOversizedEntry(t *testing.T) {
	_, mux := newPacksTestServer(t)
	// 51 MiB of zeros — compresses very well so the zip itself stays small
	// (well under maxZipBodyBytes), but the uncompressed entry trips the
	// per-entry cap.
	huge := make([]byte, (51 << 20))
	zb := makeZip(t, map[string][]byte{
		"index.html": []byte("ok"),
		"big.bin":    huge,
	})
	body, ct := makePackUpload(t, "huge", "zip", "x.zip", zb)
	req := httptest.NewRequest(http.MethodPost, "/packs", body)
	req.Header.Set("Content-Type", ct)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
}

func TestPostPackZipBomb(t *testing.T) {
	_, mux := newPacksTestServer(t)
	// 5 entries × 45 MiB each = 225 MiB uncompressed, each entry is under
	// the per-entry 50 MiB cap so the only trip-wire is the total cap.
	files := map[string][]byte{"index.html": []byte("ok")}
	for i := 0; i < 5; i++ {
		files[fmt.Sprintf("blob-%d.bin", i)] = make([]byte, 45<<20)
	}
	zb := makeZip(t, files)
	body, ct := makePackUpload(t, "bomb", "zip", "x.zip", zb)
	req := httptest.NewRequest(http.MethodPost, "/packs", body)
	req.Header.Set("Content-Type", ct)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
}

func TestPostPackZipTooManyEntries(t *testing.T) {
	_, mux := newPacksTestServer(t)
	files := map[string][]byte{"index.html": []byte("ok")}
	for i := 0; i < maxZipEntries+5; i++ {
		files[fmt.Sprintf("f%05d.txt", i)] = []byte("x")
	}
	zb := makeZip(t, files)
	body, ct := makePackUpload(t, "many", "zip", "x.zip", zb)
	req := httptest.NewRequest(http.MethodPost, "/packs", body)
	req.Header.Set("Content-Type", ct)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
}

func TestGetPackDownloadServesZipBytes(t *testing.T) {
	_, mux := newPacksTestServer(t)
	zb := makeZip(t, map[string][]byte{
		"index.html": []byte("<html>hi</html>"),
	})
	body, ct := makePackUpload(t, "zd", "zip", "z.zip", zb)
	req := httptest.NewRequest(http.MethodPost, "/packs", body)
	req.Header.Set("Content-Type", ct)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("upload status=%d body=%s", rr.Code, rr.Body.String())
	}

	req2 := httptest.NewRequest(http.MethodGet, "/packs/zd/download", nil)
	rr2 := httptest.NewRecorder()
	mux.ServeHTTP(rr2, req2)
	if rr2.Code != http.StatusOK {
		t.Fatalf("download status=%d", rr2.Code)
	}
	if cct := rr2.Header().Get("Content-Type"); !strings.HasPrefix(cct, "application/zip") {
		t.Errorf("content-type = %q, want application/zip prefix", cct)
	}
	got, _ := io.ReadAll(rr2.Body)
	if !bytes.Equal(got, zb) {
		t.Errorf("download bytes mismatch: got %d want %d", len(got), len(zb))
	}
}

func TestPostPackZipBumpsVersion(t *testing.T) {
	srv, mux := newPacksTestServer(t)
	doPost := func(payload []byte) PackManifest {
		body, ct := makePackUpload(t, "zv", "zip", "x.zip", payload)
		req := httptest.NewRequest(http.MethodPost, "/packs", body)
		req.Header.Set("Content-Type", ct)
		rr := httptest.NewRecorder()
		mux.ServeHTTP(rr, req)
		if rr.Code != http.StatusOK {
			t.Fatalf("upload status=%d body=%s", rr.Code, rr.Body.String())
		}
		var m PackManifest
		_ = json.Unmarshal(rr.Body.Bytes(), &m)
		return m
	}
	z1 := makeZip(t, map[string][]byte{"index.html": []byte("v1")})
	z2 := makeZip(t, map[string][]byte{"index.html": []byte("v2-different")})
	m1 := doPost(z1)
	m2 := doPost(z2)
	if m1.Version != 1 || m2.Version != 2 {
		t.Errorf("versions = %d, %d", m1.Version, m2.Version)
	}
	for _, v := range []string{"1", "2"} {
		p := filepath.Join(srv.dataDir, "packs", "zv", v, "content", "index.html")
		if _, err := os.Stat(p); err != nil {
			t.Errorf("missing %s: %v", p, err)
		}
	}
}

func TestDeletePackZipRemovesFiles(t *testing.T) {
	srv, mux := newPacksTestServer(t)
	zb := makeZip(t, map[string][]byte{"index.html": []byte("hi")})
	body, ct := makePackUpload(t, "zdel", "zip", "x.zip", zb)
	req := httptest.NewRequest(http.MethodPost, "/packs", body)
	req.Header.Set("Content-Type", ct)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("upload status=%d", rr.Code)
	}
	req2 := httptest.NewRequest(http.MethodDelete, "/packs/zdel", nil)
	rr2 := httptest.NewRecorder()
	mux.ServeHTTP(rr2, req2)
	if rr2.Code != http.StatusNoContent {
		t.Fatalf("delete status=%d", rr2.Code)
	}
	pd := filepath.Join(srv.dataDir, "packs", "zdel")
	if _, err := os.Stat(pd); !os.IsNotExist(err) {
		t.Errorf("pack dir still exists: %v", err)
	}
}

func TestPostPackInvalidId(t *testing.T) {
	_, mux := newPacksTestServer(t)
	for _, bad := range []string{"..", "../etc", "Bad-Caps", "has slash/in", "", strings.Repeat("a", 64)} {
		body, ct := makePackUpload(t, bad, "png", "x.png", makeTinyPNG(t))
		req := httptest.NewRequest(http.MethodPost, "/packs", body)
		req.Header.Set("Content-Type", ct)
		rr := httptest.NewRecorder()
		mux.ServeHTTP(rr, req)
		if rr.Code != http.StatusBadRequest {
			t.Errorf("id=%q status=%d, want 400", bad, rr.Code)
		}
	}
}

func TestPostPackOversize(t *testing.T) {
	_, mux := newPacksTestServer(t)
	// Build a body that overshoots the 50 MiB cap. Use 51 MiB of zeros
	// inside a multipart `file` part — png type and .png extension so the
	// only failure path is the size cap.
	huge := make([]byte, (51 << 20))
	body, ct := makePackUpload(t, "big", "png", "x.png", huge)
	req := httptest.NewRequest(http.MethodPost, "/packs", body)
	req.Header.Set("Content-Type", ct)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code < 400 {
		t.Fatalf("status = %d, want >= 400", rr.Code)
	}
}

func TestGetPacksReturnsIndex(t *testing.T) {
	_, mux := newPacksTestServer(t)
	// Empty case.
	{
		req := httptest.NewRequest(http.MethodGet, "/packs", nil)
		rr := httptest.NewRecorder()
		mux.ServeHTTP(rr, req)
		if rr.Code != http.StatusOK {
			t.Fatalf("empty list status = %d", rr.Code)
		}
		var arr []PackManifest
		if err := json.Unmarshal(rr.Body.Bytes(), &arr); err != nil {
			t.Fatalf("empty body JSON: %v", err)
		}
		if len(arr) != 0 {
			t.Errorf("expected empty array, got %+v", arr)
		}
	}
	// After upload.
	{
		body, ct := makePackUpload(t, "alpha", "png", "x.png", makeTinyPNG(t))
		req := httptest.NewRequest(http.MethodPost, "/packs", body)
		req.Header.Set("Content-Type", ct)
		rr := httptest.NewRecorder()
		mux.ServeHTTP(rr, req)
		if rr.Code != http.StatusOK {
			t.Fatalf("upload status = %d", rr.Code)
		}
	}
	{
		req := httptest.NewRequest(http.MethodGet, "/packs", nil)
		rr := httptest.NewRecorder()
		mux.ServeHTTP(rr, req)
		if rr.Code != http.StatusOK {
			t.Fatalf("list status = %d", rr.Code)
		}
		var arr []PackManifest
		if err := json.Unmarshal(rr.Body.Bytes(), &arr); err != nil {
			t.Fatalf("list body JSON: %v", err)
		}
		if len(arr) != 1 || arr[0].ID != "alpha" {
			t.Errorf("list mismatch: %+v", arr)
		}
	}
}

func TestGetPackManifestNotFound(t *testing.T) {
	_, mux := newPacksTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/packs/nonexistent/manifest", nil)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rr.Code)
	}
}

func TestGetPackDownloadServesBytes(t *testing.T) {
	_, mux := newPacksTestServer(t)
	payload := makeTinyPNG(t)
	body, ct := makePackUpload(t, "snap", "png", "cat.png", payload)
	req := httptest.NewRequest(http.MethodPost, "/packs", body)
	req.Header.Set("Content-Type", ct)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("upload status = %d", rr.Code)
	}

	req2 := httptest.NewRequest(http.MethodGet, "/packs/snap/download", nil)
	rr2 := httptest.NewRecorder()
	mux.ServeHTTP(rr2, req2)
	if rr2.Code != http.StatusOK {
		t.Fatalf("download status = %d", rr2.Code)
	}
	if ct := rr2.Header().Get("Content-Type"); ct != "image/png" {
		t.Errorf("content-type = %q, want image/png", ct)
	}
	if cc := rr2.Header().Get("Cache-Control"); cc != "public, max-age=3600" {
		t.Errorf("cache-control = %q", cc)
	}
	got, _ := io.ReadAll(rr2.Body)
	if !bytes.Equal(got, payload) {
		t.Errorf("download bytes mismatch (got %d, want %d)", len(got), len(payload))
	}
}

func TestDeletePackRemovesFiles(t *testing.T) {
	srv, mux := newPacksTestServer(t)
	body, ct := makePackUpload(t, "del", "png", "cat.png", makeTinyPNG(t))
	req := httptest.NewRequest(http.MethodPost, "/packs", body)
	req.Header.Set("Content-Type", ct)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("upload status = %d", rr.Code)
	}

	req2 := httptest.NewRequest(http.MethodDelete, "/packs/del", nil)
	rr2 := httptest.NewRecorder()
	mux.ServeHTTP(rr2, req2)
	if rr2.Code != http.StatusNoContent {
		t.Fatalf("delete status = %d", rr2.Code)
	}
	pd := filepath.Join(srv.dataDir, "packs", "del")
	if _, err := os.Stat(pd); !os.IsNotExist(err) {
		t.Errorf("pack directory still exists: %v", err)
	}
	idx, _ := srv.readIndex()
	for _, e := range idx {
		if e.ID == "del" {
			t.Errorf("index still has deleted entry")
		}
	}

	// Second delete should 404.
	req3 := httptest.NewRequest(http.MethodDelete, "/packs/del", nil)
	rr3 := httptest.NewRecorder()
	mux.ServeHTTP(rr3, req3)
	if rr3.Code != http.StatusNotFound {
		t.Errorf("second delete status = %d, want 404", rr3.Code)
	}
}

func TestPostPackBumpsVersion(t *testing.T) {
	srv, mux := newPacksTestServer(t)
	first := makeTinyPNG(t)
	second := append([]byte{}, first...)
	second[len(second)-1] ^= 0xFF // mutate one byte to force a different sha

	doPost := func(payload []byte) PackManifest {
		body, ct := makePackUpload(t, "ver", "png", "x.png", payload)
		req := httptest.NewRequest(http.MethodPost, "/packs", body)
		req.Header.Set("Content-Type", ct)
		rr := httptest.NewRecorder()
		mux.ServeHTTP(rr, req)
		if rr.Code != http.StatusOK {
			t.Fatalf("upload status = %d, body=%s", rr.Code, rr.Body.String())
		}
		var m PackManifest
		if err := json.Unmarshal(rr.Body.Bytes(), &m); err != nil {
			t.Fatalf("decode: %v", err)
		}
		return m
	}

	m1 := doPost(first)
	if m1.Version != 1 {
		t.Errorf("first version = %d, want 1", m1.Version)
	}
	m2 := doPost(second)
	if m2.Version != 2 {
		t.Errorf("second version = %d, want 2", m2.Version)
	}
	// Both versions should still be on disk (retention = 2).
	for _, v := range []string{"1", "2"} {
		p := filepath.Join(srv.dataDir, "packs", "ver", v, "content", "image.png")
		if _, err := os.Stat(p); err != nil {
			t.Errorf("version %s missing on disk: %v", v, err)
		}
	}
	// Index has only the latest entry for `ver`.
	idx, _ := srv.readIndex()
	count := 0
	var latest PackManifest
	for _, e := range idx {
		if e.ID == "ver" {
			count++
			latest = e
		}
	}
	if count != 1 {
		t.Errorf("index entries for ver = %d, want 1", count)
	}
	if latest.Version != 2 {
		t.Errorf("index latest version = %d, want 2", latest.Version)
	}
}
