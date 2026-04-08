package main

// Resource pack endpoints (M5: images, M6: zip with manifest).
//
// On-disk layout under <dataDir>/packs/:
//
//   index.json                # array of latest manifests, one entry per id
//   <id>/<version>/manifest.json
//   <id>/<version>/content/image.<ext>             # image pack
//   <id>/<version>/content/index.html              # zip pack: extracted tree
//   <id>/<version>/content/<other files...>
//   <id>/<version>/source.zip                       # zip pack: original upload
//
// Versioning is per-pack monotonic int. Atomic writes use tmp+rename for
// individual files, and the zip extraction pipeline writes everything into
// a sibling `<version>.staging/` directory which is then renamed atomically
// to `<version>/`. All mutations are serialized by hyacinthServer.packsMu.

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path"
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
	Type      string `json:"type"`     // png|jpg|webp|gif (M5) | zip (M6) | mp4 (M16)
	Filename  string `json:"filename"` // e.g. image.png
	SHA256    string `json:"sha256"`
	Size      int64  `json:"size"`
	CreatedAt string `json:"createdAt"`
}

// maxPackBodyBytes caps multipart upload size. Image packs cap at 50 MiB
// per the prompt; zip packs are allowed to be larger on the wire because
// the *uncompressed* total is what we really care about. We still cap zip
// uploads at maxZipBodyBytes to keep memory bounded.
const maxPackBodyBytes = 50 << 20

// Zip-pack defenses (server-side validation, mirrored on client).
const (
	maxZipBodyBytes      = 60 << 20  // raw upload cap for zip body itself
	maxZipUncompressed   = 200 << 20 // total uncompressed size cap
	maxZipEntryUncompr   = 50 << 20  // single-entry uncompressed cap
	maxZipEntries        = 5000      // sanity cap on entry count
)

// Video-pack defenses (M16). Videos are larger than images on the wire,
// so they get their own ceiling. The multipart parser uses
// maxUploadBodyBytes (the largest of the three caps) so any pack type can
// reach its full per-type ceiling; the per-type helper then enforces its
// own cap precisely.
const maxVideoBodyBytes = 200 << 20

// maxUploadBodyBytes is the upper bound for the multipart parser. It must
// be >= every per-type cap so the parser does not bail out before the
// per-type check can emit a precise error.
const maxUploadBodyBytes = maxVideoBodyBytes

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

	// allowedVideoExt maps a video pack `type` form value to its on-disk
	// extension. M16 ships mp4 only; webm/h265 are explicitly out of scope
	// (see the M16 paragraph in plan.md).
	allowedVideoExt = map[string]string{
		"mp4": "mp4",
	}
)

// validImagePackType returns true if `t` is one of the allowed image types.
func validImagePackType(t string) bool {
	_, ok := allowedImageExt[t]
	return ok
}

// validVideoPackType returns true if `t` is one of the allowed video types.
func validVideoPackType(t string) bool {
	_, ok := allowedVideoExt[t]
	return ok
}

// validPackType returns true for any allowed pack type (image, zip, or video).
func validPackType(t string) bool {
	return t == "zip" || validImagePackType(t) || validVideoPackType(t)
}

// sourcePath returns the on-disk path of the original uploaded bytes for
// the given manifest. Image packs ARE the source (content/image.<ext>),
// so they reuse their content file. Zip packs store the raw upload at
// `<version>/source.zip` so it can be re-served verbatim from
// /packs/<id>/download.
func sourcePath(packDir string, m PackManifest) string {
	versionDir := filepath.Join(packDir, strconv.Itoa(m.Version))
	if m.Type == "zip" {
		return filepath.Join(versionDir, "source.zip")
	}
	return filepath.Join(versionDir, "content", m.Filename)
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
		writeError(w, http.StatusMethodNotAllowed,
			"method_not_allowed", "method not allowed")
	}
}

// handlePackByID dispatches GET /packs/{id}/manifest, GET /packs/{id}/download
// and DELETE /packs/{id}.
func (s *hyacinthServer) handlePackByID(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/packs/")
	if rest == "" {
		writeError(w, http.StatusNotFound, "not_found", "not found")
		return
	}
	parts := strings.Split(rest, "/")
	id := parts[0]
	if !validPackID(id) {
		logError(r, "bad_request", errors.New("invalid pack id"))
		writeError(w, http.StatusBadRequest,
			"bad_request", "invalid pack id (slug ^[a-z0-9][a-z0-9-]{0,31}$)")
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
		writeError(w, http.StatusNotFound, "not_found", "not found")
	}
}

