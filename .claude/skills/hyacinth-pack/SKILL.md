---
name: hyacinth-pack
description: Scaffold a new Hyacinth content pack — a small Vite project that builds to a zip the kiosk server can serve over the `hyacinth://pack/<id>/` scheme. Use this whenever the user wants to make new visual content for their Ita-Bag display, including phrases like "make a new pack", "scaffold a content pack", "I want to put X on the bag", "create something for the kiosk", "spin up a Vite project for hyacinth", "new hyacinth pack", "make me a clock pack", "I want to design a screen for the bag", or any request that would result in new content being shown on the wall-mounted tablet. Prefer this skill over generic Vite scaffolding whenever the project is at `/home/nvirellia/Projects/hyacinth` or its working directory mentions Hyacinth — generic `npm create vite` will produce a project that doesn't render correctly under the `hyacinth://` custom scheme.
---

# Hyacinth Pack — Scaffolding & Lifecycle

## What you're building

A "content pack" is a tiny self-contained Vite project that lives at `packs/<pack-id>/` in the Hyacinth repo. You build it (`vite build`) into a `dist/` directory; the project's Justfile zips that dist up and POSTs it to the running Hyacinth server, which validates, stores, and serves it back to the tablet over the custom `hyacinth://pack/<id>/<path>` scheme. Inside the kiosk's WebView, the pack's `index.html` becomes the entire display surface — fullscreen, no chrome, no scroll. The built `dist/` must be fully self-contained: no runtime network requests, no CDN references, no hot-linked assets — the Ita-Bag tablet is routinely offline, and a pack that tries to fetch anything across the wire silently degrades.

The kiosk has very specific constraints. Get them right once in the scaffold and every future pack inherits them.

## Constraints the scaffold encodes

These are the gotchas that distinguish a Hyacinth pack from a normal Vite project. The bundled templates already handle them; this section exists so you understand *why* and don't undo them.

