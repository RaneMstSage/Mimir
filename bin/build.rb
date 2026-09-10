#!/usr/bin/env ruby
# frozen_string_literal: true
# Ruby build pipeline for the Android app: aapt2 -> ecj -> d8 -> zip -> apksigner.
# Usage: bin/build.rb [build|install|run|clean]
require 'fileutils'
require 'open3'
require 'digest'
require 'json'

ROOT    = File.expand_path('..', __dir__)
ANDROID = File.join(ROOT, 'android')
TOOLS   = File.join(ROOT, 'tools')
BUILD   = File.join(ROOT, 'build')
JAR     = File.join(TOOLS, 'android.jar')
KS      = File.join(TOOLS, 'debug.keystore')
PKG     = 'com.mstsage.mimir'
MIN_SDK = 26
TGT_SDK = 36
OUT_APK = File.join(BUILD, 'Mimir.apk')
VENDOR     = File.join(ROOT, 'vendor')
MRUBY_SRC  = File.join(VENDOR, 'mruby')
MRUBY_TAG  = '4.0.0'
JSON_SRC   = File.join(VENDOR, 'mruby-json')
JSON_REPO  = 'https://github.com/mattn/mruby-json.git'
MRUBY_OUT  = File.join(BUILD, 'mruby')
ON_TERMUX  = File.directory?('/data/data/com.termux')
NDK        = ENV['ANDROID_NDK_HOME'].to_s
CROSS      = !ON_TERMUX && !NDK.empty?            # PC with the Android NDK: cross-compile the native parts
if CROSS && !File.directory?(File.join(NDK, 'toolchains'))
  abort "ANDROID_NDK_HOME=#{NDK} is not an NDK directory (no toolchains/ inside). Install 'NDK (Side by side)' in Android Studio's SDK Manager, then point ANDROID_NDK_HOME at e.g. ~/Android/Sdk/ndk/<version>."
end
abort 'On a PC set ANDROID_NDK_HOME to the Android NDK (the native library must target Android arm64).' if !ON_TERMUX && NDK.empty? && !%w[test opal mrb fetch].include?(ARGV.reject { |a| a.start_with?('--') }[0].to_s)
MRUBY_LIB  = File.join(MRUBY_OUT, CROSS ? 'android-arm64' : 'host', 'lib', 'libmruby.a')
MRBC       = File.join(MRUBY_OUT, 'host', 'bin', 'mrbc')
MRUBY_BIN  = File.join(MRUBY_OUT, 'host', 'bin', 'mruby')

# NDK prebuilt toolchain directory for this host OS.
def ndk_bin
  host = case RUBY_PLATFORM
         when /darwin/ then 'darwin-x86_64'
         when /mingw|mswin/ then 'windows-x86_64'
         else 'linux-x86_64'
         end
  dir = File.join(NDK, 'toolchains', 'llvm', 'prebuilt', host, 'bin')
  abort "NDK toolchain not found at #{dir}" unless File.directory?(dir)
  dir
end
def tool(name) ; CROSS ? File.join(ndk_bin, name) : name ; end
def cc_cmd     ; CROSS ? [File.join(ndk_bin, 'clang'), '--target=aarch64-linux-android26'] : ['clang'] ; end
def readelf_cmd ; CROSS ? tool('llvm-readelf') : 'readelf' ; end
RUBY_DIR   = File.join(ROOT, 'ruby')
NATIVE_DIR = File.join(ROOT, 'native')
STAGE      = File.join(BUILD, 'stage')                       # extra APK entries: lib/, assets/
UI_DIR     = File.join(ROOT, 'ui')
UI_OUT     = File.join(STAGE, 'assets', 'ui')
APP_MRB    = File.join(STAGE, 'assets', 'app.mrb')
SO_DIR     = File.join(STAGE, 'lib', 'arm64-v8a')
SO_OUT     = File.join(SO_DIR, 'libmimir.so')
SO_UNSTRIPPED = File.join(BUILD, 'libmimir.unstripped.so')
ALLOWED_NEEDED = %w[libc.so libm.so libdl.so liblog.so]
RELEASE_KS  = File.join(TOOLS, 'release.keystore')
RELEASE_ENV = File.join(TOOLS, 'release.env')
BUNDLETOOL  = File.join(TOOLS, 'bundletool.jar')
OUT_AAB     = File.join(BUILD, 'Mimir.aab')

