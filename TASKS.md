# Task list (mirrors PLAN.md; one commit per step)


### Phase 0 — Prove the foundation (small)
- [x] Remove adb mode (`git rm -r app bin/inspect`, `$PREFIX/bin/inspect` symlink, `~/.shortcuts/InspectElement`); update README/PLAN/TASKS. Commit.
- [x] Core mechanism PROVEN on device (photo 2026-09-10): in-process WebView DevTools attach, Origin strip, CDN frontend loads, Elements/Styles live, picker highlights. Installs via Downloads → My Files (Termux can't call the installer on Android 14+). Verify same-uid DevTools connect, Origin strip, frontend attach, Elements picker. Fix what breaks. (Runtime debugging without logcat: add a temporary in-app status text of bridge/attach errors.) Commit.
- [x] `bin/build.rb fetch` (mruby 4.0.0, mruby-json f99d942) and `bin/build.rb mruby` → libmruby.a (11.9 MB, -g), mrbc, mruby. Needed: no mruby-print in 4.0, positional gem path, explicit hal-posix-io/hal-posix-socket.
- [x] Spike with the built `mruby` CLI — OK: IO.select, TCPServer ephemeral + getsockname port, accept, _setnonblock, sysread→Errno::EAGAIN, syswrite returns n, IO.pipe, IO.for_fd, BasicSocket.for_fd, setsockopt SO_RCVTIMEO, JSON.parse/to_json, Struct, format, File. NOT: `close_write` on sockets (EBADF → use `shutdown(SHUT_WR)`), no Regexp (string ops only). Abstract sockaddr_un keeps the leading NUL but connect addrlen unverified → C helper as planned.
- [x] Link a hello `.so` with the production flags; `readelf` gate passes (NEEDED = liblog/libm/libdl/libc, no RUNPATH after patchelf, LOAD align 0x4000, only JNI_OnLoad exported; 24 KB).

### Phase 1 — Ruby executes inside the APK (medium)
- [x] `native/inspect.c` (+ `inspect_socket.c`), `Native.java`, `RubyRuntime.java`, `ruby/app.rb` + `lib/host.rb`, `lib/loop.rb` (boot → toast).
- [x] `bin/build.rb` stages `mrb`, `native` (clang, patchelf, strip, gate before finalizing), staging of `lib/arm64-v8a/libinspect.so` (1.6 MB) + `assets/app.mrb`; manifest `extractNativeLibs="true"`; APK 501 KB.
- [x] In-app log pane + Ruby console (Rb button; `console.eval` → `eval` via mruby-eval).
- [x] Milestone: Ruby 4.0.0 boots inside the APK on device (Rb pane shows `[info] Ruby 4.0.0 up in pid …`). Console `1+1` still to confirm.

### Phase 2 — DevTools discovery + relay in Ruby (medium)
- [x] `ruby/lib/http.rb`, `lib/devtools.rb`, `lib/util.rb`, `lib/loop.rb`, `lib/relay.rb` (token-guarded, non-blocking, backpressure), `native/inspect_socket.c`; `bin/build.rb test` = 8 tests green under mruby.
- [x] Java: DevTools button → `devtools.attach{url}` event; executes `devtools.open{url}`/`devtools.error`; `bridge.ready`/`bridge.fallback` → Java DevToolsBridge only on fallback.
- [~] Verify Elements/Console/Network through the Ruby relay on device; verify forced fallback path.

### Phase 3 — App logic in Ruby (medium)
- [x] `lib/tabs.rb` (Browser/Tab), `lib/urlnorm.rb`, `lib/settings.rb`, event handlers in `app.rb`; `MainActivity` rewritten as a logic-free view host driven by `ui.state` + commands; `DevToolsClient.java` deleted; Java fallback relay reports `bridge.java_ready`.
- [x] `bin/build.rb test`: 14 tests green under the built mruby CLI (relay, devtools, urlnorm, browser model).

### Phase 4 — Browser chrome in Ruby via Opal (large)
Design target: what a modern desktop browser does, in a compact dark theme.
- [x] Toolchain: `bin/build.rb opal` compiles `ui/ui.rb` → `assets/ui/ui.js` (782 KB single bundle, node-validated); Opal 1.8.3.
- [x] Chrome WebView + `ChromeBridge.send(json)` → Ruby events (chrome.height handled locally); `ui.state` → `UI.receive(json)`; chrome excluded from DevTools targets; omnibox keeps focus while typing.
- [~] Tab strip: favicon + title, × close, + new tab, active/loading state, scroll. (drag order later)
- [~] Toolbar: back/forward/reload/stop, omnibox + suggestions (history/bookmarks), ★, Desktop/Mobile, DevTools, ⋮ menu (dock in menu). Needs on-device check.
- [~] **Bookmarks** (Chrome model): Bookmarks bar + Other bookmarks roots, nested folders, bar folder dropdowns, star → "Bookmark added" popup (name + folder), manager with folder tree, breadcrumb, new folder, move, rename, delete, search; legacy list migrated. On-device check pending.
- [x] History (200 entries) for omnibox suggestions + History page grouped by day with remove/clear; stored by Ruby.
- [x] Removed XML toolbar/tab strip; Rb pane stays as a developer drawer (menu → Ruby console).

### Phase 5 — Settings, scripts, polish
- [~] **Settings page** (Ruby-owned, Opal overlay, Chrome-style nav + cards): search engine, home page, desktop default, bookmarks bar, force dark, text size, JavaScript, third-party cookies, clear data, DevTools dock/theme/screencast. On-device check pending.
- [~] **Scripts & styles** (the extension substitute): per-site JS/CSS with URL globs, page start/end, enable/disable, editor, "run on current tab", import from URL (reads ==UserScript== headers), request-blocking globs via `shouldInterceptRequest`. On-device check pending.
- [ ] Offline DevTools frontend; `extractNativeLibs=false` + Ruby zip aligner; release keystore; DeX window behaviour; about page (mruby/Chromium versions).

## Phase 6 — Release
- [x] Release keystore (`tools/release.keystore` + `tools/release.env`, ignored; RSA-4096, 30y, alias mimir) + `bin/build.rb release` → `build/Mimir-release.apk`
- [x] Play bundle: `aapt2 link --proto-format` + bundletool 1.18.3 → `build/Mimir.aab` (validated); `bin/build.rb bundle --play` hides Donate
- [ ] Store listing assets: icon (adaptive), feature graphic, screenshots (DeX), short/long description, privacy policy (no data collection)
- [x] About page: licenses (mruby, mruby-json, Opal MIT; DevTools frontend BSD), version, Donate + Source links (from mimir.config.json)
- [ ] GitHub repo + Releases with APK (Obtainium-friendly); README for users
- [~] Monetization: user open to Play Billing donations; Billing 9.1 = 50 transitive libs (AndroidX, Kotlin stdlib, Firebase encoders, Play Services) → deferred past v1 (needs a Ruby Maven/AAR resolver). v1: paid or free listing; external Donate in GitHub build only.
- [ ] Pre-release QA checklist: fresh install, settings/bookmarks/scripts persistence, DevTools attach, DeX resize, rotation, back button, external links, downloads (not yet handled), file chooser (not yet handled)

## Notes
- Opal gotcha (cost us three 'renders but invisible' bugs): the last expression of a method gets `return`; a backtick with `a; b` there runs only `a`. `bin/build.rb opal` now lints for it; use `UI.show/hide`.
- Engine is Android System WebView = Chromium (Blink/V8), system-updated. No Chrome extensions (browser-layer feature; needs a Chromium fork). Cannot read Chrome's profile/sync/cookies (app sandbox).
