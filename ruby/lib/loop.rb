# Registry of handlers for the single select loop in App.run. A handler exposes
#   read_ios  -> Array<IO> it wants readability for
#   write_ios -> Array<IO> it wants writability for
#   on_readable(io) / on_writable(io)
#   close
# Handlers are removed by calling Loop.remove(handler) (usually from themselves).
module Loop
  @handlers = []

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
