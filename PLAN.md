# Inspect Element — Ruby-built Android DevTools browser (plan v4)

## Context

Rane wants a **standalone Android developer-tools browser** for a Galaxy Tab S10+ that runs in
Samsung DeX (adb/USB debugging unavailable), developed **entirely on the tablet in Termux**, written
in **Ruby as far as technically possible**, git-versioned, planned first, executed step by step.

Decisions taken with the user (2026-09-10):
* Standalone browser app with the real Chrome DevTools attached in-process (no adb, no Developer options).
* Ruby depth: **Ruby logic + Ruby UI** — mruby runs app logic and the DevTools relay inside the APK;
  the toolbar/tab UI is Ruby compiled with Opal in a WebView. Java is thin view glue.
* Remove the adb/Sinatra mode (`app/`, `bin/inspect`).

### Research result: Ruby on Android
| Option | Status | Usable in Termux? |
|---|---|---|
| Ruboto (JRuby) | last release 2017 | no |
| RubyMotion | commercial, macOS-only | no |
| Rhodes/Tau | needs desktop SDK+NDK | no |
| **mruby embedded via JNI** | 4.0.0 (Apr 2026), active; Termux clang targets `aarch64-linux-android24`; AOSP `jni.h` + `android/log.h` present | **yes** |
| **Opal (Ruby→JS)** | gem 1.8.3 on Termux CRuby 3.3 | **yes** (UI inside a WebView) |

Verified on device (design review): a Termux-clang `.so` has NEEDED = libc/libdl only and 16 KB-aligned
LOAD segments, but the driver injects a Termux `RUNPATH` (strip with `patchelf`). The Termux `mruby`
package's `libmruby.a` links Termux-only libs → **build mruby from source** (rake + clang, host == target).
mruby 4.0.0 has **no core JSON gem** → vendor `mattn/mruby-json`. mruby-io gives `IO.select`, `IO.for_fd`,
`sysread/syswrite`, `IO.pipe`, `close_write`; mruby-socket gives `TCPServer#accept`, `BasicSocket.for_fd`,
`_setnonblock`, `setsockopt`. Abstract-namespace connect and ephemeral-port lookup go in 3 tiny C helpers.

### Core mechanism (from Chromium source; **still unproven on this device**)
`WebView.setWebContentsDebuggingEnabled(true)` opens `@webview_devtools_remote_<pid>`;
`content::CanUserConnectToDevTools` admits **the app's own uid**. Chromium rejects WebSocket upgrades
carrying a browser `Origin` header (verified 403 against Chrome here), so the relay strips it.
The existing 33 KB Java APK implements exactly this and has never been launched → **Phase 0 tests it first.**

## Target architecture ("Ruby brain, Java glue")

```
android/src/com/mstsage/inspect/
  MainActivity.java     views (page WebViews, devtools WebView, chrome WebView) + execute(json) command switch
  RubyRuntime.java      process singleton: ruby thread, post(json), onCommand(json) -> main Handler, log pane feed
  Native.java           System.loadLibrary("inspect"); static native run(byte[] mrb, String boot), post(String)
  DevToolsBridge.java   KEPT as switchable fallback relay
  DevToolsClient.java   deleted in Phase 3 (logic moves to ruby/lib/devtools.rb)
native/
  build_config.rb       MRUBY_CONFIG: -fPIC, -fvisibility=hidden, MRB_UTF8_STRING, explicit core gem list
                        (io socket errno sprintf print time struct pack string/array/hash/enum-ext metaprog
                        compiler eval bin-mrbc bin-mruby ...; NO complex/cmath/rational/bigint/dir/mirb) + vendor/mruby-json
  inspect.c             JNI_OnLoad + RegisterNatives; run(): mrb_open, load irep, App.run; post(): mutex queue + self-pipe;
                        Inspect.emit/log/wake_fd/next_event/pid/version
  inspect_socket.c      Inspect.connect_abstract(name)->fd, listen_loopback(port)->[fd,port], set_nonblock(fd,bool)
ruby/                   app brain (mruby dialect; also runs under the built `mruby` CLI for tests)
  load_order.txt, app.rb (App.run select loop + dispatch), lib/host.rb, lib/loop.rb, lib/relay.rb,
  lib/devtools.rb, lib/http.rb, lib/tabs.rb, lib/urlnorm.rb, lib/settings.rb, test/*.rb (fake host)
ui/                     Opal Ruby → android/assets/ui/ui.js (+ ui.html, ui.css): toolbar, tab strip, dock, status
vendor/mruby (tag 4.0.0), vendor/mruby-json (pinned sha)   — gitignored, fetched by bin/build.rb fetch
bin/build.rb            fetch → mruby → mrbc → clang .so (+patchelf, readelf gate) → opal → aapt2 → javac → d8 → zip → apksigner
```

### Threading & data flow (strictly asynchronous, no reentrancy)
* One **ruby thread** (Java `Thread` → `Native.run`) owns the VM and runs `App.run`: `IO.select(relay_fds + [wake])`.
* **Java→Ruby**: `Native.post(json)` from any thread → C mutex queue + one byte on a self-pipe; Ruby drains
  `Inspect.next_event` and dispatches. Never blocks the UI thread.
