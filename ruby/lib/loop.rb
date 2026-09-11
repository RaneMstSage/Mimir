# Registry of handlers for the single select loop in App.run. A handler exposes
#   read_ios  -> Array<IO> it wants readability for
#   write_ios -> Array<IO> it wants writability for
#   on_readable(io) / on_writable(io)
#   close
# Handlers are removed by calling Loop.remove(handler) (usually from themselves).
module Loop
  @handlers = []
  @timers = []      # [due_time, proc]

  # Run a block from the main loop after `seconds` (never blocks the relay).
  def self.after(seconds, &blk) ; @timers << [Time.now.to_f + seconds, blk] ; end

  def self.run_timers
    now = Time.now.to_f
    due, @timers = @timers.partition { |t, _| t <= now }
    due.each do |_, blk|
      begin
        blk.call
      rescue => e
        Host.log(:error, "timer: #{e.class}: #{e.message}")
      end
    end
  end

  def self.next_timeout(default)
    return default if @timers.empty?
    [[@timers.map(&:first).min - Time.now.to_f, 0.01].max, default].min
  end

  def self.add(h)    ; @handlers << h ; h ; end
  def self.remove(h) ; @handlers.delete(h) ; end
  def self.handlers  ; @handlers ; end
  def self.readers   ; @handlers.flat_map(&:read_ios) ; end
  def self.writers   ; @handlers.flat_map(&:write_ios) ; end

  def self.dispatch(readable, writable)
    readable ||= []
    writable ||= []
    @handlers.dup.each do |h|
      begin
        (h.read_ios & readable).each { |io| h.on_readable(io) }
        next unless @handlers.include?(h)
        (h.write_ios & writable).each { |io| h.on_writable(io) }
      rescue => e
        Host.log(:error, "loop handler #{h.class}: #{e.class}: #{e.message}")
        (h.close rescue nil)
        remove(h)
      end
    end
  end
end
