package com.mstsage.inspect;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;
import android.util.Log;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.webkit.ConsoleMessage;
import android.webkit.CookieManager;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * View host. All browser logic lives in Ruby (ruby/lib/tabs.rb); this class forwards UI and
 * page events to Ruby and executes the commands Ruby sends back. It holds no decisions of its own.
 */
public class MainActivity extends Activity implements RubyRuntime.Listener {
    private static final String TAG = "Inspect";
    private static final String DESKTOP_UA =
            "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36";
    private static final String DEVTOOLS_CDN = "https://chrome-devtools-frontend.appspot.com";

    private final Handler main = new Handler(Looper.getMainLooper());
    private final RubyRuntime ruby = RubyRuntime.get();
    private final Map<Integer, WebView> tabs = new HashMap<>();
    private final Map<Integer, TextView> chips = new HashMap<>();
    private int currentTab = -1;

    private LinearLayout tabStrip;
    private HorizontalScrollView tabScroll;
    private EditText urlBar;
    private ProgressBar progress;
    private LinearLayout split;
    private FrameLayout pages;
    private View divider;
    private FrameLayout devtoolsContainer;
    private Button btnDevtools, btnDock, btnUa;
    private TextView statusView;
    private View rubyPane;
    private TextView rubyLog;
    private ScrollView rubyLogScroll;
    private EditText rubyInput;

    private WebView devtoolsView;
    private boolean devtoolsOpen = false;
    private boolean dockRight = true;
    private float devtoolsFraction = 0.45f;
    private boolean desktopUa = true;
    private int rubyRelayPort = -1;
    private DevToolsBridge fallbackBridge;