def sh(*cmd, quiet: false)
  puts "→ #{cmd.join(' ')[0, 160]}" unless quiet
  out, st = Open3.capture2e(*cmd)
  unless st.success?
    puts out
    abort "✗ failed: #{cmd.first}"
  end
  out
end

def newer?(srcs, target)
  return true unless File.exist?(target)
  t = File.mtime(target)
  srcs.any? { |f| File.mtime(f) > t }
end

def check_tools
  needed = %w[aapt2 javac d8 apksigner zip]
  needed += %w[clang patchelf llvm-strip llvm-nm readelf] unless CROSS
  needed.each { |t| abort "missing tool: #{t}" unless system("command -v #{t} >/dev/null 2>&1") }
  abort "missing #{JAR} — download platform zip into tools/" unless File.exist?(JAR)
  abort "missing #{KS} — run keytool (see PLAN.md)" unless File.exist?(KS)
end

# Vendor mruby (pinned tag) and mruby-json (pinned in vendor/PINS after first fetch).
def fetch
  FileUtils.mkdir_p(VENDOR)
  pins = File.join(VENDOR, 'PINS')
  pinned = File.exist?(pins) ? File.read(pins).scan(/^(\S+)\s+(\S+)$/).to_h : {}
  unless Dir.exist?(MRUBY_SRC)
    sh('git', 'clone', '--depth', '1', '--branch', MRUBY_TAG, 'https://github.com/mruby/mruby.git', MRUBY_SRC)
  end
  unless Dir.exist?(JSON_SRC)
    sh('git', 'clone', '--depth', '1', JSON_REPO, JSON_SRC)
    if pinned['mruby-json']
      sh('git', '-C', JSON_SRC, 'fetch', '--depth', '1', 'origin', pinned['mruby-json'])
      sh('git', '-C', JSON_SRC, 'checkout', '-q', pinned['mruby-json'])
    end
  end
  json_sha = sh('git', '-C', JSON_SRC, 'rev-parse', 'HEAD', quiet: true).strip
  File.write(pins, "mruby #{MRUBY_TAG}\nmruby-json #{json_sha}\n")
  puts "✓ vendored mruby #{MRUBY_TAG}, mruby-json #{json_sha[0, 10]}"
end

# Build libmruby.a + mrbc + mruby with Termux clang. Incremental on build_config.rb.
def mruby
  fetch unless Dir.exist?(MRUBY_SRC) && Dir.exist?(JSON_SRC)
  cfg = File.join(ROOT, 'native', 'build_config.rb')
  if File.exist?(MRUBY_LIB) && !newer?([cfg], MRUBY_LIB)
    puts '✓ mruby up to date'
    return
  end
  FileUtils.mkdir_p(MRUBY_OUT)
  env = { 'MRUBY_CONFIG' => cfg, 'MRUBY_BUILD_DIR' => MRUBY_OUT }
  puts "→ rake (mruby #{MRUBY_TAG}) — first build takes a few minutes"
  out, st = Open3.capture2e(env, 'rake', '-j4', chdir: MRUBY_SRC)
  unless st.success?
    puts out.lines.last(60).join
    abort '✗ mruby build failed'
  end
  abort "✗ #{MRUBY_LIB} missing after build (CROSS=#{CROSS})" unless File.exist?(MRUBY_LIB)
  puts "✓ built #{MRUBY_LIB} (#{(File.size(MRUBY_LIB) / 1024).round} KB), #{MRBC}, #{MRUBY_BIN}"
end

