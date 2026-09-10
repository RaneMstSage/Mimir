#!/usr/bin/env ruby
# frozen_string_literal: true
# Ruby build pipeline for the Android app: aapt2 -> ecj -> d8 -> zip -> apksigner.
# Usage: bin/build.rb [build|install|run|clean]
require 'fileutils'
require 'open3'
require 'digest'

ROOT    = File.expand_path('..', __dir__)
ANDROID = File.join(ROOT, 'android')
TOOLS   = File.join(ROOT, 'tools')
BUILD   = File.join(ROOT, 'build')
JAR     = File.join(TOOLS, 'android.jar')
KS      = File.join(TOOLS, 'debug.keystore')
PKG     = 'com.mstsage.inspect'
MIN_SDK = 26
TGT_SDK = 35
OUT_APK = File.join(BUILD, 'InspectElement.apk')
VENDOR     = File.join(ROOT, 'vendor')
MRUBY_SRC  = File.join(VENDOR, 'mruby')
MRUBY_TAG  = '4.0.0'
JSON_SRC   = File.join(VENDOR, 'mruby-json')
JSON_REPO  = 'https://github.com/mattn/mruby-json.git'
MRUBY_OUT  = File.join(BUILD, 'mruby')
MRUBY_LIB  = File.join(MRUBY_OUT, 'host', 'lib', 'libmruby.a')
MRBC       = File.join(MRUBY_OUT, 'host', 'bin', 'mrbc')
MRUBY_BIN  = File.join(MRUBY_OUT, 'host', 'bin', 'mruby')

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
  %w[aapt2 javac d8 apksigner zip].each { |t| abort "missing tool: #{t} (pkg install #{t})" unless system("command -v #{t} >/dev/null") }
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
  abort "✗ #{MRUBY_LIB} missing after build" unless File.exist?(MRUBY_LIB)
  puts "✓ built #{MRUBY_LIB} (#{(File.size(MRUBY_LIB) / 1024).round} KB), #{MRBC}, #{MRUBY_BIN}"
end

def build
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

  staged = File.join(BUILD, 'staged.apk')
  FileUtils.cp(unsigned, staged)
  Dir.chdir(dex_dir) { sh('zip', '-q', '-j', staged, 'classes.dex') }
  assets = File.join(ANDROID, 'assets')
  Dir.chdir(assets) { sh('zip', '-q', '-r', staged, '.', '-x', '.*') } if Dir.exist?(assets) && !Dir.empty?(assets)
  sh('apksigner', 'sign', '--ks', KS, '--ks-pass', 'pass:android', '--key-pass', 'pass:android',
     '--ks-key-alias', 'inspect', '--min-sdk-version', MIN_SDK.to_s, '--out', OUT_APK, staged)
  puts "✓ built #{OUT_APK} (#{(File.size(OUT_APK) / 1024.0).round} KB, sha1 #{Digest::SHA1.file(OUT_APK).hexdigest[0, 12]})"
end

def install
  abort 'no APK; run build first' unless File.exist?(OUT_APK)
  sh('termux-open', '--content-type', 'application/vnd.android.package-archive', OUT_APK)
  puts 'Installer opened — tap Install (or Update).'
end

def run
  system('am', 'start', '-n', "#{PKG}/.MainActivity") || puts('could not launch; open the app manually')
end

case ARGV[0] || 'build'
when 'fetch'   then fetch
when 'mruby'   then mruby
when 'build'   then build
when 'install' then build; install
when 'run'     then run
when 'clean'   then FileUtils.rm_rf(BUILD); puts 'cleaned'
else abort 'usage: bin/build.rb [fetch|mruby|build|install|run|clean]'
end
