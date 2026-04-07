package main

// Resource pack endpoints (M5: image-only).
//
// On-disk layout under <dataDir>/packs/:
//
//   index.json                # array of latest manifests, one entry per id
//   <id>/<version>/manifest.json
//   <id>/<version>/content/image.<ext>
//
// Versioning is per-pack monotonic int. Atomic writes use tmp+rename.
// All mutations are serialized by hyacinthServer.packsMu.
//
// M6 will extend this with zip packs (POST currently rejects type=zip with
// 501).

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// PackManifest is the wire + on-disk representation of one pack version.
// The same struct doubles as the entry shape inside packs/index.json.
type PackManifest struct {
	ID        string `json:"id"`
	Version   int    `json:"version"`
	Type      string `json:"type"`     // png|jpg|webp|gif (M5) | zip (M6)
	Filename  string `json:"filename"` // e.g. image.png
	SHA256    string `json:"sha256"`
	Size      int64  `json:"size"`
	CreatedAt string `json:"createdAt"`
}

// maxPackBodyBytes caps multipart upload size. 50 MiB matches the prompt.
const maxPackBodyBytes = 50 << 20

// versionsToKeep is the rollback retention; M5 keeps the last two versions
// of each pack on disk so a bad upload can be rolled back manually.
const versionsToKeep = 2