# ruby/**/*.rb (in load_order.txt order) -> assets/app.mrb. Depends on mrbc (bytecode format).
def mrb
  mruby
  order = File.read(File.join(RUBY_DIR, 'load_order.txt')).split.map { |f| File.join(RUBY_DIR, f) }
  order.each { |f| abort "missing #{f} (listed in load_order.txt)" unless File.exist?(f) }
  if File.exist?(APP_MRB) && !newer?(order + [MRBC], APP_MRB)
    puts '✓ app.mrb up to date'
    return
  end
  FileUtils.mkdir_p(File.dirname(APP_MRB))
  sh(MRBC, '-g', '-o', APP_MRB, *order)
  puts "✓ #{APP_MRB} (#{File.size(APP_MRB)} bytes)"
end

# native/*.c + libmruby.a -> lib/arm64-v8a/libmimir.so, then the loader gate.
def native
  mruby
  srcs = Dir[File.join(NATIVE_DIR, '*.c')]
  if File.exist?(SO_OUT) && !newer?(srcs + Dir[File.join(NATIVE_DIR, '*.h')] + [MRUBY_LIB], SO_OUT)
    puts '✓ libmimir.so up to date'
    return
  end
  FileUtils.mkdir_p(SO_DIR)
  Dir[File.join(SO_DIR, '*.so')].each { |f| FileUtils.rm_f(f) }   # never ship a stale/renamed library
  sh(*cc_cmd, '-shared', '-fPIC', '-O2', '-g', '-std=gnu11', '-fvisibility=hidden',
     '-ffunction-sections', '-fdata-sections', '-Wall',
     '-DMRB_UTF8_STRING', '-DMRB_INT64', '-DMRB_USE_DEBUG_HOOK', '-DMRB_DEBUG',
     '-I', File.join(MRUBY_SRC, 'include'), '-I', File.join(MRUBY_OUT, 'host', 'include'),
     '-Wl,-soname,libmimir.so', '-Wl,--build-id=sha1', '-Wl,-z,max-page-size=16384', '-Wl,--no-undefined', '-Wl,-z,defs',
     '-Wl,--exclude-libs,ALL', '-Wl,--gc-sections',
     '-o', SO_UNSTRIPPED, *srcs, MRUBY_LIB, '-llog', '-lm')
  sh('patchelf', '--remove-rpath', SO_UNSTRIPPED) unless CROSS    # Termux's clang injects a RUNPATH; the NDK's does not
  tmp = SO_OUT + '.tmp'
  sh(tool('llvm-strip'), '--strip-unneeded', '-o', tmp, SO_UNSTRIPPED)
  gate(tmp)                       # only a library that passes the gate becomes libmimir.so
  FileUtils.mv(tmp, SO_OUT)
  # Play Console "native debug symbols": zip of <abi>/<lib>.so with symbols, uploaded per release.
  sym_dir = File.join(BUILD, 'symbols', 'arm64-v8a'); FileUtils.mkdir_p(sym_dir)
  FileUtils.cp(SO_UNSTRIPPED, File.join(sym_dir, File.basename(SO_OUT)))
  sym_zip = File.join(BUILD, 'native-debug-symbols.zip'); FileUtils.rm_f(sym_zip)
  Dir.chdir(File.join(BUILD, 'symbols')) { sh('zip', '-q', '-r', sym_zip, 'arm64-v8a') }
  puts "✓ #{SO_OUT} (#{(File.size(SO_OUT) / 1024).round} KB; unstripped kept for symbolizing)"
end

