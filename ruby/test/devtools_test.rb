list = [
  { "type" => "page", "id" => "1", "url" => "https://example.com/", "description" => '{"visible":true,"attached":false}', "devtoolsFrontendUrl" => "https://chrome-devtools-frontend.appspot.com/serve_rev/@abc/inspector.html?ws=127.0.0.1:5555/devtools/page/1" },
  { "type" => "page", "id" => "2", "url" => "https://chrome-devtools-frontend.appspot.com/serve_rev/@abc/inspector.html?ws=x", "description" => '{"visible":true}' },
  { "type" => "page", "id" => "3", "url" => "https://other.test/", "description" => '{"visible":false,"attached":true}' },
  { "type" => "service_worker", "id" => "4", "url" => "https://example.com/sw.js" }
]

test "find_target prefers exact url and skips the frontend itself" do
  assert_equal "1", DevTools.find_target(list, "https://example.com/")["id"]
  assert_equal "1", DevTools.find_target(list, "https://nomatch/")["id"]   # visible beats attached-invisible
end

test "frontend_url rewrites ws host and inserts token" do
  fe = DevTools.frontend_url(list[0], 6000, "TOK")
  assert_equal "https://chrome-devtools-frontend.appspot.com/serve_rev/@abc/inspector.html?ws=127.0.0.1:6000/TOK/devtools/page/1", fe
end

test "frontend_url builds a CDN url from WebKit-Version when relative" do
  t = { "id" => "9", "devtoolsFrontendUrl" => "/devtools/inspector.html?ws=127.0.0.1/devtools/page/9" }
  fe = DevTools.frontend_url(t, 6000, "TOK", "537.36 (@deadbeef)")
  assert_equal "https://chrome-devtools-frontend.appspot.com/serve_rev/@deadbeef/inspector.html?ws=127.0.0.1:6000/TOK/devtools/page/9", fe
end

test "Http.parse extracts body by content-length" do
  assert_equal "[1]", Http.parse("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n[1]junk", "/json")
end

test "Util.header / replace_first" do
  assert_equal ["origin", "https://x"], Util.header("Origin: https://x")
  assert_equal "a-c-c-c", Util.replace_first("a-b-c", "b", "c-c")
end
