#!/usr/bin/env ruby
# 512x512 images for the Play one-time products (tip jar tiers): the Mímir mark with a heart badge.
require 'fileutils'
load File.join(__dir__, 'make_store_art.rb') if false   # (mark() is duplicated below to stay standalone)
OUT = File.expand_path('../store/tips', __dir__)
FileUtils.mkdir_p(OUT)
NAVY = '#0f172a'; SKY = '#38bdf8'; ROSE = '#f43f5e'; GOLD = '#fbbf24'; FG = '#e2e8f0'

TIERS = [
  ['tip_small',  'Coffee', 1, SKY],
  ['tip_medium', 'Lunch',  2, GOLD],
  ['tip_large',  'Dinner', 3, ROSE]
]

TIERS.each do |id, label, hearts, accent|
  s = 512; m = s * 0.20; w = s * 0.075; l = s * 0.24
  corner = ->(cx, cy, dx, dy) { %(<path d="M#{cx} #{cy + dy * l} L#{cx} #{cy} L#{cx + dx * l} #{cy}" fill="none" stroke="#{SKY}" stroke-width="#{w}" stroke-linecap="square"/>) }
  heart = ->(x, y, r) { %(<path transform="translate(#{x} #{y}) scale(#{r / 12.0})" d="M0 9 C-1 8 -12 2 -12 -4 A6 6 0 0 1 0 -6 A6 6 0 0 1 12 -4 C12 2 1 8 0 9 Z" fill="#{accent}"/>) }
  badge_w = 110 + (hearts - 1) * 46
  bx = s - badge_w - 40; by = s - 150
  hearts_svg = (0...hearts).map { |i| heart.call(bx + 55 + i * 46, by + 58, 18) }.join
  svg = <<~SVG
    <svg xmlns="http://www.w3.org/2000/svg" width="#{s}" height="#{s}" viewBox="0 0 #{s} #{s}">
      <rect width="#{s}" height="#{s}" rx="#{s * 0.18}" fill="#{NAVY}"/>
      #{corner.call(m, m, 1, 1)}#{corner.call(s - m, m, -1, 1)}#{corner.call(m, s - m, 1, -1)}#{corner.call(s - m, s - m, -1, -1)}
      <text x="#{s / 2.0}" y="#{s * 0.62}" text-anchor="middle" font-family="DejaVu Sans" font-weight="bold" font-size="#{s * 0.42}" fill="#{SKY}">M</text>
      <rect x="#{bx}" y="#{by}" width="#{badge_w}" height="116" rx="58" fill="#1e293b" stroke="#{accent}" stroke-width="6"/>
      #{hearts_svg}
    </svg>
  SVG
  path = File.join(OUT, "#{id}.svg"); File.write(path, svg)
  png = File.join(OUT, "#{id}.png")
  system('rsvg-convert', '-w', '512', '-h', '512', '-o', png, path) or abort 'rsvg failed'
  puts "#{png} (#{label})"
end
