package com.mstsage.mimir;

import android.content.ContentResolver;
import android.content.Context;
import android.content.UriPermission;
import android.database.Cursor;
import android.net.Uri;
import android.provider.DocumentsContract;
import android.webkit.MimeTypeMap;
import android.webkit.WebResourceResponse;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Local files and folders served on the private origin https://local.mimir/<absolute path>.
 *
 * Android sandboxes apps, so Mímir reads files only through folders the user has granted via the
 * Storage Access Framework (a one-time "Use this folder"). Supported providers are the ones whose
 * documents map to real filesystem paths:
 *   - Termux (com.termux.documents): document id == absolute path.
 *   - Shared storage (com.android.externalstorage.documents): "primary:Download/x" == /storage/emulated/0/Download/x.
 * Because the URL path mirrors the filesystem, relative links, ES modules and fetch() resolve like a site.
 */
final class FolderAccess {
    static final String HOST = "local.mimir";
    static final String ORIGIN = "https://" + HOST;
    static final String TERMUX = "com.termux.documents";
    static final String EXTERNAL = "com.android.externalstorage.documents";
    static final String TERMUX_HOME = "/data/data/com.termux/files/home";
    static final String EXT_ROOT = "/storage/emulated/0";

    static final class Grant {
        final Uri tree; final String authority; final String rootPath;
        Grant(Uri tree, String authority, String rootPath) { this.tree = tree; this.authority = authority; this.rootPath = rootPath; }
    }

    private final Context ctx;
    private volatile List<Grant> cached;

    FolderAccess(Context c) { ctx = c.getApplicationContext(); }

    // ------------------------------------------------------------------ paths & grants

    /** Canonical form: /sdcard and /storage/self/primary become /storage/emulated/0; no trailing slash. */
    static String normalize(String p) {
        if (p == null || p.isEmpty()) return "/";
        if (p.startsWith("/sdcard")) p = EXT_ROOT + p.substring("/sdcard".length());
        else if (p.startsWith("/storage/self/primary")) p = EXT_ROOT + p.substring("/storage/self/primary".length());
        while (p.length() > 1 && p.endsWith("/")) p = p.substring(0, p.length() - 1);
        return p;
    }

    static String docIdToPath(String authority, String docId) {
        if (TERMUX.equals(authority)) return normalize(docId);
        if (EXTERNAL.equals(authority)) {
            int c = docId.indexOf(':');
            if (c < 0 || !"primary".equals(docId.substring(0, c))) return null;   // SD cards etc.: not mapped
            String rest = docId.substring(c + 1);
            return normalize(rest.isEmpty() ? EXT_ROOT : EXT_ROOT + "/" + rest);
        }
        return null;
    }

    static String pathToDocId(String authority, String path) {
        if (TERMUX.equals(authority)) return path;
        if (EXTERNAL.equals(authority)) {
            String rel = path.length() > EXT_ROOT.length() ? path.substring(EXT_ROOT.length() + 1) : "";
            return "primary:" + rel;
        }
        return null;
    }

    synchronized void refresh() {
        List<Grant> out = new ArrayList<>();
        for (UriPermission p : ctx.getContentResolver().getPersistedUriPermissions()) {
            if (!p.isReadPermission()) continue;
            Uri u = p.getUri();
            try {
                String docId = DocumentsContract.getTreeDocumentId(u);
                String path = docIdToPath(u.getAuthority(), docId);
                if (path != null) out.add(new Grant(u, u.getAuthority(), path));
            } catch (Exception ignored) { /* not a tree uri */ }
        }
        cached = out;
    }

    List<Grant> grants() {
        if (cached == null) refresh();
        return cached;
    }

    /** The grant with the longest root covering path, or null. */
    Grant covering(String path) {
        Grant best = null;
        for (Grant g : grants()) {
            boolean in = path.equals(g.rootPath) || path.startsWith(g.rootPath.endsWith("/") ? g.rootPath : g.rootPath + "/");
            if (in && (best == null || g.rootPath.length() > best.rootPath.length())) best = g;
        }
        return best;
    }

    Uri documentUri(Grant g, String path) {
        return DocumentsContract.buildDocumentUriUsingTree(g.tree, pathToDocId(g.authority, path));
    }

    /** Initial picker location: Termux home for Termux paths (one grant covers every project). */
    static Uri initialUriFor(String path) {
        if (path == null) return null;
        if (path.startsWith("/data/data/com.termux/")) return DocumentsContract.buildDocumentUri(TERMUX, TERMUX_HOME);
        if (path.startsWith(EXT_ROOT)) return DocumentsContract.buildDocumentUri(EXTERNAL, pathToDocId(EXTERNAL, path));
        return null;
    }

    boolean release(String rootPath) {
        boolean done = false;
        for (Grant g : grants()) {
            if (g.rootPath.equals(rootPath)) {
                ctx.getContentResolver().releasePersistableUriPermission(g.tree, android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION);
                done = true;
            }
        }
        refresh();
        return done;
    }

