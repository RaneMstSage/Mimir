# DevTools target discovery and frontend URL construction (port of the Java DevToolsClient).
module DevTools
  CDN = "https://chrome-devtools-frontend.appspot.com/serve_rev/"

  def self.targets
    JSON.parse(Http.get_devtools("/json/list"))
  end

  def self.version
    JSON.parse(Http.get_devtools("/json/version"))
  end

  # Pick the page target for `url`. WebView's entries carry a "description" JSON with
  # visible/attached flags; prefer an exact URL match, then visible, then unattached.
  # `exclude_prefix` filters out the DevTools frontend WebView itself.
  def self.find_target(list, url, exclude_prefix = CDN)
    best = nil
    best_score = -1
    list.each do |t|
      next unless t["type"] == "page"
      u = t["url"].to_s
      next if exclude_prefix && u.start_with?(exclude_prefix)
      score = 0
      score += 4 if url && url == u
      desc = (JSON.parse(t["description"].to_s) rescue {})
      score += 2 if desc["visible"]
      score += 1 unless desc["attached"]
      if score > best_score
        best_score = score
        best = t
      end
    end
    best
  end

  # Frontend URL whose websocket points at our relay: ws=127.0.0.1:<port>/<token>/devtools/page/<id>
  def self.frontend_url(target, relay_port, token, webkit_version = nil)
    id = target["id"].to_s
    ws = "127.0.0.1:#{relay_port}/#{token}/devtools/page/#{id}"
    u = target["devtoolsFrontendUrl"].to_s
    if u.start_with?("http")
      i = u.index("ws=")
      if i
        j = u.index("/", i)                      # end of host[:port]
        return u[0, i] + "ws=" + ws + (j ? u[(j + "/devtools/page/#{id}".size)..-1].to_s : "")
      end
      return u
    end
    wk = webkit_version.to_s
    at = wk.index("@")
    rev = at ? wk[(at + 1)..-1].to_s.delete(")").strip : ""
    "#{CDN}@#{rev}/inspector.html?ws=#{ws}"
  end
end
