# Registry of IO objects the main select loop should watch. Handlers are objects responding to
# #io, #want_write?, #on_readable, #on_writable. Filled in by the relay in Phase 2.
module Loop
  @handlers = []

  def self.add(h)    = @handlers << h
  def self.remove(h) = @handlers.delete(h)
  def self.readers   = @handlers.map(&:io)
  def self.writers   = @handlers.select(&:want_write?).map(&:io)

  def self.dispatch(readable, writable)
    @handlers.dup.each do |h|
      begin
        h.on_readable if readable && readable.include?(h.io)
        h.on_writable if writable && writable.include?(h.io)
      rescue => e
        Host.log(:error, "loop handler #{h.class}: #{e.class}: #{e.message}")
        (h.close rescue nil)
        remove(h)
      end
    end
  end
end
