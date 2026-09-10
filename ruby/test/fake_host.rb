# Stand-in for the native Inspect module so ruby/ logic runs under the plain mruby CLI.
module Inspect
  @emitted = []
  @events = []
  @r, @w = IO.pipe
  def self.emitted ; @emitted ; end
  def self.emit(json) ; @emitted << JSON.parse(json) ; end
  def self.log(level, msg) ; puts "  [log#{level}] #{msg}" if ENV_VERBOSE ; end
  def self.wake_fd ; @r.fileno ; end
  def self.next_event ; @events.shift ; end
  def self.push_event(h) ; @events << h.to_json ; @w.syswrite("x") ; end
  def self.pid ; 4242 ; end
  def self.version ; MRUBY_VERSION ; end
  def self.connect_abstract(name) ; raise "no abstract socket in tests: #{name}" ; end
  def self.listen_loopback(port = 0) ; raise "unused" ; end
  def self.set_nonblock(fd, on) ; end
end
ENV_VERBOSE = false
