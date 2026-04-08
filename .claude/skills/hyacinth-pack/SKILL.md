---
name: hyacinth-pack
description: Scaffold a new Hyacinth content pack — a small Vite project that builds to a zip the kiosk server can serve over the `hyacinth://pack/<id>/` scheme. Use this whenever the user wants to make new visual content for their Ita-Bag display, including phrases like "make a new pack", "scaffold a content pack", "I want to put X on the bag", "create something for the kiosk", "spin up a Vite project for hyacinth", "new hyacinth pack", "make me a clock pack", "I want to design a screen for the bag", or any request that would result in new content being shown on the wall-mounted tablet. Prefer this skill over generic Vite scaffolding whenever the project is at `/home/nvirellia/Projects/hyacinth` or its working directory mentions Hyacinth — generic `npm create vite` will produce a project that doesn't render correctly under the `hyacinth://` custom scheme.
---

# Hyacinth Pack — Scaffolding & Lifecycle

## What you're building

A "content pack" is a tiny self-contained Vite project that lives at `packs/<pack-id>/` in the Hyacinth repo. You build it (`vite build`) into a `dist/` directory; the project's Justfile zips that dist up and POSTs it to the running Hyacinth server, which validates, stores, and serves it back to the tablet over the custom `hyacinth://pack/<id>/<path>` scheme. Inside the kiosk's WebView, the pack's `index.html` becomes the entire display surface — fullscreen, no chrome, no scroll.

The kiosk has very specific constraints. Get them right once in the scaffold and every future pack inherits them.

## Constraints the scaffold encodes

These are the gotchas that distinguish a Hyacinth pack from a normal Vite project. The bundled templates already handle them; this section exists so you understand *why* and don't undo them.