1. **`base: './'` in `vite.config.js`** — Vite defaults to `base: '/'`, which produces absolute URLs (`<script src="/assets/main.js">`). Under the `hyacinth://pack/<id>/` scheme those resolve against the WebView origin and break every asset reference. Relative `./` paths are mandatory; never change this.
2. **`target: 'esnext'`** — `flutter_inappwebview` is modern Chrome (M115+ on the user's tablet). Skip the legacy polyfill bundle bloat. The M11 powersave CPU governor means every wasted cycle hurts.
3. **No touch events** — M12 unconditionally wraps the WebView in `IgnorePointer`. `click` / `tap` / `pointerdown` listeners on pack content will never fire. Don't bother. Build for ambient consumption: animations, clocks, slideshows, dashboards, art. Not interactive widgets.
4. **Single CSS bundle (`cssCodeSplit: false`)** — packs are usually one HTML page. Splitting CSS adds loader overhead for no benefit at this scale.
5. **No network requests at runtime** — packs are sealed offline payloads. Source `index.html` can keep a `<link>` to `fonts.googleapis.com` for readability (the font choice stays obvious at a glance, and `vite dev` still works over Wi-Fi), but `vite-plugin-webfont-dl` is wired into the template's `vite.config.js` so the built `dist/` contains zero `https://` references — the plugin downloads the Google Fonts CSS + woff2 files at build time and rewrites the `<link>` to point at local asset paths. Do **not** remove the plugin. Do **not** add `<script src="https://...">`, `fetch('https://...')`, hotlinked images, or CDN imports — those are not covered by the plugin and will break offline. The `just pack-build <id>` recipe runs a `pack-lint` step that greps the built `dist/` for any `https://` reference and hard-fails the build if it finds one, so a regression here is caught before the zip is uploaded.
6. **Size caps** — the server enforces ≤ 50 MiB zip body, ≤ 200 MiB uncompressed total, ≤ 50 MiB per entry, ≤ 5000 entries. The hello-bag starter is well under 30 KiB before fonts. Stay light.
7. **No path traversal** — every file in the dist must live at or under the dist root. Don't reach outside it with `../` references.
8. **Powersave CPU** — M11 auto-tunes the tablet to `powersave` while content is showing. Heavy `requestAnimationFrame` loops (60fps shaders, particle physics) will jitter. Prefer CSS animations, sparse `setInterval` updates, or 30fps caps.
9. **Landscape, responsive** — the tablet is mounted horizontally. Design with `vw`/`vh`/`clamp()` and relative units so the layout adapts to whatever viewport the WebView reports — Android's `devicePixelRatio` scaling means the CSS viewport is smaller than the physical screen, and hardcoding pixel counts will bite. `vite dev` in a desktop browser at a landscape tablet aspect ratio is the primary preview surface; the layout should survive any reasonable viewport without breaking.

## Device telemetry (Web APIs)

Packs can reach the tablet's battery and network state directly through two standard web APIs — no Hyacinth-owned JS bridge, no MethodChannel, no `window.hyacinth` namespace. Android System WebView is Chromium/Blink and still ships both `navigator.getBattery()` and `navigator.connection`; Firefox and Safari removed them on fingerprinting grounds, but Chrome kept them, and `flutter_inappwebview` inherits that. Use them as-is and treat the desktop-browser preview path as the edge case, not the kiosk.

**`navigator.getBattery()`** — returns a `Promise<BatteryManager>`. The manager exposes `level` (float, 0..1), `charging` (bool), `chargingTime` (seconds until full, or `Infinity` if discharging), and `dischargingTime` (seconds until empty, or `Infinity` if charging or unknown). It emits four events: `levelchange`, `chargingchange`, `chargingtimechange`, `dischargingtimechange`. Subscribe to whichever ones you care about; the updates are push-driven by the OS so no polling timer is needed.

**`navigator.connection`** — a live `NetworkInformation` object. Read `type` (`'wifi'`, `'ethernet'`, `'cellular'`, `'none'`, etc.), `effectiveType` (`'4g'`, `'3g'`, `'2g'`, `'slow-2g'`), `downlink` (estimated Mbps), and `saveData` (bool, reflects the OS data-saver toggle). It emits a single `change` event whenever any of those fields updates.

**Feature-detect, always.** Packs MUST guard both APIs with `if ('getBattery' in navigator)` / `if ('connection' in navigator)` before calling them. The `pnpm dev` desktop preview path is the primary iteration surface before M15.1 kiosk push, and pack authors routinely open it in Firefox — which returns `undefined` for both. Treat "API missing" as a first-class branch that hides the telemetry element cleanly, not as an error state.

```js
// Feature-detect once at startup.
const battery = 'getBattery' in navigator ? await navigator.getBattery() : null;
const el = document.querySelector('#battery');

function renderBattery() {
  if (!battery) { el.style.display = 'none'; return; }
  el.textContent = Math.round(battery.level * 100) + '%';
}

renderBattery();
battery?.addEventListener('levelchange', renderBattery);
battery?.addEventListener('chargingchange', renderBattery);
```

**What this doesn't give you.** No data-usage byte counters (Android `TrafficStats` has no web equivalent, and a pack-side carrier-cap calculation would be worse than useless); no carrier or SIM info (gated on phone-state permissions Hyacinth deliberately never requests); no per-pack permission gating (if the WebView has the API, every pack has it — treat it as ambient, not scoped); read-only (these APIs cannot change device state, only observe it). If you find yourself wanting any of those, stop and ask — a future milestone can add a native bridge, but today's answer is "out of scope, use what the web gives you."

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

Set these once per shell (or in your shell rc):
  export HYACINTH_SERVER=http://<kiosk-ip>:8080
  export HYACINTH_TOKEN=<operator-token>

Iterate on the actual tablet with HMR (recommended):
  just pack-dev <id>      # pushes vite --host URL to the kiosk; HMR on save
                          # Ctrl-C to stop and restore the previous content
                          # falls back to http://localhost:5173 if HYACINTH_SERVER
                          # is unset or unreachable

When the pack is ready, publish a release-ready zip to the kiosk:
  just pack-upload <id>   # build, lint, zip, and POST

Any installed Hyacinth APK (debug or release) works with `pack-dev` —
M15.3 dropped the network security config so cleartext HTTP to LAN
IPs is allowed in both build variants.
```

Don't run any of those commands automatically — `vite dev` blocks the terminal, and `pack-upload` will fail with a confusing curl error if the user hasn't started the server yet. Let them drive the next step.

## Justfile recipes

The pack lifecycle recipes (`pack-dev`, `pack-build`, `pack-lint`, `pack-upload`, `_pack-vite-build`) live in the project's top-level `Justfile` and are checked into the repo. They are considered the canonical, evolving definition — this skill does **not** duplicate the source here, because every milestone that touches pack tooling (M5 added the basic recipes, M15 split `pack-build` and added `pack-lint`, M15.1 rewrote `pack-dev` as a bash script with on-device kiosk push) would otherwise drift out of sync.

If the recipes are missing from a fresh checkout (which should not happen — they're tracked in git), copy them from the live `Justfile` rather than from any embedded block in this skill.

The recipes use `pnpm`, not `npm` (install via `corepack enable && corepack prepare pnpm@latest --activate`, or `npm install -g pnpm`), and respect two env vars in this project: `HYACINTH_SERVER` (kiosk URL, default `http://localhost:8080`) and `HYACINTH_TOKEN` (operator bearer token, default empty). Both `pack-dev` (M15.1 on-device live dev) and `pack-upload` use them; both fall back gracefully when they're unset.

## After the user has a pack

Once the scaffold is in place, the **primary iteration loop** is `just pack-dev <id>` against the actual tablet. The recipe auto-detects the dev machine's LAN IP relative to `HYACINTH_SERVER`, pushes `http://<dev-ip>:5173/` onto the kiosk's `/config.content` so the tablet's WebView loads the running Vite dev server directly, and Vite HMR patches modules in place on every source save — edit a CSS file, blink, the change is on the tablet. Ctrl-C the recipe to stop and restore the previous kiosk content (an EXIT trap handles this on normal exit, errors, and Ctrl-C alike).

**No build-variant prerequisite**: any installed Hyacinth APK works with `pack-dev`. M15.3 dropped the M8/M15.1 network security config story entirely — the release manifest now declares `android:usesCleartextTraffic="true"` and ships no NSC, so debug and release builds both accept cleartext HTTP to LAN IPs. Whether the tablet is running `just install` (debug) or `just apk-install` (release) makes no difference here.

**Fallback path** for when you don't have the tablet handy: if `HYACINTH_SERVER` is unset, unreachable, or the LAN-IP detection fails, `pack-dev` prints a warning and falls through to plain `pnpm exec vite` on `http://localhost:5173/` for desktop-browser preview. No env-var juggling needed — same recipe, automatic fallback.

When the pack is ready for actual deployment, `just pack-upload <id>` builds, lints (M15 offline-pure check), zips, and POSTs the dist to the kiosk; the WS broadcast switches the tablet to the released pack within ~1s.

The first upload also wires up the operator UI: open `http://<server>:8080/`, find the new pack in the Packs list, click the play_arrow icon — that publishes the pack's URL as the active `content` and the tablet switches to it within ~1s.

To remove a pack: delete `packs/<id>/` from disk and call `DELETE /packs/<id>` (or use the operator UI's delete button on the pack row). The client's M8.3 auto-sync will GC the cached copy on the tablet's next connect.

## Aesthetics — what the starter looks like

Cream paper background (`#F2F1DD`), forest-green ink (`#1F3A20`), muted sage (`#7E9072`) for accents. Big italic Cormorant Garamond clock centered on the canvas, the pack id rendered as spaced-out OpenType small caps below it, a single `✦` flourish underneath. Inspired by the Project Hyacinth herbarium card — the same visual language, restrained and editorial.

This is deliberately distinct from the operator UI's bold Material You purple. The two surfaces are different rooms in the same house: the operator UI is the *interface* (functional, dense, dark mode at night), the content packs are the *art* (ambient, sparse, paper-like, the thing strangers actually see when they look at the bag).

The user is welcome to throw all of this out — it's a starter, not a brand guide. The constraints in the "Constraints the scaffold encodes" section are the only things that must survive aesthetic rewrites.