var (
	// packIDRe is the slug regex from plan.md / the prompt. It explicitly
	// disallows path-traversal characters (`.`, `/`, `\`).
	packIDRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,31}$`)

	// allowedImageExt maps the `type` form field to the on-disk extension.
	// Both lowercase. The two distinct types png/jpg/webp/gif each map to
	// exactly one filename suffix; "jpeg" is not accepted as a type but a
	// jpg upload may have either suffix on the original filename — we
	// always store as .jpg for consistency.
	allowedImageExt = map[string]string{
		"png":  "png",
		"jpg":  "jpg",
		"webp": "webp",
		"gif":  "gif",
	}
)

// validPackType returns true if `t` is one of the M5-allowed image types.
func validPackType(t string) bool {
	_, ok := allowedImageExt[t]
	return ok
}

// validPackID returns true if id is a safe slug.
func validPackID(id string) bool {
	if id == "" {
		return false
	}
	if strings.ContainsAny(id, "/\\\x00") || strings.Contains(id, "..") {
		return false
	}
	return packIDRe.MatchString(id)
}

// packsRoot returns the on-disk root for the pack store, ensuring the
// directory exists.
func (s *hyacinthServer) packsRoot() (string, error) {
	root := filepath.Join(s.dataDir, "packs")
	if err := os.MkdirAll(root, 0o755); err != nil {
		return "", err
	}
	return root, nil
}

// packDir returns <packsRoot>/<id>.
func (s *hyacinthServer) packDir(id string) (string, error) {
	root, err := s.packsRoot()
	if err != nil {
		return "", err
	}
	return filepath.Join(root, id), nil
}

// indexPath returns <packsRoot>/index.json.
func (s *hyacinthServer) indexPath() (string, error) {
	root, err := s.packsRoot()
	if err != nil {
		return "", err
	}
	return filepath.Join(root, "index.json"), nil
}

// readIndex returns the parsed manifest list. A missing file is treated as
// an empty index (so first-boot does not need a special-case).
func (s *hyacinthServer) readIndex() ([]PackManifest, error) {
	p, err := s.indexPath()
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(p)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return []PackManifest{}, nil
		}
		return nil, err
	}
	var out []PackManifest
	if err := json.Unmarshal(data, &out); err != nil {
		return nil, err
	}
	if out == nil {
		out = []PackManifest{}
	}
	return out, nil
}

// writeIndex serializes `entries` to <packsRoot>/index.json via tmp+rename.
func (s *hyacinthServer) writeIndex(entries []PackManifest) error {
	p, err := s.indexPath()
	if err != nil {
		return err
	}
	if entries == nil {
		entries = []PackManifest{}
	}
	body, err := json.MarshalIndent(entries, "", "  ")
	if err != nil {
		return err
	}
	return atomicWriteFile(p, body)
}

// upsertIndexEntry replaces the entry whose id matches `m.ID`, or appends
// it. Sorts by id for stable output.
func upsertIndexEntry(entries []PackManifest, m PackManifest) []PackManifest {
	found := false
	for i := range entries {
		if entries[i].ID == m.ID {
			entries[i] = m
			found = true
			break
		}
	}
	if !found {
		entries = append(entries, m)
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].ID < entries[j].ID })
	return entries
}

// removeIndexEntry returns entries with id stripped, plus a bool indicating
// whether anything was removed.
func removeIndexEntry(entries []PackManifest, id string) ([]PackManifest, bool) {
	out := entries[:0]
	removed := false
	for _, e := range entries {
		if e.ID == id {
			removed = true
			continue
		}
		out = append(out, e)
	}
	return out, removed
}

// atomicWriteFile writes `body` to `dest` via a sibling .tmp file followed
// by an os.Rename. Caller must hold the appropriate mutex.
func atomicWriteFile(dest string, body []byte) error {
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	tmp := dest + ".tmp"
	if err := os.WriteFile(tmp, body, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, dest)
}

// listVersionsDesc returns existing version subdirs (numeric names) under
// <packsRoot>/<id>, sorted descending. Non-numeric entries are ignored.
func listVersionsDesc(packDir string) ([]int, error) {
	entries, err := os.ReadDir(packDir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	var versions []int
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		n, err := strconv.Atoi(e.Name())
		if err != nil || n <= 0 {
			continue
		}
		versions = append(versions, n)
	}
	sort.Sort(sort.Reverse(sort.IntSlice(versions)))
	return versions, nil
}

// loadManifest reads <packDir>/<version>/manifest.json.
func loadManifest(packDir string, version int) (PackManifest, error) {
	p := filepath.Join(packDir, strconv.Itoa(version), "manifest.json")
	data, err := os.ReadFile(p)
	if err != nil {
		return PackManifest{}, err
	}
	var m PackManifest
	if err := json.Unmarshal(data, &m); err != nil {
		return PackManifest{}, err
	}
	return m, nil
}

// latestManifest returns the highest-version manifest for `id`, or
// (zero, os.ErrNotExist) if none exist.
func (s *hyacinthServer) latestManifest(id string) (PackManifest, error) {
	pd, err := s.packDir(id)
	if err != nil {
		return PackManifest{}, err
	}
	versions, err := listVersionsDesc(pd)
	if err != nil {
		return PackManifest{}, err
	}
	if len(versions) == 0 {
		return PackManifest{}, os.ErrNotExist
	}
	return loadManifest(pd, versions[0])
}

// handlePacks dispatches GET /packs and POST /packs.
func (s *hyacinthServer) handlePacks(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		s.handleListPacks(w, r)
	case http.MethodPost:
		s.handleUploadPack(w, r)
	default:
		w.Header().Set("Allow", "GET, POST")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

// handlePackByID dispatches GET /packs/{id}/manifest, GET /packs/{id}/download
// and DELETE /packs/{id}.
func (s *hyacinthServer) handlePackByID(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/packs/")
	if rest == "" {
		http.NotFound(w, r)
		return
	}
	parts := strings.Split(rest, "/")
	id := parts[0]
	if !validPackID(id) {
		http.Error(w, "invalid pack id", http.StatusBadRequest)
		return
	}
	switch {
	case len(parts) == 1 && r.Method == http.MethodDelete:
		s.handleDeletePack(w, r, id)
	case len(parts) == 2 && parts[1] == "manifest" && r.Method == http.MethodGet:
		s.handleGetManifest(w, r, id)
	case len(parts) == 2 && parts[1] == "download" && r.Method == http.MethodGet:
		s.handleDownloadPack(w, r, id)
	default:
		http.NotFound(w, r)
	}
}

func (s *hyacinthServer) handleListPacks(w http.ResponseWriter, _ *http.Request) {
	s.packsMu.Lock()
	defer s.packsMu.Unlock()
	entries, err := s.readIndex()
	if err != nil {
		http.Error(w, "read index: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(entries)
}

func (s *hyacinthServer) handleGetManifest(w http.ResponseWriter, _ *http.Request, id string) {
	s.packsMu.Lock()
	defer s.packsMu.Unlock()
	m, err := s.latestManifest(id)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			http.NotFound(w, nil)
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(m)
}

func (s *hyacinthServer) handleDownloadPack(w http.ResponseWriter, r *http.Request, id string) {
	s.packsMu.Lock()
	m, err := s.latestManifest(id)
	if err != nil {
		s.packsMu.Unlock()
		if errors.Is(err, os.ErrNotExist) {
			http.NotFound(w, r)
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	pd, _ := s.packDir(id)
	contentPath := filepath.Join(pd, strconv.Itoa(m.Version), "content", m.Filename)
	s.packsMu.Unlock()

	f, err := os.Open(contentPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			http.NotFound(w, r)
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer f.Close()
	stat, err := f.Stat()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", mimeForType(m.Type))
	w.Header().Set("Cache-Control", "public, max-age=3600")
	w.Header().Set("ETag", `"`+m.SHA256+`"`)
	http.ServeContent(w, r, m.Filename, stat.ModTime(), f)
}

func (s *hyacinthServer) handleDeletePack(w http.ResponseWriter, _ *http.Request, id string) {
	s.packsMu.Lock()
	defer s.packsMu.Unlock()

	pd, err := s.packDir(id)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if _, err := os.Stat(pd); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			http.NotFound(w, nil)
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if err := os.RemoveAll(pd); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	entries, err := s.readIndex()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	entries, _ = removeIndexEntry(entries, id)
	if err := s.writeIndex(entries); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *hyacinthServer) handleUploadPack(w http.ResponseWriter, r *http.Request) {
	// Cap the request body BEFORE touching multipart parsing so an oversize
	// upload bails out early. The body cap is enforced both here and by
	// ParseMultipartForm's own internal limit.
	r.Body = http.MaxBytesReader(w, r.Body, maxPackBodyBytes)
	if err := r.ParseMultipartForm(maxPackBodyBytes); err != nil {
		// MaxBytesReader / ParseMultipartForm signal oversize via a
		// generic error; map any parse failure that's plausibly an
		// oversize-body case to 413, otherwise 400.
		if strings.Contains(err.Error(), "request body too large") {
			http.Error(w, "pack too large", http.StatusRequestEntityTooLarge)
			return
		}
		http.Error(w, "multipart parse: "+err.Error(), http.StatusBadRequest)
		return
	}

	id := strings.TrimSpace(r.FormValue("id"))
	packType := strings.TrimSpace(strings.ToLower(r.FormValue("type")))

	if !validPackID(id) {
		http.Error(w, "invalid pack id (slug ^[a-z0-9][a-z0-9-]{0,31}$)", http.StatusBadRequest)
		return
	}
	if packType == "zip" {
		http.Error(w, "zip packs land in M6", http.StatusNotImplemented)
		return
	}
	if !validPackType(packType) {
		http.Error(w, "invalid pack type (allowed: png, jpg, webp, gif)", http.StatusBadRequest)
		return
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		http.Error(w, "missing 'file' part: "+err.Error(), http.StatusBadRequest)
		return
	}
	defer file.Close()
	if header.Size <= 0 {
		http.Error(w, "empty file", http.StatusBadRequest)
		return
	}
	if header.Size > maxPackBodyBytes {
		http.Error(w, "pack too large", http.StatusRequestEntityTooLarge)
		return
	}

	// Filename extension must match the declared type. We accept .jpeg as
	// an alias for jpg.
	origName := header.Filename
	gotExt := strings.ToLower(strings.TrimPrefix(filepath.Ext(origName), "."))
	if gotExt == "jpeg" {
		gotExt = "jpg"
	}
	if gotExt != allowedImageExt[packType] {
		http.Error(w, fmt.Sprintf("file extension %q does not match type %q", gotExt, packType), http.StatusBadRequest)
		return
	}

	// Read into memory (capped at 50 MiB) so we can both sha256 and write
	// the file in one pass. For an image-only path this is fine; M6's zip
	// pipeline will stream straight to disk.
	buf, err := io.ReadAll(file)
	if err != nil {
		http.Error(w, "read upload: "+err.Error(), http.StatusBadRequest)
		return
	}
	if int64(len(buf)) != header.Size {
		http.Error(w, "short read", http.StatusBadRequest)
		return
	}
	// Content sniff: must be image/*. http.DetectContentType only needs
	// the first 512 bytes.
	sniff := http.DetectContentType(buf)
	if !strings.HasPrefix(sniff, "image/") {
		http.Error(w, "uploaded bytes are not an image (sniffed: "+sniff+")", http.StatusBadRequest)
		return
	}

	sum := sha256.Sum256(buf)
	hash := hex.EncodeToString(sum[:])

	s.packsMu.Lock()
	defer s.packsMu.Unlock()

	pd, err := s.packDir(id)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	existing, err := listVersionsDesc(pd)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	nextVersion := 1
	if len(existing) > 0 {
		nextVersion = existing[0] + 1
	}

	storedFilename := "image." + allowedImageExt[packType]
	versionDir := filepath.Join(pd, strconv.Itoa(nextVersion))
	contentDir := filepath.Join(versionDir, "content")
	if err := os.MkdirAll(contentDir, 0o755); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	contentPath := filepath.Join(contentDir, storedFilename)
	if err := atomicWriteFile(contentPath, buf); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	manifest := PackManifest{
		ID:        id,
		Version:   nextVersion,
		Type:      packType,
		Filename:  storedFilename,
		SHA256:    hash,
		Size:      int64(len(buf)),
		CreatedAt: time.Now().UTC().Format(time.RFC3339),
	}
	manifestBytes, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	manifestPath := filepath.Join(versionDir, "manifest.json")
	if err := atomicWriteFile(manifestPath, manifestBytes); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	// Update the index with the new latest manifest for this id.
	entries, err := s.readIndex()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	entries = upsertIndexEntry(entries, manifest)
	if err := s.writeIndex(entries); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	// Rollback retention: keep the last `versionsToKeep` versions on disk
	// per pack. Re-list versions (now includes the freshly written one)
	// and prune anything older than the keep window.
	allVersions, _ := listVersionsDesc(pd)
	if len(allVersions) > versionsToKeep {
		for _, v := range allVersions[versionsToKeep:] {
			_ = os.RemoveAll(filepath.Join(pd, strconv.Itoa(v)))
		}
	}

	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(manifestBytes)
}

// mimeForType returns the canonical Content-Type for an image pack type.
func mimeForType(t string) string {
	switch t {
	case "png":
		return "image/png"
	case "jpg":
		return "image/jpeg"
	case "webp":
		return "image/webp"
	case "gif":
		return "image/gif"
	}
	return "application/octet-stream"
}
