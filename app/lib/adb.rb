# frozen_string_literal: true
require 'open3'
require 'socket'
require 'json'
require 'fileutils'
require 'timeout'

# Thin wrapper around the adb binary plus the on-device tricks needed to make
# adb-in-Termux talk to the tablet it is running on (Wireless debugging over loopback).
module Adb
  STATE_DIR   = File.join(Dir.home, '.config', 'inspectelement')
  STATE_FILE  = File.join(STATE_DIR, 'state.json')
  HOST        = '127.0.0.1'
  # adbd binds an ephemeral port for Wireless debugging; Android's ip_local_port_range.
  SCAN_RANGE  = (32768..60999)
  CHROME_SOCKET = 'chrome_devtools_remote'
  BASE_LOCAL_PORT = 9222

  Result = Struct.new(:ok, :out, :status, keyword_init: true)

  module_function

  # ---- low level -----------------------------------------------------------

  def run(*args, timeout: 20)
    out = +''
    status = nil
    Open3.popen2e('adb', *args.map(&:to_s)) do |_i, oe, thr|
      begin
        Timeout.timeout(timeout) { out << oe.read }
      rescue Timeout::Error
        Process.kill('TERM', thr.pid) rescue nil
        out << "\n[timeout after #{timeout}s]"
      end
      status = thr.value
    end
    Result.new(ok: status&.success? || false, out: out.strip, status: status&.exitstatus)
  rescue Errno::ENOENT
    Result.new(ok: false, out: 'adb binary not found (pkg install android-tools)', status: 127)
  end

  def getprop(name)
    out, = Open3.capture2('getprop', name)
    out.strip
  rescue StandardError
    ''
  end

  # Wireless debugging (and USB debugging) start adbd; Termux may read this prop.
  def adbd_running?
    getprop('init.svc.adbd') == 'running'
  end

  # ---- state ---------------------------------------------------------------

  def state
    JSON.parse(File.read(STATE_FILE))
  rescue StandardError
    {}
  end

  def save_state(h)
    merged = state.merge(h)
    FileUtils.mkdir_p(STATE_DIR)
    File.write(STATE_FILE, JSON.pretty_generate(merged))
    merged
  end

  # ---- discovery -----------------------------------------------------------

  # Fast non-blocking connect scan of loopback. Closed ports refuse instantly, so
  # each batch finishes as soon as every socket has an answer (or the deadline).
  def scan_ports(range = SCAN_RANGE, batch: 512, wait: 0.25)
    open = []
    range.each_slice(batch) do |ports|
      pending = {}
      ports.each do |p|
        s = Socket.new(:INET, :STREAM)
        begin
          s.connect_nonblock(Socket.sockaddr_in(p, HOST))
          open << p; s.close
        rescue IO::WaitWritable
          pending[s] = p
        rescue SystemCallError
          s.close
        end
      end
      deadline = Time.now + wait
      until pending.empty? || (left = deadline - Time.now) <= 0
        _r, w, = IO.select(nil, pending.keys, nil, left)
        break unless w
        w.each do |s|
          p = pending.delete(s)
          begin
            s.connect_nonblock(Socket.sockaddr_in(p, HOST))
            open << p
          rescue Errno::EISCONN
            open << p
          rescue SystemCallError
            # refused / reset
          end
          s.close
        end
      end
      pending.each_key(&:close)
    end
    open.sort
  end

  # Try `adb connect` against each candidate; the Wireless-debugging connect port
  # answers either "connected"/"already connected" or an auth failure (not paired yet).
  def identify_adb_port(candidates)
    candidates.each do |p|
      r = run('connect', "#{HOST}:#{p}", timeout: 8)
      return [p, :connected] if r.out =~ /(already )?connected to/i
      # Unpaired TLS port: adb reports a bare "failed to connect to host:port" with no
      # reason. Ordinary closed/other ports add a reason ("...: Connection refused").
      return [p, :unpaired]  if r.out =~ /failed to authenticate/i || r.out =~ /failed to connect to #{Regexp.escape(HOST)}:#{p}\s*\z/i
      run('disconnect', "#{HOST}:#{p}", timeout: 5)
    end
    nil
  end

  # Returns [port, status] where status is :connected or :unpaired, or nil.
  def find_wireless_port
    if (last = state['adb_port'])
      res = identify_adb_port([last])
      return res if res
    end
    res = identify_adb_port(scan_ports)
    save_state('adb_port' => res[0]) if res
    res
  end

  # ---- devices -------------------------------------------------------------

  def devices
    r = run('devices', '-l', timeout: 10)
    r.out.lines.drop(1).filter_map do |l|
      next if l.strip.empty?
      serial, st, *rest = l.split
      { serial: serial, state: st, info: rest.join(' ') }
    end
  end

  def local_device
    devices.find { |d| d[:serial].start_with?(HOST, 'localhost') && d[:state] == 'device' }
  end

  def connected?
    !local_device.nil?
  end

  def pair(port, code)
    r = run('pair', "#{HOST}:#{port}", code.to_s, timeout: 30)
    ok = r.out =~ /Successfully paired/i ? true : false
    save_state('paired' => true) if ok
    Result.new(ok: ok, out: r.out, status: r.status)
  end

  # Pair knowing only the code: the pairing dialog opens a fresh listener, so try every
  # open loopback port that is not the known connect port. Non-pairing ports answer with a
  # protocol fault quickly. Returns Result; out includes which port worked.
  def pair_by_code(code)
    known = state['adb_port']
    tried = []
    candidates = scan_ports.reject { |p| p == known }
    candidates.each do |p|
      r = run('pair', "#{HOST}:#{p}", code.to_s, timeout: 12)
      tried << p
      if r.out =~ /Successfully paired/i
        save_state('paired' => true, 'pair_port' => p)
        return Result.new(ok: true, out: "#{r.out} (port #{p})", status: 0)
      end
      return Result.new(ok: false, out: r.out, status: r.status) if r.out =~ /wrong code|incorrect|failed to pair/i
    end
    Result.new(ok: false, out: "No pairing service found on localhost (tried #{tried.size} ports). Is the pairing dialog still open?", status: 1)
  end

  def connect(port)
    r = run('connect', "#{HOST}:#{port}", timeout: 15)
    ok = r.out =~ /(already )?connected to/i ? true : false
    save_state('adb_port' => port.to_i) if ok
    Result.new(ok: ok, out: r.out, status: r.status)
  end

  def disconnect_all
    run('disconnect', timeout: 5)
  end

  # ---- devtools sockets & forwards ----------------------------------------

  # All Chromium-style DevTools sockets visible to the shell user, e.g.
  # chrome_devtools_remote, webview_devtools_remote_1234, Terrace_devtools_remote (Samsung Internet)
  def devtools_sockets
    d = local_device or return []
    r = run('-s', d[:serial], 'shell', 'cat /proc/net/unix', timeout: 10)
    r.out.scan(/@([A-Za-z0-9_.\-]*devtools_remote[A-Za-z0-9_.\-]*)/).flatten.uniq
  end

  def forwards
    d = local_device or return {}
    r = run('-s', d[:serial], 'forward', '--list', timeout: 10)
    r.out.lines.each_with_object({}) do |l, h|
      _serial, local, remote = l.split
      next unless local && remote
      h[remote.sub('localabstract:', '')] = local.sub('tcp:', '').to_i
    end
  end

  def forward(socket_name, local_port)
    d = local_device or return Result.new(ok: false, out: 'no adb device connected')
    r = run('-s', d[:serial], 'forward', "tcp:#{local_port}", "localabstract:#{socket_name}", timeout: 10)
    Result.new(ok: r.ok, out: r.out, status: r.status)
  end

  # Ensure every visible devtools socket has a stable local forward; chrome gets 9222.
  # Returns { socket_name => local_port }.
  def ensure_forwards
    socks = devtools_sockets
    current = forwards
    used = current.values
    next_port = BASE_LOCAL_PORT + 1
    socks.each do |s|
      next if current[s]
      port = if s == CHROME_SOCKET
               BASE_LOCAL_PORT
             else
               next_port += 1 while used.include?(next_port) || next_port == BASE_LOCAL_PORT
               next_port
             end
      forward(s, port)
      current[s] = port
      used << port
    end
    current.select { |k, _| socks.include?(k) }
  end

  # ---- orchestration -------------------------------------------------------

  # One call that tries to get from "nothing" to "Chrome forwarded". Returns a status hash.
  def auto_connect
    log = []
    unless adbd_running?
      return { ok: false, stage: :adbd_off, log: ['adbd is not running: turn on Wireless debugging in Developer options'] }
    end
    unless connected?
      res = find_wireless_port
      if res.nil?
        return { ok: false, stage: :no_port, log: ['Could not find the Wireless debugging port on localhost'] }
      end
      port, st = res
      log << "adb port #{port}: #{st}"
      return { ok: false, stage: :unpaired, port: port, log: log } if st == :unpaired
    end
    fw = ensure_forwards
    log << "forwards: #{fw.inspect}"
    if fw[CHROME_SOCKET]
      { ok: true, stage: :ready, forwards: fw, log: log }
    else
      { ok: false, stage: :no_chrome, forwards: fw, log: log + ['Chrome DevTools socket not found. Is Chrome open, and is USB debugging on?'] }
    end
  end

  def open_developer_settings
    system('am', 'start', '-a', 'android.settings.APPLICATION_DEVELOPMENT_SETTINGS', out: File::NULL, err: File::NULL)
  end

  def open_wireless_debugging_settings
    ok = system('am', 'start', '-n', 'com.android.settings/.Settings$WirelessDebuggingActivity', out: File::NULL, err: File::NULL)
    ok || open_developer_settings
  end
end