func (s *hyacinthServer) handleListPacks(w http.ResponseWriter, r *http.Request) {
	s.packsMu.Lock()
	defer s.packsMu.Unlock()
	entries, err := s.readIndex()
	if err != nil {
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "read pack index")
		return
	}
	body, err := json.Marshal(entries)
	if err != nil {
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "encode pack index")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(body)
}

func (s *hyacinthServer) handleGetManifest(w http.ResponseWriter, r *http.Request, id string) {
	s.packsMu.Lock()
	defer s.packsMu.Unlock()
	m, err := s.latestManifest(id)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			logError(r, "not_found", err)
			writeError(w, http.StatusNotFound, "not_found", "pack not found")
			return
		}
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "read manifest")
		return
	}
	body, err := json.Marshal(m)
	if err != nil {
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "encode manifest")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(body)
}

func (s *hyacinthServer) handleDownloadPack(w http.ResponseWriter, r *http.Request, id string) {
	s.packsMu.Lock()
	m, err := s.latestManifest(id)
	if err != nil {
		s.packsMu.Unlock()
		if errors.Is(err, os.ErrNotExist) {
			logError(r, "not_found", err)
			writeError(w, http.StatusNotFound, "not_found", "pack not found")
			return
		}
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "read manifest")
		return
	}
	pd, _ := s.packDir(id)
	srcPath := sourcePath(pd, m)
	// Open the file BEFORE releasing packsMu so a concurrent DELETE
	// can't unlink the inode out from under us. On POSIX the OS keeps
	// the inode alive as long as we hold the descriptor; on Windows the
	// rename/delete in DELETE would fail, which is fine.
	f, openErr := os.Open(srcPath)
	s.packsMu.Unlock()

	if openErr != nil {
		if errors.Is(openErr, os.ErrNotExist) {
			logError(r, "not_found", openErr)
			writeError(w, http.StatusNotFound, "not_found", "pack file missing")
			return
		}
		logError(r, "internal_error", openErr)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "open pack file")
		return
	}
	defer f.Close()
	stat, err := f.Stat()
	if err != nil {
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "stat pack file")
		return
	}
	w.Header().Set("Content-Type", mimeForType(m.Type))
	w.Header().Set("Cache-Control", "public, max-age=3600")
	w.Header().Set("ETag", `"`+m.SHA256+`"`)
	servedName := m.Filename
	if m.Type == "zip" {
		servedName = id + ".zip"
	}
	http.ServeContent(w, r, servedName, stat.ModTime(), f)
}

