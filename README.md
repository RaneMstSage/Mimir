# Mímir

**A developer-tools browser for Android, written in Ruby.**

Mímir is a tabbed browser built on the system WebView (Chromium) with the *real* Chrome DevTools
attached in-process: Elements, Styles, Console, Network, Sources with breakpoints. No adb, no
developer options, no desktop. It runs happily in Samsung DeX.

It exists because its developer wanted to do full-stack work from a tablet after going through
[The Odin Project](https://www.theodinproject.com/), and found there was no real way to inspect a
page on Android.

Named for the Norse sage whose counsel reveals hidden knowledge.

## Features

- **DevTools on any page**: the Chrome DevTools frontend docked right or bottom, tap-to-inspect, live CSS editing.
- **Desktop-class chrome**: tabs with favicons and close buttons, omnibox with history and bookmark suggestions,
  desktop/mobile site toggle.
- **Bookmarks like Chrome**: bookmarks bar, Other bookmarks, nested folders, star popup, full manager.
- **History** grouped by day with search.
- **Settings** laid out like Chrome's: search engine, home page, force dark, text size, JavaScript,
  cookies, clear data, DevTools defaults.
- **Scripts & styles**: per-site user JavaScript and CSS with URL patterns, run at page start or end,
  import `.user.js` files, and block unwanted requests. The extension substitute.

## How it is built

Everything is developed *on the tablet* in Termux. There is no Gradle and no Android Studio.

| Layer | Language | Where |
|---|---|---|
| App logic, tab model, bookmarks, scripts, DevTools relay | Ruby ([mruby](https://mruby.org) 4.0, embedded via JNI) | `ruby/` |
| Browser chrome (tabs, toolbar, pages) | Ruby compiled to JavaScript with [Opal](https://opalrb.com) | `ui/` |
| Native host: WebViews, JNI shim | Java + a little C | `android/`, `native/` |
| Build pipeline | Ruby | `bin/build.rb` |

The DevTools trick: Android WebView opens a DevTools socket for its own process, and Chromium admits
connections from the app's own user id. A small Ruby relay strips the browser `Origin` header the
frontend sends (which Chromium would otherwise reject) and the real DevTools UI connects through it.

## Install

**Google Play:** https://play.google.com/store/apps/details?id=com.mstsage.mimir

**Direct download:** `Mimir-<version>.apk` from [Releases](https://github.com/RaneMstSage/Mimir/releases);
open it with your file manager. The GitHub build is identical except that its Support page links to
PayPal instead of Google Play tips.

## Build from source (Termux, Android 10+)

    pkg install clang make aapt2 d8 apksigner zip patchelf openjdk-21 nodejs
    gem install opal                       # Ruby 3.x
    ruby bin/build.rb fetch                # vendors mruby 4.0.0 and mruby-json
    ruby bin/build.rb mruby                # builds libmruby with Termux clang (once)
    ruby bin/build.rb test                 # Ruby tests under the built mruby
    ruby bin/build.rb install              # debug APK -> ~/storage/downloads/Mimir.apk

You also need `tools/android.jar` (from the Android platform-35 zip) and a debug keystore
(`keytool -genkeypair -keystore tools/debug.keystore -storepass android -keypass android -alias inspect -keyalg RSA`).
See `CONTRIBUTING.md` for the architecture and `TASKS.md` for progress.

## Support

Mímir is free and open source. If it earns a place in your workflow, the About page has a Donate link.

## License

MIT License. Copyright (c) 2026 MstSage Entertainment, LLC. See [LICENSE](LICENSE) for the full text.
