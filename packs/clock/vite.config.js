import { defineConfig } from 'vite';

// Hyacinth content pack — see .claude/skills/hyacinth-pack/SKILL.md for the
// full constraint list. The two load-bearing settings:
//
//   - `base: './'` — the WebView serves the built dist at `hyacinth://pack/<id>/`,
//     and Vite's default `base: '/'` would produce absolute URLs that resolve
//     against the WebView's *origin* and break every asset reference. Relative
//     paths are mandatory.
//   - `target: 'esnext'` — the kiosk's flutter_inappwebview is modern Chrome,
//     so we skip the legacy polyfill bloat. Smaller bundle, faster cold start
//     on the M11 powersave CPU.
export default defineConfig({
  base: './',
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    target: 'esnext',
    cssCodeSplit: false,
    minify: 'esbuild',
    assetsInlineLimit: 0,
  },
});