1. **`base: './'` in `vite.config.js`** — Vite defaults to `base: '/'`, which produces absolute URLs (`<script src="/assets/main.js">`). Under the `hyacinth://pack/<id>/` scheme those resolve against the WebView origin and break every asset reference. Relative `./` paths are mandatory; never change this.
2. **`target: 'esnext'`** — `flutter_inappwebview` is modern Chrome (M115+ on the user's tablet). Skip the legacy polyfill bundle bloat. The M11 powersave CPU governor means every wasted cycle hurts.
3. **No touch events** — M12 unconditionally wraps the WebView in `IgnorePointer`. `click` / `tap` / `pointerdown` listeners on pack content will never fire. Don't bother. Build for ambient consumption: animations, clocks, slideshows, dashboards, art. Not interactive widgets.
4. **Single CSS bundle (`cssCodeSplit: false`)** — packs are usually one HTML page. Splitting CSS adds loader overhead for no benefit at this scale.
5. **Size caps** — the server enforces ≤ 50 MiB zip body, ≤ 200 MiB uncompressed total, ≤ 50 MiB per entry, ≤ 5000 entries. The hello-bag starter is well under 30 KiB before fonts. Stay light.
6. **No path traversal** — every file in the dist must live at or under the dist root. Don't reach outside it with `../` references.
7. **Powersave CPU** — M11 auto-tunes the tablet to `powersave` while content is showing. Heavy `requestAnimationFrame` loops (60fps shaders, particle physics) will jitter. Prefer CSS animations, sparse `setInterval` updates, or 30fps caps.
8. **Landscape 1280×800** — that's the target tablet. Use `vw`/`vh`/`clamp()` so the layout still works in `vite dev` at desktop sizes.

## Scaffolding flow

When the user asks you to create a new pack:

### Step 1 — get the pack id

Ask for a slug if the user didn't already give one. Validate against the server's regex `^[a-z0-9][a-z0-9-]{0,31}$`:

- starts with `[a-z0-9]`
- contains only `[a-z0-9-]`
- 1–32 characters total
- no leading hyphen, no underscores, no uppercase

If the user proposes something invalid (e.g. `Cat Photos`), suggest a normalized form (`cat-photos`) and confirm before continuing. If they propose something the server's `slugRe` allows but that's still ugly (e.g. `aaaa`), accept it — it's their bag.

### Step 2 — refuse to clobber

Check whether `packs/<id>/` already exists. If it does, **stop and tell the user**. Don't overwrite. Suggest either picking a new slug or using `just pack-dev <id>` to iterate on the existing one.

### Step 3 — copy the templates with substitution

The skill bundles five template files at `.claude/skills/hyacinth-pack/assets/`:

- `package.json` — Vite devDep, npm scripts.
- `vite.config.js` — the load-bearing `base: './'` + esnext target config.
- `index.html` — the herbarium starter markup.
- `style.css` — cream paper, forest-green ink, Cormorant Garamond, generous negative space.
- `main.js` — ticks the clock once a second.

Each template contains the literal string `__PACK_ID__` wherever the pack id should be substituted. Copy each to `packs/<id>/<filename>`, replacing every `__PACK_ID__` with the user's slug. The substitution is a flat `s/__PACK_ID__/<slug>/g` — don't get clever with templating engines.

### Step 4 — add Justfile recipes if missing

The lifecycle recipes (`pack-dev`, `pack-build`, `pack-upload`) are added to the top-level `Justfile` once and reused for every pack. Check whether the recipes already exist (grep for `^pack-dev`). If they do, skip this step. If they don't, append the block from the "Justfile recipes" section below to the end of the file.

This is idempotent — the first pack you scaffold installs the recipes, every subsequent pack reuses them.

### Step 5 — verify pnpm is installed (and tell the user how to fix it if not)

The lifecycle recipes use `pnpm`, not `npm`. Before telling the user the next commands, run `command -v pnpm` (or check `pnpm --version`). If it's missing, tell the user **before** they hit a confusing recipe error:

```
⚠ pnpm not found. The pack lifecycle recipes (just pack-dev / pack-build /
  pack-upload) need pnpm installed.

  Recommended (ships with Node 16.13+):
      corepack enable
      corepack prepare pnpm@latest --activate

  Alternative:
      npm install -g pnpm

  Re-run `just pack-dev <id>` once pnpm is on PATH.
```

If pnpm IS installed, skip the warning and move on.

### Step 6 — tell the user the next commands

After the scaffold lands, print exactly:

```
✦ Pack scaffolded at packs/<id>/

Next steps:
  just pack-dev <id>      # live preview at http://localhost:5173
  just pack-upload <id>   # build, zip, and POST to the running Hyacinth server

The server respects HYACINTH_SERVER (default http://localhost:8080) and
HYACINTH_TOKEN (default empty) from the environment.
```

Don't run any of those commands automatically — `vite dev` blocks the terminal, and `pack-upload` will fail with a confusing curl error if the user hasn't started the server yet. Let them drive the next step.

## Justfile recipes

Append this block to the project's top-level `Justfile` if `pack-dev` doesn't already exist:

```just
# ----- Hyacinth content packs (see .claude/skills/hyacinth-pack/SKILL.md)
# Requires pnpm — install via `npm install -g pnpm` or `corepack enable`
# (recommended: corepack, ships with Node 16.13+).
# Lazy install: node_modules is created on first dev/build, reused thereafter.
# Override server + auth via env: HYACINTH_SERVER, HYACINTH_TOKEN.

pack-dev id:
    @cd packs/{{id}} && [ -d node_modules ] || pnpm install --silent
    cd packs/{{id}} && pnpm exec vite

pack-build id:
    @cd packs/{{id}} && [ -d node_modules ] || pnpm install --silent
    cd packs/{{id}} && pnpm exec vite build

pack-upload id: (pack-build id)
    cd packs/{{id}}/dist && zip -qr ../pack.zip .
    curl -fsS -X POST \
        -H "Authorization: Bearer ${HYACINTH_TOKEN:-}" \
        -F "id={{id}}" -F "type=zip" -F "file=@packs/{{id}}/pack.zip" \
        "${HYACINTH_SERVER:-http://localhost:8080}/packs"
    @echo ""
    @echo "✦ Uploaded {{id}} to ${HYACINTH_SERVER:-http://localhost:8080}"
    @echo "  Set the operator UI's content URL to: hyacinth://pack/{{id}}/index.html"
```

## After the user has a pack

Once the scaffold is in place, the user iterates with `just pack-dev <id>` (browser preview at http://localhost:5173, Vite hot-reloads on save) and `just pack-upload <id>` (publishes to the server, which broadcasts to the tablet via WS).

The first upload also wires up the operator UI: open `http://<server>:8080/`, find the new pack in the Packs list, click the play_arrow icon — that publishes the pack's URL as the active `content` and the tablet switches to it within ~1s.

To remove a pack: delete `packs/<id>/` from disk and call `DELETE /packs/<id>` (or use the operator UI's delete button on the pack row). The client's M8.3 auto-sync will GC the cached copy on the tablet's next connect.

## Aesthetics — what the starter looks like

Cream paper background (`#F2F1DD`), forest-green ink (`#1F3A20`), muted sage (`#7E9072`) for accents. Big italic Cormorant Garamond clock centered on the canvas, the pack id rendered as spaced-out OpenType small caps below it, a single `✦` flourish underneath. Inspired by the Project Hyacinth herbarium card — the same visual language, restrained and editorial.

This is deliberately distinct from the operator UI's bold Material You purple. The two surfaces are different rooms in the same house: the operator UI is the *interface* (functional, dense, dark mode at night), the content packs are the *art* (ambient, sparse, paper-like, the thing strangers actually see when they look at the bag).

The user is welcome to throw all of this out — it's a starter, not a brand guide. The constraints in the "Constraints the scaffold encodes" section are the only things that must survive aesthetic rewrites.
