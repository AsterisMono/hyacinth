import { defineConfig } from 'vite';
import webfontDownload from 'vite-plugin-webfont-dl';

// Hyacinth content pack — see .claude/skills/hyacinth-pack/SKILL.md for the
// full constraint list.
//
// M15 offline-pure invariant: `vite-plugin-webfont-dl` is wired in below so
// the Google Fonts <link> tags in index.html are transparently converted into
// self-hosted woff2 assets at build time. The source <link> is deliberately
// left in place in index.html — it makes the font choice obvious at a glance
// and works in `vite dev` over Wi-Fi — but the built `dist/` contains zero
// https:// references so the tablet renders correctly with the WAN unplugged.
// Do NOT remove this plugin. A pack with a network dependency silently falls
// back to the WebView's default sans-serif when offline and the whole
// herbarium aesthetic disintegrates.
//
// The two load-bearing settings below:
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
  plugins: [webfontDownload()],
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    target: 'esnext',
    cssCodeSplit: false,
    minify: 'esbuild',
    assetsInlineLimit: 0,
  },
});
