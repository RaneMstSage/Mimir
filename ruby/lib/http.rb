# Minimal blocking HTTP/1.1 GET against the WebView DevTools server on its abstract unix socket.
# Used only for the tiny /json endpoints. A receive timeout keeps a stuck server from freezing
# the event loop for more than `timeout` seconds.
module Http
  class Error < StandardError; end

  def self.get_devtools(path, timeout: 2)
    fd = Inspect.connect_abstract("webview_devtools_remote_#{Inspect.pid}")
    sock = BasicSocket.for_fd(fd)
    tv = [timeout, 0].pack("q!q!")            # struct timeval { tv_sec, tv_usec } on LP64
    sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, tv)
    sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDTIMEO, tv)
    # Chromium rejects a Host that is not localhost/an IP (DNS-rebinding guard).
    sock.syswrite("GET #{path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
    raw = ""
    begin
      loop { raw << sock.sysread(65536) }
    rescue EOFError
    rescue Errno::EAGAIN, Errno::EWOULDBLOCK
      raise Error, "timeout reading #{path}" if raw.empty?
    end
    sock.close rescue nil
    parse(raw, path)
  end

  def self.parse(raw, path)
    sep = raw.index("\r\n\r\n")
    raise Error, "malformed response for #{path}" unless sep
    head = raw[0, sep]
    body = raw[(sep + 4)..-1] || ""
    lines = head.split("\r\n")
    status = lines[0].to_s.split(" ")[1].to_i
    raise Error, "HTTP #{status} for #{path}" unless status >= 200 && status < 300
    len = nil
    lines[1..-1].each do |l|
      h = Util.header(l)
      len = h[1].to_i if h && h[0] == "content-length"
    end
    len ? body[0, len] : body
  end
end
