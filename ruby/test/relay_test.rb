relay = Relay.new
token = relay.token

test "rewrite_head strips Origin/Host and token, adds Host" do
  head = "GET /#{token}/devtools/page/42 HTTP/1.1\r\nHost: 127.0.0.1:9\r\nOrigin: https://chrome-devtools-frontend.appspot.com\r\nUpgrade: websocket\r\n\r\n"
  out = relay.rewrite_head(head)
  assert_equal "GET /devtools/page/42 HTTP/1.1\r\nUpgrade: websocket\r\nHost: 127.0.0.1:#{relay.port}\r\n\r\n", out
end

test "rewrite_head rejects a missing token" do
  assert_equal nil, relay.rewrite_head("GET /devtools/page/42 HTTP/1.1\r\n\r\n")
  assert_equal nil, relay.rewrite_head("GET /wrongtoken/devtools/page/42 HTTP/1.1\r\n\r\n")
end

test "relay accepts a client and relays only after a valid head" do
  cli = TCPSocket.new("127.0.0.1", relay.port)
  r = IO.select(Loop.readers, nil, nil, 1)
  Loop.dispatch(r[0], [])
  assert_equal 1, relay.connections
  cli.syswrite("GET /nope HTTP/1.1\r\n\r\n")
  r = IO.select(Loop.readers, nil, nil, 1)
  Loop.dispatch(r[0], [])
  assert_equal 0, relay.connections      # rejected and closed
  cli.close
end
relay.close

# Frame-boundary tracking: an injected server frame must never land inside a page frame, however
# the upstream bytes are chunked.
test "relay injects frontend frames only at WebSocket frame boundaries" do
  r = Relay.new
  conn = Relay::Conn.new(r, nil)
  f1 = Relay.server_text_frame("a" * 10)           # 2-byte header
  f2 = Relay.server_text_frame("b" * 300)          # 4-byte header (126)
  stream = f1 + f2
  # deliver in awkward chunks: split inside f1's payload and inside f2's header
  chunks = [stream[0, 5], stream[5, 8], stream[13, 50], stream[63..-1]]
  out = []
  conn.instance_variable_set(:@to_client, out)
  conn.send(:track_frames, chunks[0]); out << chunks[0]
  conn.inject_to_client("X")                        # mid-frame: must wait
  assert_equal 1, out.size
  conn.send(:track_frames, chunks[1]); out << chunks[1]; conn.send(:flush_injections)
  # after chunk 1 we are at f1's end (5+8 = 13 bytes = whole f1 incl. 2-byte header + 10 payload... plus 1 byte of f2 header)
  # so still inside f2's header -> still waiting
  assert_equal 2, out.size
  conn.send(:track_frames, chunks[2]); out << chunks[2]; conn.send(:flush_injections)
  assert_equal 3, out.size                          # inside f2's payload -> waiting
  conn.send(:track_frames, chunks[3]); out << chunks[3]; conn.send(:flush_injections)
  assert_equal 5, out.size                          # boundary reached -> injected frame appended
  assert_equal Relay.server_text_frame("X"), out.last
  joined = out.join
  assert_equal stream + Relay.server_text_frame("X"), joined
  r.close
end

test "Cdp.client_frame masks and sizes correctly" do
  f = Cdp.client_frame("hi")
  assert_equal 0x81, f.getbyte(0)
  assert_equal 0x80 | 2, f.getbyte(1)
  assert_equal 2 + 4 + 2, f.bytesize
  big = Cdp.client_frame("x" * 300)
  assert_equal 0x80 | 126, big.getbyte(1)
  assert_equal 300, big.byteslice(2, 2).unpack1("n")
end
