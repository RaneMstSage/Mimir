package com.mstsage.inspect;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;
import android.util.Log;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.util.ArrayDeque;

/**
 * Process-wide owner of the Ruby VM thread. Java code sends events with {@link #post}; Ruby sends
 * commands back through {@link #onCommand}, which are delivered on the main thread to the current
 * {@link Listener} (the Activity). Commands arriving while no listener is attached are buffered.
 */
public final class RubyRuntime {
    private static final String TAG = "RubyRuntime";
    private static RubyRuntime instance;

    public interface Listener {
        void onRubyCommand(JSONObject cmd);
    }

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ArrayDeque<JSONObject> pending = new ArrayDeque<>();
    private final StringBuilder logBuffer = new StringBuilder();
    private Listener listener;
    private Thread thread;
    private volatile boolean started;
    private volatile int exitCode = -1;

    public static synchronized RubyRuntime get() {
        if (instance == null) instance = new RubyRuntime();
        return instance;
    }

    private RubyRuntime() {}

    /** Starts the VM thread once. Loads assets/app.mrb and hands Ruby a boot descriptor. */
    public synchronized void start(Context ctx) {
        if (started) return;
        started = true;
        final Context app = ctx.getApplicationContext();
        thread = new Thread(() -> {
            try {
                if (Native.loadError != null) {
                    appendLog("libinspect.so failed to load: " + Native.loadError);
                    deliver(fatal("libinspect.so failed to load: " + Native.loadError));
                    return;
                }
                Native.initCrash(new java.io.File(app.getFilesDir(), InspectApp.NATIVE_CRASH_FILE).getAbsolutePath());
                byte[] mrb = readAsset(app, "app.mrb");
                JSONObject boot = new JSONObject();
                boot.put("pid", Process.myPid());
                boot.put("files_dir", app.getFilesDir().getAbsolutePath());
                boot.put("cache_dir", app.getCacheDir().getAbsolutePath());
                boot.put("app_version", BuildInfo.VERSION);
                appendLog("boot " + boot);
                exitCode = Native.run(mrb, boot.toString());
                appendLog("ruby thread exited with code " + exitCode);
            } catch (Throwable t) {
                Log.e(TAG, "ruby thread died", t);
                appendLog("ruby thread died: " + t);
                deliver(fatal("ruby thread died: " + t));
            }
        }, "ruby");
        thread.setDaemon(true);
        thread.start();
    }

    public void post(String json) {
        if (!started || Native.loadError != null) { Log.w(TAG, "post ignored: " + json); return; }
        Native.post(json);
    }

    public void post(JSONObject ev) { post(ev.toString()); }

    /** Convenience: {"ev": name, ...fields} */
    public void event(String name, Object... kv) {
        try {
            JSONObject o = new JSONObject();
            o.put("ev", name);
            for (int i = 0; i + 1 < kv.length; i += 2) o.put(String.valueOf(kv[i]), kv[i + 1]);
            post(o);
        } catch (Exception e) {
            Log.w(TAG, "event build failed", e);
        }
    }

    public void setListener(Listener l) {
        main.post(() -> {
            listener = l;
            if (l != null) while (!pending.isEmpty()) l.onRubyCommand(pending.poll());
        });
    }

    public String logText() { synchronized (logBuffer) { return logBuffer.toString(); } }

    public void appendLog(String line) {
        Log.i(TAG, line);
        synchronized (logBuffer) {
            logBuffer.append(line).append('\n');
            if (logBuffer.length() > 60_000) logBuffer.delete(0, logBuffer.length() - 50_000);
        }
    }

    /** Called from native code (any thread, in practice the ruby thread). */
    static void onCommand(String json) {
        RubyRuntime rt = get();
        JSONObject cmd;
        try {
            cmd = new JSONObject(json);
        } catch (Exception e) {
            cmd = fatal("bad command JSON: " + json);
        }
        rt.deliver(cmd);
    }

    private void deliver(final JSONObject cmd) {
        String c = cmd.optString("cmd");
        if ("log".equals(c)) appendLog("[" + cmd.optString("level") + "] " + cmd.optString("text"));
        else if ("fatal".equals(c)) appendLog("[FATAL] " + cmd.optString("text"));
        main.post(() -> {
            if (listener != null) listener.onRubyCommand(cmd);
            else pending.add(cmd);
        });
    }

    private static JSONObject fatal(String text) {
        JSONObject o = new JSONObject();
        try { o.put("cmd", "fatal"); o.put("text", text); } catch (Exception ignored) {}
        return o;
    }

    private static byte[] readAsset(Context ctx, String name) throws Exception {
        try (InputStream in = ctx.getAssets().open(name)) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[16384];
            int n;
            while ((n = in.read(buf)) != -1) out.write(buf, 0, n);
            return out.toByteArray();
        }
    }
}
