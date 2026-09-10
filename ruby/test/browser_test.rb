test "UrlNorm: schemes, hosts, searches" do
  assert_equal "https://example.com", UrlNorm.normalize("example.com")
  assert_equal "https://example.com/a b", UrlNorm.normalize("https://example.com/a b")
  assert_equal "about:blank", UrlNorm.normalize("about:blank")
  assert_equal "https://localhost:8765/x", UrlNorm.normalize("localhost:8765/x")
  assert_equal "https://www.google.com/search?q=ruby+on+android%3F", UrlNorm.normalize("ruby on android?")
  assert_equal "https://www.google.com/search?q=hello", UrlNorm.normalize("hello")
  assert_equal nil, UrlNorm.normalize("   ")
end

Inspect.emitted.clear
settings = Settings.new(nil)
browser = Browser.new(settings)
module App ; def self.attach_devtools(url) ; Inspect.emit({ "cmd" => "attach", "url" => url }.to_json) ; end ; end

test "Browser: new tab emits create+show+state, ids increment" do
  t1 = browser.new_tab(nil)
  assert_equal 1, t1.id
  assert_equal settings["home"], t1.url
  cmds = Inspect.emitted.map { |c| c["cmd"] }
  assert cmds.include?("tab.create") && cmds.include?("tab.show") && cmds.include?("ui.state"), cmds.inspect
  t2 = browser.new_tab("https://b.test/")
  assert_equal 2, t2.id
  assert_equal t2, browser.current
end

test "Browser: closing current selects neighbour; closing last resets to home" do
  browser.close_tab(2)
  assert_equal 1, browser.current.id
  Inspect.emitted.clear
  browser.close_tab(1)
  assert_equal 1, browser.tabs.size
  assert_equal settings["home"], browser.tabs[0].url
  assert Inspect.emitted.any? { |c| c["cmd"] == "tab.load" }
end

test "Browser: page events update state; title falls back to url" do
  browser.page_started(1, "https://x.test/p")
  browser.page_title(1, "")
  assert_equal "https://x.test/p", browser.current.title
  browser.page_progress(1, 50)
  st = Inspect.emitted.last["state"]
  assert_equal 50, st["progress"]
  assert_equal true, st["loading"]
end

test "Browser: navigate normalizes and emits tab.load" do
  Inspect.emitted.clear
  browser.navigate(1, "ruby lang")
  load = Inspect.emitted.find { |c| c["cmd"] == "tab.load" }
  assert_equal "https://www.google.com/search?q=ruby+lang", load["url"]
end

test "Browser: devtools toggle docks and attaches current url; ua toggle reloads" do
  Inspect.emitted.clear
  browser.toggle_devtools
  cmds = Inspect.emitted.map { |c| c["cmd"] }
  assert_equal ["devtools.dock", "attach", "ui.state"], cmds
  browser.toggle_devtools
  assert_equal "devtools.close", Inspect.emitted[-2]["cmd"]
  Inspect.emitted.clear
  browser.toggle_ua
  assert_equal false, browser.desktop?
  assert Inspect.emitted.any? { |c| c["cmd"] == "ua.set" && c["desktop"] == false }
  assert Inspect.emitted.any? { |c| c["cmd"] == "tab.reload" }
end

test "Bookmarks: toggle, history visit dedupes and caps" do
  bm = Bookmarks.new(nil)
  assert_equal true, bm.toggle("https://a.test/", "A")
  assert_equal false, bm.toggle("https://a.test/", "A")
  bm.visit("https://h.test/1", "one"); bm.visit("https://h.test/2", "two"); bm.visit("https://h.test/1", "one again")
  assert_equal ["https://h.test/1", "https://h.test/2"], bm.history.map { |h| h["url"] }
  bm.visit("about:blank", "x")
  assert_equal 2, bm.history.size
end

test "Browser: state carries bookmarks, history and bar flag; find_target skips the chrome UI" do
  bm = Bookmarks.new(nil)
  br = Browser.new(Settings.new(nil), bm)
  br.new_tab("https://s.test/")
  br.page_title(1, "S")
  br.page_finished(1, "https://s.test/", true, false)
  st = Inspect.emitted.last["state"]
  assert_equal true, st["can_back"]
  assert_equal "https://s.test/", st["history"][0]["url"]
  assert_equal true, st["bookmarks_bar"]
  list = [{ "type" => "page", "id" => "c", "url" => "file:///android_asset/ui/ui.html", "description" => '{"visible":true}' },
          { "type" => "page", "id" => "p", "url" => "https://s.test/", "description" => '{"visible":true}' }]
  assert_equal "p", DevTools.find_target(list, "https://zzz/")["id"]
end

test "Settings: set_setting persists, pushes prefs for webview keys, search engine used by navigate" do
  bm = Bookmarks.new(nil)
  br = Browser.new(Settings.new(nil), bm)
  br.new_tab("https://s.test/")
  Inspect.emitted.clear
  br.set_setting("javascript", false)
  prefs = Inspect.emitted.find { |c| c["cmd"] == "prefs.apply" }
  assert_equal false, prefs["javascript"]
  br.set_setting("search", "duckduckgo")
  Inspect.emitted.clear
  br.navigate(1, "ruby")
  assert_equal "https://duckduckgo.com/?q=ruby", Inspect.emitted.find { |c| c["cmd"] == "tab.load" }["url"]
  br.set_setting("nonsense", 1)
  assert_equal nil, br.settings["nonsense"]
  st = Inspect.emitted.last["state"]
  assert_equal "duckduckgo", st["settings"]["search"]
end

test "History/bookmarks management" do
  bm = Bookmarks.new(nil)
  br = Browser.new(Settings.new(nil), bm)
  bm.visit("https://h1.test/", "H1"); bm.visit("https://h2.test/", "H2")
  br.history_remove("https://h1.test/")
  assert_equal ["https://h2.test/"], bm.history.map { |h| h["url"] }
  bm.toggle("https://b.test/", "B")
  br.bookmark_rename("https://b.test/", "Better")
  assert_equal "Better", bm.list[0]["title"]
  br.bookmark_remove("https://b.test/")
  assert_equal [], bm.list
  Inspect.emitted.clear
  br.clear_data(["history", "cache"])
  assert_equal [], bm.history
  assert Inspect.emitted.any? { |c| c["cmd"] == "data.clear" && c["cache"] == true && c["cookies"] == false }
end
