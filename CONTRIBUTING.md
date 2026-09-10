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

**Android Studio / desktop:** the Gradle module opens and compiles the Java, but Gradle only packages
what the Ruby pipeline produces (`libmimir.so`, `app.mrb`, `assets/ui/`). The native stage currently
assumes a compiler that emits Android arm64 binaries, which Termux's clang does and a desktop clang
does not. A desktop build needs the Android NDK: mruby's `MRuby::CrossBuild` with `toolchain :android`
for `libmruby.a`, and the NDK clang for `native/*.c`. `bin/build.rb` doesn't do that yet; see the
"desktop build path" issue if you want to take it on. The `mrb` and `opal` stages already run anywhere.

    pkg install clang make aapt2 d8 apksigner zip patchelf openjdk-21 nodejs gradle librsvg
    gem install opal                                  # needs Ruby 3.x
    ruby bin/build.rb fetch                           # vendors mruby 4.0.0 + mruby-json
    ruby bin/build.rb mruby                           # builds libmruby with clang (once, a few minutes)
    ruby bin/build.rb test                            # Ruby tests under the built mruby
    ruby bin/build.rb install                         # debug APK without billing -> ~/storage/downloads
    ruby bin/build.rb ginstall                        # debug APK with Play Billing, via Gradle

The Ruby pipeline needs `tools/android.jar` (from the Android platform zip) and `tools/debug.keystore`.
The Gradle path also needs `tools/sdk/` laid out as `platforms/android-36` and `build-tools/36.0.0`
with Termux's `aapt2` and `d8` symlinked over the x86 binaries. See `PLAN.md` for the full story.

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