* **Ruby→Java**: `Inspect.emit(json)` → `CallStaticVoidMethod(RubyRuntime.onCommand)` → `Handler.post` to main →
  `MainActivity.execute(json)`. One local ref per call, deleted; `ExceptionCheck/Clear` after every JNI call.
* Relay: `listen_loopback(0)`, per-connection state machine (`:head → :piping → :closing`), chunk queues with
  1 MB backpressure, non-blocking both sides, `close_write` on half-close; head rewrite = drop `Origin`, replace
  `Host`; **random token required in the request path** so other apps on the device can't drive our DevTools.
* HTTP `/json` discovery uses `SO_RCVTIMEO` 2 s so it can't stall the loop. Per-event `rescue` → `log` command.
* Fallback: Ruby emits `bridge.ready{port}` or `bridge.fallback{reason}`; Java starts `DevToolsBridge` on fallback.

### JSON schema v1
Events (Java→Ruby, `ev`): `boot{pid,files_dir,version}`, `ui.ready{tabs}`, `navigate{tab,text}`, `tab.new{url?}`,
`tab.select|tab.close{tab}`, `nav.back|forward|reload{tab}`, `page.started|finished{tab,url}`, `page.title{tab,title}`,
`page.progress{tab,p}`, `devtools.toggle|reattach`, `dock.toggle`, `ua.toggle`, `intent.url{url}`, `console.eval{src}`, `quit`.
Commands (Ruby→Java, `cmd`): `toast`, `log{level,text}`, `tab.create{tab,url,select}`, `tab.show|destroy|load|back|forward|reload`,
`tab.set_ua`, `ui.state{tabs,current,url,progress,devtools,dock,desktop}` (drives the Opal UI via evaluateJavascript),
`devtools.open{url}`, `devtools.close`, `devtools.dock{side,fraction}`, `bridge.ready|fallback`, `console.result`, `fatal`.
Tab ids are allocated by Ruby; Java ignores unknown ids.

## Phases & task list (one commit per step; TASKS.md mirrors this list)

### Phase 0 — Prove the foundation (small)
- [ ] Remove adb mode (`git rm -r app bin/inspect`, `$PREFIX/bin/inspect` symlink, `~/.shortcuts/InspectElement`); update README/PLAN/TASKS. Commit.
- [ ] Install + run the existing Java APK. Verify same-uid DevTools connect, Origin strip, frontend attach, Elements picker. Fix what breaks. (Runtime debugging without logcat: add a temporary in-app status text of bridge/attach errors.) Commit.
- [ ] `bin/build.rb fetch` (clone mruby tag 4.0.0 + mruby-json into `vendor/`), `bin/build.rb mruby` (rake with `native/build_config.rb`, `MRUBY_BUILD_DIR=build/mruby`). Confirm `libmruby.a`, `mrbc`, `mruby`.
- [ ] Spike with the built `mruby` CLI: `IO.select`, `TCPServer` accept, `for_fd`, `_setnonblock`, EAGAIN class, partial `syswrite`, `close_write`, `JSON.parse/generate`. Record in TASKS.md.
- [ ] Link a hello `.so` with the production flags; `readelf` gate passes (NEEDED ⊆ libc/libm/libdl/liblog, no RUNPATH, LOAD align ≥ 0x4000). Commit.

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

## Build details
Link: `clang -shared -fPIC -O2 -g -fvisibility=hidden -ffunction-sections -fdata-sections -Wl,-soname,libinspect.so
-Wl,-z,max-page-size=16384 -Wl,--no-undefined -Wl,-z,defs -Wl,--exclude-libs,ALL -Wl,--gc-sections native/*.c
build/mruby/host/lib/libmruby.a -llog -lm` → `patchelf --remove-rpath` → keep unstripped copy → `llvm-strip`.
Incremental rules by mtime as today. `.mrb` shipped as an asset so Ruby-only edits skip the C link (dev hot-reload later).

## Verification
1. Phase 0: DevTools pane shows the Elements tree of a loaded page in the Java app; picker highlights nodes.
2. Phase 1: toast from mruby; console `1+1 → 2`; log pane shows Ruby `puts`.
3. Phase 2: DevTools works via the Ruby relay (Elements, Console eval, Network); forced fallback also works.
4. Phase 3: `bin/build.rb test` green; tabs/URL/search/UA behaviours driven by Ruby.
5. Phase 4: toolbar and tab strip rendered by Opal; all interactions round-trip through Ruby.
6. Every phase: `readelf` gate passes, APK installs on Android 16 in DeX, commit made, TASKS.md updated.

## Top risks & fallbacks
1. `.so` fails to load (Termux-only NEEDED, RUNPATH, non-PIC) → `--no-undefined`, `--exclude-libs,ALL`, patchelf, readelf gate; fallback: compile mruby sources directly into the shim link.
2. mruby-io/socket gaps for non-blocking relay → C helpers, Phase 0 spike; fallback: Java `DevToolsBridge` behind a flag (Ruby still owns discovery).
3. Silent failures (no logcat from Termux) → in-app log pane + Ruby console in Phase 1, per-event rescue, unstripped `.so`.
4. Threading/lifecycle → strictly async protocol, main-Handler commands, process-scoped runtime, `ui.ready` resync, `SO_RCVTIMEO`.
5. Same-uid WebView DevTools access not honoured by Samsung's WebView → discovered in Phase 0; fallback is script injection (chobitsu) through the same relay design.
