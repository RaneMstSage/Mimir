# Task list

## Phase 0 — Environment
- [x] Install android-tools (adb) via pkg
- [x] Install gems: sinatra, webrick
- [x] Verify adb runs and can start its server in Termux

## Phase 1 — Ruby core
- [x] lib/adb.rb: adb wrapper (devices, pair, connect, forward, port discovery)
- [x] lib/devtools.rb: Chrome DevTools HTTP client (version, list, new, close, activate)
- [x] app.rb: Sinatra routes + JSON API
- [x] Setup wizard UI (developer options → wireless debugging → pair → connect)
- [x] Tab list UI with "Inspect" buttons launching DevTools frontend
- [x] PWA: manifest, icons, service worker
- [x] bin/inspect launcher (wake lock, auto-connect, open browser)

## Phase 2 — Device bring-up (needs you)
- [x] Enable Developer options + USB debugging + Wireless debugging
- [x] Pair via the app's setup page
- [x] Fix: Origin-stripping WebSocket relay (Chrome 403 on browser Origin) — lib/wsproxy.rb
- [~] Confirm Inspect opens DevTools on a live tab (CDP round trip verified; awaiting your tap)
- [ ] Add to home screen / Termux:Widget shortcut

## Phase 3 — Standalone app (chosen direction, DeX-friendly)
### 3.0 Toolchain
- [x] pkg install ecj d8 aapt2 apksigner
- [x] Download android.jar (platform 35/36) into tools/
- [x] Generate debug keystore with keytool
- [ ] bin/build.rb: Ruby build pipeline (aapt2 → ecj → d8 → zip → apksigner), incremental
- [ ] Hello-world APK builds and installs (verifies toolchain end to end)
### 3.1 App core
- [x] Manifest + resources (resizeable, multi-window, cleartext localhost, INTERNET)
- [ ] Browser: tabs, URL bar, nav buttons, WebView settings (JS, DOM storage, desktop UA toggle)
- [x] DevToolsBridge: LocalSocket ↔ TCP relay with Origin stripping
- [x] Target discovery (/json) and per-tab DevTools frontend URL
- [ ] DevTools pane: dock right/bottom, draggable divider, open/close
- [ ] Verify Elements picker highlights on the page; Console; Network; breakpoints
### 3.2 Polish
- [ ] Icons from make_icons.rb, app name, DeX window sizing
- [ ] Bundle DevTools frontend for offline (Ruby server or assets)
- [ ] Bookmarks / recent URLs, "open in Chrome" share intent

## Phase 4 — Parked
- [ ] Mode A (adb, Chrome tabs): kept as-is; works when not in DeX
- [ ] Mode B (bookmarklet bridge): not needed for the standalone app
