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