func (s *hyacinthServer) handleDeletePack(w http.ResponseWriter, r *http.Request, id string) {
	s.packsMu.Lock()
	defer s.packsMu.Unlock()

	pd, err := s.packDir(id)
	if err != nil {
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "resolve pack dir")
		return
	}
	if _, err := os.Stat(pd); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			logError(r, "not_found", err)
			writeError(w, http.StatusNotFound, "not_found", "pack not found")
			return
		}
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "stat pack dir")
		return
	}
	if err := os.RemoveAll(pd); err != nil {
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "remove pack dir")
		return
	}
	entries, err := s.readIndex()
	if err != nil {
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "read pack index")
		return
	}
	entries, _ = removeIndexEntry(entries, id)
	if err := s.writeIndex(entries); err != nil {
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "write pack index")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *hyacinthServer) handleUploadPack(w http.ResponseWriter, r *http.Request) {
	// Cap the request body BEFORE touching multipart parsing so an oversize
	// upload bails out early. We use the largest of the per-type caps here
	// so the type-specific check below can still emit a precise error.
	r.Body = http.MaxBytesReader(w, r.Body, maxUploadBodyBytes)
	if err := r.ParseMultipartForm(maxUploadBodyBytes); err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) || strings.Contains(err.Error(), "request body too large") {
			logError(r, "payload_too_large", err)
			writeError(w, http.StatusRequestEntityTooLarge,
				"payload_too_large", "pack too large")
			return
		}
		logError(r, "bad_request", err)
		writeError(w, http.StatusBadRequest,
			"bad_request", "multipart parse: "+err.Error())
		return
	}

	id := strings.TrimSpace(r.FormValue("id"))
	packType := strings.TrimSpace(strings.ToLower(r.FormValue("type")))

	if !validPackID(id) {
		logError(r, "bad_request", errors.New("invalid pack id"))
		writeError(w, http.StatusBadRequest,
			"bad_request", "invalid pack id (slug ^[a-z0-9][a-z0-9-]{0,31}$)")
		return
	}
	if !validPackType(packType) {
		logError(r, "bad_request", errors.New("invalid pack type"))
		writeError(w, http.StatusBadRequest,
			"bad_request", "invalid pack type (allowed: png, jpg, webp, gif, zip, mp4)")
		return
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		logError(r, "bad_request", err)
		writeError(w, http.StatusBadRequest,
			"bad_request", "missing 'file' part: "+err.Error())
		return
	}
	defer file.Close()
	if header.Size <= 0 {
		logError(r, "bad_request", errors.New("empty file"))
		writeError(w, http.StatusBadRequest, "bad_request", "empty file")
		return
	}

	mh := &multipartHeader{Filename: header.Filename, Size: header.Size}
	if packType == "zip" {
		s.uploadZipPack(w, r, id, file, mh)
		return
	}
	if validVideoPackType(packType) {
		s.uploadVideoPack(w, r, id, packType, file, mh)
		return
	}
	s.uploadImagePack(w, r, id, packType, file, mh)
}

// uploadVideoPack is the M16 video path. Parallel to uploadImagePack but
// with a video MIME sniff and a 200 MiB ceiling instead of 50 MiB.
func (s *hyacinthServer) uploadVideoPack(w http.ResponseWriter, r *http.Request, id, packType string, file io.Reader, header *multipartHeader) {
	if header.Size > maxVideoBodyBytes {
		logError(r, "payload_too_large", errors.New("video pack too large"))
		writeError(w, http.StatusRequestEntityTooLarge,
			"payload_too_large", "pack too large")
		return
	}

	// Filename extension must match the declared type. M16 ships mp4 only,
	// so the only accepted suffix is .mp4 — no aliases.
	origName := header.Filename
	gotExt := strings.ToLower(strings.TrimPrefix(filepath.Ext(origName), "."))
	if gotExt != allowedVideoExt[packType] {
		logError(r, "bad_request", errors.New("ext mismatch"))
		writeError(w, http.StatusBadRequest, "bad_request",
			fmt.Sprintf("file extension %q does not match type %q", gotExt, packType))
		return
	}

	buf, err := io.ReadAll(file)
	if err != nil {
		logError(r, "bad_request", err)
		writeError(w, http.StatusBadRequest,
			"bad_request", "read upload: "+err.Error())
		return
	}
	if int64(len(buf)) != header.Size {
		logError(r, "bad_request", errors.New("short read"))
		writeError(w, http.StatusBadRequest, "bad_request", "short read")
		return
	}
	sniff := http.DetectContentType(buf)
	// http.DetectContentType returns "video/mp4" for ISO-BMFF mp4 files; we
	// only accept that exact prefix to keep the gate tight (no audio/* or
	// application/* fallbacks).
	if !strings.HasPrefix(sniff, "video/mp4") {
		logError(r, "bad_request", errors.New("not mp4: "+sniff))
		writeError(w, http.StatusBadRequest, "bad_request",
			"uploaded bytes are not an mp4 video (sniffed: "+sniff+")")
		return
	}

	sum := sha256.Sum256(buf)
	hash := hex.EncodeToString(sum[:])

	s.packsMu.Lock()
	defer s.packsMu.Unlock()

	pd, err := s.packDir(id)
	if err != nil {
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "resolve pack dir")
		return
	}
	nextVersion, err := s.nextVersionLocked(pd)
	if err != nil {
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "next version")
		return
	}

	storedFilename := "video." + allowedVideoExt[packType]
	versionDir := filepath.Join(pd, strconv.Itoa(nextVersion))
	contentDir := filepath.Join(versionDir, "content")
	if err := os.MkdirAll(contentDir, 0o755); err != nil {
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "mkdir content")
		return
	}
	contentPath := filepath.Join(contentDir, storedFilename)
	if err := atomicWriteFile(contentPath, buf); err != nil {
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "write content")
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
	if err := s.writeManifestAndIndex(w, r, pd, versionDir, manifest); err != nil {
		return // writeManifestAndIndex already wrote the error response
	}
	s.pruneOldVersionsLocked(pd)
}

