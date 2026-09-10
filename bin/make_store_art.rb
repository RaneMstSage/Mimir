#!/usr/bin/env ruby
# Play Store art: 512x512 icon (PNG with alpha) and 1024x500 feature graphic (24-bit PNG),
# generated from SVG so the art stays reproducible and matches the launcher motif.
require 'fileutils'
OUT = File.expand_path('../store', __dir__)
FileUtils.mkdir_p(OUT)

NAVY = '#0f172a'; INK = '#020617'; SKY = '#38bdf8'; FG = '#e2e8f0'; MUTED = '#94a3b8'

# The mark: rounded square, inspect brackets, a bold M. `s` is the box size.
def mark(x, y, s, radius: 0.18, with_bg: true)
  m = s * 0.20; w = s * 0.075; l = s * 0.24
  bg = with_bg ? %(<rect x="#{x}" y="#{y}" width="#{s}" height="#{s}" rx="#{s * radius}" fill="#{NAVY}"/>) : ''
  corner = lambda do |cx, cy, dx, dy|
    %(<path d="M#{cx} #{cy + dy * l} L#{cx} #{cy} L#{cx + dx * l} #{cy}" fill="none" stroke="#{SKY}" stroke-width="#{w}" stroke-linecap="square"/>)
  end
  <<~SVG
    #{bg}
    #{corner.call(x + m, y + m, 1, 1)}
    #{corner.call(x + s - m, y + m, -1, 1)}
    #{corner.call(x + m, y + s - m, 1, -1)}
    #{corner.call(x + s - m, y + s - m, -1, -1)}
    <text x="#{x + s / 2.0}" y="#{y + s * 0.665}" text-anchor="middle" font-family="DejaVu Sans" font-weight="bold" font-size="#{s * 0.46}" fill="#{SKY}">M</text>
  SVG
end

icon = <<~SVG
  <svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">
    #{mark(0, 0, 512)}
  </svg>
SVG
File.write(File.join(OUT, 'icon-512.svg'), icon)
system('rsvg-convert', '-w', '512', '-h', '512', '-o', File.join(OUT, 'icon-512.png'), File.join(OUT, 'icon-512.svg')) or abort 'rsvg failed'

feature = <<~SVG
  <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="500" viewBox="0 0 1024 500">
    <defs>
      <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
        <stop offset="0" stop-color="#{INK}"/><stop offset="1" stop-color="#1e293b"/>
      </linearGradient>
      <linearGradient id="glow" x1="0" y1="0" x2="1" y2="0">
        <stop offset="0" stop-color="#{SKY}" stop-opacity="0.18"/><stop offset="1" stop-color="#{SKY}" stop-opacity="0"/>
      </linearGradient>
    </defs>
    <rect width="1024" height="500" fill="url(#bg)"/>
    <rect width="1024" height="500" fill="url(#glow)"/>
    <!-- faint code lines, like a DevTools panel -->
    <g font-family="DejaVu Sans Mono" font-size="15" fill="#{MUTED}" opacity="0.35">
      <text x="560" y="44">&lt;main class="lesson"&gt;</text>
      <text x="580" y="68">&lt;h1&gt;Full-stack, from a tablet&lt;/h1&gt;</text>
      <text x="580" y="92">&lt;section id="devtools"&gt;…&lt;/section&gt;</text>
      <text x="560" y="116">&lt;/main&gt;</text>
    </g>
    #{mark(72, 110, 280, radius: 0.18)}
    <text x="400" y="248" font-family="DejaVu Sans" font-weight="bold" font-size="112" fill="#{FG}">Mímir</text>
    <text x="404" y="312" font-family="DejaVu Sans" font-size="34" fill="#{SKY}">Real DevTools. On your tablet.</text>
    <text x="404" y="362" font-family="DejaVu Sans" font-size="22" fill="#{MUTED}">Inspect, debug and code on Android — no PC, no cable.</text>
    <g font-family="DejaVu Sans" font-size="18" fill="#{FG}">
      <rect x="404" y="398" width="132" height="34" rx="17" fill="#1e293b"/><text x="470" y="421" text-anchor="middle">Elements</text>
      <rect x="546" y="398" width="118" height="34" rx="17" fill="#1e293b"/><text x="605" y="421" text-anchor="middle">Console</text>
      <rect x="674" y="398" width="118" height="34" rx="17" fill="#1e293b"/><text x="733" y="421" text-anchor="middle">Network</text>
      <rect x="802" y="398" width="150" height="34" rx="17" fill="#1e293b"/><text x="877" y="421" text-anchor="middle">Open source</text>
    </g>
  </svg>
SVG
File.write(File.join(OUT, 'feature-1024x500.svg'), feature)
# Feature graphics must be 24-bit (no alpha): flatten on the ink colour.
system('rsvg-convert', '-w', '1024', '-h', '500', '-b', INK, '-o', File.join(OUT, 'feature-1024x500.png'), File.join(OUT, 'feature-1024x500.svg')) or abort 'rsvg failed'
# Launcher icons for the APK, from the same mark, so device and store match.
{ 'mdpi' => 48, 'hdpi' => 72, 'xhdpi' => 96, 'xxhdpi' => 144, 'xxxhdpi' => 192 }.each do |dpi, sz|
  dir = File.expand_path("../android/res/mipmap-#{dpi}", __dir__)
  FileUtils.mkdir_p(dir)
  system('rsvg-convert', '-w', sz.to_s, '-h', sz.to_s, '-o', File.join(dir, 'ic_launcher.png'), File.join(OUT, 'icon-512.svg')) or abort 'rsvg failed'
end
puts Dir[File.join(OUT, '*.png')].map { |f| "#{f} #{File.size(f)} bytes" }
puts 'launcher mipmaps regenerated'

