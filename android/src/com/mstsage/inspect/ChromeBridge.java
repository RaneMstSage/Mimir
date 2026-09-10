package com.mstsage.inspect;

import android.webkit.JavascriptInterface;

/**
 * `window.host` inside the chrome WebView. The Opal UI calls host.send(json) for every user
 * action; everything is forwarded to Ruby except a few purely visual requests the Activity
 * handles itself (chrome height).
 */
final class ChromeBridge {
    interface Local { boolean handleLocally(String ev, org.json.JSONObject o); }

    private final RubyRuntime ruby;
    private final Local local;

    ChromeBridge(RubyRuntime ruby, Local local) { this.ruby = ruby; this.local = local; }

    @JavascriptInterface
    public void send(String json) {
        try {
            org.json.JSONObject o = new org.json.JSONObject(json);
            String ev = o.optString("ev");
            if (local.handleLocally(ev, o)) return;
        } catch (Exception ignored) {}
        ruby.post(json);
    }
}