// uploadImagePack is the M5 image-only path, factored out so the dispatch
// in handleUploadPack stays trivial.
func (s *hyacinthServer) uploadImagePack(w http.ResponseWriter, r *http.Request, id, packType string, file io.Reader, header *multipartHeader) {
	if header.Size > maxPackBodyBytes {
		logError(r, "payload_too_large", errors.New("image pack too large"))
		writeError(w, http.StatusRequestEntityTooLarge,
			"payload_too_large", "pack too large")
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
		logError(r, "bad_request", errors.New("ext mismatch"))
		writeError(w, http.StatusBadRequest, "bad_request",
			fmt.Sprintf("file extension %q does not match type %q", gotExt, packType))
		return
	}

	buf, err := io.ReadAll(file)
	if err != nil {
		logError(r, "bad_request", err)
		writeError(w, http.StatusBadRequest,
			"bad_request", "read upload: "+err.Error())
		return
	}
	if int64(len(buf)) != header.Size {
		logError(r, "bad_request", errors.New("short read"))
		writeError(w, http.StatusBadRequest, "bad_request", "short read")
		return
	}
	sniff := http.DetectContentType(buf)
	if !strings.HasPrefix(sniff, "image/") {
		logError(r, "bad_request", errors.New("not image: "+sniff))
		writeError(w, http.StatusBadRequest, "bad_request",
			"uploaded bytes are not an image (sniffed: "+sniff+")")
		return
	}

	sum := sha256.Sum256(buf)
	hash := hex.EncodeToString(sum[:])

	s.packsMu.Lock()
	defer s.packsMu.Unlock()

	pd, err := s.packDir(id)
	if err != nil {
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "resolve pack dir")
		return
	}
	nextVersion, err := s.nextVersionLocked(pd)
	if err != nil {
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "next version")
		return
	}

	storedFilename := "image." + allowedImageExt[packType]
	versionDir := filepath.Join(pd, strconv.Itoa(nextVersion))
	contentDir := filepath.Join(versionDir, "content")
	if err := os.MkdirAll(contentDir, 0o755); err != nil {
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "mkdir content")
		return
	}
	contentPath := filepath.Join(contentDir, storedFilename)
	if err := atomicWriteFile(contentPath, buf); err != nil {
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "write content")
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
	if err := s.writeManifestAndIndex(w, r, pd, versionDir, manifest); err != nil {
		return // writeManifestAndIndex already wrote the error response
	}
	s.pruneOldVersionsLocked(pd)
}

