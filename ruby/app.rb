# Inspect Element — Ruby side entry point (runs inside the APK on the dedicated ruby thread).
#
# App.run(boot_json) never returns until a "quit" event arrives. It owns the single event loop:
# IO.select over the native wake pipe (Java -> Ruby events) plus the DevTools relay sockets.
module App
  VERSION = "0.3.0"

  @handlers = {}
  @running = false
  @relay = nil

  def self.on(event, &blk) ; @handlers[event] = blk ; end
  def self.relay ; @relay ; end
  def self.boot  ; @boot ; end

  def self.run(boot_json)
    @boot = JSON.parse(boot_json.to_s) rescue {}
    @running = true
    wake = IO.for_fd(Inspect.wake_fd)
    Host.log(:info, "Ruby #{Inspect.version} up in pid #{Inspect.pid}; app #{VERSION}")
    Host.emit("ready", "ruby" => Inspect.version, "app" => VERSION)
    start_relay

    while @running
      readers = [wake] + Loop.readers
      writers = Loop.writers
      ready = IO.select(readers, writers, nil, 1.0)
      next unless ready
      if ready[0].include?(wake)
        begin
          wake.sysread(4096)
        rescue Errno::EAGAIN
        end
        drain_events
      end
      Loop.dispatch(ready[0], ready[1])
    end
    Host.log(:info, "App.run: quitting")
  end

  def self.start_relay
    @relay = Relay.new
    Host.log(:info, "relay listening on 127.0.0.1:#{@relay.port}")
    Host.emit("bridge.ready", "port" => @relay.port)
  rescue => e
    Host.log(:error, "relay failed: #{e.class}: #{e.message}")
    Host.emit("bridge.fallback", "reason" => "#{e.class}: #{e.message}")
  end

  def self.drain_events
    while (raw = Inspect.next_event)
      handle(raw)
    end
  end

  def self.handle(raw)
    ev = JSON.parse(raw)
    name = ev["ev"].to_s
    if (h = @handlers[name])
      h.call(ev)
    else
      Host.log(:warn, "unhandled event #{name}")
    end
  rescue => e
    Host.log(:error, "event #{raw[0, 120]} failed: #{e.class}: #{e.message}")
    (e.backtrace || []).each { |l| Host.log(:error, "  #{l}") }
  end

  def self.stop! ; @running = false ; end
end

App.on("quit") { |_| App.stop! }

App.on("console.eval") do |ev|
  result = begin
    eval(ev["src"].to_s).inspect
  rescue => e
    "#{e.class}: #{e.message}"
  end
  Host.emit("console.result", "text" => result)
end

App.on("ping") { |ev| Host.emit("pong", "t" => ev["t"]) }

# Java asks for DevTools on the page currently shown (url). We find the WebView target and
# hand back the frontend URL pointing at our relay.
App.on("devtools.attach") do |ev|
  url = ev["url"].to_s
  relay = App.relay
  unless relay
    Host.emit("devtools.error", "text" => "relay not running")
    next
  end
  target = nil
  list = []
  5.times do
    list = DevTools.targets
    target = DevTools.find_target(list, url)
    break if target
    sleep 0.3
  end
  if target
    wk = target["devtoolsFrontendUrl"].to_s.start_with?("http") ? nil : DevTools.version["WebKit-Version"]
    fe = DevTools.frontend_url(target, relay.port, relay.token, wk)
    Host.log(:info, "attach #{target["id"]} (#{target["url"].to_s[0, 60]}) -> #{fe[0, 80]}…")
    Host.emit("devtools.open", "url" => fe, "target" => target["id"])
  else
    Host.emit("devtools.error", "text" => "no target for #{url}; #{list.size} targets: " + list.map { |t| t["url"].to_s[0, 40] }.join(" | "))
  end
end

App.on("devtools.list") do |_|
  DevTools.targets.each { |t| Host.log(:info, "target #{t["id"]} #{t["type"]} #{t["url"]} #{t["description"]}") }
  Host.log(:info, "relay connections: #{App.relay ? App.relay.connections : 'n/a'}")
end
