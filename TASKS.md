# Task list (mirrors PLAN.md; one commit per step)


### Phase 0 — Prove the foundation (small)
- [x] Remove adb mode (`git rm -r app bin/inspect`, `$PREFIX/bin/inspect` symlink, `~/.shortcuts/InspectElement`); update README/PLAN/TASKS. Commit.
- [~] Install + run the existing Java APK (built with in-app status line; installer opened, awaiting user test). Verify same-uid DevTools connect, Origin strip, frontend attach, Elements picker. Fix what breaks. (Runtime debugging without logcat: add a temporary in-app status text of bridge/attach errors.) Commit.
- [~] `bin/build.rb fetch` done (mruby 4.0.0, mruby-json f99d942); `bin/build.rb mruby` (rake with `native/build_config.rb`, `MRUBY_BUILD_DIR=build/mruby`). Confirm `libmruby.a`, `mrbc`, `mruby`.
- [ ] Spike with the built `mruby` CLI: `IO.select`, `TCPServer` accept, `for_fd`, `_setnonblock`, EAGAIN class, partial `syswrite`, `close_write`, `JSON.parse/generate`. Record in TASKS.md.
- [x] Link a hello `.so` with the production flags; `readelf` gate passes (NEEDED = liblog/libm/libdl/libc, no RUNPATH after patchelf, LOAD align 0x4000, only JNI_OnLoad exported; 24 KB).

### Phase 1 — Ruby executes inside the APK (medium)
- [ ] `native/inspect.c`, `Native.java`, `RubyRuntime.java`, `ruby/app.rb` (boot → `toast "Hello from mruby <version>"`).
- [ ] `bin/build.rb` stages `mrb` (mrbc, depends on mrbc mtime), `native` (clang link flags below, patchelf, strip, readelf gate), stage `lib/arm64-v8a/libinspect.so` + `assets/app.mrb`; manifest `extractNativeLibs="true"` explicit.
- [ ] In-app **log pane + Ruby console** (`mruby-eval`) — our only debugging window without logcat.
- [ ] Milestone: toast shows, log pane shows Ruby output, console evaluates `1+1`. Commit.

### Phase 2 — DevTools discovery + relay in Ruby (medium)
- [ ] `ruby/lib/http.rb`, `lib/devtools.rb` (target scoring + `ws=` rewrite + token; port of DevToolsClient.java), `lib/loop.rb`, `lib/relay.rb`, `native/inspect_socket.c`.
- [ ] Java: DevTools button → `devtools.toggle` event; executes `devtools.open{url}`; fallback flag to Java bridge.
- [ ] Verify Elements/Console/Network through the Ruby relay; verify forced fallback path. Commit.

### Phase 3 — App logic in Ruby (medium)
- [ ] `lib/tabs.rb`, `lib/urlnorm.rb`, `lib/settings.rb` (files_dir/settings.json), dispatch in `app.rb`; `MainActivity` → view wiring + `execute(json)` only; delete `DevToolsClient.java`.
- [ ] `bin/build.rb test`: `ruby/test` under the built `mruby` CLI with a fake `Inspect` host. Commit.

### Phase 4 — UI in Ruby via Opal (large)
User's explicit choice; the review flags cost (≈1 MB JS runtime, IME/focus quirks with nested WebViews, an extra
DevTools target to filter, replaces ~150 Java lines). Kept, sequenced last, minimal footprint.
- [ ] `ui/ui.rb` (plain DOM via Opal `Native`/`$$`, no opal-jquery), `ui.html/css`; `bin/build.rb opal` → `assets/ui/ui.js`.
- [ ] Chrome WebView + `@JavascriptInterface host.send(json)` → `Native.post`; `ui.state` → `UI.receive(json)`; filter the chrome WebView out of DevTools targets; IME handling for URL field.
- [ ] Remove XML toolbar/tab strip. Commit.

### Phase 5 — Polish
- [ ] Offline DevTools frontend (assets via Ruby loop or WebViewAssetLoader), `extractNativeLibs=false` + `bin/apkzip.rb` aligner (drop `zip` dependency), release keystore, DeX window behaviour, icons/about page.