// uploadZipPack handles type=zip uploads: validation, extraction into a
// staging dir, atomic rename to the version dir, sha256 over the raw zip
// bytes, manifest write, and index upsert.
func (s *hyacinthServer) uploadZipPack(w http.ResponseWriter, r *http.Request, id string, file io.Reader, header *multipartHeader) {
	if header.Size > maxZipBodyBytes {
		logError(r, "payload_too_large", errors.New("zip pack too large"))
		writeError(w, http.StatusRequestEntityTooLarge,
			"payload_too_large", "pack too large")
		return
	}

	buf, err := io.ReadAll(file)
	if err != nil {
		logError(r, "bad_request", err)
		writeError(w, http.StatusBadRequest,
			"bad_request", "read upload: "+err.Error())
		return
	}
	if int64(len(buf)) != header.Size {
		logError(r, "bad_request", errors.New("short read"))
		writeError(w, http.StatusBadRequest, "bad_request", "short read")
		return
	}

	zr, err := zip.NewReader(bytes.NewReader(buf), int64(len(buf)))
	if err != nil {
		logError(r, "bad_request", err)
		writeError(w, http.StatusBadRequest,
			"bad_request", "invalid zip: "+err.Error())
		return
	}
	if err := validateZipEntries(zr); err != nil {
		logError(r, "bad_request", err)
		writeError(w, http.StatusBadRequest,
			"bad_request", "zip validation: "+err.Error())
		return
	}

	sum := sha256.Sum256(buf)
	hash := hex.EncodeToString(sum[:])

	s.packsMu.Lock()
	defer s.packsMu.Unlock()

	pd, err := s.packDir(id)
	if err != nil {
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "resolve pack dir")
		return
	}
	nextVersion, err := s.nextVersionLocked(pd)
	if err != nil {
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "next version")
		return
	}

	versionDir := filepath.Join(pd, strconv.Itoa(nextVersion))
	stagingDir := versionDir + ".staging"
	// Wipe any leftover staging from a previous crash.
	_ = os.RemoveAll(stagingDir)
	contentDir := filepath.Join(stagingDir, "content")
	if err := os.MkdirAll(contentDir, 0o755); err != nil {
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "mkdir content")
		return
	}

	// Extract every entry into the staging content dir. validateZipEntries
	// already verified entry names are safe and capped sizes.
	if err := extractZipTo(zr, contentDir); err != nil {
		_ = os.RemoveAll(stagingDir)
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "zip extract: "+err.Error())
		return
	}

	// Save the original zip alongside the extracted tree so /download can
	// re-serve it byte-for-byte.
	if err := os.WriteFile(filepath.Join(stagingDir, "source.zip"), buf, 0o644); err != nil {
		_ = os.RemoveAll(stagingDir)
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "write source.zip")
		return
	}

	manifest := PackManifest{
		ID:        id,
		Version:   nextVersion,
		Type:      "zip",
		Filename:  "index.html",
		SHA256:    hash,
		Size:      int64(len(buf)),
		CreatedAt: time.Now().UTC().Format(time.RFC3339),
	}
	manifestBytes, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		_ = os.RemoveAll(stagingDir)
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "encode manifest")
		return
	}
	if err := os.WriteFile(filepath.Join(stagingDir, "manifest.json"), manifestBytes, 0o644); err != nil {
		_ = os.RemoveAll(stagingDir)
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "write manifest")
		return
	}

	// Atomic flip: rename the entire staging dir to the final version dir.
	if err := os.Rename(stagingDir, versionDir); err != nil {
		_ = os.RemoveAll(stagingDir)
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "atomic rename: "+err.Error())
		return
	}

	// Index update.
	entries, err := s.readIndex()
	if err != nil {
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "read index")
		return
	}
	entries = upsertIndexEntry(entries, manifest)
	if err := s.writeIndex(entries); err != nil {
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "write index")
		return
	}
	s.pruneOldVersionsLocked(pd)

	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(manifestBytes)
}

// nextVersionLocked computes the next monotonic version. Caller holds packsMu.
func (s *hyacinthServer) nextVersionLocked(packDir string) (int, error) {
	existing, err := listVersionsDesc(packDir)
	if err != nil {
		return 0, err
	}
	if len(existing) == 0 {
		return 1, nil
	}
	return existing[0] + 1, nil
}

// writeManifestAndIndex writes manifest.json under versionDir and upserts
// the index entry. On any error it writes an HTTP error response and
// returns the same error so the caller can early-return. Image-pack only.
func (s *hyacinthServer) writeManifestAndIndex(w http.ResponseWriter, r *http.Request, _ /*packDir*/, versionDir string, manifest PackManifest) error {
	manifestBytes, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "encode manifest")
		return err
	}
	manifestPath := filepath.Join(versionDir, "manifest.json")
	if err := atomicWriteFile(manifestPath, manifestBytes); err != nil {
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "write manifest")
		return err
	}
	entries, err := s.readIndex()
	if err != nil {
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "read index")
		return err
	}
	entries = upsertIndexEntry(entries, manifest)
	if err := s.writeIndex(entries); err != nil {
		logError(r, "internal_error", err)
		writeError(w, http.StatusInternalServerError,
			"internal_error", "write index")
		return err
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(manifestBytes)
	return nil
}

// pruneOldVersionsLocked enforces the rollback-retention window. Caller
// holds packsMu.
func (s *hyacinthServer) pruneOldVersionsLocked(packDir string) {
	allVersions, _ := listVersionsDesc(packDir)
	if len(allVersions) > versionsToKeep {
		for _, v := range allVersions[versionsToKeep:] {
			_ = os.RemoveAll(filepath.Join(packDir, strconv.Itoa(v)))
		}
	}
}

