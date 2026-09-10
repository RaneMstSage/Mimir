package com.mstsage.inspect;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;

/** Small blocking client for the DevTools HTTP endpoints reachable through the bridge. */
public final class DevToolsClient {
    public static final String CDN = "https://chrome-devtools-frontend.appspot.com/serve_rev/";
    private final int port;

    public DevToolsClient(int port) { this.port = port; }

    public String get(String path) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL("http://127.0.0.1:" + port + path).openConnection();
        c.setConnectTimeout(2000);
        c.setReadTimeout(4000);
        c.setRequestProperty("Host", "127.0.0.1:" + port);
        try (BufferedReader r = new BufferedReader(new InputStreamReader(c.getInputStream(), "UTF-8"))) {
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = r.readLine()) != null) sb.append(line).append('\n');
            return sb.toString();
        } finally {
            c.disconnect();
        }
    }

    public JSONArray list() throws Exception { return new JSONArray(get("/json/list")); }

    public JSONObject version() throws Exception { return new JSONObject(get("/json/version")); }

    /**
     * Find the page target for a given WebView URL. WebView's /json entries carry a
     * "description" JSON with visible/attached flags; we prefer visible, unattached ones.
     */
    public JSONObject findTarget(String url, String excludeUrlPrefix) throws Exception {
        JSONArray arr = list();
        JSONObject best = null;
        int bestScore = -1;
        for (int i = 0; i < arr.length(); i++) {
            JSONObject t = arr.getJSONObject(i);
            if (!"page".equals(t.optString("type"))) continue;
            String u = t.optString("url");
            if (excludeUrlPrefix != null && u.startsWith(excludeUrlPrefix)) continue;
            int score = 0;
            if (url != null && url.equals(u)) score += 4;
            try {
                JSONObject d = new JSONObject(t.optString("description", "{}"));
                if (d.optBoolean("visible")) score += 2;
                if (!d.optBoolean("attached")) score += 1;
            } catch (Exception ignored) {}
            if (score > bestScore) { bestScore = score; best = t; }
        }
        return best;
    }

    /** Frontend URL for a target, with the websocket pointed at the bridge. */
    public String frontendUrl(JSONObject target) throws Exception {
        String id = target.getString("id");
        String ws = "127.0.0.1:" + port + "/devtools/page/" + id;
        String u = target.optString("devtoolsFrontendUrl", "");
        if (u.startsWith("http")) {
            // Replace whatever ws= host the server echoed with the bridge address.
            return u.replaceAll("ws=[^&/]+/", "ws=" + ws.substring(0, ws.indexOf('/') + 1));
        }
        // Relative or missing: build the CDN URL from the WebKit revision hash.
        String wk = version().optString("WebKit-Version", "");
        int at = wk.indexOf('@');
        String rev = at >= 0 ? wk.substring(at + 1).replace(")", "").trim() : "";
        return CDN + "@" + rev + "/inspector.html?ws=" + ws;
    }
}
