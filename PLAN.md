# InspectElement — Chrome DevTools on the tablet itself

Goal: desktop-grade "Inspect Element" (Elements/Styles/Console/Network/Sources) for
Chrome tabs on the Galaxy Tab S10+, running entirely on the device, written in Ruby.

## Why this architecture
* Chrome for Android already runs the full DevTools protocol server on the abstract
  unix socket `chrome_devtools_remote` whenever USB debugging is enabled.
* Chrome only accepts DevTools connections from the ADB shell uid, so a normal app
  (Termux, or any APK) cannot connect directly. ADB is the sanctioned door.
* Android 11+ Wireless debugging lets `adb` running in Termux talk to *this same tablet*
  over localhost. `adb forward tcp:9222 localabstract:chrome_devtools_remote` then
  exposes Chrome's DevTools HTTP+WebSocket endpoints on localhost:9222.
* Chrome publishes a `devtoolsFrontendUrl` for every tab: the real DevTools UI, which
  connects back to ws://localhost:9222. Browsers treat localhost as a secure origin,
  so this works from an https-served frontend.
* Ruby is a poor fit for producing a native APK (Ruboto is unmaintained, mruby
  embedding is a large project), but it is a great fit for the actual work here:
  process/adb orchestration, an HTTP server, JSON, and a small web UI.

## Components
1. `app/` — Sinatra app (pure-Ruby stack: sinatra + webrick).
   * `lib/adb.rb`       — locate/pair/connect/forward, port discovery (mdns, then localhost scan), health checks
   * `lib/devtools.rb`  — talk to localhost:9222 (/json, /json/new, /json/close, /json/version)
   * `app.rb`           — routes: status, setup wizard, tab list, open-inspector, JSON API
   * `public/`          — PWA manifest, service worker, icons, styles, JS
2. `bin/inspect`       — start script (wake-lock, boot adb, run server, open browser)
3. Termux:Widget / Termux:Boot hooks so it starts with one tap (optional)
4. Optional Phase 3: Java WebView APK wrapper built in Termux (ecj/d8/aapt2/apksigner).

## Device prerequisites (manual, one time)
* Settings → About tablet → Software information → tap Build number 7x
* Developer options → USB debugging ON, Wireless debugging ON
* Pair once: Wireless debugging → "Pair device with pairing code" while the app's
  setup page is open in split-screen. Pairing survives reboots; the connect port
  changes, and the app rediscovers it.

## Known limitations
* Wireless debugging may switch off after a reboot on some firmware; the app detects
  this and tells you to flip it back on.
* The DevTools frontend is fetched from Google's CDN (online needed on first load).
  A bundled offline copy is a later enhancement.
* Request "Desktop site" in the browser hosting DevTools for the best layout.

## Revision 2 (2026-09-10) — after research and first device test

### Bug found and fixed
Chrome returns 403 to any DevTools WebSocket upgrade that carries a browser `Origin` header
(the `--remote-allow-origins` guard, which cannot be set on Android). The DevTools frontend
always sends one, so "Inspect" showed the reconnect prompt. Fix: `lib/wsproxy.rb`, a byte-level
relay on localhost:9229 that strips `Origin` and pipes the rest to 9222. Verified with a real
`DOM.getDocument` round trip.

### What the Play Store "inspect element" apps actually do
None of them attach to Google Chrome's tabs — Chrome forbids that without adb. They are all
their own browser: either a WebView with an injected JS inspector (Eruda-style), or a full
Chromium fork with DevTools compiled in (Kiwi Browser). So "it's possible" means possible
inside *a* browser you control, not inside Chrome.

### Three modes, in order of fidelity
| Mode | Inspects | Setup cost | Limits |
|---|---|---|---|
| A. adb (built) | Google Chrome tabs, Samsung Internet | One-time pair; re-toggle Wireless debugging after reboot | none — full DevTools |
| B. Bookmarklet bridge (next) | any page in Chrome you can inject into | none: tap a bookmark | strict-CSP pages, no JS breakpoints/SW debugging |
| C. Own browser APK | pages in our WebView | install once | it is not Chrome; Java for the shell |

Mode B design: Ruby server serves `target.js` (chobitsu, a CDP implementation in JS) and a
bookmarklet; the page opens a WebSocket to the Ruby server, which pairs it with a DevTools
frontend session (same relay idea as mode A, but the "browser" side is the injected script).

## Revision 3 (2026-09-10) — standalone Android app (DeX-friendly, no adb)

User runs the tablet in DeX, where debugging is unavailable, and never required Chrome
specifically: the deliverable is an Android developer-tools *browser app*.

### Core mechanism
Android WebView is Chromium. `WebView.setWebContentsDebuggingEnabled(true)` starts a DevTools
server on the abstract socket `webview_devtools_remote_<pid>`. Chromium's
`content::CanUserConnectToDevTools` admits root, shell **or the same uid as the app** — so the
app itself may connect to its own WebView's DevTools. No adb, no Developer options, no script
injection, no CSP limits. Full protocol: Elements, Styles, Console, Network, Sources w/ breakpoints.

### App (Java, `android/`)
* Browser UI: tab strip, URL bar, back/forward/reload, WebView per tab.
* DevTools pane: second WebView hosting the Chrome DevTools frontend, dockable right/bottom, resizable divider.
* `DevToolsBridge`: Java thread; LocalSocket(abstract) ↔ TCP 127.0.0.1:port relay that strips
  `Origin` (Chromium's --remote-allow-origins guard, verified against Chrome on this device).
* Target discovery via `GET /json` on the bridge; frontend URL from `devtoolsFrontendUrl`
  (Google CDN, revision-matched) with `ws=` rewritten to the bridge.
* Manifest: `resizeableActivity=true`, landscape/multi-window friendly for DeX, `usesCleartextTraffic`
  for the localhost websocket, `INTERNET`.

### Ruby (`bin/`, `tools/`)
* `bin/build.rb`: full build pipeline in Ruby — aapt2 compile/link, ecj, d8, zip, apksigner; incremental.
* `bin/make_icons.rb`: launcher icons (already exists).
* Later: local server to host the DevTools frontend offline.

### Toolchain (Termux)
`ecj`, `d8`, `aapt2`, `apksigner` (pkg), OpenJDK 21 (present), Android platform `android.jar`
(downloaded from dl.google.com platform zip). Install via `termux-open` → system installer.
