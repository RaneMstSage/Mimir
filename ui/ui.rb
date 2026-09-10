# backtick_javascript: true
# Browser chrome for Inspect Element, written in Ruby and compiled to JavaScript with Opal.
# It renders the state snapshot Ruby (mruby, in the APK) sends and turns taps into events.
require 'opal'
require 'native'
require 'json'

module UI
  @state = { "tabs" => [], "bookmarks" => [], "history" => [] }
  @menu_open = false
  @typing = false

  # ---- plumbing -----------------------------------------------------------------------------
  def self.send(ev, fields = {})
    json = { "ev" => ev }.merge(fields).to_json
    `window.host && window.host.send(#{json})`
  end

  def self.receive(json)
    @state = JSON.parse(`#{json}`)
    render
  end

  def self.el(id) ; `document.getElementById(#{id})` ; end
  def self.esc(s)
    s.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
  end
  def self.host_of(url)
    u = url.to_s
    i = u.index("://") ; return u[0, 30] unless i
    rest = u[(i + 3)..-1] ; j = rest.index("/")
    (j ? rest[0, j] : rest).sub("www.", "")
  end
  def self.favicon(t)
    f = t["favicon"].to_s
    f.empty? ? "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Ccircle cx='8' cy='8' r='6' fill='%23334155'/%3E%3C/svg%3E" : f
  end

  # ---- rendering ----------------------------------------------------------------------------
  def self.render
    render_tabs
    render_toolbar
    render_bookmarks
    height = 80 + (@state["bookmarks_bar"] ? 28 : 0)
    `window.host && window.host.send(#{ { "ev" => "chrome.height", "dp" => height }.to_json })`
  end

  def self.render_tabs
    cur = @state["current"]
    html = @state["tabs"].map do |t|
      cls = "tab#{t["id"] == cur ? ' on' : ''}#{t["loading"] ? ' loading' : ''}"
      "<div class=\"#{cls}\" data-act=\"tab.select\" data-tab=\"#{t["id"]}\">" \
        "<img src=\"#{esc(favicon(t))}\" alt=\"\">" \
        "<span class=\"t\">#{esc(t["title"].to_s.empty? ? host_of(t["url"]) : t["title"])}</span>" \
        "<button class=\"x\" data-act=\"tab.close\" data-tab=\"#{t["id"]}\" aria-label=\"Close tab\">×</button>" \
      "</div>"
    end.join
    html << "<button class=\"new\" data-act=\"tab.new\" aria-label=\"New tab\">+</button>"
    `#{el("tabs")}.innerHTML = #{html}`
  end

  def self.render_toolbar
    url = @state["url"].to_s
    starred = @state["bookmarks"].any? { |b| b["url"] == url }
    desktop = @state["desktop"]
    dt = @state["devtools"] || {}
    secure = url.start_with?("https://")
    lock = url.empty? ? "" : (secure ? "🔒" : "ⓘ")
    html = "<button class=\"ib#{@state["can_back"] ? '' : ' dis'}\" data-act=\"nav.back\">‹</button>" \
           "<button class=\"ib#{@state["can_forward"] ? '' : ' dis'}\" data-act=\"nav.forward\">›</button>" \
           "<button class=\"ib\" data-act=\"#{@state["loading"] ? 'nav.stop' : 'nav.reload'}\">#{@state["loading"] ? '✕' : '↻'}</button>" \
           "<div id=\"omni\"><span class=\"lock\">#{lock}</span>" \
             "<input id=\"url\" type=\"text\" inputmode=\"url\" autocomplete=\"off\" autocorrect=\"off\" autocapitalize=\"off\" spellcheck=\"false\" placeholder=\"Search or enter address\" value=\"#{esc(url)}\">" \
             "<button class=\"star#{starred ? ' on' : ''}\" data-act=\"bookmark.toggle\" aria-label=\"Bookmark\">#{starred ? '★' : '☆'}</button>" \
             "<div id=\"prog\" style=\"width:#{@state["loading"] ? @state["progress"].to_i : 0}%\"></div>" \
           "</div>" \
           "<button class=\"ib txt\" data-act=\"ua.toggle\">#{desktop ? 'Desktop' : 'Mobile'}</button>" \
           "<button class=\"ib#{dt["open"] ? ' on' : ' acc'}\" data-act=\"devtools.toggle\" title=\"DevTools\">⚙</button>" \
           "<button class=\"ib\" data-act=\"menu.toggle\">⋮</button>"
    input = el("url")
    focused = input && `document.activeElement === #{input}`
    if focused
      # keep the user's typing; only refresh the bits around the field
      `#{el("prog")}.style.width = #{@state["loading"] ? @state["progress"].to_i : 0} + '%'`
      return
    end
    `#{el("toolbar")}.innerHTML = #{html}`
    wire_input
  end

  def self.render_bookmarks
    bar = el("bookmarks")
    if @state["bookmarks_bar"]
      items = @state["bookmarks"]
      html = items.empty? ? "<span class=\"empty\">No bookmarks yet — tap ☆ on a page</span>" :
        items.map { |b| "<button class=\"bm\" data-act=\"open\" data-url=\"#{esc(b["url"])}\"><img src=\"#{esc(favicon(b))}\" alt=\"\"><span>#{esc(b["title"].to_s.empty? ? host_of(b["url"]) : b["title"])}</span></button>" }.join
      `#{bar}.innerHTML = #{html}; #{bar}.hidden = false`
    else
      `#{bar}.hidden = true`
    end
  end

  def self.render_menu
    m = el("menu")
    unless @menu_open
      `#{m}.hidden = true` ; return
    end
    dt = @state["devtools"] || {}
    rows = [
      ["tab.new", "New tab", "+"],
      ["bookmarks.bar", "Bookmarks bar", @state["bookmarks_bar"] ? "✓" : ""],
      ["bookmark.toggle", "Bookmark this page", "☆"],
      :hr,
      ["ua.toggle", "Request #{@state["desktop"] ? 'mobile' : 'desktop'} site", ""],
      ["devtools.toggle", dt["open"] ? "Close DevTools" : "Open DevTools", "⚙"],
      ["dock.toggle", "Dock DevTools #{dt["side"] == 'right' ? 'bottom' : 'right'}", ""],
      :hr,
      ["dev.toggle", "Ruby console", "rb"],
      ["settings.open", "Settings", "›"],
      ["about", "About Inspect Element", ""]
    ]
    html = rows.map { |r| r == :hr ? "<hr>" : "<button class=\"m\" data-act=\"#{r[0]}\"><span>#{r[1]}</span><small>#{r[2]}</small></button>" }.join
    `#{m}.innerHTML = #{html}; #{m}.hidden = false`
  end

  def self.render_suggest(q)
    box = el("suggest")
    q = q.to_s.downcase
    if q.empty?
      `#{box}.hidden = true` ; return
    end
    pool = (@state["bookmarks"].map { |b| b.merge("k" => "★") } + @state["history"].map { |h| h.merge("k" => "⌚") })
    hits = pool.select { |e| e["url"].to_s.downcase.include?(q) || e["title"].to_s.downcase.include?(q) }.first(6)
    html = hits.map { |e| "<button class=\"s\" data-act=\"open\" data-url=\"#{esc(e["url"])}\"><span class=\"k\">#{e["k"]}</span><span>#{esc(e["title"].to_s[0, 40])}</span><span class=\"u\">#{esc(e["url"])}</span></button>" }.join
    html << "<button class=\"s\" data-act=\"navigate\" data-text=\"#{esc(q)}\"><span class=\"k\">🔍</span><span>Search for “#{esc(q)}”</span></button>"
    `#{box}.innerHTML = #{html}; #{box}.hidden = false`
  end

  # ---- input & events -------------------------------------------------------------------------
  def self.wire_input
    input = el("url")
    return unless input
    %x{
      #{input}.addEventListener('focus', function(){ #{input}.select(); });
      #{input}.addEventListener('input', function(){ #{render_suggest(`#{input}.value`)} });
      #{input}.addEventListener('blur',  function(){ setTimeout(function(){ #{el("suggest")}.hidden = true; #{render_toolbar} }, 150); });
      #{input}.addEventListener('keydown', function(e){
        if (e.key === 'Enter') { e.preventDefault(); #{navigate(`#{input}.value`)}; #{input}.blur(); }
        if (e.key === 'Escape') { #{input}.blur(); }
      });
    }
  end

  def self.navigate(text)
    send("navigate", "tab" => @state["current"], "text" => text)
    `#{el("suggest")}.hidden = true`
  end

  def self.click(target)
    act = `#{target}.dataset.act`
    tab = `#{target}.dataset.tab`
    tab = tab.to_s.empty? ? nil : tab.to_i
    @menu_open = false unless act == "menu.toggle"
    case act
    when "menu.toggle"     then @menu_open = !@menu_open
    when "tab.select", "tab.close" then send(act, "tab" => tab)
    when "tab.new"         then send("tab.new")
    when "open"            then navigate(`#{target}.dataset.url`)
    when "navigate"        then navigate(`#{target}.dataset.text`)
    when "nav.back", "nav.forward", "nav.reload", "nav.stop" then send(act, "tab" => @state["current"])
    when "bookmark.toggle" then send("bookmark.toggle")
    when "bookmarks.bar"   then send("bookmarks.bar")
    when "ua.toggle", "devtools.toggle", "dock.toggle", "dev.toggle", "settings.open", "about" then send(act)
    end
    render_menu
  end

  def self.boot
    %x{
      window.UI = { receive: function(s){ #{receive(`s`)} } };
      document.addEventListener('click', function(e){
        var t = e.target.closest('[data-act]');
        if (t) { e.preventDefault(); e.stopPropagation(); #{click(`t`)}; return; }
        if (!e.target.closest('#menu')) { #{@menu_open = false; render_menu} }
      });
      document.addEventListener('contextmenu', function(e){ e.preventDefault(); });
    }
    render
    send("chrome.ready")
  end
end

UI.boot
