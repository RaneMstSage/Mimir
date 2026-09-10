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
import android.util.Patterns;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.webkit.CookieManager;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

/**
 * A small tabbed browser whose pages can be inspected with the real Chrome DevTools
 * frontend, attached in-process through {@link DevToolsBridge}.
 */
public class MainActivity extends Activity {
    private static final String TAG = "Inspect";
    private static final String DESKTOP_UA =
            "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36";

    private final Handler main = new Handler(Looper.getMainLooper());
    private final List<Tab> tabs = new ArrayList<>();
    private Tab current;

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

    private DevToolsBridge bridge;
    private DevToolsClient client;
    private WebView devtoolsView;
    private boolean devtoolsOpen = false;
    private boolean dockRight = true;
    private float devtoolsFraction = 0.45f;
    private boolean desktopUa = true;   // tablet + inspecting: desktop layout by default

    private final class Tab {
        WebView view;
        TextView chip;
        String title = "New tab";
        String url = "";
    }

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

        // The whole point: turn on WebView's DevTools server for this process.
        WebView.setWebContentsDebuggingEnabled(true);
        bridge = new DevToolsBridge(Process.myPid());
        try {
            int port = bridge.start();
            client = new DevToolsClient(port);
            status("bridge: 127.0.0.1:" + port + " -> @webview_devtools_remote_" + Process.myPid());
        } catch (Exception e) {
            status("DevTools bridge failed: " + e);
        }

        findViewById(R.id.btn_back).setOnClickListener(v -> { if (current != null && current.view.canGoBack()) current.view.goBack(); });
        findViewById(R.id.btn_fwd).setOnClickListener(v -> { if (current != null && current.view.canGoForward()) current.view.goForward(); });
        findViewById(R.id.btn_reload).setOnClickListener(v -> { if (current != null) current.view.reload(); });
        findViewById(R.id.btn_newtab).setOnClickListener(v -> newTab(getString(R.string.home_url), true));
        btnDevtools.setOnClickListener(v -> toggleDevtools());
        btnDevtools.setOnLongClickListener(v -> { reattachDevtools(); return true; });
        btnDock.setOnClickListener(v -> { dockRight = !dockRight; applyDock(); });
        btnUa.setOnClickListener(v -> toggleUa());

        urlBar.setOnEditorActionListener((v, actionId, event) -> {
            boolean go = actionId == EditorInfo.IME_ACTION_GO
                    || (event != null && event.getKeyCode() == KeyEvent.KEYCODE_ENTER && event.getAction() == KeyEvent.ACTION_DOWN);
            if (go) { navigate(urlBar.getText().toString()); return true; }
            return false;
        });

        setupDivider();
        applyDock();

