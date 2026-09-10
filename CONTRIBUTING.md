# Contributing to Mímir

Thanks for the interest. Mímir is unusual: it is written mostly in Ruby and built entirely on an
Android tablet in Termux. This page gets you productive without re-discovering what we learned.

## Where things live

| Path | What | Language |
|---|---|---|
| `ruby/` | App logic: tabs, bookmarks, history, settings, scripts, DevTools discovery and relay | Ruby (mruby dialect) |
| `ui/` | Browser chrome: tab strip, toolbar, pages (Settings, History, Bookmarks, Scripts, Support) | Ruby → JavaScript via Opal |
| `android/src/` | Java host: WebViews, JNI binding, command executor. Holds no browser logic. | Java |
| `android/src-billing/` | Play Billing (compiled only by the Gradle build) | Java |
| `native/` | JNI shim that hosts the mruby VM, socket helpers, crash reporter | C |
| `bin/build.rb` | The build pipeline | Ruby |
| `tools/` | Test harnesses (`ui_smoke.js`, `ui_jsdom.js`), store art generators | JS / Ruby |

Java and Ruby talk in JSON: Java sends **events** (`{"ev":"tab.new"}`), Ruby answers with **commands**
(`{"cmd":"tab.create", ...}`) and a `ui.state` snapshot the chrome renders. If you add behaviour, add it
to Ruby and give Java a dumb command to execute.

## Building

Termux on Android 10+ (arm64) is the supported environment; the project is developed and tested on-device.

**PC (Linux, macOS, WSL) with the Android NDK.** The same commands work; the native stage cross-compiles
when it sees the NDK. Untested on Windows proper.

    # Android Studio → SDK Manager → SDK Tools: install "NDK (Side by side)" (Gradle installs missing platforms itself)
    export ANDROID_HOME=~/Android/Sdk                       # or wherever Studio put it
    export ANDROID_NDK_HOME=$ANDROID_HOME/ndk/<version>
    export JAVA_HOME=<a JDK 21+>                            # e.g. Android Studio's bundled one: .../android-studio/jbr
    export PATH=$JAVA_HOME/bin:$PATH
    # Ruby 3.x, Node 18+, and: gem install opal
    ruby bin/build.rb fetch
    ruby bin/build.rb mruby          # host build (mrbc, mruby) + android-arm64 cross build (libmruby.a)
    ruby bin/build.rb test
    ruby bin/build.rb gbuild         # Gradle debug APK in app/build/outputs/apk/debug/

`mruby` uses mruby's own NDK toolchain support; `native` links with the NDK's clang and checks the result
with `llvm-readelf`. Gradle runs through the committed wrapper (9.7.1), finds the SDK via `ANDROID_HOME`, and
signs debug builds with Android's default debug keystore unless `tools/debug.keystore` exists. Verified on
Arch Linux with NDK 30 and Studio's JBR 25 (2026-09-10). The pure-Ruby packaging path (`build`,
`install`, `bundle`) is Termux-oriented; on a PC use the `g*` Gradle commands. Android Studio can open the
project directly once `ruby bin/build.rb mrb native opal` has produced the staged artifacts.

Android 14+ won't let Termux launch the package installer, so `install` copies the APK to Downloads;
open it from your file manager.

## Tests

- `ruby bin/build.rb test` runs `ruby/test/*_test.rb` under mruby with a fake host (`test/fake_host.rb`).
- The `opal` stage runs `tools/ui_smoke.js` (stub DOM) and `tools/ui_jsdom.js` (real DOM) against the
  compiled chrome: boot, receive state, open every page, click through. A failing UI test fails the build.
- Add a test when you add logic. Layout bugs still need a device.

## Things that will bite you

- **Opal returns a method's last expression.** A backtick block with two JavaScript statements as the
  last line runs only the first. The build lints for `a; b` inside backticks; use `UI.show`/`UI.hide` or
  separate backticks.
- **mruby has no Regexp** in our build. Use string methods. `Struct` keyword args, `require`, and
  refinements are also out.
- **C-implemented methods and braceless hashes**: `array.unshift("k" => v)` loses the hash in mruby;
  write `unshift({ "k" => v })`.
- **Never chain `; ` in JS strings passed through Ruby string interpolation** without checking the
  compiled output in `build/stage/assets/ui/ui.js`.
- The native library must pass the gate in `build.rb`: only `libc/libm/libdl/liblog` as dependencies,
  16 KB page alignment, a single exported symbol.

## Reporting bugs

Termux cannot read the app's logcat, so Mímir reports on itself:

- A grey status line at the bottom shows errors (informational messages fade).
- ⋮ → **Ruby console** shows the Ruby log and lets you evaluate Ruby inside the running app.
- ⋮ → **Inspect browser UI** attaches DevTools to Mímir's own chrome.
- Crashes are written to `Downloads/Mimir-crash.txt` (Java) or `Mimir-native-crash.txt` (native).

Open an issue with the status line text, the crash file if any, your device and Android version, and
what you tapped. Screenshots help enormously.

## Pull requests

Keep PRs focused. Run `ruby bin/build.rb test` and `ruby bin/build.rb opal` before pushing. If you touch
`ui/`, include a jsdom check for the new behaviour. Commit messages in plain imperative English; no
generated trailers.

By contributing you agree your work is licensed under the MIT License in `LICENSE`.
