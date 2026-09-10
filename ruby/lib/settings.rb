# Persisted user preferences: files_dir/settings.json (written on every change; tiny).
class Settings
  DEFAULTS = {
    "desktop_ua" => true, "dock_side" => "right", "dock_fraction" => 0.45,
    "home" => "https://www.google.com/", "bookmarks_bar" => true,
    "search" => "google", "javascript" => true, "cookies_3p" => true, "force_dark" => false,
    "text_zoom" => 100, "devtools_theme" => "dark", "devtools_screencast" => false
  }
  # keys that change WebView behaviour and must be pushed to Java
  WEBVIEW_KEYS = %w[javascript cookies_3p force_dark text_zoom]

  def initialize(dir)
    @path = dir ? "#{dir}/settings.json" : nil
    @data = DEFAULTS.dup
    load
  end

  def [](k)     ; @data[k] ; end
  def []=(k, v) ; @data[k] = v ; save ; end
  def to_h      ; @data.dup ; end

  def webview_prefs
    { "javascript" => @data["javascript"] ? true : false, "cookies_3p" => @data["cookies_3p"] ? true : false,
      "force_dark" => @data["force_dark"] ? true : false, "text_zoom" => @data["text_zoom"].to_i }
  end

  def load
    return unless @path && File.exist?(@path)
    parsed = JSON.parse(File.read(@path))
    @data = DEFAULTS.merge(parsed) if parsed.is_a?(Hash)
  rescue => e
    Host.log(:warn, "settings load: #{e.message}")
  end

  def save
    return unless @path
    File.open(@path, "w") { |f| f.write(@data.to_json) }
  rescue => e
    Host.log(:warn, "settings save: #{e.message}")
  end
end