        String start = urlFromIntent(getIntent());
        newTab(start != null ? start : getString(R.string.home_url), true);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        String u = urlFromIntent(intent);
        if (u != null) newTab(u, true);
    }

    private String urlFromIntent(Intent i) {
        if (i == null) return null;
        if (Intent.ACTION_VIEW.equals(i.getAction()) && i.getData() != null) return i.getData().toString();
        if (Intent.ACTION_SEND.equals(i.getAction())) {
            String t = i.getStringExtra(Intent.EXTRA_TEXT);
            if (t != null) {
                for (String w : t.split("\\s+")) if (w.startsWith("http")) return w;
            }
        }
        return null;
    }

    // ---------------------------------------------------------------- tabs

    private Tab newTab(String url, boolean select) {
        Tab t = new Tab();
        t.view = new WebView(this);
        configure(t.view);
        t.view.setWebViewClient(new PageClient(t));
        t.view.setWebChromeClient(new PageChrome(t));
        t.view.setLayoutParams(new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        pages.addView(t.view);

        t.chip = new TextView(this);
        t.chip.setSingleLine(true);
        t.chip.setMaxWidth(dp(220));
        t.chip.setMinWidth(dp(100));
        t.chip.setPadding(dp(12), 0, dp(12), 0);
        t.chip.setGravity(android.view.Gravity.CENTER_VERTICAL);
        t.chip.setTextSize(13);
        t.chip.setText(t.title);
        t.chip.setOnClickListener(v -> selectTab(t));
        t.chip.setOnLongClickListener(v -> { closeTab(t); return true; });
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT);
        lp.setMargins(dp(2), dp(4), dp(2), 0);
        tabStrip.addView(t.chip, lp);

        tabs.add(t);
        t.view.loadUrl(url);
        if (select) selectTab(t);
        return t;
    }

    private void selectTab(Tab t) {
        current = t;
        for (Tab o : tabs) {
            boolean on = o == t;
            o.view.setVisibility(on ? View.VISIBLE : View.GONE);
            o.chip.setBackgroundColor(on ? 0xFF1e293b : 0xFF020617);
            o.chip.setTextColor(on ? 0xFFe2e8f0 : 0xFF94a3b8);
        }
        urlBar.setText(t.url);
        tabScroll.post(() -> tabScroll.smoothScrollTo(t.chip.getLeft() - dp(40), 0));
        if (devtoolsOpen) attachDevtools(t);
    }

    private void closeTab(Tab t) {
        if (tabs.size() == 1) { t.view.loadUrl(getString(R.string.home_url)); return; }
        int idx = tabs.indexOf(t);
        tabs.remove(t);
        pages.removeView(t.view);
        tabStrip.removeView(t.chip);
        t.view.destroy();
        if (current == t) selectTab(tabs.get(Math.max(0, Math.min(idx, tabs.size() - 1))));
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
        s.setJavaScriptCanOpenWindowsAutomatically(false);
        s.setMediaPlaybackRequiresUserGesture(true);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE);
        s.setAllowFileAccess(false);
        if (desktopUa) s.setUserAgentString(DESKTOP_UA);
        CookieManager.getInstance().setAcceptThirdPartyCookies(w, true);
        w.setBackgroundColor(Color.WHITE);
    }

    private void toggleUa() {
        desktopUa = !desktopUa;
        for (Tab t : tabs) {
            t.view.getSettings().setUserAgentString(desktopUa ? DESKTOP_UA : null);
        }
        btnUa.setText(desktopUa ? "🖥" : "📱");
        if (current != null) current.view.reload();
        toast(desktopUa ? "Desktop site" : "Mobile site");
    }

    private void navigate(String text) {
        if (current == null) return;
        String q = text.trim();
        if (q.isEmpty()) return;
        String url;
        if (q.matches("^[a-zA-Z][a-zA-Z0-9+.-]*:.*")) url = q;
        else if (Patterns.WEB_URL.matcher(q).matches() || q.contains(".") && !q.contains(" ")) url = "https://" + q;
        else url = "https://www.google.com/search?q=" + Uri.encode(q);
        current.view.loadUrl(url);
        hideKeyboard();
        current.view.requestFocus();
    }

    private final class PageClient extends WebViewClient {
        private final Tab tab;
        PageClient(Tab t) { tab = t; }

        @Override public void onPageStarted(WebView view, String url, Bitmap favicon) {
            tab.url = url;
            if (tab == current) { urlBar.setText(url); progress.setVisibility(View.VISIBLE); progress.setProgress(5); }
        }
        @Override public void onPageFinished(WebView view, String url) {
            tab.url = url;
            if (tab == current) { urlBar.setText(url); progress.setVisibility(View.GONE); }
        }
        @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest req) {
            Uri u = req.getUrl();
            String s = u.getScheme();
            if ("http".equals(s) || "https".equals(s)) return false;
            try { startActivity(new Intent(Intent.ACTION_VIEW, u)); } catch (Exception ignored) {}
            return true;
        }
    }

    private final class PageChrome extends WebChromeClient {
        private final Tab tab;
        PageChrome(Tab t) { tab = t; }
        @Override public void onProgressChanged(WebView view, int p) {
            if (tab == current) { progress.setProgress(p); if (p >= 100) progress.setVisibility(View.GONE); }
        }
        @Override public void onReceivedTitle(WebView view, String title) {
            tab.title = title == null || title.isEmpty() ? tab.url : title;
            tab.chip.setText(tab.title);
        }
    }

    // ---------------------------------------------------------------- devtools

    private void toggleDevtools() {
        if (devtoolsOpen) { closeDevtools(); return; }
        if (client == null) { toast("DevTools bridge not running"); return; }
        devtoolsOpen = true;
        divider.setVisibility(View.VISIBLE);
        devtoolsContainer.setVisibility(View.VISIBLE);
        btnDevtools.setTextColor(0xFF22c55e);
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
                @Override public void onReceivedError(WebView v, WebResourceRequest r, android.webkit.WebResourceError err) {
                    if (r.isForMainFrame()) status("frontend load error: " + err.getDescription() + " " + r.getUrl());
                }
                @Override public void onReceivedHttpError(WebView v, WebResourceRequest r, android.webkit.WebResourceResponse resp) {
                    if (r.isForMainFrame()) status("frontend HTTP " + resp.getStatusCode() + " " + r.getUrl());
                }
                @Override public void onPageFinished(WebView v, String u) { status("frontend loaded: " + u); }
            });
            devtoolsView.setWebChromeClient(new WebChromeClient() {
                @Override public boolean onConsoleMessage(android.webkit.ConsoleMessage m) {
                    Log.d(TAG, "devtools: " + m.message());
                    if (m.messageLevel() == android.webkit.ConsoleMessage.MessageLevel.ERROR) status("frontend console: " + m.message());
                    return true;
                }
            });
            devtoolsContainer.addView(devtoolsView, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        }
        applyDock();
        if (current != null) attachDevtools(current);
    }

    private void closeDevtools() {
        devtoolsOpen = false;
        divider.setVisibility(View.GONE);
        devtoolsContainer.setVisibility(View.GONE);
        btnDevtools.setTextColor(0xFF38bdf8);
        if (devtoolsView != null) devtoolsView.loadUrl("about:blank");
        applyDock();
    }

    private void reattachDevtools() {
        if (!devtoolsOpen) toggleDevtools(); else if (current != null) attachDevtools(current);
    }

    /** Look up the current tab's DevTools target and load the frontend for it. */
    private void attachDevtools(final Tab tab) {
        final String url = tab.url;
        status("attaching: " + url);
        new Thread(() -> {
            try {
                JSONObject target = null;
                for (int attempt = 0; attempt < 5 && target == null; attempt++) {
                    target = client.findTarget(url, DevToolsClient.CDN);
                    if (target == null) Thread.sleep(300);
                }
                if (target == null) {
                    final String list = client.get("/json/list");
                    main.post(() -> status("no target for tab; /json/list = " + list.replace('\n', ' ')));
                    return;
                }
                final String fe = client.frontendUrl(target);
                final String tid = target.optString("id");
                Log.i(TAG, "devtools frontend: " + fe);
                main.post(() -> status("target " + tid + " -> " + fe));
                main.post(() -> { if (devtoolsOpen && devtoolsView != null) devtoolsView.loadUrl(fe); });
            } catch (Exception e) {
                Log.w(TAG, "attach failed", e);
                final String msg = e.toString();
                main.post(() -> status("attach failed: " + msg));
            }
        }, "devtools-attach").start();
    }

    // ---------------------------------------------------------------- layout

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
            if (ev.getAction() == MotionEvent.ACTION_MOVE || ev.getAction() == MotionEvent.ACTION_DOWN) {
                float total = dockRight ? split.getWidth() : split.getHeight();
                float pos = dockRight ? ev.getRawX() - locX(split) : ev.getRawY() - locY(split);
                if (total > 0) {
                    devtoolsFraction = Math.max(0.15f, Math.min(0.85f, 1f - pos / total));
                    applyDock();
                }
                return true;
            }
            return ev.getAction() == MotionEvent.ACTION_UP;
        });
    }

    private static int locX(View v) { int[] l = new int[2]; v.getLocationOnScreen(l); return l[0]; }
    private static int locY(View v) { int[] l = new int[2]; v.getLocationOnScreen(l); return l[1]; }

    private int dp(int d) { return Math.round(d * getResources().getDisplayMetrics().density); }

    private void hideKeyboard() {
        InputMethodManager imm = (InputMethodManager) getSystemService(INPUT_METHOD_SERVICE);
        if (imm != null) imm.hideSoftInputFromWindow(urlBar.getWindowToken(), 0);
    }

    private void toast(String s) { Toast.makeText(this, s, Toast.LENGTH_SHORT).show(); }

    /** Diagnostics line under the toolbar (long-press to hide). We cannot read logcat from Termux. */
    private void status(String s) {
        Log.i(TAG, s);
        statusView.setText(s);
        statusView.setVisibility(View.VISIBLE);
    }

    @Override
    public void onBackPressed() {
        if (current != null && current.view.canGoBack()) current.view.goBack();
        else if (devtoolsOpen) closeDevtools();
        else super.onBackPressed();
    }

    @Override
    protected void onDestroy() {
        if (bridge != null) bridge.stop();
        for (Tab t : tabs) t.view.destroy();
        if (devtoolsView != null) devtoolsView.destroy();
        super.onDestroy();
    }
}
