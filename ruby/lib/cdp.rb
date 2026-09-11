# Minimal Chrome DevTools Protocol client over the WebView's abstract socket, for short synchronous
# calls from the Ruby thread (e.g. "which node is at x,y"). Not for streaming; keep calls brief.
class Cdp
  class Error < StandardError; end

  def self.call(target_id, method, params = {}, timeout: 2)
    c = new(target_id, timeout)
    begin
      c.send_cmd(1, method, params)
      c.wait_result(1)
    ensure
      c.close
    end
  end

  def initialize(target_id, timeout)
    fd = Inspect.connect_abstract("webview_devtools_remote_#{Inspect.pid}")
    @sock = BasicSocket.for_fd(fd)
    tv = [timeout, 0].pack("q!q!")
    @sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, tv)
    @sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDTIMEO, tv)
    @sock.syswrite("GET /devtools/page/#{target_id} HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                   "Sec-WebSocket-Key: bWltaXItY2RwLWNsaWVudC1rZXk=\r\nSec-WebSocket-Version: 13\r\n\r\n")
    head = ""
    head << @sock.sysread(1) until head.end_with?("\r\n\r\n")
    raise Error, "handshake failed: #{head.lines.first}" unless head.start_with?("HTTP/1.1 101")
    @buf = ""
  end

  def send_cmd(id, method, params)
    payload = { "id" => id, "method" => method, "params" => params }.to_json
    @sock.syswrite(Cdp.client_frame(payload))
  end

  # Masked client text frame.
  def self.client_frame(text)
    mask = [0x12, 0x34, 0x56, 0x78]
    bytes = text.bytes
    masked = bytes.each_with_index.map { |b, i| b ^ mask[i % 4] }
    len = bytes.size
    hdr = [0x81]
    if len < 126 then hdr << (0x80 | len)
    elsif len < 65_536 then hdr << (0x80 | 126) << (len >> 8) << (len & 0xff)
    else hdr << (0x80 | 127) ; 7.downto(0) { |i| hdr << ((len >> (8 * i)) & 0xff) }
    end
    (hdr + mask + masked).pack("C*")
  end

  def read_exact(n)
    @buf << @sock.sysread(n - @buf.size) while @buf.size < n
    out = @buf[0, n] ; @buf = @buf[n..-1].to_s ; out
  end

  # Reads one unmasked server frame's text payload (reassembles continuation frames).
  def read_message
    text = ""
    loop do
      h = read_exact(2)
      b0 = h.getbyte(0) ; b1 = h.getbyte(1)
      fin = (b0 & 0x80) != 0 ; op = b0 & 0x0f
      len = b1 & 0x7f
      len = read_exact(2).unpack1("n") if len == 126
      len = read_exact(8).unpack1("Q>") if len == 127
      payload = len > 0 ? read_exact(len) : ""
      raise Error, "connection closed by target" if op == 8
      text << payload unless op == 9 || op == 10     # ignore ping/pong
      return text if fin && op != 9 && op != 10
    end
  end

  def wait_result(id)
    10.times do
      msg = JSON.parse(read_message)
      next unless msg["id"] == id
      raise Error, (msg["error"] || {})["message"].to_s if msg["error"]
      return msg["result"] || {}
    end
    raise Error, "no response for #{id}"
  end

  def close ; @sock.close rescue nil ; end
end
