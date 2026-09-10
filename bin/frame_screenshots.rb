#!/usr/bin/env ruby
# Frame device screenshots onto 16:9 canvases for Play (phone / 7" / 10" slots share the output).
# Usage: bin/frame_screenshots.rb out_dir "caption|path.png" ["caption|path.png" ...]
# Each frame: dark gradient, the screenshot scaled to fit with rounded corners, a caption strip.
require 'fileutils'
W, H = 1920, 1080
CROP_BOTTOM = (ENV['CROP_BOTTOM'] || 46).to_i     # source px to drop from the bottom (diagnostic status line)
INK = '#020617'; NAVY = '#1e293b'; SKY = '#38bdf8'; FG = '#e2e8f0'

out_dir = ARGV.shift or abort 'usage: frame_screenshots.rb out_dir "caption|file" ...'
FileUtils.mkdir_p(out_dir)
ARGV.each_with_index do |spec, i|
  caption, path = spec.split('|', 2)
  abort "missing #{path}" unless path && File.exist?(path)
  # librsvg only loads images from the SVG's own directory; copy the source beside it (no spaces)
  ext = File.extname(path).downcase == '.png' ? 'png' : 'jpg'
  src = File.join(out_dir, "src-#{i + 1}.#{ext}")
  FileUtils.cp(path, src)
  info = `file "#{src}"`
  m = info.match(/(\d{3,5})\s*x\s*(\d{3,5})/)
  sw, sh = m ? [m[1].to_i, m[2].to_i] : [2800, 1752]
  full_h = sh
  sh -= CROP_BOTTOM
  # fit into a box leaving room for the caption
  box_w, box_h = W - 160, H - 220
  scale = [box_w.to_f / sw, box_h.to_f / sh].min
  iw, ih = (sw * scale).round, (sh * scale).round
  ix, iy = (W - iw) / 2, 150 + (box_h - ih) / 2
  svg = <<~SVG
    <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="#{W}" height="#{H}" viewBox="0 0 #{W} #{H}">
      <defs>
        <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#{INK}"/><stop offset="1" stop-color="#{NAVY}"/></linearGradient>
        <clipPath id="r"><rect x="#{ix}" y="#{iy}" width="#{iw}" height="#{ih}" rx="22"/></clipPath>
        <filter id="shadow" x="-10%" y="-10%" width="120%" height="130%"><feDropShadow dx="0" dy="18" stdDeviation="22" flood-color="#000" flood-opacity="0.55"/></filter>
      </defs>
      <rect width="#{W}" height="#{H}" fill="url(#bg)"/>
      <text x="#{W / 2}" y="96" text-anchor="middle" font-family="DejaVu Sans" font-weight="bold" font-size="52" fill="#{FG}">#{caption.gsub('&', '&amp;').gsub('<', '&lt;')}</text>
      <rect x="#{ix}" y="#{iy}" width="#{iw}" height="#{ih}" rx="22" fill="#{NAVY}" filter="url(#shadow)"/>
      <image x="#{ix}" y="#{iy}" width="#{iw}" height="#{(full_h * scale).round}" preserveAspectRatio="none" clip-path="url(#r)" xlink:href="src-#{i + 1}.#{ext}"/>
      <rect x="#{ix}" y="#{iy}" width="#{iw}" height="#{ih}" rx="22" fill="none" stroke="#{SKY}" stroke-opacity="0.35" stroke-width="2"/>
    </svg>
  SVG
  svg_path = File.join(out_dir, "shot-#{i + 1}.svg")
  File.write(svg_path, svg)
  png = File.join(out_dir, "shot-#{i + 1}.png")
  system('rsvg-convert', '-w', W.to_s, '-h', H.to_s, '-b', INK, '-o', png, svg_path) or abort 'rsvg failed'
  File.delete(svg_path); File.delete(src)
  puts "#{png} (#{File.size(png) / 1024} KB) — #{caption}"
end
