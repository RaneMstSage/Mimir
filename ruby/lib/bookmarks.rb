# Bookmarks and recent history, persisted as JSON in files_dir. Owned by Ruby; rendered by the chrome.
class Bookmarks
  MAX_HISTORY = 200

  def initialize(dir)
    @path = dir ? "#{dir}/bookmarks.json" : nil
    @data = { "bookmarks" => [], "history" => [] }
    load
  end

  def list    ; @data["bookmarks"] ; end
  def history ; @data["history"] ; end

  def bookmarked?(url) ; list.any? { |b| b["url"] == url } ; end

  # Returns true if now bookmarked, false if removed.
  def toggle(url, title, favicon = nil)
    return false if url.to_s.empty?
    if bookmarked?(url)
      list.reject! { |b| b["url"] == url }
      save ; false
    else
      list << { "url" => url, "title" => title.to_s.empty? ? url : title, "favicon" => favicon, "added" => Time.now.to_i }
      save ; true
    end
  end

  def remove(url) ; list.reject! { |b| b["url"] == url } ; save ; end

  def visit(url, title, favicon = nil)
    return if url.to_s.empty? || url.start_with?("about:") || url.start_with?("file:")
    history.reject! { |h| h["url"] == url }
    history.unshift({ "url" => url, "title" => title.to_s.empty? ? url : title, "favicon" => favicon, "at" => Time.now.to_i })
    history.pop while history.size > MAX_HISTORY
    save
  end

  def load
    return unless @path && File.exist?(@path)
    parsed = JSON.parse(File.read(@path))
    @data = parsed if parsed.is_a?(Hash) && parsed["bookmarks"] && parsed["history"]
  rescue => e
    Host.log(:warn, "bookmarks load: #{e.message}")
  end

  def save
    return unless @path
    File.open(@path, "w") { |f| f.write(@data.to_json) }
  rescue => e
    Host.log(:warn, "bookmarks save: #{e.message}")
  end
end
