package com.mstsage.mimir;

import android.os.Build;
import android.webkit.WebView;

import androidx.webkit.UserAgentMetadata;
import androidx.webkit.WebSettingsCompat;
import androidx.webkit.WebViewCompat;
import androidx.webkit.WebViewFeature;

import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;

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

    /** Minimal window.chrome so "is this Chrome?" checks pass; real Chrome exposes these members. */
    static final String CHROME_SHIM =
            "(function(){if(!window.chrome){var c={app:{isInstalled:false,InstallState:{DISABLED:'disabled',INSTALLED:'installed',NOT_INSTALLED:'not_installed'},RunningState:{CANNOT_RUN:'cannot_run',READY_TO_RUN:'ready_to_run',RUNNING:'running'},getDetails:function(){return null},getIsInstalled:function(){return false},runningState:function(){return 'cannot_run'}},"
            + "runtime:{OnInstalledReason:{},OnRestartRequiredReason:{},PlatformArch:{},PlatformOs:{},RequestUpdateCheckStatus:{},connect:function(){},sendMessage:function(){},id:undefined},"
            + "loadTimes:function(){return {}},csi:function(){return {}}};"
            + "Object.defineProperty(window,'chrome',{value:c,writable:true,configurable:true,enumerable:true});}})();";

    /** Applies everything and returns a one-line report for the in-app log. */
    public static String apply(WebView w, boolean desktop) {
        StringBuilder report = new StringBuilder("tuning:");
        try {
            if (WebViewFeature.isFeatureSupported(WebViewFeature.REQUESTED_WITH_HEADER_ALLOW_LIST)) {
                // Never send X-Requested-With: <package> (the classic WebView tell).
                try {
                    WebSettingsCompat.setRequestedWithHeaderOriginAllowList(w.getSettings(), new HashSet<String>());
                    report.append(" xrw=off");
                } catch (Throwable t) { report.append(" xrw=ERR(" + t.getClass().getSimpleName() + ")"); }
            } else report.append(" xrw=unsupported");
            if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
                try {
                    WebViewCompat.addDocumentStartJavaScript(w, CHROME_SHIM, new HashSet<>(Collections.singletonList("*")));
                    report.append(" chrome-shim=on");
                } catch (Throwable t) { report.append(" chrome-shim=ERR(" + t.getClass().getSimpleName() + ")"); }
            } else report.append(" chrome-shim=unsupported");
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
                report.append(" hints=chrome/" + full);
            } else report.append(" hints=unsupported");
        } catch (Throwable t) {
            report.append(" ERR " + t);
        }
        return report.toString();
    }
}
