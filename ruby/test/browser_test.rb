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

test "Bookmarks tree: toggle adds to bar, folders, move, rename, remove; history dedupes" do
  bm = Bookmarks.new(nil)
  n = bm.toggle("https://a.test/", "A")
  assert_equal "url", n["type"]
  assert_equal ["https://a.test/"], bm.bar["children"].map { |c| c["url"] }
  f = bm.new_folder("bar", "Work")
  assert bm.move(n["id"], f["id"])
  assert_equal [], bm.bar["children"].select { |c| c["type"] == "url" }
  assert_equal "https://a.test/", f["children"][0]["url"]
  assert_equal false, bm.move(f["id"], f["id"])            # folder into itself
  sub = bm.new_folder(f["id"], "Sub")
  assert_equal false, bm.move(f["id"], sub["id"])          # folder into its descendant
  assert bm.rename(n["id"], "Renamed")
  assert_equal "Renamed", bm.find(n["id"])["title"]
  assert_equal true, bm.bookmarked?("https://a.test/")
  assert_equal nil, bm.toggle("https://a.test/", "A")     # second toggle removes
  assert_equal false, bm.bookmarked?("https://a.test/")
  assert_equal false, bm.remove("bar")
  assert_equal 4, bm.folders.size                           # bar, other, Work, Sub
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
  n = bm.toggle("https://b.test/", "B")
  br.bookmark_update(n["id"], "Better", "other")
  assert_equal "Better", bm.other["children"][0]["title"]
  br.bookmark_remove(n["id"])
  assert_equal [], bm.urls
  Inspect.emitted.clear
  br.clear_data(["history", "cache"])
  assert_equal [], bm.history
  assert Inspect.emitted.any? { |c| c["cmd"] == "data.clear" && c["cache"] == true && c["cookies"] == false }
end

test "Scripts: glob matching" do
  assert Scripts.glob?("https://*.theodinproject.com/*", "https://www.theodinproject.com/lessons/x")
  assert_equal false, Scripts.glob?("https://*.theodinproject.com/*", "https://theodinproject.com/")
  assert Scripts.glob?("*://example.com/*", "http://example.com/a")
  assert Scripts.glob?("*", "https://anything/")
  assert Scripts.glob?("https://a.test/exact", "https://a.test/exact")
  assert_equal false, Scripts.glob?("https://a.test/exact", "https://a.test/exact/no")
  assert Scripts.glob?("*github.com*", "https://github.com/x")
end

test "Scripts: selection, payload, import of userscript headers, blocks" do
  sc = Scripts.new(nil)
  js = sc.add("name" => "Hi", "match" => "https://a.test/*", "code" => "console.log(1)", "run_at" => "end")
  css = sc.add("name" => "Dark", "type" => "css", "match" => ["*"], "code" => "body{background:#000}", "run_at" => "start")
  assert_equal [css["id"]], sc.for_url("https://a.test/p", "start").map { |x| x["id"] }
  assert_equal [js["id"]], sc.for_url("https://a.test/p", "end").map { |x| x["id"] }
  assert_equal nil, sc.payload("https://b.test/", "end")
  assert sc.payload("https://a.test/p", "end").include?("console.log(1)")
  assert sc.payload("https://a.test/p", "start").include?("createElement('style')")
  sc.toggle(js["id"])
  assert_equal [], sc.for_url("https://a.test/p", "end")
  us = "// ==UserScript==\n// @name  Odin Helper\n// @match https://www.theodinproject.com/*\n// @run-at document-start\n// ==/UserScript==\nconsole.log('hi')"
  imp = sc.import("https://x.test/odin.user.js", us)
  assert_equal "Odin Helper", imp["name"]
  assert_equal ["https://www.theodinproject.com/*"], imp["match"]
  assert_equal "start", imp["run_at"]
  sc.set_blocks(["*doubleclick.net*", "", "*doubleclick.net*"])
  assert_equal ["*doubleclick.net*"], sc.blocks
  sc.remove(css["id"])
  assert_equal 2, sc.list.size
end

test "Browser: page events inject matching scripts" do
  sc = Scripts.new(nil)
  sc.add("name" => "x", "match" => "https://s.test/*", "code" => "1+1", "run_at" => "end")
  br = Browser.new(Settings.new(nil), Bookmarks.new(nil), sc)
  br.new_tab("https://s.test/")
  Inspect.emitted.clear
  br.page_finished(1, "https://s.test/", false, false)
  inj = Inspect.emitted.find { |c| c["cmd"] == "tab.inject" }
  assert inj && inj["js"].include?("1+1"), "expected tab.inject"
end

test "every event the chrome UI sends has a Ruby handler" do
  ui = File.read(File.expand_path("../../ui/ui.rb", __FILE__))
  names = []
  # send("name" ...) occurrences
  pos = 0
  while (i = ui.index('send("', pos))
    j = ui.index('"', i + 6)
    names << ui[(i + 6)...j] if j
    pos = i + 6
  end
  # `when "a", "b", ... then send(act)` forwards the literal act names
  ui.split("\n").each do |line|
    next unless line.include?("then send(act)")
    parts = line.split('"')
    parts.each_with_index { |p, k| names << p if k.odd? }
  end
  handled_locally_by_java = %w[chrome.height chrome.ready ui.error ui.debug]
  missing = (names.uniq - handled_locally_by_java).reject { |n| App.handlers.key?(n) }
  assert missing.empty?, "UI sends events with no Ruby handler: #{missing.inspect}"
end

test "context menu items depend on the hit target and actions route correctly" do
  Inspect.emitted.clear
  App.handle({ "ev" => "context.menu", "tab" => 1, "type" => "link", "link" => "https://l.test/", "src" => "", "x" => 10, "y" => 20, "css_x" => 5, "css_y" => 6, "can_back" => true, "can_forward" => false }.to_json)
  ctx = Inspect.emitted.find { |c| c["cmd"] == "ui.context" }
  ids = ctx["items"].map { |i| i["id"] }.compact
  assert ids.include?("open_tab") && ids.include?("copy_link") && ids.include?("inspect") && !ids.include?("back"), ids.inspect
  Inspect.emitted.clear
  App.handle({ "ev" => "context.menu", "tab" => 1, "type" => "page", "link" => "", "src" => "", "selection" => "hello world", "x" => 1, "y" => 2, "css_x" => 1, "css_y" => 2, "can_back" => true, "can_forward" => false }.to_json)
  sel_ids = Inspect.emitted.find { |c| c["cmd"] == "ui.context" }["items"].map { |i| i["id"] }.compact
  assert sel_ids.include?("copy_sel") && sel_ids.include?("search_sel") && !sel_ids.include?("back"), sel_ids.inspect
  Inspect.emitted.clear
  App.handle({ "ev" => "context.menu", "tab" => 1, "type" => "page", "link" => "", "src" => "", "selection" => "", "x" => 1, "y" => 2, "css_x" => 1, "css_y" => 2, "can_back" => true, "can_forward" => false }.to_json)
  page_ids = Inspect.emitted.find { |c| c["cmd"] == "ui.context" }["items"].map { |i| i["id"] }.compact
  assert page_ids.include?("back") && page_ids.include?("reload") && page_ids.include?("inspect") && !page_ids.include?("copy_sel"), page_ids.inspect
  Inspect.emitted.clear
  App.handle({ "ev" => "context.action", "id" => "copy_link", "target" => ctx["target"] }.to_json)
  clip = Inspect.emitted.find { |c| c["cmd"] == "clipboard.set" }
  assert_equal "https://l.test/", clip["text"]
end
