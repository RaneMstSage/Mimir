package com.mstsage.mimir;

import android.os.Build;
import android.webkit.WebView;

import androidx.webkit.UserAgentMetadata;
import androidx.webkit.WebSettingsCompat;
import androidx.webkit.WebViewFeature;

import java.util.Arrays;
import java.util.Collections;

/**
 * Makes Mímir's pages look like the Chrome they run on, instead of "an embedded WebView".
 * Google's sign-in (and some other sites) refuse WebViews, which they detect through the
 * X-Requested-With header and the User-Agent Client Hints brand "Android WebView". Both are
 * adjusted here via AndroidX WebKit. Gradle-only source dir; loaded reflectively by MainActivity.
 */
public final class WebViewTuning {
    private WebViewTuning() {}

    /** Chromium major/full version parsed from the WebView's default UA, e.g. "152.0.7977.82". */
    static String chromiumVersion(WebView w) {
        String ua = w.getSettings().getUserAgentString();
        int i = ua.indexOf("Chrome/");
        if (i < 0) return "120.0.0.0";
        int j = ua.indexOf(' ', i);
        return ua.substring(i + 7, j < 0 ? ua.length() : j);
    }

    public static void apply(WebView w, boolean desktop) {
        try {
            if (WebViewFeature.isFeatureSupported(WebViewFeature.REQUESTED_WITH_HEADER_ALLOW_LIST)) {
                // Never send X-Requested-With: <package> (the classic WebView tell).
                WebSettingsCompat.setRequestedWithHeaderOriginAllowList(w.getSettings(), Collections.emptySet());
            }
            if (WebViewFeature.isFeatureSupported(WebViewFeature.USER_AGENT_METADATA)) {
                String full = chromiumVersion(w);
                String major = full.contains(".") ? full.substring(0, full.indexOf('.')) : full;
                UserAgentMetadata md = new UserAgentMetadata.Builder()
                        .setBrandVersionList(Arrays.asList(
                                new UserAgentMetadata.BrandVersion.Builder().setBrand("Chromium").setMajorVersion(major).setFullVersion(full).build(),
                                new UserAgentMetadata.BrandVersion.Builder().setBrand("Google Chrome").setMajorVersion(major).setFullVersion(full).build(),
                                new UserAgentMetadata.BrandVersion.Builder().setBrand("Not_A Brand").setMajorVersion("24").setFullVersion("24.0.0.0").build()))
                        .setFullVersion(full)
                        .setPlatform(desktop ? "Linux" : "Android")
                        .setPlatformVersion(desktop ? "" : Build.VERSION.RELEASE)
                        .setArchitecture(desktop ? "x86" : "arm")
                        .setModel(desktop ? "" : Build.MODEL)
                        .setMobile(!desktop)
                        .setBitness(64)
                        .setWow64(false)
                        .build();
                WebSettingsCompat.setUserAgentMetadata(w.getSettings(), md);
            }
        } catch (Throwable t) {
            android.util.Log.w("Mimir", "WebView tuning unavailable: " + t);
        }
    }
}
