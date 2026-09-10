# Browser state: tabs, current tab, DevTools pane state. Every change is pushed to Java as
# imperative commands (tab.create/show/destroy/load...) plus a full `ui.state` snapshot the UI
# renders from. Java holds no browser logic of its own.
class Tab
  attr_accessor :id, :url, :title, :progress, :loading, :favicon, :can_back, :can_forward
  def initialize(id, url)
    @id, @url, @title, @progress, @loading = id, url, "New tab", 0, false
    @favicon, @can_back, @can_forward = nil, false, false
  end
  def to_h
    { "id" => @id, "url" => @url, "title" => @title, "progress" => @progress, "loading" => @loading, "favicon" => @favicon }
  end
end

class Browser
  attr_reader :tabs, :current, :settings
  attr_accessor :devtools_open

  attr_reader :billing

  def initialize(settings, bookmarks = nil, scripts = nil)
    @settings = settings
    @bookmarks = bookmarks
    @scripts = scripts
    @billing = { "status" => "unknown", "products" => [], "thanks" => false, "reason" => "" }
    @tabs = []
    @current = nil
    @next_id = 1
    @devtools_open = false
  end

  # ---- tabs -------------------------------------------------------------------------------
  def new_tab(url = nil, select: true)
    url = url.to_s.empty? ? @settings["home"] : url
    t = Tab.new(@next_id, url)
    @next_id += 1
    @tabs << t
    Host.emit("tab.create", "tab" => t.id, "url" => url, "select" => select)
    select_tab(t.id) if select
    push_state
    t
  end

  def find(id) ; @tabs.find { |t| t.id == id.to_i } ; end

  def select_tab(id)
    t = find(id) or return
    @current = t
    Host.emit("tab.show", "tab" => t.id)
    push_state
    attach_devtools if @devtools_open
  end

  def close_tab(id)
    t = find(id) or return
    if @tabs.size == 1
      t.url = @settings["home"]
      Host.emit("tab.load", "tab" => t.id, "url" => t.url)
      push_state
      return
    end
    idx = @tabs.index(t)
    @tabs.delete(t)
    Host.emit("tab.destroy", "tab" => t.id)
    select_tab(@tabs[[idx, @tabs.size - 1].min].id) if @current.equal?(t)
    push_state
  end

  def navigate(id, text)
    t = find(id) || @current or return
    url = UrlNorm.normalize(text, @settings["search"]) or return
    t.url = url
    Host.emit("tab.load", "tab" => t.id, "url" => url)
    push_state
  end

  def nav(id, action)
    t = find(id) || @current or return
    Host.emit("tab.#{action}", "tab" => t.id)   # back / forward / reload
  end

  # ---- page events from Java ------------------------------------------------------------

  def page_finished(id, url, can_back = nil, can_forward = nil)
    t = find(id) or return
    t.url = url.to_s unless url.to_s.empty?
    t.loading = false
    t.progress = 100
    t.can_back = can_back unless can_back.nil?
    t.can_forward = can_forward unless can_forward.nil?
    @bookmarks.visit(t.url, t.title, t.favicon) if @bookmarks
    inject(t, "end")
    push_state
  end

  def page_favicon(id, data_url)
    t = find(id) or return
    t.favicon = data_url
    push_state
  end

  def page_started(id, url)
    t = find(id) or return
    t.url = url.to_s
    t.loading = true
    t.progress = 5
    t.favicon = nil
    inject(t, "start")
    push_state
  end

  def inject(t, run_at)
    return unless @scripts
    js = @scripts.payload(t.url, run_at)
    Host.emit("tab.inject", "tab" => t.id, "js" => js) if js
  end

  def push_blocks ; Host.emit("block.rules", "patterns" => @scripts ? @scripts.blocks : []) ; end

  # ---- bookmarks ------------------------------------------------------------------------
  def toggle_bookmark
    return unless @current && @bookmarks
    node = @bookmarks.toggle(@current.url, @current.title, @current.favicon)
    Host.toast(node ? "Bookmark added" : "Bookmark removed")
    push_state
  end

  def toggle_bookmarks_bar
    @settings["bookmarks_bar"] = !@settings["bookmarks_bar"]
    push_state
  end

  # ---- settings -----------------------------------------------------------------------------
  def set_setting(key, value)
    return unless Settings::DEFAULTS.key?(key)
    value = value.to_i if key == "text_zoom"
    value = value.to_f if key == "dock_fraction"
    @settings[key] = value
    Host.emit("prefs.apply", @settings.webview_prefs) if Settings::WEBVIEW_KEYS.include?(key)
    Host.emit("ua.set", "desktop" => desktop?) if key == "desktop_ua"
    Host.emit("devtools.dock", "side" => @settings["dock_side"], "fraction" => @settings["dock_fraction"]) if key == "dock_side" && @devtools_open
    devtools_prefs if key.start_with?("devtools_")
    push_state
  end

  def apply_prefs
    Host.emit("prefs.apply", @settings.webview_prefs)
    devtools_prefs
  end

  def devtools_prefs
    Host.emit("devtools.prefs", "theme" => @settings["devtools_theme"].to_s, "screencast" => @settings["devtools_screencast"] ? true : false)
  end

  def clear_data(what)
    what = Array(what)
    @bookmarks.history.clear && @bookmarks.save if @bookmarks && what.include?("history")
    Host.emit("data.clear", "cookies" => what.include?("cookies"), "cache" => what.include?("cache"), "storage" => what.include?("storage"))
    Host.toast("Cleared #{what.join(', ')}")
    push_state
  end

  def history_remove(url) ; @bookmarks.history.reject! { |h| h["url"] == url } ; @bookmarks.save ; push_state ; end
  def bookmark_remove(id) ; @bookmarks.remove(id) ; push_state ; end
  def bookmark_update(id, title, parent) ; @bookmarks.update(id, title, parent) ; push_state ; end
  def folder_new(parent, title) ; @bookmarks.new_folder(parent, title) ; push_state ; end

  def page_title(id, title)
    t = find(id) or return
    t.title = title.to_s.empty? ? t.url : title.to_s
    push_state
  end

  def page_progress(id, p)
    t = find(id) or return
    t.progress = p.to_i
    t.loading = p.to_i < 100
    push_state if t.equal?(@current)
  end

  # ---- desktop / mobile -------------------------------------------------------------------
  def desktop? ; @settings["desktop_ua"] ? true : false ; end

  def toggle_ua
    @settings["desktop_ua"] = !desktop?
    Host.emit("ua.set", "desktop" => desktop?)
    Host.toast(desktop? ? "Requesting desktop site" : "Requesting mobile site")
    nav(nil, "reload") if @current
    push_state
  end

  # ---- devtools ---------------------------------------------------------------------------
  def toggle_devtools
    if @devtools_open
      @devtools_open = false
      Host.emit("devtools.close")
    else
      @devtools_open = true
      Host.emit("devtools.dock", "side" => @settings["dock_side"], "fraction" => @settings["dock_fraction"])
      attach_devtools
    end
    push_state
  end

  def toggle_dock
    @settings["dock_side"] = @settings["dock_side"] == "right" ? "bottom" : "right"
    Host.emit("devtools.dock", "side" => @settings["dock_side"], "fraction" => @settings["dock_fraction"])
    push_state
  end

  def set_dock_fraction(f)
    f = f.to_f
    @settings["dock_fraction"] = [[f, 0.15].max, 0.85].min
  end

  def attach_devtools
    return unless @current
    App.attach_devtools(@current.url)
  end

  # ---- snapshot for the UI ----------------------------------------------------------------
  def state
    {
      "tabs" => @tabs.map(&:to_h),
      "current" => @current ? @current.id : nil,
      "url" => @current ? @current.url : "",
      "progress" => @current ? @current.progress : 0,
      "loading" => @current ? @current.loading : false,
      "desktop" => desktop?,
      "can_back" => @current ? @current.can_back : false,
      "can_forward" => @current ? @current.can_forward : false,
      "bookmarks" => @bookmarks ? { "bar" => @bookmarks.bar, "other" => @bookmarks.other } : { "bar" => { "children" => [] }, "other" => { "children" => [] } },
      "bookmarks_flat" => @bookmarks ? @bookmarks.urls : [],
      "history" => @bookmarks ? @bookmarks.history : [],
      "bookmarks_bar" => @settings["bookmarks_bar"] ? true : false,
      "settings" => @settings.to_h,
      "scripts" => @scripts ? @scripts.list : [],
      "billing" => @billing,
      "blocks" => @scripts ? @scripts.blocks : [],
      "version" => { "app" => App::VERSION, "ruby" => Inspect.version, "donate" => (App.boot || {})["donate_url"].to_s, "source" => (App.boot || {})["source_url"].to_s },
      "devtools" => { "open" => @devtools_open, "side" => @settings["dock_side"], "fraction" => @settings["dock_fraction"] }
    }
  end

  def push_state ; Host.emit("ui.state", "state" => state) ; end
end
