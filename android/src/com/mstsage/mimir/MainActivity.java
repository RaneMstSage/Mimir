package com.mstsage.mimir;

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
    private int currentTab = -1;

    private WebView chrome;                 // the Opal-rendered browser chrome (ui/)
    private View chromeSpace;               // reserves the chrome's collapsed height in the column
    private boolean chromeReady = false;
    private String pendingState = null;
    private LinearLayout split;
    private FrameLayout pages;
    private View divider;
    private FrameLayout devtoolsContainer;
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
    private String devtoolsTheme = "dark";
    private boolean devtoolsScreencast = false;
    private DevToolsBridge fallbackBridge;
    private final Support support = Support.create();

    // ------------------------------------------------------------------ lifecycle

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.main);
        // Targeting API 35+ draws edge-to-edge; keep our chrome clear of the status/navigation bars and cutouts.
        final View root = findViewById(android.R.id.content);
        root.setOnApplyWindowInsetsListener((v, insets) -> {
            android.graphics.Insets bars = insets.getInsets(android.view.WindowInsets.Type.systemBars() | android.view.WindowInsets.Type.displayCutout());
            v.setPadding(bars.left, bars.top, bars.right, bars.bottom);
            return android.view.WindowInsets.CONSUMED;
        });
        root.setBackgroundColor(0xFF020617);

        chrome = findViewById(R.id.chrome);
        chromeSpace = findViewById(R.id.chrome_space);
        split = findViewById(R.id.split);
        pages = findViewById(R.id.pages);
        divider = findViewById(R.id.divider);
        devtoolsContainer = findViewById(R.id.devtools_container);
        statusView = findViewById(R.id.status);
        statusView.setOnLongClickListener(v -> { toggleRubyPane(); return true; });   // escape hatch if the chrome fails
        statusView.setOnClickListener(v -> statusView.setVisibility(View.GONE));
        rubyPane = findViewById(R.id.ruby_pane);
        rubyLog = findViewById(R.id.ruby_log);
        rubyLogScroll = findViewById(R.id.ruby_log_scroll);
        rubyInput = findViewById(R.id.ruby_input);
        findViewById(R.id.btn_ruby_clear).setOnClickListener(v -> rubyLog.setText(""));

        // Enable WebView's DevTools server for this process; Ruby's relay fronts it.
        WebView.setWebContentsDebuggingEnabled(true);
        setupChrome();

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

        String crash = MimirApp.takeLastCrash(this, MimirApp.CRASH_FILE);
        String ncrash = MimirApp.takeLastCrash(this, MimirApp.NATIVE_CRASH_FILE);
        if (crash != null || ncrash != null) {
            appendRubyLog("=== previous run crashed (copy also in Downloads) ===");
            if (crash != null) appendRubyLog(crash);
            if (ncrash != null) appendRubyLog(ncrash);
            if (rubyPane.getVisibility() != View.VISIBLE) toggleRubyPane();
            status("Previous run crashed — see Rb pane / Downloads/Mimir-crash.txt");
        }

        ruby.setListener(this);
        support.connect(this, ruby);
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
                    android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT, this::handleBack);
        }
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
    public boolean dispatchKeyEvent(KeyEvent event) {
        int kc = event.getKeyCode();
        boolean mouse = (event.getSource() & android.view.InputDevice.SOURCE_MOUSE) == android.view.InputDevice.SOURCE_MOUSE;
        if (event.getAction() == KeyEvent.ACTION_DOWN && (kc == KeyEvent.KEYCODE_BACK || kc == KeyEvent.KEYCODE_FORWARD)) {
            ruby.appendLog("[key] " + KeyEvent.keyCodeToString(kc) + " src=" + event.getSource() + " mouse=" + mouse);
        }
        if (event.getAction() == KeyEvent.ACTION_DOWN) {
            WebView w = tabs.get(currentTab);
            if (kc == KeyEvent.KEYCODE_FORWARD && w != null) { if (w.canGoForward()) w.goForward(); return true; }
            if (kc == KeyEvent.KEYCODE_BACK && mouse && w != null && w.canGoBack()) { w.goBack(); return true; }
        }
        return super.dispatchKeyEvent(event);
    }

    @Override
    public boolean dispatchGenericMotionEvent(MotionEvent ev) {
        if (ev.getActionMasked() == MotionEvent.ACTION_BUTTON_PRESS) {
            int b = ev.getActionButton();
            ruby.appendLog("[mouse-activity] button=" + b + " src=" + ev.getSource());
            WebView w = tabs.get(currentTab);
            if (w != null) {
                if (b == MotionEvent.BUTTON_BACK)    { if (w.canGoBack()) w.goBack(); return true; }
                if (b == MotionEvent.BUTTON_FORWARD) { if (w.canGoForward()) w.goForward(); return true; }
            }
        }
        return super.dispatchGenericMotionEvent(ev);
    }

    private long lastBackMs = 0;

    /** Single back handler for the mouse back button, the gesture, and older key-based back.
     *  Debounced: some devices deliver one press through several channels at once. */
    private void handleBack() {
        long now = android.os.SystemClock.uptimeMillis();
        if (now - lastBackMs < 350) return;
        lastBackMs = now;
        WebView w = tabs.get(currentTab);
        if (w != null && w.canGoBack()) { w.goBack(); return; }
        if (devtoolsOpen) { ruby.event("devtools.toggle"); return; }
        moveTaskToBack(true);   // at a tab's first page: background gracefully, don't close
    }

    @Override
    public void onBackPressed() {
        // On SDK 33+ the OnBackInvokedDispatcher callback handles back; don't run it twice here.
        if (android.os.Build.VERSION.SDK_INT < 33) handleBack();
        else super.onBackPressed();
    }

    @Override
    protected void onDestroy() {
        ruby.setListener(null);
        support.destroy();
        if (fallbackBridge != null) fallbackBridge.stop();
        for (WebView w : tabs.values()) w.destroy();
        if (devtoolsView != null) devtoolsView.destroy();
        chrome.destroy();
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
                case "prefs.apply": applyPrefs(cmd); break;
                case "tab.inject": { WebView w = tabs.get(cmd.getInt("tab")); if (w != null) w.evaluateJavascript(cmd.optString("js"), null); break; }
                case "block.rules": setBlockRules(cmd.optJSONArray("patterns")); break;
                case "fetch": fetchForRuby(cmd.optString("url"), cmd.optString("purpose")); break;
                case "billing.query": support.query(); break;
                case "billing.buy": support.buy(this, cmd.optString("product")); break;
                case "devtools.prefs": devtoolsTheme = cmd.optString("theme", "dark"); devtoolsScreencast = cmd.optBoolean("screencast", false); break;
                case "data.clear": clearData(cmd); break;
                case "ui.state": renderState(cmd.getJSONObject("state")); break;
                case "ui.context": chrome.evaluateJavascript("window.UI && UI.context(" + JSONObject.quote(cmd.toString()) + ")", null); break;
                case "tab.stop": { WebView w = tabs.get(cmd.getInt("tab")); if (w != null) w.stopLoading(); break; }
                case "clipboard.set": copyToClipboard(cmd.optString("label", "Mímir"), cmd.optString("text")); toast("Copied"); break;
                case "tab.paste": {
                    WebView w = tabs.get(cmd.getInt("tab"));
                    android.content.ClipboardManager cm = (android.content.ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
                    if (w != null && cm != null && cm.hasPrimaryClip() && cm.getPrimaryClip().getItemCount() > 0) {
                        CharSequence txt = cm.getPrimaryClip().getItemAt(0).coerceToText(this);
                        w.evaluateJavascript("document.execCommand('insertText', false, " + JSONObject.quote(String.valueOf(txt)) + ")", null);
                    }
                    break;
                }
                case "tab.selection": {   // ask the page for its selected text; Ruby gets it back as an event
                    final WebView w = tabs.get(cmd.getInt("tab")); final String purpose = cmd.optString("purpose");
                    if (w != null) w.evaluateJavascript("String(window.getSelection())", r -> ruby.event("page.selection", "tab", cmd.optInt("tab"), "text", r == null ? "" : r.replaceAll("^\"|\"$", ""), "purpose", purpose));
                    break;
                }
                case "dev.toggle": toggleRubyPane(); break;
                case "devtools.dock": openDevtools(cmd.optString("side", "right"), (float) cmd.optDouble("fraction", 0.45)); break;
                case "devtools.inspect": enterInspectMode((float) cmd.optDouble("x", 0), (float) cmd.optDouble("y", 0)); break;
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

    // ------------------------------------------------------------------ chrome (Opal UI)

    private void setupChrome() {
        WebSettings cs = chrome.getSettings();
        cs.setJavaScriptEnabled(true);
        cs.setDomStorageEnabled(true);
        cs.setAllowFileAccess(true);           // file:///android_asset/ui/*
        cs.setSupportZoom(false);
        cs.setTextZoom(100);
        chrome.setBackgroundColor(Color.TRANSPARENT);   // page shows through below the toolbar when expanded
        chrome.setOverScrollMode(View.OVER_SCROLL_NEVER);
        chrome.setVerticalScrollBarEnabled(false);
        chrome.addJavascriptInterface(new ChromeBridge(ruby, (ev, o) -> {
            if ("chrome.height".equals(ev)) { main.post(() -> setChromeHeight(o.optInt("dp", 80), o.optBoolean("expand", false))); return true; }
            if ("ui.debug".equals(ev)) { main.post(() -> { status(o.optString("text")); appendRubyLog("[chrome-ui] " + o.optString("text")); }); return true; }
            if ("ui.error".equals(ev)) {
                main.post(() -> { status("UI error: " + o.optString("text")); appendRubyLog("[chrome-ui] " + o.optString("text") + "\n    " + o.optString("bt")); });
                return true;
            }
            if ("chrome.ready".equals(ev)) { main.post(() -> { chromeReady = true; if (pendingState != null) pushState(pendingState); }); return false; }
            return false;
        }), "host");
        chrome.setWebChromeClient(new WebChromeClient() {
            @Override public boolean onConsoleMessage(ConsoleMessage m) {
                if (m.messageLevel() == ConsoleMessage.MessageLevel.ERROR) {
                    appendRubyLog("[chrome-ui] " + m.message() + " (" + m.lineNumber() + ")");
                    status("UI console: " + m.message());
                }
                return true;
            }
        });
        chrome.setWebViewClient(new WebViewClient());
        chrome.loadUrl("file:///android_asset/ui/ui.html");
    }

    /**
     * dp: collapsed chrome height (tabs + toolbar [+ bookmarks bar]); the spacer in the column
     * takes this so the page starts below it. expand: a dropdown or full page is open, so the
     * transparent chrome WebView grows to cover the window and shrinks back afterwards.
     */
    private void setChromeHeight(int dp, boolean expand) {
        if (dp >= 0) {
            ViewGroup.LayoutParams sp = chromeSpace.getLayoutParams();
            if (sp.height != dp(dp)) { sp.height = dp(dp); chromeSpace.setLayoutParams(sp); }
        }
        ViewGroup.LayoutParams lp = chrome.getLayoutParams();
        int px = expand || dp < 0 ? ViewGroup.LayoutParams.MATCH_PARENT : dp(dp);
        if (lp.height != px) {
            lp.height = px;
            chrome.setLayoutParams(lp);
            // The WebView does not reliably repaint newly exposed area after a resize; nudge it
            // after the layout pass and again after the content has had a frame to reflow.
            chrome.post(() -> { chrome.requestLayout(); chrome.invalidate(); chrome.evaluateJavascript("window.UI && UI.relayout && UI.relayout()", null); });
            chrome.postDelayed(chrome::invalidate, 80);
        }
    }

    /** Hand Ruby's state snapshot to the Opal chrome. */
    private void pushState(String stateJson) {
        if (!chromeReady) { pendingState = stateJson; return; }
        pendingState = null;
        chrome.evaluateJavascript("window.UI && UI.receive(" + JSONObject.quote(stateJson) + ")", null);
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
        installContextMenu(w, id);

        if (url != null && !url.isEmpty()) w.loadUrl(url);
    }

    // ---- context menu (right-click in DeX / long-press on touch) ----
    private final float[] lastPointer = new float[2];   // last pointer position inside the page view (px)
    private boolean lastFromMouse = false;              // DeX may deliver a right-click as a long-press

    private void installContextMenu(final WebView w, final int id) {
        w.setOnTouchListener((v, ev) -> {
            lastPointer[0] = ev.getX(); lastPointer[1] = ev.getY();
            lastFromMouse = ev.isFromSource(android.view.InputDevice.SOURCE_MOUSE) || ev.getToolType(0) == MotionEvent.TOOL_TYPE_MOUSE;
            return false;
        });
        // Mouse: Chromium's WebView consumes button events itself, so OnContextClickListener may
        // never fire. Catch the secondary (right) button press in the raw motion stream instead.
        w.setOnGenericMotionListener((v, ev) -> {
            lastPointer[0] = ev.getX(); lastPointer[1] = ev.getY();
            if (ev.getActionMasked() == MotionEvent.ACTION_BUTTON_PRESS) {
                int b = ev.getActionButton();
                ruby.appendLog("[mouse] button_press button=" + b + " src=" + ev.getSource());
                if (b == MotionEvent.BUTTON_SECONDARY || b == MotionEvent.BUTTON_STYLUS_PRIMARY) { contextMenu(w, id); return true; }
                if (b == MotionEvent.BUTTON_BACK)    { if (w.canGoBack()) w.goBack(); return true; }
                if (b == MotionEvent.BUTTON_FORWARD) { if (w.canGoForward()) w.goForward(); return true; }
            }
            return false;
        });
        w.setOnContextClickListener(v -> { contextMenu(w, id); return true; });   // fallback path (some devices)
        // Touch: long-press opens our menu on links and images only; on text, let the WebView select.
        w.setOnLongClickListener(v -> {
            if (lastFromMouse) { contextMenu(w, id); return true; }      // right-click translated to long-press
            int t = w.getHitTestResult().getType();
            if (t == WebView.HitTestResult.SRC_ANCHOR_TYPE || t == WebView.HitTestResult.SRC_IMAGE_ANCHOR_TYPE
                    || t == WebView.HitTestResult.IMAGE_TYPE) { contextMenu(w, id); return true; }
            return false;
        });
    }

    private void contextMenu(final WebView w, final int id) {
        WebView.HitTestResult hit = w.getHitTestResult();
        String t = "page", link = "", src = "";
        switch (hit.getType()) {
            case WebView.HitTestResult.SRC_ANCHOR_TYPE: t = "link"; link = hit.getExtra(); break;
            case WebView.HitTestResult.SRC_IMAGE_ANCHOR_TYPE: t = "link_image"; link = hit.getExtra(); break;
            case WebView.HitTestResult.IMAGE_TYPE: t = "image"; src = hit.getExtra(); break;
            case WebView.HitTestResult.EDIT_TEXT_TYPE: t = "input"; break;
            default: t = "page";
        }
        final String type = t, linkF = link == null ? "" : link, srcF = src == null ? "" : src;
        final float density = getResources().getDisplayMetrics().density;
        final int[] loc = new int[2]; w.getLocationInWindow(loc);
        final double xDp = (loc[0] + lastPointer[0]) / density, yDp = (loc[1] + lastPointer[1]) / density;
        final View root = findViewById(android.R.id.content);
        final double winW = root.getWidth() / density, winH = root.getHeight() / density;
        final float px = lastPointer[0], py = lastPointer[1];
        // Ask the page for both the selection and the exact CSS-pixel coordinates at the pointer.
        // window.getSelection() + a point mapped through devicePixelRatio, computed in-page.
        String js = "(function(x,y){return JSON.stringify({s:String(window.getSelection()),"
                + "cx:Math.round(x/window.devicePixelRatio),cy:Math.round(y/window.devicePixelRatio)});})("
                + px + "," + py + ")";
        w.evaluateJavascript(js, res -> {
            String selection = ""; double cssX = 0, cssY = 0;
            try {
                String raw = res;
                if (raw != null && raw.startsWith("\"")) raw = new org.json.JSONArray("[" + raw + "]").getString(0);
                org.json.JSONObject o = new org.json.JSONObject(raw);
                selection = o.optString("s", ""); cssX = o.optDouble("cx", 0); cssY = o.optDouble("cy", 0);
            } catch (Exception ignored) {}
            ruby.event("context.menu", "tab", id, "type", type, "link", linkF, "src", srcF, "selection", selection,
                    "x", xDp, "y", yDp, "win_w", winW, "win_h", winH, "css_x", cssX, "css_y", cssY,
                    "can_back", w.canGoBack(), "can_forward", w.canGoForward());
        });
    }

    private void copyToClipboard(String label, String text) {
        android.content.ClipboardManager cm = (android.content.ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
        if (cm != null) cm.setPrimaryClip(android.content.ClipData.newPlainText(label, text));
    }

    private void showTab(int id) {
        currentTab = id;
        for (Map.Entry<Integer, WebView> e : tabs.entrySet()) e.getValue().setVisibility(e.getKey() == id ? View.VISIBLE : View.GONE);
    }

    private void destroyTab(int id) {
        WebView w = tabs.remove(id);
        if (w != null) { pages.removeView(w); w.destroy(); }
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
        tune(w, desktopUa);
        w.setBackgroundColor(Color.WHITE);
        applyPrefs(w);
    }

    private JSONObject prefs = new JSONObject();

    /** WebView preferences Ruby owns (Settings page): JS, third-party cookies, force dark, text zoom. */
    private void applyPrefs(JSONObject p) {
        prefs = p;
        for (WebView w : tabs.values()) applyPrefs(w);
    }

    private void applyPrefs(WebView w) {
        WebSettings s = w.getSettings();
        s.setJavaScriptEnabled(prefs.optBoolean("javascript", true));
        s.setTextZoom(prefs.optInt("text_zoom", 100));
        CookieManager.getInstance().setAcceptThirdPartyCookies(w, prefs.optBoolean("cookies_3p", true));
        boolean dark = prefs.optBoolean("force_dark", false);
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            s.setAlgorithmicDarkeningAllowed(dark);
        } else if (android.os.Build.VERSION.SDK_INT >= 29) {
            s.setForceDark(dark ? WebSettings.FORCE_DARK_ON : WebSettings.FORCE_DARK_OFF);
        }
    }

    private void clearData(JSONObject c) {
        if (c.optBoolean("cookies")) { CookieManager.getInstance().removeAllCookies(null); CookieManager.getInstance().flush(); }
        if (c.optBoolean("cache")) for (WebView w : tabs.values()) w.clearCache(true);
        if (c.optBoolean("storage")) android.webkit.WebStorage.getInstance().deleteAllData();
    }

    // ---- request blocking (Ruby-owned glob patterns) and downloads on Ruby's behalf ----
    private volatile String[] blockRules = new String[0];

    private void setBlockRules(JSONArray arr) {
        if (arr == null) { blockRules = new String[0]; return; }
        String[] r = new String[arr.length()];
        for (int i = 0; i < arr.length(); i++) r[i] = arr.optString(i);
        blockRules = r;
    }

    /** Same glob semantics as ruby/lib/scripts.rb: "*" matches anything. */
    static boolean glob(String pattern, String url) {
        if (pattern == null || pattern.isEmpty() || url == null) return false;
        if (pattern.equals("*") || pattern.equals("<all_urls>")) return true;
        String[] parts = pattern.split("\\*", -1);
        if (parts.length == 1) return url.equals(pattern);
        if (!url.startsWith(parts[0]) || !url.endsWith(parts[parts.length - 1])) return false;
        int pos = parts[0].length();
        for (int i = 1; i < parts.length - 1; i++) {
            if (parts[i].isEmpty()) continue;
            int at = url.indexOf(parts[i], pos);
            if (at < 0) return false;
            pos = at + parts[i].length();
        }
        return pos <= url.length() - parts[parts.length - 1].length();
    }

    private boolean blocked(String url) {
        for (String p : blockRules) if (glob(p, url)) return true;
        return false;
    }

    /** Ruby cannot reach the network itself; download a URL and hand the body back as an event. */
    private void fetchForRuby(final String url, final String purpose) {
        new Thread(() -> {
            String body = null, error = null;
            try {
                java.net.HttpURLConnection c = (java.net.HttpURLConnection) new java.net.URL(url).openConnection();
                c.setConnectTimeout(10000); c.setReadTimeout(15000); c.setInstanceFollowRedirects(true);
                c.setRequestProperty("User-Agent", DESKTOP_UA);
                try (java.io.InputStream in = c.getInputStream()) {
                    java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
                    byte[] buf = new byte[16384]; int n; long total = 0;
                    while ((n = in.read(buf)) != -1) { out.write(buf, 0, n); total += n; if (total > 2_000_000) throw new java.io.IOException("file too large (>2 MB)"); }
                    body = out.toString("UTF-8");
                }
            } catch (Exception e) { error = e.toString(); }
            ruby.event("fetched", "url", url, "purpose", purpose, "body", body == null ? "" : body, "error", error == null ? "" : error);
        }, "fetch").start();
    }

    private void setDesktopUa(boolean desktop) {
        desktopUa = desktop;
        for (WebView w : tabs.values()) {
            w.getSettings().setUserAgentString(desktop ? DESKTOP_UA : null);
            tune(w, desktop);
        }
    }

    private boolean tuningReported = false;

    /** Present pages as Chrome rather than an embedded WebView (Gradle builds only; no-op otherwise). */
    private void tune(WebView w, boolean desktop) {
        try {
            Object r = Class.forName("com.mstsage.mimir.WebViewTuning").getMethod("apply", WebView.class, boolean.class).invoke(null, w, desktop);
            if (!tuningReported && r != null) { tuningReported = true; ruby.appendLog("[webview] " + r); status(String.valueOf(r)); }
        } catch (Throwable t) {
            if (!tuningReported) { tuningReported = true; ruby.appendLog("[webview] tuning unavailable in this build"); }
        }
    }

    /** The chrome renders Ruby's snapshot; nothing native to update besides the pane state. */
    private void renderState(JSONObject st) {
        pushState(st.toString());
    }

    private final class PageClient extends WebViewClient {
        private final int id;
        PageClient(int id) { this.id = id; }
        @Override public void onPageStarted(WebView view, String url, Bitmap favicon) { ruby.event("page.started", "tab", id, "url", url); }
        @Override public void onPageFinished(WebView view, String url) {
            ruby.event("page.finished", "tab", id, "url", url, "can_back", view.canGoBack(), "can_forward", view.canGoForward());
        }
        @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest req) {
            Uri u = req.getUrl();
            String s = u.getScheme();
            if ("http".equals(s) || "https".equals(s)) return false;
            try { startActivity(new Intent(Intent.ACTION_VIEW, u)); } catch (Exception ignored) {}
            return true;
        }
        @Override public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest req) {
            if (blockRules.length > 0 && !req.isForMainFrame() && blocked(req.getUrl().toString())) {
                return new WebResourceResponse("text/plain", "utf-8", 204, "Blocked by Mimir", new HashMap<>(), new java.io.ByteArrayInputStream(new byte[0]));
            }
            return null;
        }
    }

    private final class PageChrome extends WebChromeClient {
        private final int id;
        PageChrome(int id) { this.id = id; }
        @Override public void onProgressChanged(WebView view, int p) { ruby.event("page.progress", "tab", id, "p", p); }
        @Override public void onReceivedTitle(WebView view, String title) { ruby.event("page.title", "tab", id, "title", title == null ? "" : title); }
        @Override public void onReceivedIcon(WebView view, Bitmap icon) {
            if (icon == null) return;
            try {
                Bitmap small = icon.getWidth() > 32 ? Bitmap.createScaledBitmap(icon, 32, 32, true) : icon;
                java.io.ByteArrayOutputStream bos = new java.io.ByteArrayOutputStream();
                small.compress(Bitmap.CompressFormat.PNG, 100, bos);
                String data = "data:image/png;base64," + android.util.Base64.encodeToString(bos.toByteArray(), android.util.Base64.NO_WRAP);
                ruby.event("page.favicon", "tab", id, "data", data);
            } catch (Exception ignored) {}
        }
    }

    // ------------------------------------------------------------------ devtools pane (views only)

    private void openDevtools(String side, float fraction) {
        devtoolsOpen = true;
        dockRight = !"bottom".equals(side);
        // A right dock on a narrow (phone-portrait) window leaves no room for the page.
        float widthDp = getResources().getConfiguration().screenWidthDp;
        if (widthDp < 600) dockRight = false;
        devtoolsFraction = fraction;
        divider.setVisibility(View.VISIBLE);
        devtoolsContainer.setVisibility(View.VISIBLE);
        if (devtoolsView == null) {
            devtoolsView = new DevToolsWebView(this);
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
                    // Plain-text editing for DevTools' contenteditable fields (Android IME composition
                    // otherwise garbles inline style/attribute edits).
                    v.evaluateJavascript("(function(){var st=document.createElement('style');st.textContent="
                            + "'[contenteditable],[contenteditable] *{-webkit-user-modify:read-write-plaintext-only !important}';"
                            + "document.head.appendChild(st);"
                            + "var fix=function(root){root.querySelectorAll('[contenteditable],input,textarea').forEach(function(e){e.setAttribute('autocomplete','off');e.setAttribute('autocorrect','off');e.setAttribute('autocapitalize','off');e.setAttribute('spellcheck','false');});};"
                            + "fix(document);new MutationObserver(function(ms){ms.forEach(function(m){m.addedNodes.forEach(function(n){if(n.querySelectorAll)fix(n);});});}).observe(document.documentElement,{childList:true,subtree:true});"
                            + "return 'ok';})()", null);
                    // Apply Ruby-owned DevTools prefs (theme, screencast) via the frontend's localStorage
                    // settings store; reload once if anything changed.
                    String want = "{screencastEnabled:'" + (devtoolsScreencast ? "true" : "false") + "',uiTheme:'\"" + devtoolsTheme + "\"'}";
                    v.evaluateJavascript("(function(w){try{var r='ok';for(var k in w){if(localStorage.getItem(k)!==w[k]){localStorage.setItem(k,w[k]);r='reload';}}return r;}catch(e){return 'err:'+e;}})(" + want + ")",
                            res -> { if (res != null && res.contains("reload")) v.reload(); });
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

    // Turn on the DevTools inspect cursor (Ctrl+Shift+C in the frontend), then simulate a tap on the
    // page at the given CSS point so the target reveals that node in the Elements panel — exactly
    // what desktop "right-click → Inspect element" does.
    private void enterInspectMode(float cssX, float cssY) {
        if (devtoolsView == null) return;
        final WebView page = tabs.get(currentTab);
        String js = "(function(){try{['keydown','keyup'].forEach(function(t){document.dispatchEvent(new KeyboardEvent(t,{key:'C',code:'KeyC',keyCode:67,which:67,ctrlKey:true,shiftKey:true,bubbles:true}));});return 'ok';}catch(e){return 'err:'+e;}})()";
        devtoolsView.evaluateJavascript(js, r -> {
            appendRubyLog("[inspect] mode=" + r);
            if (page == null) return;
            float density = getResources().getDisplayMetrics().density;
            float scale = page.getScale() == 0 ? density : page.getScale();
            final float vx = cssX * scale, vy = cssY * scale;   // CSS px -> view px
            main.postDelayed(() -> tapPage(page, vx, vy), 250);
        });
    }

    private void tapPage(WebView page, float x, float y) {
        long t = android.os.SystemClock.uptimeMillis();
        MotionEvent down = MotionEvent.obtain(t, t, MotionEvent.ACTION_DOWN, x, y, 0);
        MotionEvent up = MotionEvent.obtain(t, t + 40, MotionEvent.ACTION_UP, x, y, 0);
        page.dispatchTouchEvent(down); page.dispatchTouchEvent(up);
        down.recycle(); up.recycle();
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
        if (imm != null) imm.hideSoftInputFromWindow(chrome.getWindowToken(), 0);
    }

    // ------------------------------------------------------------------ diagnostics

    private void toast(String s) { Toast.makeText(this, s, Toast.LENGTH_SHORT).show(); }

    private final Runnable hideStatus = () -> statusView.setVisibility(View.GONE);

    /** Diagnostics line. Informational messages fade after a few seconds; errors stay until tapped. */
    private void status(String s) {
        Log.i(TAG, s);
        statusView.setText(s);
        statusView.setVisibility(View.VISIBLE);
        main.removeCallbacks(hideStatus);
        boolean sticky = s.startsWith("UI error") || s.startsWith("RUBY FATAL") || s.startsWith("attach failed") || s.startsWith("Previous run crashed") || s.contains("failed");
        if (!sticky) main.postDelayed(hideStatus, 4000);
    }

    private void toggleRubyPane() {
        boolean show = rubyPane.getVisibility() != View.VISIBLE;
        rubyPane.setVisibility(show ? View.VISIBLE : View.GONE);
        if (show) { rubyLog.setText(ruby.logText()); scrollRubyLog(); }
    }

    private void appendRubyLog(String line) { rubyLog.append(line + "\n"); scrollRubyLog(); }
    private void scrollRubyLog() { rubyLogScroll.post(() -> rubyLogScroll.fullScroll(View.FOCUS_DOWN)); }
}
