# Inspect Element

A standalone Android developer-tools browser for the Galaxy Tab S10+ (DeX-friendly, no adb),
developed entirely on the tablet in Termux. Ruby runs the app logic and DevTools relay inside the
APK (mruby via JNI); the UI is Ruby compiled with Opal; Java is thin view glue. The DevTools pane
is the real Chrome DevTools frontend attached in-process to the app's own WebView.

See PLAN.md for architecture and research, TASKS.md for progress.

## Build (Termux)
    ruby bin/build.rb fetch     # once: vendor mruby 4.0.0 + mruby-json
    ruby bin/build.rb mruby     # once: build libmruby.a / mrbc / mruby with Termux clang
    ruby bin/build.rb install   # build APK and hand it to the system installer
    ruby bin/build.rb test      # run ruby/ tests under the built mruby CLI

Toolchain: pkg install aapt2 d8 apksigner zip clang make patchelf; OpenJDK 21 (javac);
tools/android.jar from the platform-35 zip; tools/debug.keystore via keytool (see PLAN.md).
