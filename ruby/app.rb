# Mímir — Ruby side entry point (runs inside the APK on the dedicated ruby thread).
#
# App.run(boot_json) never returns until a "quit" event arrives. It owns the single event loop:
# IO.select over the native wake pipe (Java -> Ruby events) plus the DevTools relay sockets.
module App
  VERSION = "0.8.0"

  @handlers = {}
  @running = false
  @relay = nil

  def self.on(event, &blk) ; @handlers[event] = blk ; end
  def self.handlers ; @handlers ; end
  def self.relay   ; @relay ; end
  def self.boot    ; @boot ; end
  def self.browser ; @browser ; end
  def self.scripts ; @scripts ; end
  def self.attached_target ; @attached_target ; end

  def self.run(boot_json)
    @boot = JSON.parse(boot_json.to_s) rescue {}
    @running = true
    wake = IO.for_fd(Inspect.wake_fd)
    Host.log(:info, "Ruby #{Inspect.version} up in pid #{Inspect.pid}; app #{VERSION}")
    Host.emit("ready", "ruby" => Inspect.version, "app" => VERSION)
    @settings = Settings.new(@boot["files_dir"])
    @bookmarks = Bookmarks.new(@boot["files_dir"])
    @scripts = Scripts.new(@boot["files_dir"])
    @browser = Browser.new(@settings, @bookmarks, @scripts)
    start_relay

    while @running
      readers = [wake] + Loop.readers
      writers = Loop.writers
      ready = IO.select(readers, writers, nil, Loop.next_timeout(1.0))
      Loop.run_timers
      next unless ready
      if ready[0].include?(wake)
        begin
          wake.sysread(4096)
        rescue Errno::EAGAIN
        end
        drain_events
      end
      Loop.dispatch(ready[0], ready[1])
    end
    Host.log(:info, "App.run: quitting")
  end

  def self.start_relay
    @relay = Relay.new
    Host.log(:info, "relay listening on 127.0.0.1:#{@relay.port}")
    Host.emit("bridge.ready", "port" => @relay.port)
  rescue => e
    Host.log(:error, "relay failed: #{e.class}: #{e.message}")
    Host.emit("bridge.fallback", "reason" => "#{e.class}: #{e.message}")
  end

  def self.drain_events
    while (raw = Inspect.next_event)
      handle(raw)
    end
  end

  def self.handle(raw)
    ev = JSON.parse(raw)
    name = ev["ev"].to_s
    if (h = @handlers[name])
      h.call(ev)
    else
      Host.log(:warn, "unhandled event #{name}")
    end
  rescue => e
    Host.log(:error, "event #{raw[0, 120]} failed: #{e.class}: #{e.message}")
    (e.backtrace || []).each { |l| Host.log(:error, "  #{l}") }
  end

  def self.stop! ; @running = false ; end
end

App.on("quit") { |_| App.stop! }

App.on("console.eval") do |ev|
  result = begin
    eval(ev["src"].to_s).inspect
  rescue => e
    "#{e.class}: #{e.message}"
  end
  Host.emit("console.result", "text" => result)
end

App.on("ping") { |ev| Host.emit("pong", "t" => ev["t"]) }

# Find the WebView target for `url` and tell Java to load the DevTools frontend for it.
module App
  def self.attach_devtools(url, exclude = DevTools::EXCLUDE)
    port, token = @relay ? [@relay.port, @relay.token] : [@fallback_port, nil]
    unless port
      Host.emit("devtools.error", "text" => "relay not running")
      return
    end
    target = nil
    list = []
    5.times do
      list = DevTools.targets
      target = DevTools.find_target(list, url, exclude)
      break if target
      sleep 0.3
    end
    unless target
      Host.emit("devtools.error", "text" => "no target for #{url}; #{list.size} targets: " + list.map { |t| t["url"].to_s[0, 40] }.join(" | "))
      return
    end
    wk = target["devtoolsFrontendUrl"].to_s.start_with?("http") ? nil : DevTools.version["WebKit-Version"]
    fe = DevTools.frontend_url(target, port, token, wk)
    Host.log(:info, "attach #{target["id"]} (#{target["url"].to_s[0, 60]})")
    @attached_target = target["id"].to_s
    Host.emit("devtools.open", "url" => fe, "target" => target["id"])
  rescue => e
    Host.emit("devtools.error", "text" => "#{e.class}: #{e.message}")
  end
end

# Java started its own relay because ours failed; use its port (no token).
App.on("bridge.java_ready") do |ev|
  App.instance_variable_set(:@fallback_port, ev["port"].to_i)
  Host.log(:warn, "using Java fallback relay on port #{ev["port"]}")
end

App.on("devtools.list") do |_|
  DevTools.targets.each { |t| Host.log(:info, "target #{t["id"]} #{t["type"]} #{t["url"]} #{t["description"]}") }
  Host.log(:info, "relay connections: #{App.relay ? App.relay.connections : 'n/a'}")
end

# ---- UI events (Java -> Ruby). Java has no browser logic; everything routes through Browser. ----
b = ->() { App.browser }

