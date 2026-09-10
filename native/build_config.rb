# mruby build configuration for Inspect Element.
# Host == target: Termux clang emits aarch64 Android (bionic) code, so a single "host" build
# yields libmruby.a for the APK plus mrbc/mruby CLIs for compiling and testing in Termux.
MRuby::Build.new do |conf|
  conf.toolchain :clang

  conf.cc do |cc|
    cc.flags << '-fPIC' << '-O2' << '-g' << '-fvisibility=hidden' << '-ffunction-sections' << '-fdata-sections'
    cc.defines << 'MRB_UTF8_STRING' << 'MRB_INT64' << 'MRB_USE_DEBUG_HOOK'
  end
  conf.linker.flags << '-fPIC'
  conf.enable_debug

  # Explicit core gem list. Deliberately excluded: complex, cmath, rational, bigint (pull in
  # Termux-only libandroid-complex-math), dir, bin-mirb, bin-strip, bin-debugger.
  %w[
    mruby-compiler mruby-eval mruby-error mruby-errno mruby-catch
    mruby-sprintf mruby-math mruby-time mruby-struct mruby-set mruby-pack
    mruby-io mruby-socket mruby-sleep hal-posix-io hal-posix-socket
    mruby-compar-ext mruby-enum-ext mruby-string-ext mruby-numeric-ext mruby-array-ext
    mruby-hash-ext mruby-range-ext mruby-proc-ext mruby-symbol-ext mruby-object-ext
    mruby-kernel-ext mruby-class-ext mruby-toplevel-ext
    mruby-enumerator mruby-enum-lazy mruby-fiber mruby-random mruby-metaprog mruby-method
    mruby-objectspace mruby-bin-mrbc mruby-bin-mruby
  ].each { |g| conf.gem core: g }

  conf.gem File.expand_path('../vendor/mruby-json', __dir__)
end
