# backtick_javascript: true
# Browser chrome for Mímir, written in Ruby and compiled to JavaScript with Opal.
# It renders the state snapshot Ruby (mruby, in the APK) sends and turns taps into events.
require 'opal'
require 'native'
require 'json'

module UI
  @state = { "tabs" => [], "bookmarks" => [], "history" => [] }
  @menu_open = false
  @page = nil            # nil | "settings" | "history" | "bookmarks" | "about"
  @section = nil         # settings section
  @filter = ""           # history/bookmarks search

  # ---- plumbing -----------------------------------------------------------------------------
  def self.send(ev, fields = {})
    json = { "ev" => ev }.merge(fields).to_json
    `window.host && window.host.send(#{json})`
  end

  def self.receive(json)
    @state = JSON.parse(`String(#{json})`)
    if @page && `document.activeElement && document.activeElement.closest('#page')`
      render_tabs ; render_toolbar ; render_bookmarks     # don't rebuild the page while typing in it
    else
      render
    end
  rescue Exception => e
    report_error("receive", e)
  end

  # Any UI exception: tell the host (status line + Ruby log), drop back to the plain browser state
  # so the expanded chrome layer never gets stuck covering the page.
  def self.report_error(where, e)
    text = "#{where}: #{e.class}: #{e.message}"
    bt = (e.backtrace || []).first(3).join(" | ")
    `console.error(#{text} + " " + #{bt})`
    `window.host && window.host.send(#{ { "ev" => "ui.error", "text" => text, "bt" => bt }.to_json })`
    @page = nil
    @menu_open = false
    begin
      `#{el("page")}.hidden = true; #{el("menu")}.hidden = true; #{el("suggest")}.hidden = true`
      sync_height
    rescue Exception
    end
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
    render_page
    sync_height
  end

  # Collapsed height = tabs + toolbar (+ bookmarks bar). While a dropdown or page is open the
  # transparent chrome layer expands over the page so the popup is not clipped.
  def self.sync_height
    dp = 80 + (@state["bookmarks_bar"] ? 28 : 0)
    suggest_open = `!#{el("suggest")}.hidden`
    expand = !!(@page || @menu_open || suggest_open)
    `window.host && window.host.send(#{ { "ev" => "chrome.height", "dp" => dp, "expand" => expand }.to_json })`
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
    html += "<button class=\"new\" data-act=\"tab.new\" aria-label=\"New tab\">+</button>"
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
      `#{m}.hidden = true` ; sync_height ; return
    end
    dt = @state["devtools"] || {}
    rows = [
      ["tab.new", "New tab", "+"],
      ["bookmark.toggle", "Bookmark this page", "☆"],
      ["page:bookmarks", "Bookmarks", "›"],
      ["page:history", "History", "›"],
      ["bookmarks.bar", "Show bookmarks bar", @state["bookmarks_bar"] ? "✓" : ""],
      :hr,
      ["ua.toggle", "Request #{@state["desktop"] ? 'mobile' : 'desktop'} site", ""],
      ["devtools.toggle", dt["open"] ? "Close DevTools" : "Open DevTools", "⚙"],
      ["dock.toggle", "Dock DevTools #{dt["side"] == 'right' ? 'bottom' : 'right'}", ""],
      :hr,
      ["dev.toggle", "Ruby console", "rb"],
      ["devtools.chrome", "Inspect browser UI", "⚙"],
      ["page:settings", "Settings", "›"],
      ["page:about", "About Mímir", ""]
    ]
    html = rows.map { |r| r == :hr ? "<hr>" : "<button class=\"m\" data-act=\"#{r[0]}\"><span>#{r[1]}</span><small>#{r[2]}</small></button>" }.join
    `#{m}.innerHTML = #{html}; #{m}.hidden = false`
    sync_height
  end

  def self.render_suggest(q)
    box = el("suggest")
    q = q.to_s.downcase
    if q.empty?
      `#{box}.hidden = true` ; sync_height ; return
    end
    pool = (@state["bookmarks"].map { |b| b.merge("k" => "★") } + @state["history"].map { |h| h.merge("k" => "⌚") })
    hits = pool.select { |e| e["url"].to_s.downcase.include?(q) || e["title"].to_s.downcase.include?(q) }.first(6)
    html = hits.map { |e| "<button class=\"s\" data-act=\"open\" data-url=\"#{esc(e["url"])}\"><span class=\"k\">#{e["k"]}</span><span>#{esc(e["title"].to_s[0, 40])}</span><span class=\"u\">#{esc(e["url"])}</span></button>" }.join
    html += "<button class=\"s\" data-act=\"navigate\" data-text=\"#{esc(q)}\"><span class=\"k\">🔍</span><span>Search for “#{esc(q)}”</span></button>"
    `#{box}.innerHTML = #{html}; #{box}.hidden = false`
    sync_height
  end

  # ---- input & events -------------------------------------------------------------------------
  def self.wire_input
    input = el("url")
    return unless input
    %x{
      #{input}.addEventListener('focus', function(){ #{input}.select(); });
      #{input}.addEventListener('input', function(){ #{render_suggest(`String(#{input}.value || "")`)} });
      #{input}.addEventListener('blur',  function(){ setTimeout(function(){ #{el("suggest")}.hidden = true; #{render_toolbar}; #{sync_height} }, 150); });
      #{input}.addEventListener('keydown', function(e){
        if (e.key === 'Enter') { e.preventDefault(); #{navigate(`String(#{input}.value || "")`)}; #{input}.blur(); }
        if (e.key === 'Escape') { #{input}.blur(); }
      });
    }
  end

  def self.navigate(text)
    send("navigate", "tab" => @state["current"], "text" => text)
    `#{el("suggest")}.hidden = true`
    sync_height
  end

  def self.click(target)
    begin
      click!(target)
    rescue Exception => e
      report_error("click", e)
    end
  end

  def self.click!(target)
    # dataset reads come back as JS undefined when absent — coerce to Ruby strings first.
    act = `String(#{target}.dataset.act || "")`
    tab = `String(#{target}.dataset.tab || "")`
    tab = tab.empty? ? nil : tab.to_i
    @menu_open = false unless act == "menu.toggle"
    if act.start_with?("page:")
      @page = act[5..-1]
      @page = nil if @page == "close"
      @section = nil
      @filter = ""
      render_menu
      return render
    end
    if act.start_with?("section:")
      @section = act[8..-1]
      return render_page
    end
    case act
    when "menu.toggle"     then @menu_open = !@menu_open
    when "setting"         then set_setting(target)
    when "clear.data"      then send("data.clear", "what" => `Array.from(document.querySelectorAll('#page input[data-clear]:checked')).map(function(i){return i.dataset.clear})`)
    when "history.remove"  then send("history.remove", "url" => `String(#{target}.dataset.url || "")`)
    when "history.clear"   then send("history.clear")
    when "bookmark.remove" then send("bookmark.remove", "url" => `String(#{target}.dataset.url || "")`)
    when "bookmark.rename" then rename_bookmark(target)
    when "open.page"       then @page = nil; navigate(`String(#{target}.dataset.url || "")`)
    when "tab.select", "tab.close" then send(act, "tab" => tab)
    when "tab.new"         then send("tab.new")
    when "open"            then navigate(`String(#{target}.dataset.url || "")`)
    when "navigate"        then navigate(`String(#{target}.dataset.text || "")`)
    when "nav.back", "nav.forward", "nav.reload", "nav.stop" then send(act, "tab" => @state["current"])
    when "bookmark.toggle" then send("bookmark.toggle")
    when "bookmarks.bar"   then send("bookmarks.bar")
    when "ua.toggle", "devtools.toggle", "dock.toggle", "dev.toggle", "devtools.chrome", "settings.open", "about" then send(act)
    end
    render_menu
  end

  # ---- overlay pages ------------------------------------------------------------------------
  def self.setting(k) ; (@state["settings"] || {})[k] ; end

  def self.set_setting(target)
    key = `String(#{target}.dataset.key || "")`
    kind = `String(#{target}.dataset.kind || "")`
    value = case kind
            when "toggle" then !setting(key)
            when "number" then `Number(#{target}.value)`
            else `String(#{target}.value || "")`
            end
    send("settings.set", "key" => key, "value" => value)
  end

  def self.rename_bookmark(target)
    url = `String(#{target}.dataset.url || "")`
    input = `document.querySelector('#page input[data-rename="' + #{url}.replace(/"/g, '\\"') + '"]')`
    return if `#{input} == null`
    send("bookmark.rename", "url" => url, "title" => `String(#{input}.value || "")`)
  end

  def self.toggle(key, label, desc = "")
    on = setting(key) ? " on" : ""
    "<div class=\"row\"><div class=\"l\"><b>#{label}</b>#{desc.empty? ? '' : "<small>#{desc}</small>"}</div><button class=\"sw#{on}\" data-act=\"setting\" data-kind=\"toggle\" data-key=\"#{key}\" aria-label=\"#{label}\"></button></div>"
  end

  def self.select(key, label, options)
    cur = setting(key).to_s
    opts = options.map { |v, t| "<option value=\"#{v}\"#{v == cur ? ' selected' : ''}>#{t}</option>" }.join
    "<div class=\"row\"><div class=\"l\"><b>#{label}</b></div><select data-key=\"#{key}\" data-kind=\"select\" onchange=\"UI.change(this)\">#{opts}</select></div>"
  end

  def self.text(key, label, type = "text")
    "<div class=\"row\"><div class=\"l\"><b>#{label}</b></div><input type=\"#{type}\" value=\"#{esc(setting(key))}\" data-key=\"#{key}\" data-kind=\"#{type}\" onchange=\"UI.change(this)\"></div>"
  end

  def self.change(el) ; set_setting(el) ; end   # called from onchange in the DOM

  SECTIONS = [["general", "General"], ["appearance", "Appearance"], ["privacy", "Privacy & data"], ["devtools", "Developer tools"]]

  def self.render_page
    pg = el("page")
    unless @page
      `#{pg}.hidden = true` ; return
    end
    title = { "settings" => "Settings", "history" => "History", "bookmarks" => "Bookmarks", "about" => "About" }[@page] || @page
    search = @page == "history" || @page == "bookmarks" ? "<input type=\"search\" placeholder=\"Search #{title.downcase}\" value=\"#{esc(@filter)}\" oninput=\"UI.filter(this.value)\">" : ""
    nav = ""
    body = case @page
           when "settings"
             @section ||= "general"
             nav = "<nav>" + SECTIONS.map { |id, t| "<button class=\"#{id == @section ? 'on' : ''}\" data-act=\"section:#{id}\">#{t}</button>" }.join + "</nav>"
             settings_section(@section)
           when "history"  then history_body
           when "bookmarks" then bookmarks_body
           when "about"    then about_body
           else "<div class=\"empty\">Unknown page</div>"
           end
    html = "<header><h1>#{title}</h1>#{search}<button class=\"ib\" data-act=\"page:close\" aria-label=\"Close\">✕</button></header>" \
           "<div class=\"body\">#{nav}<main>#{body}</main></div>"
    `#{pg}.innerHTML = #{html}; #{pg}.hidden = false`
    debug_page(pg)
  end

  # Temporary diagnostics: how the overlay actually ended up on screen.
  def self.debug_page(pg)
    info = `(function(el){ var r = el.getBoundingClientRect(), cs = getComputedStyle(el);
      return 'page rect ' + Math.round(r.left) + ',' + Math.round(r.top) + ' ' + Math.round(r.width) + 'x' + Math.round(r.height) +
        ' display=' + cs.display + ' pos=' + cs.position + ' bg=' + cs.backgroundColor + ' z=' + cs.zIndex + ' vis=' + cs.visibility + ' op=' + cs.opacity +
        ' hidden=' + el.hidden + ' html=' + el.innerHTML.length + ' viewport ' + window.innerWidth + 'x' + window.innerHeight +
        ' body ' + document.body.clientWidth + 'x' + document.body.clientHeight + ' dpr=' + window.devicePixelRatio; })(#{pg})`
    `window.host && window.host.send(#{ { "ev" => "ui.debug", "text" => info }.to_json })`
  end

  def self.filter(q) ; @filter = q.to_s ; render_page ; end

  def self.settings_section(id)
    case id
    when "general"
      "<h2>Search & startup</h2><div class=\"card\">" +
        select("search", "Search engine", [["google", "Google"], ["duckduckgo", "DuckDuckGo"], ["bing", "Bing"], ["brave", "Brave Search"]]) +
        text("home", "Home page") +
        toggle("desktop_ua", "Request desktop site by default", "Sends a desktop user agent to every page") +
      "</div><h2>Bookmarks</h2><div class=\"card\">" + toggle("bookmarks_bar", "Show bookmarks bar") + "</div>"
    when "appearance"
      "<h2>Pages</h2><div class=\"card\">" +
        toggle("force_dark", "Force dark mode on pages", "Algorithmic darkening for sites without a dark theme") +
        text("text_zoom", "Text size (%)", "number") +
      "</div>"
    when "privacy"
      "<h2>Content</h2><div class=\"card\">" +
        toggle("javascript", "JavaScript", "Turning this off breaks most sites; useful for testing") +
        toggle("cookies_3p", "Allow third-party cookies") +
      "</div><h2>Clear browsing data</h2><div class=\"card\">" +
        %w[history cookies cache storage].map { |w| "<label class=\"row\"><div class=\"l\"><b>#{w.capitalize}</b></div><input type=\"checkbox\" data-clear=\"#{w}\" #{w == 'history' || w == 'cache' ? 'checked' : ''}></label>" }.join +
        "<div class=\"row\"><div class=\"l\"></div><button class=\"btn danger\" data-act=\"clear.data\">Clear selected</button></div>" +
      "</div>"
    when "devtools"
      dt = @state["devtools"] || {}
      "<h2>DevTools</h2><div class=\"card\">" +
        select("dock_side", "Dock side", [["right", "Right"], ["bottom", "Bottom"]]) +
        select("devtools_theme", "Theme", [["dark", "Dark"], ["light", "Light"]]) +
        toggle("devtools_screencast", "Show screencast preview", "Live thumbnail of the page inside DevTools") +
        "<div class=\"row\"><div class=\"l\"><b>Engine</b><small>Android System WebView (Chromium). No Chrome extensions; use Scripts instead.</small></div></div>" +
      "</div>"
    end
  end

  def self.matches?(e)
    q = @filter.downcase
    q.empty? || e["url"].to_s.downcase.include?(q) || e["title"].to_s.downcase.include?(q)
  end

  def self.history_body
    items = (@state["history"] || []).select { |h| matches?(h) }
    return "<div class=\"empty\">No history#{@filter.empty? ? ' yet' : ' matches'}</div>" if items.empty?
    days = {}
    items.each { |h| (days[day_label(h["at"])] ||= []) << h }
    out = "<div class=\"row\" style=\"padding:0 0 8px\"><div class=\"l\"></div><button class=\"btn\" data-act=\"history.clear\">Clear all history</button></div>"
    days.each do |d, list|
      out += "<div class=\"day\">#{d}</div><div class=\"card\">" + list.map { |h|
        "<div class=\"row link\" data-act=\"open.page\" data-url=\"#{esc(h["url"])}\"><img src=\"#{esc(favicon(h))}\" alt=\"\"><div class=\"l\"><b>#{esc(h["title"])}</b><small>#{esc(h["url"])}</small></div>" \
        "<button class=\"del\" data-act=\"history.remove\" data-url=\"#{esc(h["url"])}\" aria-label=\"Remove\">✕</button></div>"
      }.join + "</div>"
    end
    out
  end

  def self.day_label(t)
    return "Earlier" unless t
    now = `Math.floor(Date.now()/1000)`
    d = `new Date(#{t} * 1000)`
    today = `new Date().toDateString() === #{d}.toDateString()`
    return "Today" if today
    return "Yesterday" if now - t.to_i < 172_800
    `#{d}.toLocaleDateString(undefined, {weekday:'long', month:'short', day:'numeric'})`
  end

  def self.bookmarks_body
    items = (@state["bookmarks"] || []).select { |b| matches?(b) }
    return "<div class=\"empty\">No bookmarks#{@filter.empty? ? ' yet — tap ☆ on a page' : ' match'}</div>" if items.empty?
    "<div class=\"card\">" + items.map { |b|
      "<div class=\"row\"><img src=\"#{esc(favicon(b))}\" alt=\"\"><div class=\"l\"><input type=\"text\" value=\"#{esc(b["title"])}\" data-rename=\"#{esc(b["url"])}\" onchange=\"UI.rename_from(this)\"><small>#{esc(b["url"])}</small></div>" \
      "<button class=\"btn\" data-act=\"open.page\" data-url=\"#{esc(b["url"])}\">Open</button>" \
      "<button class=\"del\" data-act=\"bookmark.remove\" data-url=\"#{esc(b["url"])}\" aria-label=\"Delete\">✕</button></div>"
    }.join + "</div>"
  end

  def self.rename_from(input)
    send("bookmark.rename", "url" => `String(#{input}.dataset.rename || "")`, "title" => `String(#{input}.value || "")`)
  end

  def self.about_body
    v = @state["version"] || {}
    "<div class=\"card\"><div class=\"row\"><div class=\"l about\"><b>Mímir #{esc(v["app"])}</b>" \
    "A developer-tools browser for Android, written in Ruby.<br>App logic and DevTools relay: mruby #{esc(v["ruby"])} embedded in the APK.<br>" \
    "Browser chrome: Ruby compiled with Opal.<br>Engine: Android System WebView (Chromium).<br>Built on the tablet in Termux.</div></div></div>"
  end

  def self.boot
    %x{
      window.UI = {
        receive: function(s){ #{receive(`s`)} },
        change: function(el){ #{change(`el`)} },
        filter: function(q){ #{filter(`String(q || "")`)} },
        rename_from: function(el){ #{rename_from(`el`)} }
      };
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
