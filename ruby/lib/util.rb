# Small string helpers; this mruby build has no Regexp.
module Util
  # Replace the first occurrence of `from` with `to`.
  def self.replace_first(str, from, to)
    i = str.index(from)
    return str unless i
    str[0, i] + to + str[(i + from.size)..-1]
  end

  # Split "Header: value" into [name_downcased, value] or nil.
  def self.header(line)
    i = line.index(":")
    return nil unless i
    [line[0, i].strip.downcase, line[(i + 1)..-1].strip]
  end

  def self.random_token(len = 24)
    chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    s = ""
    len.times { s << chars[rand(chars.size)] }
    s
  end
end
