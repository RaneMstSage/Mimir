# Turn what the user typed in the URL bar into something loadable. No Regexp in this build.
module UrlNorm
  SEARCH = "https://www.google.com/search?q="
  ENGINES = {
    "google"     => "https://www.google.com/search?q=",
    "duckduckgo" => "https://duckduckgo.com/?q=",
    "bing"       => "https://www.bing.com/search?q=",
    "brave"      => "https://search.brave.com/search?q="
  }
  SAFE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"

  def self.normalize(text, engine = "google")
    q = text.to_s.strip
    return nil if q.empty?
    return q if scheme?(q)
    return "https://#{q}" if hostish?(q)
    (ENGINES[engine] || SEARCH) + encode(q)
  end

  # "http:", "about:", "javascript:" ... — letters/digits/+.- then a colon, and something after it.
  def self.scheme?(s)
    i = s.index(":")
    return false unless i && i > 0 && i < s.size - 1
    return false if digit?(s[i + 1])          # "localhost:8765/x" is host:port, not a scheme
    head = s[0, i]
    return false unless letter?(head[0])
    head.each_char { |c| return false unless letter?(c) || digit?(c) || "+.-".include?(c) }
    true
  end

  def self.hostish?(s)
    return false if s.include?(" ")
    host = s.split("/")[0].to_s.split(":")[0].to_s
    return true if host == "localhost"
    return false unless host.include?(".")
    return false if host.start_with?(".") || host.end_with?(".")
    tld = host.split(".").last.to_s
    tld.size >= 2 && tld.each_char.all? { |c| letter?(c) || digit?(c) }
  end

  def self.encode(s)
    out = ""
    s.each_byte do |b|
      c = b.chr
      if SAFE.include?(c) then out << c
      elsif c == " " then out << "+"
      else out << format("%%%02X", b)
      end
    end
    out
  end

  def self.letter?(c) ; c && (("a".."z").include?(c.downcase)) ; end
  def self.digit?(c)  ; c && (("0".."9").include?(c)) ; end
end