    JSONArray toJson() {
        JSONArray a = new JSONArray();
        for (Grant g : grants()) {
            try {
                JSONObject o = new JSONObject();
                o.put("path", g.rootPath);
                o.put("label", g.rootPath.equals(TERMUX_HOME) ? "Termux home" : g.rootPath.startsWith(EXT_ROOT) ? "Device storage" + g.rootPath.substring(EXT_ROOT.length()) : g.rootPath);
                a.put(o);
            } catch (Exception ignored) {}
        }
        return a;
    }

    // ------------------------------------------------------------------ URLs

    static String encodePath(String path) {
        StringBuilder sb = new StringBuilder();
        for (String seg : path.split("/")) {
            if (seg.isEmpty()) continue;
            sb.append('/').append(Uri.encode(seg));
        }
        return sb.length() == 0 ? "/" : sb.toString();
    }

    static String urlFor(String path) { return ORIGIN + encodePath(normalize(path)); }

    // ------------------------------------------------------------------ serving

    static final class Result {
        final WebResourceResponse response; final String needsGrantFor;
        Result(WebResourceResponse r, String needs) { response = r; needsGrantFor = needs; }
    }

    /** Serve a https://local.mimir/... request. needsGrantFor is set when no grant covers the path. */
    Result serve(Uri url) {
        String raw = url.getPath() == null ? "/" : url.getPath();
        boolean slash = raw.endsWith("/");
        String path = normalize(raw);
        Grant g = covering(path);
        if (g == null) return new Result(page(403, "Mímir needs access to this folder",
                "<p>A folder picker has opened. Choose <b>Use this folder</b> to let Mímir open files there.</p>"
                + "<p class=m>Tip: grant your Termux home once and every project under it opens instantly.</p>"
                + "<p class=m>" + esc(path) + "</p>"), path);
        try {
            ContentResolver cr = ctx.getContentResolver();
            Uri doc = documentUri(g, path);
            String mime = queryMime(cr, doc);
            if (mime == null) return new Result(page(404, "Not found", "<p class=m>" + esc(path) + "</p>"), null);
            if (DocumentsContract.Document.MIME_TYPE_DIR.equals(mime)) {
                if (!slash) return new Result(redirect(url.getEncodedPath() + "/"), null);
                Uri index = documentUri(g, path.equals("/") ? "/index.html" : path + "/index.html");
                if (queryMime(cr, index) != null) return new Result(stream(cr.openInputStream(index), "text/html"), null);
                return new Result(listing(cr, g, path), null);
            }
            InputStream in = cr.openInputStream(doc);
            if (in == null) return new Result(page(404, "Not found", "<p class=m>" + esc(path) + "</p>"), null);
            return new Result(stream(in, mimeFor(path)), null);
        } catch (SecurityException e) {
            return new Result(page(403, "Access was revoked", "<p>Reopen the file to grant access again.</p>"), path);
        } catch (Exception e) {
            return new Result(page(404, "Not found", "<p class=m>" + esc(path) + "</p><p class=m>" + esc(String.valueOf(e)) + "</p>"), null);
        }
    }

    private static String queryMime(ContentResolver cr, Uri doc) {
        try (Cursor c = cr.query(doc, new String[]{DocumentsContract.Document.COLUMN_MIME_TYPE}, null, null, null)) {
            if (c != null && c.moveToFirst()) return c.getString(0);
        } catch (Exception ignored) {}
        return null;
    }

    private static final Map<String, String> MIME = new HashMap<>();
    static {
        String[][] t = {
            {"html", "text/html"}, {"htm", "text/html"}, {"css", "text/css"},
            {"js", "text/javascript"}, {"mjs", "text/javascript"}, {"cjs", "text/javascript"},
            {"json", "application/json"}, {"map", "application/json"}, {"webmanifest", "application/manifest+json"},
            {"svg", "image/svg+xml"}, {"png", "image/png"}, {"jpg", "image/jpeg"}, {"jpeg", "image/jpeg"},
            {"gif", "image/gif"}, {"webp", "image/webp"}, {"avif", "image/avif"}, {"ico", "image/x-icon"},
            {"wasm", "application/wasm"}, {"txt", "text/plain"}, {"md", "text/markdown"}, {"xml", "application/xml"},
            {"woff", "font/woff"}, {"woff2", "font/woff2"}, {"ttf", "font/ttf"}, {"otf", "font/otf"},
            {"mp4", "video/mp4"}, {"webm", "video/webm"}, {"mp3", "audio/mpeg"}, {"ogg", "audio/ogg"}, {"wav", "audio/wav"},
            {"pdf", "application/pdf"}
        };
        for (String[] e : t) MIME.put(e[0], e[1]);
    }

