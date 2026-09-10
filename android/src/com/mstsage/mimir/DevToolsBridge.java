package com.mstsage.mimir;

import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import android.util.Log;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;

/**
 * Exposes this process's WebView DevTools socket (abstract unix socket
 * "webview_devtools_remote_<pid>", created by WebView.setWebContentsDebuggingEnabled(true))
 * on 127.0.0.1:<port> so the DevTools frontend in a WebView can reach it over ws://.
 *
 * Chromium admits connections from the app's own uid (content::CanUserConnectToDevTools), so
 * no adb is involved. It does, however, reject WebSocket upgrades carrying a browser Origin
 * header (--remote-allow-origins guard). We therefore parse the client's HTTP head, drop the
 * Origin header, normalise Host, and pipe everything else byte-for-byte.
 */
public final class DevToolsBridge {
    private static final String TAG = "DevToolsBridge";
    private final String socketName;
    private ServerSocket server;
    private Thread acceptThread;
    private volatile boolean running;

    public DevToolsBridge(int pid) {
        this.socketName = "webview_devtools_remote_" + pid;
    }

    public synchronized int start() throws IOException {
        if (server != null) return server.getLocalPort();
        server = new ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"));
        running = true;
        acceptThread = new Thread(this::acceptLoop, "devtools-bridge-accept");
        acceptThread.setDaemon(true);
        acceptThread.start();
        Log.i(TAG, "listening on 127.0.0.1:" + server.getLocalPort() + " -> @" + socketName);
        return server.getLocalPort();
    }

    public int port() {
        return server == null ? -1 : server.getLocalPort();
    }

    public synchronized void stop() {
        running = false;
        try { if (server != null) server.close(); } catch (IOException ignored) {}
        server = null;
    }

    private void acceptLoop() {
        while (running) {
            try {
                Socket client = server.accept();
                Thread t = new Thread(() -> handle(client), "devtools-bridge-conn");
                t.setDaemon(true);
                t.start();
            } catch (IOException e) {
                if (running) Log.w(TAG, "accept failed: " + e.getMessage());
            }
        }
    }

    private void handle(Socket client) {
        LocalSocket upstream = new LocalSocket();
        try {
            client.setTcpNoDelay(true);
            InputStream cin = client.getInputStream();
            OutputStream cout = client.getOutputStream();

            String head = readHead(cin);
            if (head.isEmpty()) return;
            String rewritten = rewriteHead(head);

            upstream.connect(new LocalSocketAddress(socketName, LocalSocketAddress.Namespace.ABSTRACT));
            OutputStream uout = upstream.getOutputStream();
            InputStream uin = upstream.getInputStream();
            uout.write(rewritten.getBytes("ISO-8859-1"));
            uout.flush();

            Thread up = new Thread(() -> pump(cin, uout, upstream, client), "devtools-bridge-up");
            up.setDaemon(true);
            up.start();
            pump(uin, cout, upstream, client);
            up.join(2000);
        } catch (Exception e) {
            Log.w(TAG, "conn: " + e);
        } finally {
            try { upstream.close(); } catch (IOException ignored) {}
            try { client.close(); } catch (IOException ignored) {}
        }
    }

    /** Reads up to and including the blank line ending the HTTP request head. */
    private static String readHead(InputStream in) throws IOException {
        StringBuilder sb = new StringBuilder();
        int c;
        while ((c = in.read()) != -1) {
            sb.append((char) c);
            int n = sb.length();
            if (n >= 4 && sb.charAt(n - 1) == '\n' && sb.charAt(n - 2) == '\r'
                    && sb.charAt(n - 3) == '\n' && sb.charAt(n - 4) == '\r') break;
            if (n >= 2 && sb.charAt(n - 1) == '\n' && sb.charAt(n - 2) == '\n') break;
            if (n > 65536) throw new IOException("request head too large");
        }
        return sb.toString();
    }

    private String rewriteHead(String head) {
        String[] lines = head.split("\r?\n");
        StringBuilder out = new StringBuilder(lines[0]).append("\r\n");
        for (int i = 1; i < lines.length; i++) {
            String l = lines[i];
            if (l.isEmpty()) continue;
            String lower = l.toLowerCase();
            if (lower.startsWith("origin:") || lower.startsWith("host:")) continue;
            out.append(l).append("\r\n");
        }
        out.append("Host: 127.0.0.1:").append(port()).append("\r\n\r\n");
        return out.toString();
    }

    private static void pump(InputStream in, OutputStream out, LocalSocket a, Socket b) {
        byte[] buf = new byte[65536];
        try {
            int n;
            while ((n = in.read(buf)) != -1) {
                out.write(buf, 0, n);
                out.flush();
            }
        } catch (IOException ignored) {
        } finally {
            try { a.shutdownInput(); } catch (Exception ignored) {}
            try { b.shutdownInput(); } catch (Exception ignored) {}
            try { a.close(); } catch (Exception ignored) {}
            try { b.close(); } catch (Exception ignored) {}
        }
    }
}
