# mruby build configuration for Mímir.
#
# Two ways to get an Android arm64 libmruby.a:
#  * On the tablet (Termux): clang already emits Android code, so a plain host build is enough and
#    also yields the mrbc/mruby tools we run directly.
#  * On a PC with the Android NDK (ANDROID_NDK_HOME set): a host build supplies mrbc/mruby for
#    compiling bytecode and running tests, and a cross build produces the arm64 library.
GEMS = %w[
  mruby-compiler mruby-eval mruby-error mruby-errno mruby-catch
  mruby-sprintf mruby-math mruby-time mruby-struct mruby-set mruby-pack
  mruby-io mruby-socket mruby-sleep hal-posix-io hal-posix-socket
  mruby-compar-ext mruby-enum-ext mruby-string-ext mruby-numeric-ext mruby-array-ext
  mruby-hash-ext mruby-range-ext mruby-proc-ext mruby-symbol-ext mruby-object-ext
  mruby-kernel-ext mruby-class-ext mruby-toplevel-ext
  mruby-enumerator mruby-enum-lazy mruby-fiber mruby-random mruby-metaprog mruby-method
  mruby-objectspace mruby-bin-mrbc mruby-bin-mruby
].freeze
JSON_GEM = File.expand_path('../vendor/mruby-json', __dir__)

def configure(conf)
  conf.cc do |cc|
    cc.flags << '-fPIC' << '-O2' << '-g' << '-fvisibility=hidden' << '-ffunction-sections' << '-fdata-sections'
    cc.defines << 'MRB_UTF8_STRING' << 'MRB_INT64' << 'MRB_USE_DEBUG_HOOK'
  end
  conf.linker.flags << '-fPIC'
  conf.enable_debug
  GEMS.each { |g| conf.gem core: g }
  conf.gem JSON_GEM
end

ndk = ENV['ANDROID_NDK_HOME'].to_s
on_termux = File.directory?('/data/data/com.termux')

MRuby::Build.new do |conf|
  conf.toolchain :clang
  configure(conf)
end

unless ndk.empty? || on_termux
  # PC: cross-compile the library for Android arm64 (API 26+, matching the app's minSdk).
  MRuby::CrossBuild.new('android-arm64') do |conf|
    conf.toolchain :android, arch: 'arm64-v8a', sdk_version: 26, ndk_home: ndk
    configure(conf)
    conf.gems.delete_if { |g| g.name.start_with?('mruby-bin-') }   # no host tools in the cross build
  end
end