    static String mimeFor(String path) {
        int dot = path.lastIndexOf('.');
        int sl = path.lastIndexOf('/');
        if (dot < 0 || dot < sl) return "text/plain";
        String ext = path.substring(dot + 1).toLowerCase(Locale.ROOT);
        String m = MIME.get(ext);
        if (m == null) m = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext);
        return m == null ? "application/octet-stream" : m;
    }

    private static Map<String, String> headers() {
        Map<String, String> h = new HashMap<>();
        h.put("Cache-Control", "no-store");            // edit in Termux, reload, see the change
        h.put("Access-Control-Allow-Origin", "*");
        return h;
    }

    private static WebResourceResponse stream(InputStream in, String mime) {
        boolean text = mime.startsWith("text/") || mime.endsWith("json") || mime.endsWith("xml") || mime.equals("image/svg+xml");
        return new WebResourceResponse(mime, text ? "utf-8" : null, 200, "OK", headers(), in);
    }

    private static WebResourceResponse html(int code, String reason, String body) {
        return new WebResourceResponse("text/html", "utf-8", code, reason, headers(),
                new ByteArrayInputStream(body.getBytes(StandardCharsets.UTF_8)));
    }

    private static final String STYLE = "<meta name=viewport content='width=device-width,initial-scale=1'><style>"
            + "body{font:15px/1.5 system-ui,Roboto,sans-serif;background:#0f172a;color:#e2e8f0;margin:0;padding:24px}"
            + "h1{font-size:18px;margin:0 0 14px}a{color:#38bdf8;text-decoration:none}a:hover{text-decoration:underline}"
            + ".m{color:#94a3b8;font-size:13px;word-break:break-all}ul{list-style:none;padding:0;margin:0;max-width:880px}"
            + "li{display:flex;gap:12px;padding:9px 12px;border-bottom:1px solid #1e293b}li span:last-child{margin-left:auto;color:#94a3b8;font-size:13px}"
            + "</style>";

    private static WebResourceResponse page(int code, String title, String body) {
        return html(code, code == 403 ? "Forbidden" : "Not Found",
                "<!doctype html><title>" + esc(title) + "</title>" + STYLE + "<h1>" + esc(title) + "</h1>" + body);
    }

    private static WebResourceResponse redirect(String encodedPath) {
        String u = esc(encodedPath);
        return html(200, "OK", "<!doctype html><meta http-equiv=refresh content='0;url=" + u + "'><script>location.replace('" + u.replace("'", "%27") + "')</script>");
    }

    private WebResourceResponse listing(ContentResolver cr, Grant g, String path) {
        Uri children = DocumentsContract.buildChildDocumentsUriUsingTree(g.tree, pathToDocId(g.authority, path));
        List<String[]> rows = new ArrayList<>();
        try (Cursor c = cr.query(children, new String[]{
                DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE}, null, null, null)) {
            while (c != null && c.moveToNext()) {
                rows.add(new String[]{c.getString(0), c.getString(1), c.isNull(2) ? "" : String.valueOf(c.getLong(2))});
            }
        } catch (Exception ignored) {}
        Collections.sort(rows, (a, b) -> {
            boolean da = DocumentsContract.Document.MIME_TYPE_DIR.equals(a[1]), db = DocumentsContract.Document.MIME_TYPE_DIR.equals(b[1]);
            if (da != db) return da ? -1 : 1;
            return a[0].compareToIgnoreCase(b[0]);
        });
        StringBuilder sb = new StringBuilder("<!doctype html><title>" + esc(path) + "</title>" + STYLE + "<h1>📁 " + esc(path) + "</h1><ul>");
        if (!path.equals(g.rootPath)) sb.append("<li><a href='../'>⬆ Parent folder</a></li>");
        for (String[] r : rows) {
            boolean dir = DocumentsContract.Document.MIME_TYPE_DIR.equals(r[1]);
            String href = Uri.encode(r[0]) + (dir ? "/" : "");
            sb.append("<li><span>").append(dir ? "📁" : "📄").append("</span><a href='").append(esc(href)).append("'>")
              .append(esc(r[0])).append(dir ? "/" : "").append("</a><span>").append(dir ? "" : human(r[2])).append("</span></li>");
        }
        if (rows.isEmpty()) sb.append("<li class=m>Empty folder</li>");
        return html(200, "OK", sb.append("</ul>").toString());
    }

    private static String human(String bytes) {
        if (bytes.isEmpty()) return "";
        long b = Long.parseLong(bytes);
        if (b < 1024) return b + " B";
        if (b < 1024 * 1024) return String.format(Locale.ROOT, "%.1f KB", b / 1024.0);
        return String.format(Locale.ROOT, "%.1f MB", b / (1024.0 * 1024));
    }

    static String esc(String s) {
        return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("'", "&#39;").replace("\"", "&quot;");
    }
}
