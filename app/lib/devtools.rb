# frozen_string_literal: true
require 'net/http'
require 'json'
require 'uri'

# Client for the Chrome DevTools HTTP endpoints exposed through the adb forward.
class DevTools
  attr_reader :port, :ws_port

  # ws_port: the port the DevTools *frontend* should connect to (an Origin-stripping
  # relay); defaults to the raw forwarded port.
  def initialize(port = 9222, ws_port: nil)
    @port = port
    @ws_port = ws_port || port
  end

  def reachable?
    !version.nil?
  end

  def version
    get_json('/json/version')
  end

  def tabs
    (get_json('/json/list') || []).select { |t| t['type'] == 'page' }
  end

  def all_targets
    get_json('/json/list') || []
  end

  def new_tab(url = 'about:blank')
    request(:put, "/json/new?#{URI.encode_www_form_component(url)}")
  end

  def activate(id)
    request(:get, "/json/activate/#{id}")
  end

  def close(id)
    request(:get, "/json/close/#{id}")
  end

  # Full URL to the DevTools frontend for a tab. Chrome for Android normally hands back
  # an absolute https://chrome-devtools-frontend.appspot.com/... URL; older builds return a
  # relative /devtools/... path, which we make absolute against the forwarded port.
  def frontend_url(tab)
    u = tab['devtoolsFrontendUrl'].to_s
    return nil if u.empty?
    u = "http://localhost:#{port}#{u}" if u.start_with?('/')
    # Point the frontend's WebSocket at the relay instead of Chrome's raw port.
    u.sub(/ws=localhost:#{port}\//, "ws=localhost:#{ws_port}/")
  end

  private

  def get_json(path)
    body = request(:get, path)
    body && JSON.parse(body)
  rescue JSON::ParserError
    nil
  end

  def request(method, path)
    http = Net::HTTP.new('127.0.0.1', port)
    http.open_timeout = 2
    http.read_timeout = 4
    req = method == :put ? Net::HTTP::Put.new(path) : Net::HTTP::Get.new(path)
    # Chrome rejects DevTools HTTP requests whose Host is not localhost/IP (DNS-rebinding guard).
    req['Host'] = "localhost:#{port}"
    res = http.request(req)
    res.is_a?(Net::HTTPSuccess) ? res.body : nil
  rescue StandardError
    nil
  end
end