# Refuse to ship a library the Android loader would reject or that leaks Termux dependencies.
def gate(so)
  dyn = sh(readelf_cmd, '-d', so, quiet: true)
  needed = dyn.scan(/\(NEEDED\)\s+Shared library: \[([^\]]+)\]/).flatten
  bad = needed - ALLOWED_NEEDED
  abort "✗ gate: unexpected NEEDED #{bad.inspect}" unless bad.empty?
  abort '✗ gate: RUNPATH/RPATH present' if dyn =~ /\((RUNPATH|RPATH)\)/
  abort '✗ gate: TEXTREL present' if dyn =~ /TEXTREL/
  loads = sh(readelf_cmd, '-lW', so, quiet: true).lines.grep(/^\s*LOAD/)
  aligns = loads.map { |l| l.split.last.hex }
  abort "✗ gate: LOAD alignment #{aligns.inspect} < 0x4000" if aligns.any? { |a| a < 0x4000 }
  exported = sh(tool('llvm-nm'), '-D', '--defined-only', so, quiet: true).lines.map { |l| l.split.last }
  exported -= %w[edata etext end _edata _etext _end]   # linker-provided, harmless
  abort "✗ gate: unexpected exports #{exported.inspect}" unless exported == ['JNI_OnLoad']
  puts "✓ gate: NEEDED=#{needed.join(',')} align=0x#{aligns.min.to_s(16)} exports=JNI_OnLoad"
end

# Run ruby/test under the built mruby CLI: fake host + app sources + tests concatenated in order.
def test
  mruby
  order = File.read(File.join(RUBY_DIR, 'load_order.txt')).split.map { |f| File.join(RUBY_DIR, f) }
  tests = Dir[File.join(RUBY_DIR, 'test', '*_test.rb')].sort
  files = [File.join(RUBY_DIR, 'test', 'fake_host.rb'), File.join(RUBY_DIR, 'test', 'run.rb')] + order + tests
  bundle = File.join(BUILD, 'test_bundle.rb')
  FileUtils.mkdir_p(BUILD)
  summary = "\nputs \"#{'#'}{$tests} tests, #{'#'}{$failures} failures\"\nraise \"tests failed\" if $failures > 0\n"
  File.write(bundle, files.map { |f| "# ---- #{File.basename(f)}\n" + File.read(f) }.join("\n") + summary)
  out, st = Open3.capture2e(MRUBY_BIN, bundle)
  puts out
  abort '✗ tests failed' unless st.success?
end