# Activity (re)attached. Java tells us which tab ids it still has; recreate missing ones.
App.on("ui.ready") do |ev|
  have = (ev["tabs"] || []).map(&:to_i)
  if b.call.tabs.empty?
    b.call.new_tab(ev["url"])
  else
    b.call.tabs.each { |t| Host.emit("tab.create", "tab" => t.id, "url" => t.url, "select" => false) unless have.include?(t.id) }
    b.call.select_tab(b.call.current.id) if b.call.current
  end
  Host.emit("ua.set", "desktop" => b.call.desktop?)
  b.call.apply_prefs
  b.call.push_blocks
  b.call.push_state
end

# ---- user scripts & styles, request blocking ----
App.on("script.add")    { |ev| App.scripts.add(ev["attrs"] || {}) ; b.call.push_state }
App.on("script.update") { |ev| App.scripts.update(ev["id"], ev["attrs"] || {}) ; b.call.push_state }
App.on("script.remove") { |ev| App.scripts.remove(ev["id"]) ; b.call.push_state }
App.on("script.toggle") { |ev| App.scripts.toggle(ev["id"]) ; b.call.push_state }
App.on("script.import") { |ev| Host.emit("fetch", "url" => ev["url"].to_s, "purpose" => "script") }   # Java downloads, replies with fetched
App.on("fetched") do |ev|
  if ev["purpose"] == "script"
    if ev["error"].to_s.empty?
      s = App.scripts.import(ev["url"].to_s, ev["body"].to_s)
      Host.toast("Imported #{s["name"]}")
    else
      Host.toast("Import failed: #{ev["error"]}")
    end
    b.call.push_state
  end
end
App.on("blocks.set") { |ev| App.scripts.set_blocks(ev["patterns"]) ; b.call.push_blocks ; b.call.push_state }
App.on("script.run") do |ev|   # run a script once on the current tab (test button)
  s = App.scripts.find(ev["id"]) or next
  js = App.scripts.payload_for([s])
  Host.emit("tab.inject", "tab" => b.call.current.id, "js" => js) if js && b.call.current
end

App.on("navigate")      { |ev| b.call.navigate(ev["tab"], ev["text"]) }
App.on("tab.new")       { |ev| b.call.new_tab(ev["url"]) }
App.on("tab.select")    { |ev| b.call.select_tab(ev["tab"]) }
App.on("tab.close")     { |ev| b.call.close_tab(ev["tab"]) }
App.on("nav.back")      { |ev| b.call.nav(ev["tab"], "back") }
App.on("nav.forward")   { |ev| b.call.nav(ev["tab"], "forward") }
App.on("nav.reload")    { |ev| b.call.nav(ev["tab"], "reload") }
App.on("page.started")  { |ev| b.call.page_started(ev["tab"], ev["url"]) }
App.on("page.finished") { |ev| b.call.page_finished(ev["tab"], ev["url"], ev["can_back"], ev["can_forward"]) }
App.on("page.favicon")  { |ev| b.call.page_favicon(ev["tab"], ev["data"]) }
App.on("nav.stop")      { |ev| b.call.nav(ev["tab"], "stop") }
App.on("bookmark.toggle") { |_| b.call.toggle_bookmark }
App.on("bookmarks.bar")   { |_| b.call.toggle_bookmarks_bar }
App.on("chrome.ready")  { |_| b.call.push_state }
App.on("dev.toggle")    { |_| Host.emit("dev.toggle") }
App.on("settings.set")     { |ev| b.call.set_setting(ev["key"].to_s, ev["value"]) }
App.on("data.clear")       { |ev| b.call.clear_data(ev["what"]) }
App.on("history.remove")   { |ev| b.call.history_remove(ev["url"].to_s) }
App.on("history.clear")    { |_|  b.call.clear_data(["history"]) }
App.on("bookmark.remove")  { |ev| b.call.bookmark_remove(ev["id"].to_s) }
App.on("bookmark.update")  { |ev| b.call.bookmark_update(ev["id"].to_s, ev["title"], ev["parent"]) }
App.on("folder.new")       { |ev| b.call.folder_new(ev["parent"].to_s, ev["title"]) }
App.on("page.title")    { |ev| b.call.page_title(ev["tab"], ev["title"]) }
App.on("page.progress") { |ev| b.call.page_progress(ev["tab"], ev["p"]) }
App.on("devtools.toggle")   { |_| b.call.toggle_devtools }
App.on("devtools.reattach") { |_| b.call.attach_devtools }
# Dogfooding: attach DevTools to our own Opal chrome (file:///android_asset/ui/ui.html).
App.on("devtools.chrome") do |_|
  br = b.call
  br.devtools_open = true
  Host.emit("devtools.dock", "side" => br.settings["dock_side"], "fraction" => br.settings["dock_fraction"])
  App.attach_devtools("file:///android_asset/ui/ui.html", [DevTools::CDN])
  br.push_state
end
App.on("dock.toggle")   { |_| b.call.toggle_dock }
App.on("dock.fraction") { |ev| b.call.set_dock_fraction(ev["fraction"]) }
App.on("ua.toggle")     { |_| b.call.toggle_ua }
App.on("intent.url")    { |ev| b.call.new_tab(ev["url"]) }

