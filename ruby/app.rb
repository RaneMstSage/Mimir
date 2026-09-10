# Inspect Element — Ruby side entry point (runs inside the APK on the dedicated ruby thread).
#
# App.run(boot_json) never returns until a "quit" event arrives. It owns the single event loop:
# IO.select over the native wake pipe (Java -> Ruby events) plus, later, the DevTools relay sockets.
module App
  VERSION = "0.2.0"

  @handlers = {}
  @running = false

  def self.on(event, &blk)
    @handlers[event] = blk
  end

  def self.run(boot_json)
    @boot = JSON.parse(boot_json.to_s) rescue {}
    @running = true
    wake = IO.for_fd(Inspect.wake_fd)
    Host.log(:info, "Ruby #{Inspect.version} up in pid #{Inspect.pid}; app #{VERSION}")
    Host.toast("Hello from mruby #{Inspect.version}")
    Host.emit("ready", "ruby" => Inspect.version, "app" => VERSION)

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
    e.backtrace.each { |l| Host.log(:error, "  #{l}") } if e.backtrace
  end

  def self.stop!
    @running = false
  end
end

App.on("quit") { |_| App.stop! }

App.on("console.eval") do |ev|
  src = ev["src"].to_s
  result = begin
    eval(src).inspect
  rescue => e
    "#{e.class}: #{e.message}"
  end
  Host.emit("console.result", "text" => result)
end

App.on("ping") { |ev| Host.emit("pong", "t" => ev["t"]) }
