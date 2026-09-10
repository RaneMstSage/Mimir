# Loopback TCP relay in front of the WebView DevTools abstract socket.
#
# Why: the DevTools frontend runs in a WebView and its WebSocket upgrade carries a browser
# Origin header, which Chromium rejects (--remote-allow-origins guard). We terminate the TCP
# connection, drop Origin, normalise Host, require a per-process random token in the path (so
# other apps on the device cannot drive our DevTools), then pipe bytes both ways.
#
# Everything is non-blocking and driven by the App select loop via Loop handlers.
class Relay
  MAX_HEAD  = 64 * 1024
  BACKLOG   = 1024 * 1024        # per-direction queued bytes before we stop reading
  CHUNK     = 65536

  attr_reader :port, :token

  def initialize
    @token = Util.random_token
    @server = TCPServer.new("127.0.0.1", 0)
    @port = Socket.unpack_sockaddr_in(@server.getsockname)[0]
    @server._setnonblock(true)
    @conns = []
    Loop.add(self)
  end

  def socket_name
    "webview_devtools_remote_#{Inspect.pid}"
  end

  # -- Loop handler (the listening socket) ---------------------------------------------------
  def read_ios  ; [@server] ; end
  def write_ios ; [] ; end
  def on_writable(_io) ; end

  def on_readable(_io)
    loop do
      client = begin
        @server.accept
      rescue Errno::EAGAIN, Errno::EWOULDBLOCK
        return
      end
      client._setnonblock(true)
      @conns << Loop.add(Conn.new(self, client))
    end
  end

  def forget(conn) ; @conns.delete(conn) ; end
  def connections  ; @conns.size ; end

  def close
    @conns.dup.each(&:close)
    @server.close rescue nil
  end

  # Rewrite the client's HTTP head: validate + strip the token from the request path, drop
  # Origin and Host, add our own Host. Returns the new head or nil if the token is missing.
  def rewrite_head(head)
    lines = head.split("\r\n")
    req = lines.shift.to_s
    parts = req.split(" ")
    return nil unless parts.size >= 2
    prefix = "/#{@token}/"
    return nil unless parts[1].start_with?(prefix)
    parts[1] = "/" + parts[1][prefix.size..-1]
    out = [parts.join(" ")]
    lines.each do |l|
      next if l.empty?
      h = Util.header(l)
      next if h && (h[0] == "origin" || h[0] == "host")
      out << l
    end
    out << "Host: 127.0.0.1:#{@port}"
    out.join("\r\n") + "\r\n\r\n"
  end

  # -- One relayed connection ----------------------------------------------------------------
  class Conn
    def initialize(relay, client)
      @relay = relay
      @client = client
      @upstream = nil
      @state = :head
      @head = ""
      @to_up = []      # chunks waiting to be written to upstream
      @to_client = []  # chunks waiting to be written to client
      @client_eof = false
      @up_eof = false
      @closed = false
    end

    def read_ios
      ios = []
      ios << @client   if !@client_eof && queued(@to_up) < BACKLOG
      ios << @upstream if @upstream && !@up_eof && queued(@to_client) < BACKLOG
      ios
    end

    def write_ios
      ios = []
      ios << @upstream if @upstream && !@to_up.empty?
      ios << @client   if !@to_client.empty?
      ios
    end

    def on_readable(io)
      if io.equal?(@client) then read_client
      elsif io.equal?(@upstream) then read_upstream
      end
    end

    def on_writable(io)
      if io.equal?(@upstream)
        flush(@upstream, @to_up)
        @upstream.shutdown(Socket::SHUT_WR) if @client_eof && @to_up.empty? && !@up_shut
        @up_shut = true if @client_eof && @to_up.empty?
      elsif io.equal?(@client)
        flush(@client, @to_client)
        @client.shutdown(Socket::SHUT_WR) if @up_eof && @to_client.empty? && !@client_shut
        @client_shut = true if @up_eof && @to_client.empty?
      end
      finish_if_done
    end

    def close
      return if @closed
      @closed = true
      @client.close rescue nil
      @upstream.close if @upstream rescue nil
      @relay.forget(self)
      Loop.remove(self)
    end

    private

    def queued(q) ; q.inject(0) { |s, c| s + c.size } ; end

    def read_client
      data = @client.sysread(CHUNK)
      if @state == :head
        @head << data
        raise "request head too large" if @head.size > MAX_HEAD
        sep = @head.index("\r\n\r\n")
        return unless sep
        rewritten = @relay.rewrite_head(@head[0, sep + 4])
        unless rewritten
          Host.log(:warn, "relay: rejected request without valid token")
          return close
        end
        rest = @head[(sep + 4)..-1].to_s
        connect_upstream
        @to_up << rewritten
        @to_up << rest unless rest.empty?
        @state = :piping
      else
        @to_up << data
      end
    rescue EOFError
      @client_eof = true
      if @upstream && @to_up.empty? && !@up_shut
        @upstream.shutdown(Socket::SHUT_WR) rescue nil
        @up_shut = true
      end
      finish_if_done
    rescue Errno::EAGAIN, Errno::EWOULDBLOCK
    rescue Errno::ECONNRESET, Errno::EPIPE, IOError
      close
    end

    def read_upstream
      @to_client << @upstream.sysread(CHUNK)
    rescue EOFError
      @up_eof = true
      if @to_client.empty? && !@client_shut
        @client.shutdown(Socket::SHUT_WR) rescue nil
        @client_shut = true
      end
      finish_if_done
    rescue Errno::EAGAIN, Errno::EWOULDBLOCK
    rescue Errno::ECONNRESET, Errno::EPIPE, IOError
      close
    end

    def connect_upstream
      fd = Inspect.connect_abstract(@relay.socket_name)
      @upstream = BasicSocket.for_fd(fd)
      @upstream._setnonblock(true)
    end

    def flush(io, queue)
      until queue.empty?
        chunk = queue[0]
        n = io.syswrite(chunk)
        if n >= chunk.size
          queue.shift
        else
          queue[0] = chunk[n..-1]
          return
        end
      end
    rescue Errno::EAGAIN, Errno::EWOULDBLOCK
    rescue Errno::ECONNRESET, Errno::EPIPE, IOError
      close
    end

    def finish_if_done
      return if @closed
      close if @client_eof && @up_eof && @to_up.empty? && @to_client.empty?
      close if @client_eof && @upstream.nil?
    end
  end
end