    // ------------------------------------------------------------------ lifecycle

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.main);

        tabStrip = findViewById(R.id.tab_strip);
        tabScroll = findViewById(R.id.tab_scroll);
        urlBar = findViewById(R.id.url);
        progress = findViewById(R.id.progress);
        split = findViewById(R.id.split);
        pages = findViewById(R.id.pages);
        divider = findViewById(R.id.divider);
        devtoolsContainer = findViewById(R.id.devtools_container);
        btnDevtools = findViewById(R.id.btn_devtools);
        btnDock = findViewById(R.id.btn_dock);
        btnUa = findViewById(R.id.btn_ua);
        statusView = findViewById(R.id.status);
        statusView.setOnLongClickListener(v -> { statusView.setVisibility(View.GONE); return true; });
        rubyPane = findViewById(R.id.ruby_pane);
        rubyLog = findViewById(R.id.ruby_log);
        rubyLogScroll = findViewById(R.id.ruby_log_scroll);
        rubyInput = findViewById(R.id.ruby_input);

        // Enable WebView's DevTools server for this process; Ruby's relay fronts it.
        WebView.setWebContentsDebuggingEnabled(true);

        // Toolbar -> events. No logic here.
        findViewById(R.id.btn_back).setOnClickListener(v -> ruby.event("nav.back", "tab", currentTab));
        findViewById(R.id.btn_fwd).setOnClickListener(v -> ruby.event("nav.forward", "tab", currentTab));
        findViewById(R.id.btn_reload).setOnClickListener(v -> ruby.event("nav.reload", "tab", currentTab));
        findViewById(R.id.btn_newtab).setOnClickListener(v -> ruby.event("tab.new"));
        btnDevtools.setOnClickListener(v -> ruby.event("devtools.toggle"));
        btnDevtools.setOnLongClickListener(v -> { ruby.event("devtools.list"); ruby.event("devtools.reattach"); return true; });
        btnDock.setOnClickListener(v -> ruby.event("dock.toggle"));
        btnUa.setOnClickListener(v -> ruby.event("ua.toggle"));
        findViewById(R.id.btn_ruby).setOnClickListener(v -> toggleRubyPane());
        findViewById(R.id.btn_ruby_clear).setOnClickListener(v -> rubyLog.setText(""));

        urlBar.setOnEditorActionListener((v, actionId, event) -> {
            boolean go = actionId == EditorInfo.IME_ACTION_GO
                    || (event != null && event.getKeyCode() == KeyEvent.KEYCODE_ENTER && event.getAction() == KeyEvent.ACTION_DOWN);
            if (!go) return false;
            ruby.event("navigate", "tab", currentTab, "text", urlBar.getText().toString());
            hideKeyboard();
            WebView w = tabs.get(currentTab);
            if (w != null) w.requestFocus();
            return true;
        });
        rubyInput.setOnEditorActionListener((v, actionId, event) -> {
            boolean send = actionId == EditorInfo.IME_ACTION_SEND
                    || (event != null && event.getKeyCode() == KeyEvent.KEYCODE_ENTER && event.getAction() == KeyEvent.ACTION_DOWN);
            if (!send) return false;
            String src = rubyInput.getText().toString().trim();
            if (src.isEmpty()) return true;
            appendRubyLog("rb› " + src);
            ruby.event("console.eval", "src", src);
            rubyInput.setText("");
            return true;
        });

        setupDivider();
        applyDock();

        String crash = InspectApp.takeLastCrash(this, InspectApp.CRASH_FILE);
        String ncrash = InspectApp.takeLastCrash(this, InspectApp.NATIVE_CRASH_FILE);
        if (crash != null || ncrash != null) {
            appendRubyLog("=== previous run crashed (copy also in Downloads) ===");
            if (crash != null) appendRubyLog(crash);
            if (ncrash != null) appendRubyLog(ncrash);
            if (rubyPane.getVisibility() != View.VISIBLE) toggleRubyPane();
            status("Previous run crashed — see Rb pane / Downloads/InspectElement-crash.txt");
        }

        ruby.setListener(this);
        final String startUrl = urlFromIntent(getIntent());
        main.post(() -> {
            ruby.start(this);
            ruby.event("ui.ready", "tabs", new JSONArray(new ArrayList<>(tabs.keySet())), "url", startUrl);
        });
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        String u = urlFromIntent(intent);
        if (u != null) ruby.event("intent.url", "url", u);
    }

    private String urlFromIntent(Intent i) {
        if (i == null) return null;
        if (Intent.ACTION_VIEW.equals(i.getAction()) && i.getData() != null) return i.getData().toString();
        if (Intent.ACTION_SEND.equals(i.getAction())) {
            String t = i.getStringExtra(Intent.EXTRA_TEXT);
            if (t != null) for (String w : t.split("\\s+")) if (w.startsWith("http")) return w;
        }
        return null;
    }

    @Override
    public void onBackPressed() {
        WebView w = tabs.get(currentTab);
        if (w != null && w.canGoBack()) w.goBack();
        else if (devtoolsOpen) ruby.event("devtools.toggle");
        else super.onBackPressed();
    }

    @Override
    protected void onDestroy() {
        ruby.setListener(null);
        if (fallbackBridge != null) fallbackBridge.stop();
        for (WebView w : tabs.values()) w.destroy();
        if (devtoolsView != null) devtoolsView.destroy();
        super.onDestroy();
    }

    // ------------------------------------------------------------------ commands from Ruby

    @Override
    public void onRubyCommand(JSONObject cmd) {
        String c = cmd.optString("cmd");
        try {
            switch (c) {
                case "tab.create": createTab(cmd.getInt("tab"), cmd.optString("url")); break;
                case "tab.show": showTab(cmd.getInt("tab")); break;
                case "tab.destroy": destroyTab(cmd.getInt("tab")); break;
                case "tab.load": { WebView w = tabs.get(cmd.getInt("tab")); if (w != null) w.loadUrl(cmd.optString("url")); break; }
                case "tab.back": { WebView w = tabs.get(cmd.getInt("tab")); if (w != null && w.canGoBack()) w.goBack(); break; }
                case "tab.forward": { WebView w = tabs.get(cmd.getInt("tab")); if (w != null && w.canGoForward()) w.goForward(); break; }
                case "tab.reload": { WebView w = tabs.get(cmd.getInt("tab")); if (w != null) w.reload(); break; }
                case "ua.set": setDesktopUa(cmd.optBoolean("desktop", true)); break;
                case "ui.state": renderState(cmd.getJSONObject("state")); break;
                case "devtools.dock": openDevtools(cmd.optString("side", "right"), (float) cmd.optDouble("fraction", 0.45)); break;
                case "devtools.open": {
                    String fe = cmd.optString("url");
                    status("target " + cmd.optString("target") + " -> " + fe);
                    if (devtoolsView != null) devtoolsView.loadUrl(fe);
                    break;
                }
                case "devtools.close": closeDevtools(); break;
                case "devtools.error": status("attach failed: " + cmd.optString("text")); break;
                case "bridge.ready":
                    rubyRelayPort = cmd.optInt("port", -1);
                    status("Ruby relay on 127.0.0.1:" + rubyRelayPort + " -> @webview_devtools_remote_" + Process.myPid());
                    break;
                case "bridge.fallback": startJavaBridgeFallback(cmd.optString("reason")); break;
                case "toast": toast(cmd.optString("text")); break;
                case "status": status(cmd.optString("text")); break;
                case "log": appendRubyLog("[" + cmd.optString("level") + "] " + cmd.optString("text")); break;
                case "console.result": appendRubyLog("=> " + cmd.optString("text")); break;
                case "ready": status("Ruby " + cmd.optString("ruby") + " ready (app " + cmd.optString("app") + ")"); break;
                case "fatal":
                    status("RUBY FATAL: " + cmd.optString("text"));
                    appendRubyLog("[FATAL] " + cmd.optString("text"));
                    if (rubyPane.getVisibility() != View.VISIBLE) toggleRubyPane();
                    break;
                default: appendRubyLog("? unknown command " + cmd); break;
            }
        } catch (Exception e) {
            Log.w(TAG, "command failed: " + cmd, e);
            appendRubyLog("command failed: " + cmd + " -> " + e);
        }
    }

    // ------------------------------------------------------------------ tabs (views only)

    private void createTab(final int id, String url) {
        if (tabs.containsKey(id)) return;
        WebView w = new WebView(this);
        configure(w);
        w.setWebViewClient(new PageClient(id));
        w.setWebChromeClient(new PageChrome(id));
        w.setLayoutParams(new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        w.setVisibility(View.GONE);
        pages.addView(w);
        tabs.put(id, w);

        TextView chip = new TextView(this);
        chip.setSingleLine(true);
        chip.setMaxWidth(dp(220));
        chip.setMinWidth(dp(100));
        chip.setPadding(dp(12), 0, dp(12), 0);
        chip.setGravity(android.view.Gravity.CENTER_VERTICAL);
        chip.setTextSize(13);
        chip.setText("New tab");
        chip.setOnClickListener(v -> ruby.event("tab.select", "tab", id));
        chip.setOnLongClickListener(v -> { ruby.event("tab.close", "tab", id); return true; });
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT);
        lp.setMargins(dp(2), dp(4), dp(2), 0);
        tabStrip.addView(chip, lp);
        chips.put(id, chip);

        if (url != null && !url.isEmpty()) w.loadUrl(url);
    }

    private void showTab(int id) {
        currentTab = id;
        for (Map.Entry<Integer, WebView> e : tabs.entrySet()) e.getValue().setVisibility(e.getKey() == id ? View.VISIBLE : View.GONE);
        TextView chip = chips.get(id);
        if (chip != null) tabScroll.post(() -> tabScroll.smoothScrollTo(chip.getLeft() - dp(40), 0));
    }

    private void destroyTab(int id) {
        WebView w = tabs.remove(id);
        if (w != null) { pages.removeView(w); w.destroy(); }
        TextView chip = chips.remove(id);
        if (chip != null) tabStrip.removeView(chip);
    }

    private void configure(WebView w) {
        WebSettings s = w.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setLoadWithOverviewMode(true);
        s.setUseWideViewPort(true);
        s.setBuiltInZoomControls(true);
        s.setDisplayZoomControls(false);
        s.setSupportMultipleWindows(false);
        s.setMediaPlaybackRequiresUserGesture(true);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE);
        s.setAllowFileAccess(false);
        if (desktopUa) s.setUserAgentString(DESKTOP_UA);
        CookieManager.getInstance().setAcceptThirdPartyCookies(w, true);
        w.setBackgroundColor(Color.WHITE);
    }

    private void setDesktopUa(boolean desktop) {
        desktopUa = desktop;
        for (WebView w : tabs.values()) w.getSettings().setUserAgentString(desktop ? DESKTOP_UA : null);
    }

    /** Render the Ruby-owned snapshot: chips, URL bar, progress, button labels. */
    private void renderState(JSONObject st) {
        JSONArray arr = st.optJSONArray("tabs");
        int current = st.optInt("current", -1);
        if (arr != null) {
            for (int i = 0; i < arr.length(); i++) {
                JSONObject t = arr.optJSONObject(i);
                if (t == null) continue;
                TextView chip = chips.get(t.optInt("id"));
                if (chip == null) continue;
                boolean on = t.optInt("id") == current;
                chip.setText(t.optString("title"));
                chip.setBackgroundColor(on ? 0xFF1e293b : 0xFF020617);
                chip.setTextColor(on ? 0xFFe2e8f0 : 0xFF94a3b8);
            }
        }
        if (!urlBar.hasFocus()) urlBar.setText(st.optString("url"));
        boolean loading = st.optBoolean("loading");
        progress.setVisibility(loading ? View.VISIBLE : View.GONE);
        progress.setProgress(st.optInt("progress"));
        boolean desktop = st.optBoolean("desktop", true);
        btnUa.setText(desktop ? "Desktop ✓" : "Mobile ✓");
        JSONObject dt = st.optJSONObject("devtools");
        if (dt != null) btnDevtools.setTextColor(dt.optBoolean("open") ? 0xFF22c55e : 0xFF38bdf8);
    }

    private final class PageClient extends WebViewClient {
        private final int id;
        PageClient(int id) { this.id = id; }
        @Override public void onPageStarted(WebView view, String url, Bitmap favicon) { ruby.event("page.started", "tab", id, "url", url); }
        @Override public void onPageFinished(WebView view, String url) { ruby.event("page.finished", "tab", id, "url", url); }
        @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest req) {
            Uri u = req.getUrl();
            String s = u.getScheme();
            if ("http".equals(s) || "https".equals(s)) return false;
            try { startActivity(new Intent(Intent.ACTION_VIEW, u)); } catch (Exception ignored) {}
            return true;
        }
    }

    private final class PageChrome extends WebChromeClient {
        private final int id;
        PageChrome(int id) { this.id = id; }
        @Override public void onProgressChanged(WebView view, int p) { ruby.event("page.progress", "tab", id, "p", p); }
        @Override public void onReceivedTitle(WebView view, String title) { ruby.event("page.title", "tab", id, "title", title == null ? "" : title); }
    }

    // ------------------------------------------------------------------ devtools pane (views only)

    private void openDevtools(String side, float fraction) {
        devtoolsOpen = true;
        dockRight = !"bottom".equals(side);
        devtoolsFraction = fraction;
        divider.setVisibility(View.VISIBLE);
        devtoolsContainer.setVisibility(View.VISIBLE);
        if (devtoolsView == null) {
            devtoolsView = new WebView(this);
            WebSettings s = devtoolsView.getSettings();
            s.setJavaScriptEnabled(true);
            s.setDomStorageEnabled(true);
            s.setDatabaseEnabled(true);
            s.setMixedContentMode(WebSettings.MIXED_CONTENT_ALWAYS_ALLOW);
            s.setUseWideViewPort(true);
            s.setLoadWithOverviewMode(false);
            s.setSupportZoom(false);
            devtoolsView.setBackgroundColor(0xFF202124);
            devtoolsView.setWebViewClient(new WebViewClient() {
                @Override public void onReceivedError(WebView v, WebResourceRequest r, WebResourceError err) {
                    if (r.isForMainFrame()) status("frontend load error: " + err.getDescription() + " " + r.getUrl());
                }
                @Override public void onReceivedHttpError(WebView v, WebResourceRequest r, WebResourceResponse resp) {
                    if (r.isForMainFrame()) status("frontend HTTP " + resp.getStatusCode() + " " + r.getUrl());
                }
                @Override public void onPageFinished(WebView v, String u) {
                    if (!u.startsWith(DEVTOOLS_CDN)) return;
                    status("frontend loaded");
                    // Persist DevTools prefs: no screencast preview (the page is right beside it), dark theme.
                    v.evaluateJavascript("(function(){try{var r='ok';"
                            + "if(localStorage.getItem('screencastEnabled')!=='false'){localStorage.setItem('screencastEnabled','false');r='reload';}"
                            + "if(!localStorage.getItem('uiTheme')){localStorage.setItem('uiTheme','\"dark\"');r='reload';}"
                            + "return r;}catch(e){return 'err:'+e;}})()", res -> { if (res != null && res.contains("reload")) v.reload(); });
                }
            });
            devtoolsView.setWebChromeClient(new WebChromeClient() {
                @Override public boolean onConsoleMessage(ConsoleMessage m) {
                    if (m.messageLevel() == ConsoleMessage.MessageLevel.ERROR) appendRubyLog("[devtools] " + m.message());
                    return true;
                }
            });
            devtoolsContainer.addView(devtoolsView, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        }
        applyDock();
    }

    private void closeDevtools() {
        devtoolsOpen = false;
        divider.setVisibility(View.GONE);
        devtoolsContainer.setVisibility(View.GONE);
        if (devtoolsView != null) devtoolsView.loadUrl("about:blank");
        applyDock();
    }

    private void startJavaBridgeFallback(String reason) {
        try {
            if (fallbackBridge == null) fallbackBridge = new DevToolsBridge(Process.myPid());
            int port = fallbackBridge.start();
            status("Ruby relay failed (" + reason + "); Java fallback relay on 127.0.0.1:" + port + " (tell Ruby: bridge.java_ready)");
            ruby.event("bridge.java_ready", "port", port);
        } catch (Exception e) {
            status("Ruby relay failed (" + reason + ") and Java fallback failed: " + e);
        }
    }

    // ------------------------------------------------------------------ layout

    private void applyDock() {
        split.setOrientation(dockRight ? LinearLayout.HORIZONTAL : LinearLayout.VERTICAL);
        btnDock.setText(dockRight ? "⇲" : "⇱");
        LinearLayout.LayoutParams pl, dl, vl;
        if (dockRight) {
            pl = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, devtoolsOpen ? 1f - devtoolsFraction : 1f);
            dl = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, devtoolsOpen ? devtoolsFraction : 0f);
            vl = new LinearLayout.LayoutParams(dp(8), ViewGroup.LayoutParams.MATCH_PARENT);
        } else {
            pl = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, devtoolsOpen ? 1f - devtoolsFraction : 1f);
            dl = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, devtoolsOpen ? devtoolsFraction : 0f);
            vl = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(8));
        }
        pages.setLayoutParams(pl);
        devtoolsContainer.setLayoutParams(dl);
        divider.setLayoutParams(vl);
        split.requestLayout();
    }

    private void setupDivider() {
        divider.setOnTouchListener((v, ev) -> {
            int a = ev.getAction();
            if (a == MotionEvent.ACTION_MOVE || a == MotionEvent.ACTION_DOWN) {
                float total = dockRight ? split.getWidth() : split.getHeight();
                float pos = dockRight ? ev.getRawX() - locX(split) : ev.getRawY() - locY(split);
                if (total > 0) {
                    devtoolsFraction = Math.max(0.15f, Math.min(0.85f, 1f - pos / total));
                    applyDock();
                }
                return true;
            }
            if (a == MotionEvent.ACTION_UP) { ruby.event("dock.fraction", "fraction", devtoolsFraction); return true; }
            return false;
        });
    }

    private static int locX(View v) { int[] l = new int[2]; v.getLocationOnScreen(l); return l[0]; }
    private static int locY(View v) { int[] l = new int[2]; v.getLocationOnScreen(l); return l[1]; }
    private int dp(int d) { return Math.round(d * getResources().getDisplayMetrics().density); }

    private void hideKeyboard() {
        InputMethodManager imm = (InputMethodManager) getSystemService(INPUT_METHOD_SERVICE);
        if (imm != null) imm.hideSoftInputFromWindow(urlBar.getWindowToken(), 0);
    }

    // ------------------------------------------------------------------ diagnostics

    private void toast(String s) { Toast.makeText(this, s, Toast.LENGTH_SHORT).show(); }

    private void status(String s) {
        Log.i(TAG, s);
        statusView.setText(s);
        statusView.setVisibility(View.VISIBLE);
    }

    private void toggleRubyPane() {
        boolean show = rubyPane.getVisibility() != View.VISIBLE;
        rubyPane.setVisibility(show ? View.VISIBLE : View.GONE);
        if (show) { rubyLog.setText(ruby.logText()); scrollRubyLog(); }
    }

    private void appendRubyLog(String line) { rubyLog.append(line + "\n"); scrollRubyLog(); }
    private void scrollRubyLog() { rubyLogScroll.post(() -> rubyLogScroll.fullScroll(View.FOCUS_DOWN)); }
}
