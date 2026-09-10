require 'zlib'
def png(size)
  bg=[15,23,42]; fg=[56,189,248]; rows=[]
  r=size*0.18
  size.times do |y|
    row=[0]
    size.times do |x|
      # rounded square mask
      cx=[r-x, x-(size-1-r), 0].max; cy=[r-y, y-(size-1-r), 0].max
      inside = (cx*cx+cy*cy) <= r*r
      col = inside ? bg : [0,0,0,0]
      if inside
        # corner brackets
        m=size*0.2; w=size*0.075; len=size*0.22
        nearL=(x-m).abs<w/2 && y>=m-w/2 && y<=m+len; nearT=(y-m).abs<w/2 && x>=m-w/2 && x<=m+len
        nearR=(x-(size-1-m)).abs<w/2 && y>=size-1-m-len && y<=size-1-m+w/2; nearB=(y-(size-1-m)).abs<w/2 && x>=size-1-m-len && x<=size-1-m+w/2
        nearL2=(x-m).abs<w/2 && y>=size-1-m-len && y<=size-1-m+w/2; nearB2=(y-(size-1-m)).abs<w/2 && x>=m-w/2 && x<=m+len
        nearR2=(x-(size-1-m)).abs<w/2 && y>=m-w/2 && y<=m+len; nearT2=(y-m).abs<w/2 && x>=size-1-m-len && x<=size-1-m+w/2
        # cursor arrow-ish centre: filled circle
        dx=x-size/2.0; dy=y-size/2.0; dot = dx*dx+dy*dy <= (size*0.13)**2
        col = (nearL||nearT||nearR||nearB||nearL2||nearB2||nearR2||nearT2||dot) ? fg : bg
        col = col + [255]
      end
      row.concat(col)
    end
    rows << row.pack('C*')
  end
  raw=rows.join
  chunk=->(t,d){ [d.bytesize].pack('N')+t+d+[Zlib.crc32(t+d)].pack('N') }
  "\x89PNG\r\n\x1a\n".b + chunk.call('IHDR',[size,size,8,6,0,0,0].pack('NNCCCCC')) + chunk.call('IDAT',Zlib::Deflate.deflate(raw)) + chunk.call('IEND','')
end
[192,512].each{|s| File.binwrite(File.join(__dir__,'..','app','public',"icon-#{s}.png"), png(s)) }
{ 'mdpi'=>48, 'hdpi'=>72, 'xhdpi'=>96, 'xxhdpi'=>144, 'xxxhdpi'=>192 }.each do |dpi,sz|
  dir=File.join(__dir__,'..','android','res',"mipmap-#{dpi}"); require 'fileutils'; FileUtils.mkdir_p(dir)
  File.binwrite(File.join(dir,'ic_launcher.png'), png(sz))
end
puts "icons written"
