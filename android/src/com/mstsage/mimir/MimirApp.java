package com.mstsage.mimir;

import android.app.Application;
import android.content.ContentValues;
import android.content.Context;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.provider.MediaStore;
import android.util.Log;

import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

/**
 * Process entry point. Installs crash reporting that works without adb/logcat: uncaught Java
 * exceptions and native signals are written to files/last_crash.txt and copied to the public
 * Downloads folder (MediaStore, no permission needed on Android 10+), where Termux can read them.
 */
public class MimirApp extends Application {
    private static final String TAG = "MimirApp";
    public static final String CRASH_FILE = "last_crash.txt";
    public static final String NATIVE_CRASH_FILE = "last_native_crash.txt";

    @Override
    public void onCreate() {
        super.onCreate();
        final Thread.UncaughtExceptionHandler prev = Thread.getDefaultUncaughtExceptionHandler();
        Thread.setDefaultUncaughtExceptionHandler((t, e) -> {
            try {
                StringWriter sw = new StringWriter();
                sw.write("JAVA CRASH in thread '" + t.getName() + "' (app " + BuildInfo.VERSION + ", " + Build.MODEL + " Android " + Build.VERSION.RELEASE + ")\n");
                e.printStackTrace(new PrintWriter(sw));
                sw.write("\n--- ruby log ---\n");
                sw.write(RubyRuntime.get().logText());
                writeCrash(this, CRASH_FILE, sw.toString());
            } catch (Throwable ignored) {}
            if (prev != null) prev.uncaughtException(t, e);
            else System.exit(2);
        });
        // A native crash from a previous run leaves last_native_crash.txt; publish it to Downloads now.
        File nat = new File(getFilesDir(), NATIVE_CRASH_FILE);
        if (nat.exists() && nat.length() > 0) {
            try { publish(this, "Mimir-native-crash.txt", new String(Files.readAllBytes(nat.toPath()), StandardCharsets.UTF_8)); } catch (Throwable ignored) {}
        }
    }

    static void writeCrash(Context ctx, String name, String text) {
        try (FileOutputStream out = new FileOutputStream(new File(ctx.getFilesDir(), name))) {
            out.write(text.getBytes(StandardCharsets.UTF_8));
        } catch (Throwable e) { Log.w(TAG, "write crash file", e); }
        publish(ctx, "Mimir-crash.txt", text);
    }

    /** Copy text into the public Downloads folder via MediaStore (readable from Termux). */
    static void publish(Context ctx, String displayName, String text) {
        try {
            ContentValues v = new ContentValues();
            v.put(MediaStore.Downloads.DISPLAY_NAME, displayName);
            v.put(MediaStore.Downloads.MIME_TYPE, "text/plain");
            v.put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS);
            Uri uri = ctx.getContentResolver().insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, v);
            if (uri == null) return;
            try (OutputStream out = ctx.getContentResolver().openOutputStream(uri, "wt")) {
                if (out != null) out.write(text.getBytes(StandardCharsets.UTF_8));
            }
        } catch (Throwable e) { Log.w(TAG, "publish to Downloads failed", e); }
    }

    /** Last Java crash text, or null. Consumed (deleted) on read. */
    static String takeLastCrash(Context ctx, String name) {
        File f = new File(ctx.getFilesDir(), name);
        if (!f.exists()) return null;
        try {
            String s = new String(Files.readAllBytes(f.toPath()), StandardCharsets.UTF_8);
            f.delete();
            return s;
        } catch (Throwable e) { return null; }
    }
}