# ---- pages, donate, support / tip jar (Java answers billing.* events) ----
App.on("settings.open") { |_| Host.emit("status", "text" => "Settings: ⋮ menu → Settings") }
App.on("about")         { |_| Host.toast("Mímir #{App.boot["app_version"] || App::VERSION} — mruby #{Inspect.version}") }
App.on("donate")        { |_| u = App.boot["donate_url"].to_s ; b.call.new_tab(u) unless u.empty? }
App.on("support.open")  { |_| Host.emit("billing.query") }
App.on("billing.buy")   { |ev| Host.emit("billing.buy", "product" => ev["product"].to_s) }
App.on("billing.ready") do |ev|
  br = b.call
  br.billing["status"] = "ready"
  br.billing["products"] = (ev["products"] || [])
  br.billing["reason"] = ""
  br.push_state
end
App.on("billing.unavailable") do |ev|
  br = b.call
  br.billing["status"] = "unavailable"
  br.billing["reason"] = ev["reason"].to_s
  br.push_state
end
App.on("billing.purchased") do |ev|
  br = b.call
  br.billing["thanks"] = true
  Host.toast("Thank you for supporting Mímir!")
  br.push_state
end
App.on("billing.cancelled") { |_| }
App.on("billing.error")     { |ev| Host.toast("Play Billing: #{ev["text"]}") }

# ---- context menu (right-click / long-press on a page) ----
# Java sends what is under the pointer; Ruby decides the items; the chrome renders them.
App.on("context.menu") do |ev|
  items = []
  type = ev["type"].to_s
  link = ev["link"].to_s
  src  = ev["src"].to_s
  sel  = ev["selection"].to_s.strip
  if !sel.empty?
    short = sel.size > 24 ? sel[0, 24] + "…" : sel
    items << ["copy_sel", "Copy"] << ["search_sel", "Search the web for “#{short}”"] << :hr
  end
  if type.start_with?("link")
    items << ["open_tab", "Open link in new tab"] << ["copy_link", "Copy link address"] << :hr
  end
  if type == "image" || type == "link_image"
    items << ["open_image", "Open image in new tab"] << ["copy_image", "Copy image address"] << :hr
  end
  if type == "input"
    items << ["paste", "Paste"] << ["select_all", "Select all"] << :hr
  end
  if sel.empty? && !type.start_with?("link") && type != "image" && type != "input"
    items << ["back", "Back"] if ev["can_back"]
    items << ["forward", "Forward"] if ev["can_forward"]
    items << ["reload", "Reload"] << ["select_all", "Select all"] << :hr
  end
  items << ["inspect", "Inspect element"]
  Host.emit("ui.context", "x" => ev["x"], "y" => ev["y"], "win_w" => ev["win_w"], "win_h" => ev["win_h"],
            "items" => items.map { |i| i == :hr ? { "hr" => true } : { "id" => i[0], "label" => i[1] } },
            "target" => { "tab" => ev["tab"], "type" => type, "link" => link, "src" => src, "selection" => sel, "css_x" => ev["css_x"], "css_y" => ev["css_y"] })
end

App.on("context.action") do |ev|
  t = ev["target"] || {}
  tab = t["tab"]
  br = b.call
  case ev["id"].to_s
  when "open_tab"       then br.new_tab(t["link"], select: false)
  when "copy_link"      then Host.emit("clipboard.set", "label" => "Link", "text" => t["link"])
  when "open_image"     then br.new_tab(t["src"], select: false)
  when "copy_image"     then Host.emit("clipboard.set", "label" => "Image", "text" => t["src"])
  when "copy_sel"       then Host.emit("clipboard.set", "label" => "Text", "text" => t["selection"].to_s)
  when "search_sel"     then br.new_tab(UrlNorm.normalize(t["selection"].to_s, br.settings["search"]))
  when "select_all"     then Host.emit("tab.inject", "tab" => tab, "js" => "document.execCommand('selectAll')")
  when "paste"          then Host.emit("tab.paste", "tab" => tab)
  when "back"           then br.nav(tab, "back")
  when "forward"        then br.nav(tab, "forward")
  when "reload"         then br.nav(tab, "reload")
  when "inspect"        then App.inspect_at(tab, t["css_x"], t["css_y"])
  end
end

App.on("page.selection") do |ev|
  text = ev["text"].to_s
  case ev["purpose"]
  when "copy"   then Host.emit("clipboard.set", "label" => "Text", "text" => text) unless text.empty?
  when "search" then b.call.new_tab(UrlNorm.normalize(text, b.call.settings["search"])) unless text.strip.empty?
  end
end

module App
  # "Inspect element" — Phase A: open DevTools on the tab. Phase B (Inspector module) reveals the node.
  def self.inspect_at(tab, css_x, css_y)
    br = browser
    br.select_tab(tab) if br.current.nil? || br.current.id != tab.to_i
    unless br.devtools_open
      br.toggle_devtools
    end
    if defined?(Inspector)
      Inspector.reveal(css_x.to_f, css_y.to_f)
    end
  end
end
