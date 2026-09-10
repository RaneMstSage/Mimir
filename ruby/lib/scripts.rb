# User scripts & styles (the extension substitute) and request-blocking rules.
# Stored in files_dir/scripts.json. Matching uses simple URL globs ("*" matches anything),
# e.g. "https://*.theodinproject.com/*". No Regexp in this mruby build.
class Scripts
  attr_reader :list, :blocks

  def initialize(dir)
    @path = dir ? "#{dir}/scripts.json" : nil
    @data = { "next_id" => 1, "scripts" => [], "blocks" => [] }
    load
  end

  def list   ; @data["scripts"] ; end
  def blocks ; @data["blocks"] ; end
  def find(id) ; list.find { |s| s["id"].to_s == id.to_s } ; end

  # ---- glob matching --------------------------------------------------------------------------
  def self.glob?(pattern, url)
    pat = pattern.to_s.strip
    return false if pat.empty? || url.nil?
    return true if pat == "*" || pat == "<all_urls>"
    parts = pat.split("*", -1)
    return url == pat if parts.size == 1
    return false unless url.start_with?(parts.first)
    return false unless url.end_with?(parts.last)
    pos = parts.first.size
    parts[1..-2].each do |seg|
      next if seg.empty?
      i = url.index(seg, pos) or return false
      pos = i + seg.size
    end
    pos <= url.size - parts.last.size
  end

  def self.matches_any?(patterns, url)
    Array(patterns).any? { |p| glob?(p, url) }
  end

  # ---- selection for a page ------------------------------------------------------------------
  # run_at: "start" (onPageStarted) or "end" (onPageFinished)
  def for_url(url, run_at)
    list.select { |s| s["enabled"] && s["run_at"].to_s == run_at && Scripts.matches_any?(s["match"], url) }
  end

  # One JS payload executing every matching script/style; each wrapped so one failure doesn't stop the rest.
  def payload(url, run_at)
    payload_for(for_url(url, run_at))
  end

  def payload_for(items)
    return nil if items.empty?
    js = items.map do |s|
      if s["type"] == "css"
        "(function(){try{var st=document.createElement('style');st.setAttribute('data-mimir','#{s["id"]}');st.textContent=#{s["code"].to_s.to_json};(document.head||document.documentElement).appendChild(st);}catch(e){console.warn('Mimir style #{s["id"]}',e)}})();"
      else
        "(function(){try{#{s["code"]}\n}catch(e){console.warn('Mimir script #{esc_name(s["name"])}',e)}})();"
      end
    end
    js.join("\n")
  end

  def esc_name(n) ; n.to_s.gsub("'", "\\\\'").gsub("\n", " ") ; end

  # ---- mutations -----------------------------------------------------------------------------
  def add(attrs)
    s = { "id" => next_id, "name" => "New script", "enabled" => true, "type" => "js", "run_at" => "end",
          "match" => ["*"], "code" => "", "source" => nil, "added" => Time.now.to_i }
    apply(s, attrs)
    list << s
    save
    s
  end

  def update(id, attrs)
    s = find(id) or return nil
    apply(s, attrs)
    save
    s
  end

  def remove(id) ; list.reject! { |s| s["id"].to_s == id.to_s } ; save ; end
  def toggle(id) ; s = find(id) or return ; s["enabled"] = !s["enabled"] ; save ; end

  def set_blocks(patterns)
    @data["blocks"] = Array(patterns).map { |p| p.to_s.strip }.reject(&:empty?).uniq
    save
  end

  # Import a userscript/stylesheet body fetched by Java. Reads ==UserScript== headers when present.
  def import(url, code)
    attrs = { "source" => url, "code" => code, "name" => url.split("/").last.to_s }
    attrs["type"] = url.end_with?(".css") ? "css" : "js"
    if code.include?("==UserScript==")
      head = code[code.index("==UserScript==")..(code.index("==/UserScript==") || -1)]
      matches = []
      head.split("\n").each do |l|
        l = l.strip.sub("//", "").strip
        if l.start_with?("@name ") then attrs["name"] = l.sub("@name", "").strip
        elsif l.start_with?("@match ") || l.start_with?("@include ") then matches << l.split(" ", 2)[1].to_s.strip
        elsif l.start_with?("@run-at ") then attrs["run_at"] = l.include?("document-start") ? "start" : "end"
        end
      end
      attrs["match"] = matches unless matches.empty?
    end
    add(attrs)
  end

  private

  def apply(s, attrs)
    %w[name enabled type run_at code source].each { |k| s[k] = attrs[k] unless attrs[k].nil? }
    if attrs["match"]
      m = attrs["match"].is_a?(Array) ? attrs["match"] : attrs["match"].to_s.split("\n")
      s["match"] = m.map { |x| x.to_s.strip }.reject(&:empty?)
      s["match"] = ["*"] if s["match"].empty?
    end
    s["run_at"] = "end" unless %w[start end].include?(s["run_at"])
    s["type"] = "js" unless %w[js css].include?(s["type"])
  end

  def load
    return unless @path && File.exist?(@path)
    parsed = JSON.parse(File.read(@path))
    @data = parsed if parsed.is_a?(Hash) && parsed["scripts"]
    @data["blocks"] ||= []
    @data["next_id"] ||= 1
  rescue => e
    Host.log(:warn, "scripts load: #{e.message}")
  end

  def save
    return unless @path
    File.open(@path, "w") { |f| f.write(@data.to_json) }
  rescue => e
    Host.log(:warn, "scripts save: #{e.message}")
  end

  def next_id
    id = @data["next_id"].to_i
    @data["next_id"] = id + 1
    "s#{id}"
  end
end