// multipartHeader is a tiny shim around *multipart.FileHeader so the
// per-type upload helpers don't have to import the multipart package
// directly. We only need Filename and Size.
type multipartHeader struct {
	Filename string
	Size     int64
}

// validateZipEntries enforces the path-traversal, zip-bomb, and
// entry-count defenses. Returns nil iff the archive is acceptable.
func validateZipEntries(zr *zip.Reader) error {
	if len(zr.File) == 0 {
		return errors.New("empty archive")
	}
	if len(zr.File) > maxZipEntries {
		return fmt.Errorf("too many entries (%d > %d)", len(zr.File), maxZipEntries)
	}
	var total uint64
	hasIndex := false
	for _, f := range zr.File {
		name := f.Name
		if name == "" {
			return errors.New("entry with empty name")
		}
		if !isSafeRelPath(name) {
			return fmt.Errorf("unsafe entry name %q", name)
		}
		if f.UncompressedSize64 > uint64(maxZipEntryUncompr) {
			return fmt.Errorf("entry %q exceeds %d bytes", name, maxZipEntryUncompr)
		}
		total += f.UncompressedSize64
		if total > uint64(maxZipUncompressed) {
			return fmt.Errorf("uncompressed total exceeds %d bytes", maxZipUncompressed)
		}
		// "index.html at archive root" — case-insensitive, top level only.
		if !f.FileInfo().IsDir() && strings.EqualFold(name, "index.html") {
			hasIndex = true
		}
	}
	if !hasIndex {
		return errors.New("missing index.html at archive root")
	}
	return nil
}

// isSafeRelPath rejects entry names that could escape the extraction root
// or contain control characters. Mirrored on the client.
func isSafeRelPath(name string) bool {
	if name == "" {
		return false
	}
	if strings.ContainsAny(name, "\\\x00") {
		return false
	}
	if strings.HasPrefix(name, "/") {
		return false
	}
	// Reject any segment equal to ".." (covers "../x", "a/../b", etc).
	cleaned := path.Clean(name)
	if cleaned == ".." || strings.HasPrefix(cleaned, "../") {
		return false
	}
	for _, seg := range strings.Split(name, "/") {
		if seg == ".." {
			return false
		}
	}
	return true
}

// extractZipTo writes every file entry in zr into destDir, creating
// parent directories as needed. Directory entries are skipped (parents
// are created implicitly). Caller must already have validated entry
// names and sizes via validateZipEntries.
func extractZipTo(zr *zip.Reader, destDir string) error {
	for _, f := range zr.File {
		if f.FileInfo().IsDir() {
			continue
		}
		outPath := filepath.Join(destDir, filepath.FromSlash(f.Name))
		// Defense in depth: confirm the resolved path is still inside destDir.
		rel, err := filepath.Rel(destDir, outPath)
		if err != nil || strings.HasPrefix(rel, "..") {
			return fmt.Errorf("entry %q escapes destination", f.Name)
		}
		if err := os.MkdirAll(filepath.Dir(outPath), 0o755); err != nil {
			return err
		}
		rc, err := f.Open()
		if err != nil {
			return err
		}
		// Cap per-entry copy at maxZipEntryUncompr — defends against a
		// liar header that under-reports UncompressedSize64.
		out, err := os.OpenFile(outPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
		if err != nil {
			rc.Close()
			return err
		}
		_, err = io.CopyN(out, rc, int64(maxZipEntryUncompr)+1)
		if err != nil && !errors.Is(err, io.EOF) {
			out.Close()
			rc.Close()
			return err
		}
		// If we wrote more than the cap, the header lied — abort.
		stat, _ := out.Stat()
		out.Close()
		rc.Close()
		if stat != nil && stat.Size() > int64(maxZipEntryUncompr) {
			return fmt.Errorf("entry %q exceeds %d bytes", f.Name, maxZipEntryUncompr)
		}
	}
	return nil
}

// mimeForType returns the canonical Content-Type for a pack type
// (image, zip, or video).
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
	case "zip":
		return "application/zip"
	case "mp4":
		return "video/mp4"
	}
	return "application/octet-stream"
}
