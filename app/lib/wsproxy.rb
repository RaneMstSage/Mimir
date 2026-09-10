# frozen_string_literal: true
require 'socket'

# Byte-level TCP relay in front of Chrome's forwarded DevTools port.
#
# Chrome rejects DevTools WebSocket upgrades that carry an Origin header unless the
# origin is allow-listed via --remote-allow-origins (impossible to set on Android). The
# real DevTools frontend runs in a browser tab and always sends Origin, so we sit in the
# middle: parse the client's HTTP upgrade request, drop the Origin header (and fix Host),
# then pipe bytes both ways untouched. WebSocket frames after the handshake are opaque.
class WsProxy
  attr_reader :listen_port

  def initialize(listen_port:, target_port:, host: '127.0.0.1')
    @listen_port, @target_port, @host = listen_port, target_port, host
  end

  def start
    @server = TCPServer.new(@host, @listen_port)
    @thread = Thread.new do
      loop do
        client = @server.accept
        Thread.new(client) { |c| handle(c) }
      rescue IOError, Errno::EBADF
        break
      rescue StandardError => e
        warn "wsproxy accept: #{e.message}"
      end
    end
    self
  end

  def stop
    @server&.close
  end

  private

  def read_head(sock)
    head = +''
    while (line = sock.gets)
      head << line
      break if line == "\r\n" || line == "\n"
    end
    head
  end

  def handle(client)
    head = read_head(client)
    return client.close if head.empty?
    lines = head.split(/\r?\n/)
    request_line = lines.shift
    headers = lines.reject { |l| l.strip.empty? || l =~ /\A(origin|host):/i }
    headers << "Host: localhost:#{@target_port}"
    upstream = TCPSocket.new(@host, @target_port)
    upstream.write("#{request_line}\r\n#{headers.join("\r\n")}\r\n\r\n")
    pump(client, upstream)
  rescue StandardError => e
    warn "wsproxy: #{e.class}: #{e.message}"
  ensure
    client.close rescue nil
    upstream&.close rescue nil
  end

  def pump(a, b)
    socks = [a, b]
    until socks.empty?
      ready, = IO.select(socks, nil, nil, 300)
      return unless ready
      ready.each do |s|
        other = s.equal?(a) ? b : a
        begin
          data = s.readpartial(65_536)
          other.write(data)
        rescue EOFError, IOError, SystemCallError
          return
        end
      end
    end
  end
end
