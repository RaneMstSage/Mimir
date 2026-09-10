# Persisted user preferences: files_dir/settings.json (written on every change; tiny).
class Settings
  DEFAULTS = { "desktop_ua" => true, "dock_side" => "right", "dock_fraction" => 0.45, "home" => "https://www.google.com/", "bookmarks_bar" => true }

  def initialize(dir)
    @path = dir ? "#{dir}/settings.json" : nil
    @data = DEFAULTS.dup
    load
  end

  def [](k)     ; @data[k] ; end
  def []=(k, v) ; @data[k] = v ; save ; end
  def to_h      ; @data.dup ; end

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
