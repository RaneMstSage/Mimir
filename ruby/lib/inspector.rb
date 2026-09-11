# "Inspect element": find the DOM node under a point and make the attached DevTools frontend
# reveal it — exactly what Chrome's context menu does internally. We ask the page target over CDP
# for the backend node id, then inject an Overlay.inspectNodeRequested event into the frontend's
# WebSocket stream through our relay.
module Inspector
  def self.reveal(css_x, css_y, attempts = 0)
    target_id = App.attached_target
    relay = App.relay
    conn = relay && target_id ? relay.frontend_conn_for(target_id) : nil
    if target_id.nil? || conn.nil? || !conn.piping?
      # DevTools may still be connecting (we may have just opened it); retry a few times.
      if attempts < 12
        Loop.after(0.5) { reveal(css_x, css_y, attempts + 1) }
      else
        Host.emit("status", "text" => "Inspect: DevTools is not attached to this tab")
      end
      return
    end
    node = Cdp.session(target_id) do |c|
      c.call("DOM.enable")
      c.call("DOM.getDocument", { "depth" => 0 })
      c.call("DOM.getNodeForLocation", { "x" => css_x.round, "y" => css_y.round, "includeUserAgentShadowDOM" => false })
    end
    backend_id = node["backendNodeId"]
    unless backend_id
      Host.emit("status", "text" => "Inspect: no element at that point")
      return
    end
    conn.inject_to_client({ "method" => "Overlay.inspectNodeRequested", "params" => { "backendNodeId" => backend_id } }.to_json)
    Host.log(:info, "inspect: revealed backendNodeId #{backend_id} at #{css_x.round},#{css_y.round}")
  rescue => e
    Host.emit("status", "text" => "Inspect failed: #{e.class}: #{e.message}")
  end
end
