# frozen_string_literal: true
require 'sinatra'
require 'json'
require_relative 'lib/adb'
require_relative 'lib/devtools'
require_relative 'lib/wsproxy'

PORT = (ENV['INSPECT_PORT'] || 8765).to_i

set :server, 'webrick'
set :bind, '127.0.0.1'
set :port, PORT
set :public_folder, File.join(__dir__, 'public')
set :views, File.join(__dir__, 'views')
set :show_exceptions, false
set :logging, true

WS_PORT = (ENV['INSPECT_WS_PORT'] || 9229).to_i   # Origin-stripping relay in front of 9222
CHROME = DevTools.new(Adb::BASE_LOCAL_PORT, ws_port: WS_PORT)
WSPROXY = WsProxy.new(listen_port: WS_PORT, target_port: Adb::BASE_LOCAL_PORT).start
MUTEX  = Mutex.new   # adb calls are not reentrant-friendly; serialize them

helpers do
  def json(obj, status: 200)
    content_type :json
    halt status, JSON.generate(obj)
  end

  def body_json
    (request.body.rewind rescue nil)
    JSON.parse(request.body.read.to_s) rescue {}
  end

  def status_report
    MUTEX.synchronize do
      adbd   = Adb.adbd_running?
      dev    = adbd ? Adb.local_device : nil
      fw     = dev ? Adb.forwards : {}
      chrome = fw[Adb::CHROME_SOCKET] ? CHROME.reachable? : false
      {
        adbd_running: adbd,
        adb_connected: !dev.nil?,
        adb_serial: dev && dev[:serial],
        adb_port: Adb.state['adb_port'],
        paired: Adb.state['paired'] || false,
        forwards: fw,
        chrome_reachable: chrome,
        chrome_version: chrome ? CHROME.version : nil,
        ready: chrome
      }
    end
  end
end

# ---------------- pages ----------------

get '/' do
  erb :index
end

get '/setup' do
  erb :setup
end

# Opens the DevTools frontend for a tab (used as a plain link so it can open in a new window).
get '/inspect/:id' do
  tab = CHROME.tabs.find { |t| t['id'] == params[:id] }
  halt 404, 'tab not found (was it closed?)' unless tab
  url = CHROME.frontend_url(tab)
  halt 500, 'Chrome did not provide a DevTools frontend URL for this tab' unless url
  redirect url
end

# ---------------- JSON API ----------------

get '/api/status' do
  json status_report
end

get '/api/tabs' do
  tabs = CHROME.tabs.map do |t|
    { id: t['id'], title: t['title'], url: t['url'], favicon: t['faviconUrl'],
      inspect: "/inspect/#{t['id']}", frontend: CHROME.frontend_url(t) }
  end
  json tabs
end

post '/api/tabs' do
  url = body_json['url'].to_s
  url = 'about:blank' if url.empty?
  url = "https://#{url}" unless url =~ %r{\A[a-z]+:}i
  CHROME.new_tab(url)
  json ok: true
end

post '/api/tabs/:id/activate' do
  CHROME.activate(params[:id]); json ok: true
end

post '/api/tabs/:id/close' do
  CHROME.close(params[:id]); json ok: true
end

# Other Chromium DevTools sockets (WebViews, Samsung Internet...), each on its own local port.
get '/api/browsers' do
  MUTEX.synchronize do
    fw = Adb.connected? ? Adb.ensure_forwards : {}
    list = fw.map do |sock, port|
      dt = DevTools.new(port)
      v = dt.version
      { socket: sock, port: port, browser: v && v['Browser'], tabs: v ? dt.tabs.size : 0 }
    end
    json list
  end
end

# Tabs of a non-default browser socket
get '/api/browsers/:port/tabs' do
  dt = DevTools.new(params[:port].to_i)
  json dt.tabs.map { |t| { id: t['id'], title: t['title'], url: t['url'], frontend: dt.frontend_url(t) } }
end

post '/api/connect' do
  MUTEX.synchronize do
    port = body_json['port']
    if port.to_s.empty?
      json Adb.auto_connect
    else
      r = Adb.connect(port.to_i)
      Adb.ensure_forwards if r.ok
      json ok: r.ok, out: r.out
    end
  end
end

post '/api/pair' do
  b = body_json
  port, code = b['port'].to_s.strip, b['code'].to_s.strip
  json({ ok: false, out: 'the 6-digit pairing code is required' }, status: 400) if code.empty?
  MUTEX.synchronize do
    r = port.empty? ? Adb.pair_by_code(code) : Adb.pair(port, code)
    res = { ok: r.ok, out: r.out }
    if r.ok
      # After pairing, connect through whichever port we can find.
      res[:connect] = Adb.auto_connect
    end
    json res
  end
end

post '/api/scan' do
  MUTEX.synchronize { json ports: Adb.scan_ports }
end

post '/api/disconnect' do
  MUTEX.synchronize { Adb.disconnect_all }
  json ok: true
end

post '/api/open/dev-settings' do
  json ok: Adb.open_developer_settings
end

post '/api/open/wireless-debugging' do
  json ok: Adb.open_wireless_debugging_settings
end

error do
  content_type :json
  { error: env['sinatra.error'].message }.to_json
end
