# Bookmarks (Chrome-style tree: "Bookmarks bar" + "Other bookmarks" roots, nested folders) and
# recent history, persisted as JSON in files_dir. Owned by Ruby; rendered by the Opal chrome.
class Bookmarks
  MAX_HISTORY = 200

  def initialize(dir)
    @path = dir ? "#{dir}/bookmarks.json" : nil
    @data = { "next_id" => 1, "bar" => folder_node("bar", "Bookmarks bar"), "other" => folder_node("other", "Other bookmarks"), "history" => [] }
    load
  end

  # ---- tree access ----------------------------------------------------------------------------
  def bar     ; @data["bar"] ; end
  def other   ; @data["other"] ; end
  def roots   ; [bar, other] ; end
  def history ; @data["history"] ; end

  def each_node(node = nil, &blk)
    if node.nil?
      roots.each { |r| each_node(r, &blk) }
      return
    end
    blk.call(node)
    (node["children"] || []).each { |c| each_node(c, &blk) } if node["type"] == "folder"
  end

  def find(id)
    id = id.to_s
    each_node { |n| return n if n["id"].to_s == id }
    nil
  end

  def parent_of(id)
    id = id.to_s
    each_node { |n| return n if n["type"] == "folder" && (n["children"] || []).any? { |c| c["id"].to_s == id } }
    nil
  end

  def folders
    out = []
    each_node { |n| out << n if n["type"] == "folder" }
    out
  end

  # Flat list of url bookmarks (for the star state and omnibox suggestions).
  def urls
    out = []
    each_node { |n| out << n if n["type"] == "url" }
    out
  end

  def find_by_url(url) ; urls.find { |b| b["url"] == url } ; end
  def bookmarked?(url) ; !find_by_url(url).nil? ; end

  # ---- mutations --------------------------------------------------------------------------------
  def add(url, title, favicon = nil, parent_id = "bar")
    parent = folder(parent_id) || bar
    node = { "id" => next_id, "type" => "url", "url" => url, "title" => title.to_s.empty? ? url : title, "favicon" => favicon, "added" => Time.now.to_i }
    parent["children"] << node
    save
    node
  end

  # Star behaviour: add to the bar if new, else remove. Returns the node when added, nil when removed.
  def toggle(url, title, favicon = nil)
    return nil if url.to_s.empty?
    if (b = find_by_url(url))
      remove(b["id"]) ; nil
    else
      add(url, title, favicon, "bar")
    end
  end

  def new_folder(parent_id, title)
    parent = folder(parent_id) || bar
    node = { "id" => next_id, "type" => "folder", "title" => title.to_s.empty? ? "New folder" : title, "children" => [], "added" => Time.now.to_i }
    parent["children"] << node
    save
    node
  end

  def remove(id)
    return false if %w[bar other].include?(id.to_s)
    p = parent_of(id) or return false
    p["children"].reject! { |c| c["id"].to_s == id.to_s }
    save
    true
  end

  def rename(id, title)
    n = find(id) or return false
    n["title"] = title.to_s.empty? ? (n["url"] || n["title"]) : title.to_s
    save
    true
  end

  # Move a node into another folder (appended). A folder cannot move into itself or a descendant.
  def move(id, parent_id)
    return false if %w[bar other].include?(id.to_s)
    n = find(id) or return false
    dest = folder(parent_id) or return false
    return false if n["type"] == "folder" && descendant?(n, dest["id"])
    return false if dest["id"].to_s == id.to_s
    old = parent_of(id)
    return true if old && old["id"].to_s == dest["id"].to_s
    old["children"].reject! { |c| c["id"].to_s == id.to_s } if old
    dest["children"] << n
    save
    true
  end

  def update(id, title = nil, parent_id = nil)
    rename(id, title) unless title.nil?
    move(id, parent_id) unless parent_id.nil? || parent_id.to_s.empty?
  end

  def folder(id)
    n = find(id)
    n && n["type"] == "folder" ? n : nil
  end

  def descendant?(node, id)
    (node["children"] || []).any? { |c| c["id"].to_s == id.to_s || (c["type"] == "folder" && descendant?(c, id)) }
  end

  # ---- history ------------------------------------------------------------------------------
  def visit(url, title, favicon = nil)
    return if url.to_s.empty? || url.start_with?("about:") || url.start_with?("file:")
    history.reject! { |h| h["url"] == url }
    history.unshift({ "url" => url, "title" => title.to_s.empty? ? url : title, "favicon" => favicon, "at" => Time.now.to_i })
    history.pop while history.size > MAX_HISTORY
    save
  end

  # ---- persistence ----------------------------------------------------------------------------
  def load
    return unless @path && File.exist?(@path)
    parsed = JSON.parse(File.read(@path))
    return unless parsed.is_a?(Hash)
    if parsed["bar"] && parsed["other"]
      @data = parsed
      @data["history"] ||= []
      @data["next_id"] ||= 1
    elsif parsed["bookmarks"].is_a?(Array)                       # legacy flat list -> bar folder
      @data["history"] = parsed["history"] || []
      parsed["bookmarks"].each { |b| bar["children"] << { "id" => next_id, "type" => "url", "url" => b["url"], "title" => b["title"], "favicon" => b["favicon"], "added" => b["added"] } }
      save
    end
  rescue => e
    Host.log(:warn, "bookmarks load: #{e.message}")
  end

  def save
    return unless @path
    File.open(@path, "w") { |f| f.write(@data.to_json) }
  rescue => e
    Host.log(:warn, "bookmarks save: #{e.message}")
  end

  private

  def folder_node(id, title) ; { "id" => id, "type" => "folder", "title" => title, "children" => [] } ; end

  def next_id
    id = @data["next_id"].to_i
    @data["next_id"] = id + 1
    "b#{id}"
  end
end
