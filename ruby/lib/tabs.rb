# Browser state: tabs, current tab, DevTools pane state. Every change is pushed to Java as
# imperative commands (tab.create/show/destroy/load...) plus a full `ui.state` snapshot the UI
# renders from. Java holds no browser logic of its own.
class Tab
  attr_accessor :id, :url, :title, :progress, :loading
  def initialize(id, url)
    @id, @url, @title, @progress, @loading = id, url, "New tab", 0, false
  end
  def to_h
    { "id" => @id, "url" => @url, "title" => @title, "progress" => @progress, "loading" => @loading }
  end
end

class Browser
  attr_reader :tabs, :current, :settings
  attr_accessor :devtools_open

  def initialize(settings)
    @settings = settings
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
    url = UrlNorm.normalize(text) or return
    t.url = url
    Host.emit("tab.load", "tab" => t.id, "url" => url)
    push_state
  end

  def nav(id, action)
    t = find(id) || @current or return
    Host.emit("tab.#{action}", "tab" => t.id)   # back / forward / reload
  end

  # ---- page events from Java ------------------------------------------------------------
  def page_started(id, url)
    t = find(id) or return
    t.url = url.to_s
    t.loading = true
    t.progress = 5
    push_state
  end

  def page_finished(id, url)
    t = find(id) or return
    t.url = url.to_s unless url.to_s.empty?
    t.loading = false
    t.progress = 100
    push_state
  end

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
      "devtools" => { "open" => @devtools_open, "side" => @settings["dock_side"], "fraction" => @settings["dock_fraction"] }
    }
  end

  def push_state ; Host.emit("ui.state", "state" => state) ; end
end