# ui/ui.rb (Opal Ruby) -> assets/ui/ui.js, plus the static html/css. One bundle including the
# Opal runtime; rebuilt only when ui/ changes.
def opal
  srcs = Dir[File.join(UI_DIR, '*')]
  out_js = File.join(UI_OUT, 'ui.js')
  if File.exist?(out_js) && !newer?(srcs, out_js)
    puts '✓ ui.js up to date'
    return
  end
  abort 'missing opal (gem install opal)' unless system('command -v opal >/dev/null')
  # Lint: Opal returns a method's last expression; a backtick with several JS statements there
  # silently runs only the first. Forbid multi-statement backticks outright.
  File.readlines(File.join(UI_DIR, 'ui.rb')).each_with_index do |line, i|
    next if line.strip.start_with?('#')
    if line =~ /`[^`]*;[^`]*`/ && line !~ /%x\{/
      abort "✗ ui/ui.rb:#{i + 1}: multi-statement backtick (Opal runs only the first when it is the last expression): #{line.strip[0, 90]}"
    end
  end
  FileUtils.mkdir_p(UI_OUT)
  js, err, st = Open3.capture3('opal', '-c', '--no-source-map', '-I', UI_DIR, File.join(UI_DIR, 'ui.rb'))
  unless st.success?
    puts err
    abort '✗ opal compile failed'
  end
  puts err.lines.grep_v(/backtick_javascript/).join unless err.strip.empty?
  File.write(out_js, js)
  %w[ui.html ui.css].each { |f| FileUtils.cp(File.join(UI_DIR, f), UI_OUT) }   # before the checks: they load the shell
  out, st2 = Open3.capture2e('node', '--check', out_js)
  abort "✗ ui.js is not valid JavaScript:\n#{out}" unless st2.success?
  # Boot the bundle against a stub DOM: catches Opal runtime errors (e.g. mutable-string calls).
  out, st3 = Open3.capture2e('node', File.join(ROOT, 'tools', 'ui_smoke.js'), out_js)
  abort "✗ ui.js failed to boot:\n#{out}" unless st3.success?
  # Real-DOM run (jsdom) when available: boot, receive state, open pages, click through.
  if Dir.exist?(File.join(ROOT, 'tools', 'node_modules', 'jsdom'))
    out, st4 = Open3.capture2e('node', File.join(ROOT, 'tools', 'ui_jsdom.js'), UI_OUT)
    abort "✗ ui.js failed in jsdom:\n#{out}" unless st4.success?
    puts out.lines.last.to_s.strip
  end
  puts "✓ #{out_js} (#{(File.size(out_js) / 1024).round} KB incl. Opal runtime)"
end

# BuildInfo.java is generated from mimir.config.json. `--play` produces the Play Store variant,
# which hides the Donate link (Play requires its own billing for in-app tips).
def gen_buildinfo
  cfg = JSON.parse(File.read(File.join(ROOT, 'mimir.config.json'))) rescue {}
  # Play Store artifacts (.aab) always hide the external donate link (Play billing policy);
  # sideload/GitHub/debug builds keep it and use it as the fallback when Play is unavailable.
  cmd = ARGV.reject { |a| a.start_with?('--') }[0]
  play = ARGV.include?('--play') || %w[bundle gbundle].include?(cmd)
  donate = play ? '' : cfg['donate_url'].to_s
  src = <<~JAVA
    package com.mstsage.mimir;

    /** Generated by bin/build.rb from mimir.config.json — do not edit. */
    final class BuildInfo {
        static final String VERSION = "#{cfg['version'] || '0.0.0'}";
        static final String DONATE_URL = "#{donate}";
        static final String SOURCE_URL = "#{cfg['source_url'].to_s}";
        static final String PLAY_PUBLIC_KEY = "#{cfg['play_public_key'].to_s}";
        static final boolean PLAY_BUILD = #{play};
        private BuildInfo() {}
    }
  JAVA
  out = File.join(ANDROID, 'src', 'com', 'mstsage', 'mimir', 'BuildInfo.java')
  File.write(out, src) unless File.exist?(out) && File.read(out) == src
  # Stamp the manifest from the same config: versionName = version, versionCode = MMmmpp (e.g. 0.8.0 -> 800).
  ver = (cfg['version'] || '0.0.0').to_s
  code = ver.split('.').map(&:to_i).values_at(0, 1, 2).map { |x| x || 0 }.then { |a, b, c| a * 10_000 + b * 100 + c }
  mf = File.join(ANDROID, 'AndroidManifest.xml')
  m = File.read(mf)
  m2 = m.sub(/android:versionCode="\d+"/, "android:versionCode=\"#{code}\"").sub(/android:versionName="[^"]*"/, "android:versionName=\"#{ver}\"")
  File.write(mf, m2) if m2 != m
end

def release_creds
  abort "missing #{RELEASE_KS} / #{RELEASE_ENV} (see PLAN.md: release signing)" unless File.exist?(RELEASE_KS) && File.exist?(RELEASE_ENV)
  env = File.read(RELEASE_ENV).scan(/^(\w+)=(.*)$/).to_h
  [env['MIMIR_KEYSTORE_PASS'], env['MIMIR_KEY_ALIAS'] || 'mimir']
end

# Signed release APK (GitHub Releases / sideload). Same pipeline as build, release key.
def release
  build
  pass, alias_ = release_creds
  out = File.join(BUILD, 'Mimir-release.apk')
  sh('apksigner', 'sign', '--ks', RELEASE_KS, '--ks-pass', "pass:#{pass}", '--key-pass', "pass:#{pass}",
     '--ks-key-alias', alias_, '--min-sdk-version', MIN_SDK.to_s, '--out', out, File.join(BUILD, 'staged.apk'))
  sh('apksigner', 'verify', out, quiet: true)
  puts "✓ release APK #{out} (#{(File.size(out) / 1024.0).round} KB)"
end

# Play Store bundle (.aab): resources linked in proto format, module zip laid out per bundletool,
# then bundletool build-bundle and jarsigner (bundles use JAR signing; Play re-signs the APKs).
def bundle
  gen_buildinfo
  check_tools
  mrb; native; opal
  abort "missing #{BUNDLETOOL}" unless File.exist?(BUNDLETOOL)
  pass, alias_ = release_creds
  manifest = File.join(ANDROID, 'AndroidManifest.xml')
  res_zip  = File.join(BUILD, 'res.zip')
  proto    = File.join(BUILD, 'proto.apk')
  mod_dir  = File.join(BUILD, 'aab', 'base')
  FileUtils.rm_rf(File.join(BUILD, 'aab')); FileUtils.mkdir_p(mod_dir)
  sh('aapt2', 'compile', '--dir', File.join(ANDROID, 'res'), '-o', res_zip)
  sh('aapt2', 'link', '--proto-format', '-o', proto, '-I', JAR, '--manifest', manifest,
     '--min-sdk-version', MIN_SDK.to_s, '--target-sdk-version', TGT_SDK.to_s, '--auto-add-overlay', res_zip)
  # unpack the proto apk into the module layout: manifest/AndroidManifest.xml, res/, resources.pb
  Dir.chdir(mod_dir) do
    sh('unzip', '-q', '-o', proto)
    FileUtils.mkdir_p('manifest'); FileUtils.mv('AndroidManifest.xml', 'manifest/AndroidManifest.xml')
    FileUtils.mkdir_p('dex'); FileUtils.cp(File.join(BUILD, 'dex', 'classes.dex'), 'dex/classes.dex')
    FileUtils.cp_r(File.join(STAGE, 'lib'), 'lib')
    FileUtils.cp_r(File.join(STAGE, 'assets'), 'assets')
    assets = File.join(ANDROID, 'assets')
    FileUtils.cp_r(Dir[File.join(assets, '*')], 'assets') if Dir.exist?(assets)
    FileUtils.rm_f(Dir['META-INF/**/*'])
    FileUtils.rm_f('base.zip')
    sh('zip', '-q', '-r', '../base.zip', '.', '-x', '.*')
  end
  # dex must exist: `build` (via mrb/native/opal above) does not compile java; do it if missing
  abort 'no classes.dex — run bin/build.rb build first' unless File.exist?(File.join(BUILD, 'dex', 'classes.dex'))
  FileUtils.rm_f(OUT_AAB)
  sh('java', '-jar', BUNDLETOOL, 'build-bundle', "--modules=#{File.join(BUILD, 'aab', 'base.zip')}", "--output=#{OUT_AAB}")
  sh('jarsigner', '-keystore', RELEASE_KS, '-storepass', pass, '-keypass', pass, '-sigalg', 'SHA256withRSA', '-digestalg', 'SHA-256', OUT_AAB, alias_, quiet: true)
  sh('java', '-jar', BUNDLETOOL, 'validate', "--bundle=#{OUT_AAB}", quiet: true)
  # Prove the bundle installs: derive a universal APK the way Play would (with our aapt2, the
  # bundled one is x86 Linux) and verify its signature.
  apks = File.join(BUILD, 'Mimir.apks')
  FileUtils.rm_f(apks)
  sh('java', '-jar', BUNDLETOOL, 'build-apks', "--bundle=#{OUT_AAB}", "--output=#{apks}", '--mode=universal',
     "--aapt2=#{ENV['PATH'].split(':').map { |d| File.join(d, 'aapt2') }.find { |f| File.executable?(f) }}", "--ks=#{RELEASE_KS}", "--ks-key-alias=#{alias_}", "--ks-pass=pass:#{pass}", "--key-pass=pass:#{pass}", quiet: true)
  chk = File.join(BUILD, 'aab-check'); FileUtils.rm_rf(chk); FileUtils.mkdir_p(chk)
  sh('unzip', '-q', '-o', apks, 'universal.apk', '-d', chk, quiet: true)
  sh('apksigner', 'verify', File.join(chk, 'universal.apk'), quiet: true)
  puts "✓ Play bundle #{OUT_AAB} (#{(File.size(OUT_AAB) / 1024.0).round} KB), universal APK from it verifies — upload the .aab in Play Console"
end

# Gradle path (needed for AAR dependencies such as Play Billing): Ruby builds mruby, the native
# library, bytecode and Opal UI, then Gradle compiles Java + resources and packages the APK/AAB.
def gradle_manifest
  m = File.read(File.join(ANDROID, 'AndroidManifest.xml'))
  m = m.sub(/\s*package="[^"]*"/, '')      # AGP takes the namespace from build.gradle
  FileUtils.mkdir_p(File.join(BUILD, 'gradle'))
  File.write(File.join(BUILD, 'gradle', 'AndroidManifest.xml'), m)
end

def gradle(task)
  gen_buildinfo
  mrb; native; opal
  gradle_manifest
  puts "→ gradle #{task}"
  wrapper = File.join(ROOT, 'gradlew')
  unless File.exist?(wrapper) || system('command -v gradle >/dev/null 2>&1')
    abort '✗ no Gradle: run `git pull` to get the gradlew wrapper (pinned to Gradle 9.7.1)'
  end
  args = [File.exist?(wrapper) ? wrapper : 'gradle', '--console=plain']         # wrapper pins Gradle 9.7.1 everywhere
  args << '-q' unless ENV['VERBOSE']
  args << "-Pandroid.aapt2FromMavenOverride=#{ENV['PREFIX']}/bin/aapt2" if ON_TERMUX   # AGP's aapt2 is x86; use Termux's
  ok = system({ 'JAVA_TOOL_OPTIONS' => '-Dfile.encoding=UTF-8', 'MIMIR_FROM_BUILD_RB' => '1' }, *args, task, chdir: ROOT)
  abort '✗ gradle failed (rerun with VERBOSE=1 for the full log)' unless ok
  out = Dir[File.join(ROOT, 'app', 'build', 'outputs', '**', '*.{apk,aab}')].max_by { |f| File.mtime(f) }
  puts "✓ #{out} (#{(File.size(out) / 1024.0).round} KB)" if out
  out
end

def build
  gen_buildinfo
  check_tools
  FileUtils.mkdir_p(BUILD)
  res_files = Dir[File.join(ANDROID, 'res', '**', '*')].select { |f| File.file?(f) }
  manifest  = File.join(ANDROID, 'AndroidManifest.xml')
  java_src  = Dir[File.join(ANDROID, 'src', '**', '*.java')]
  gen_dir   = File.join(BUILD, 'gen')
  cls_dir   = File.join(BUILD, 'classes')
  res_zip   = File.join(BUILD, 'res.zip')
  unsigned  = File.join(BUILD, 'unsigned.apk')
  dex_dir   = File.join(BUILD, 'dex')

  if newer?(res_files + [manifest], unsigned)
    sh('aapt2', 'compile', '--dir', File.join(ANDROID, 'res'), '-o', res_zip)
    FileUtils.mkdir_p(gen_dir)
    sh('aapt2', 'link', '-o', unsigned, '-I', JAR, '--manifest', manifest, '--java', gen_dir,
       '--min-sdk-version', MIN_SDK.to_s, '--target-sdk-version', TGT_SDK.to_s,
       '--auto-add-overlay', res_zip)
  else
    puts '✓ resources up to date'
  end

  gen_src = Dir[File.join(gen_dir, '**', '*.java')]
  if newer?(java_src + gen_src, cls_dir) || Dir[File.join(cls_dir, '**', '*.class')].empty?
    FileUtils.rm_rf(cls_dir); FileUtils.mkdir_p(cls_dir)
    at_exit { FileUtils.rm_rf(cls_dir) unless $javac_ok }   # never leave partial classes behind
    sh('javac', '--release', '8', '-nowarn', '-Xlint:none', '-proc:none', '-encoding', 'UTF-8', '-cp', JAR, '-d', cls_dir, *java_src, *gen_src)
    $javac_ok = true
    FileUtils.touch(cls_dir)
  else
    puts '✓ classes up to date'
  end

  classes = Dir[File.join(cls_dir, '**', '*.class')]
  dex = File.join(dex_dir, 'classes.dex')
  if newer?(classes, dex)
    FileUtils.rm_rf(dex_dir); FileUtils.mkdir_p(dex_dir)
    sh('d8', '--release', '--lib', JAR, '--min-api', MIN_SDK.to_s, '--output', dex_dir, *classes)
  else
    puts '✓ dex up to date'
  end

  mrb
  native
  opal
  staged = File.join(BUILD, 'staged.apk')
  FileUtils.cp(unsigned, staged)
  Dir.chdir(dex_dir) { sh('zip', '-q', '-j', staged, 'classes.dex') }
  assets = File.join(ANDROID, 'assets')
  Dir.chdir(assets) { sh('zip', '-q', '-r', staged, '.', '-x', '.*') } if Dir.exist?(assets) && !Dir.empty?(assets)
  # lib/arm64-v8a/libmimir.so + assets/app.mrb (extractNativeLibs=true, so compression is fine)
  Dir.chdir(STAGE) { sh('zip', '-q', '-r', staged, 'lib', 'assets') }
  sh('apksigner', 'sign', '--ks', KS, '--ks-pass', 'pass:android', '--key-pass', 'pass:android',
     '--ks-key-alias', 'inspect', '--min-sdk-version', MIN_SDK.to_s, '--out', OUT_APK, staged)
  puts "✓ built #{OUT_APK} (#{(File.size(OUT_APK) / 1024.0).round} KB, sha1 #{Digest::SHA1.file(OUT_APK).hexdigest[0, 12]})"
end

# Android 14+ silently drops installer requests from apps without REQUEST_INSTALL_PACKAGES
# (Termux), so we stage the APK in public Downloads and open the file manager there instead.
def install
  abort 'no APK; run build first' unless File.exist?(OUT_APK)
  dl = File.join(Dir.home, 'storage', 'downloads')
  abort 'run termux-setup-storage first (no ~/storage/downloads)' unless Dir.exist?(dl)
  FileUtils.cp(OUT_APK, File.join(dl, 'Mimir.apk'))
  system('am', 'start', '-a', 'android.intent.action.VIEW_DOWNLOADS', out: File::NULL, err: File::NULL)
  puts 'APK copied to Downloads/Mimir.apk — tap it in the file manager to install.'
end

def run
  system('am', 'start', '-n', "#{PKG}/.MainActivity") || puts('could not launch; open the app manually')
end

cmds = ARGV.reject { |a| a.start_with?('--') }
cmds = ['build'] if cmds.empty?
# several stage names may be given at once, e.g. `mrb native opal` (used by the Gradle rubyStages task)
if cmds.size > 1 && cmds.all? { |c| %w[fetch mruby mrb native opal test].include?(c) }
  cmds.each { |c| send(c) }
  exit 0
end
case cmds[0]
when 'fetch'   then fetch
when 'mruby'   then mruby
when 'mrb'     then mrb
when 'native'  then native
when 'test'    then test
when 'opal'    then opal
when 'build'   then build
when 'release' then release
when 'gradle'  then gradle(ARGV[1] || ':app:assembleDebug')
when 'gbuild'   then gradle(':app:assembleDebug')
when 'ginstall' then out = gradle(':app:assembleDebug'); FileUtils.cp(out, File.join(Dir.home, 'storage', 'downloads', 'Mimir.apk')); system('am', 'start', '-a', 'android.intent.action.VIEW_DOWNLOADS', out: File::NULL, err: File::NULL); puts 'APK copied to Downloads/Mimir.apk — tap it in the file manager to install.'
when 'grelease' then gradle(':app:assembleRelease')
when 'gbundle'  then gradle(':app:bundleRelease')
when 'bundle'  then build; bundle
when 'install' then build; install
when 'run'     then run
when 'clean'   then Dir[File.join(BUILD, '*')].each { |f| FileUtils.rm_rf(f) unless File.basename(f) == 'mruby' }; puts 'cleaned (kept build/mruby)'
else abort 'usage: bin/build.rb [fetch|mruby|mrb|native|opal|test|build|release|bundle|gradle <task>|gbuild|ginstall|grelease|gbundle|install|run|clean] [--play]'
end
