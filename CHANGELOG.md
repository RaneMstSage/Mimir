# Changelog

All notable changes to Mímir. Versions match the Play Store and GitHub releases.

## 0.8.7 — unreleased

### Added
- **Open local files and folders.** From Termux, `mimir index.html`, `mimir ~/Projects/site` or
  `mimir .` opens the file or folder in Mímir, the way `chrome <file>` works on a desktop. In the app,
  use ⋮ → **Open file…** or ⋮ → **Open folder…**.
- Local projects behave like a real site: relative links, ES modules and `fetch()` all work, and
  reloading shows your latest edits. A folder without `index.html` shows a file listing.
- The address bar shows local pages as `file://…` with a 📄 icon. Typing a path or a `file://` address
  also works.
- **Storage access** (GitHub build): opening a file in device storage asks once for storage access,
  like Termux's storage setup, then files open by path with no picker.
- **Folder access:** Termux projects, and all projects in the Play Store build, use Android's folder
  picker once. Granting your Termux home covers every project under it. Mímir explains which folder
  and where to tap before the picker opens.
- Settings → Privacy & data → **Folders Mímir can open**, with Remove.

### Notes
- The Play Store build does not request all-files storage access (Google Play policy for browsers);
  it uses the folder picker instead.

## 0.8.6 — 2026-09-13
- Inspect element is faster when DevTools is already open.

## 0.8.5 — 2026-09-11
- Google sign-in works: pages present themselves as Chrome.
- Fixed editing styles and attributes in DevTools with the on-screen keyboard.
- Desktop-style right-click menu on pages: open link, copy, search the selection, inspect element.
- Mouse back and forward buttons navigate history (one step per click).
- Arrow keys move through address-bar suggestions.
- More stable DevTools connection.

## 0.8.4 — 2026-09-10
- Phone layout: toolbar buttons stay visible in portrait, the menu scrolls, DevTools docks at the
  bottom on narrow screens.
- New launcher icon, privacy policy link in About, quieter status line.
- Play purchase verification for tips; native crash symbols for better reports.

## 0.8.2 — 2026-09-10
- First Play Store release: real Chrome DevTools inside the browser, tabs, bookmarks with folders,
  history, Chrome-style settings, user scripts and styles with request blocking, optional tip jar.
