(() => {
  const $ = (s) => document.querySelector(s);
  const api = async (path, method = 'GET', body) => {
    const r = await fetch(path, { method, headers: { 'Content-Type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
    return r.json();
  };
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const setPill = (cls, text) => { const p = $('#pill'); if (p) { p.className = 'pill ' + cls; p.textContent = text; } };
  const log = (obj) => { const l = $('#log'); if (!l) return; l.hidden = false; l.textContent = typeof obj === 'string' ? obj : JSON.stringify(obj, null, 2); };

  let lastStatus = null;

  async function refreshStatus() {
    try {
      const s = await api('/api/status'); lastStatus = s;
      if (s.ready) setPill('ok', 'Connected');
      else if (!s.adbd_running) setPill('bad', 'Wireless debugging off');
      else if (!s.adb_connected) setPill('warn', s.paired ? 'adb disconnected' : 'Not paired');
      else setPill('warn', 'Chrome not found');
      renderStatus(s);
    } catch (e) { setPill('bad', 'Backend offline'); }
  }

  function renderStatus(s) {
    const nr = $('#notready'), rd = $('#ready');
    if (nr && rd) {
      nr.hidden = s.ready; rd.hidden = !s.ready;
      if (!s.ready) {
        $('#notready-msg').textContent = !s.adbd_running
          ? 'Wireless debugging is off. Turn it on in Developer options, then tap Connect now.'
          : !s.adb_connected
            ? (s.paired ? 'adb is paired but not connected. Tap Connect now.' : 'This tablet has not been paired with adb yet. Go to Setup.')
            : 'adb is connected but Chrome\'s DevTools socket is not visible. Open Chrome (and make sure USB debugging is on), then tap Connect now.';
      } else if (s.chrome_version) {
        $('#chrome-ver').textContent = s.chrome_version.Browser || '';
      }
    }
    const a = $('#s-adbd'); if (a) { a.textContent = s.adbd_running ? 'adbd is running — Wireless debugging is on.' : 'adbd is not running — Wireless debugging is off.'; a.className = 'status ' + (s.adbd_running ? 'ok' : 'bad'); }
    const c = $('#s-conn'); if (c && !c.dataset.busy) { c.textContent = s.adb_connected ? `Connected to ${s.adb_serial}. Chrome forward: ${s.forwards.chrome_devtools_remote ? 'tcp:' + s.forwards.chrome_devtools_remote : 'none'}${s.chrome_reachable ? ' (DevTools reachable)' : ''}` : 'Not connected.'; c.className = 'status ' + (s.ready ? 'ok' : ''); }
  }

  async function refreshTabs() {
    const ul = $('#tabs'); if (!ul || !lastStatus?.ready) return;
    const tabs = await api('/api/tabs');
    ul.innerHTML = tabs.length ? tabs.map((t) => `
      <li data-id="${esc(t.id)}">
        <img src="${esc(t.favicon || '/icon-192.png')}" alt="" onerror="this.src='/icon-192.png'">
        <div class="t"><b>${esc(t.title || '(untitled)')}</b><span>${esc(t.url)}</span></div>
        <div class="acts">
          <a class="btn primary" style="background:var(--acc);color:#082f49;font-weight:600" href="${esc(t.inspect)}" target="_blank" rel="noopener">Inspect</a>
          <button data-act="activate">Show</button>
          <button data-act="close" class="danger">✕</button>
        </div>
      </li>`).join('') : '<li><div class="t"><b>No open tabs</b><span>Open a page in Chrome or use "New tab".</span></div></li>';
  }

  async function refreshBrowsers() {
    const ul = $('#browsers'); if (!ul || !lastStatus?.ready || !$('#others').open) return;
    const bs = await api('/api/browsers');
    const others = bs.filter((b) => b.socket !== 'chrome_devtools_remote');
    if (!others.length) { ul.innerHTML = '<li><div class="t"><b>None found</b><span>WebViews and other Chromium browsers appear here while they are running (USB debugging + app debuggable/WebView debugging).</span></div></li>'; return; }
    const parts = [];
    for (const b of others) {
      const tabs = await api(`/api/browsers/${b.port}/tabs`);
      parts.push(`<li><div class="t"><b>${esc(b.browser || b.socket)}</b><span>${esc(b.socket)} → localhost:${b.port}</span></div></li>`);
      tabs.forEach((t) => parts.push(`<li style="margin-left:24px"><div class="t"><b>${esc(t.title || '(untitled)')}</b><span>${esc(t.url)}</span></div><div class="acts"><a class="btn" href="${esc(t.frontend)}" target="_blank" rel="noopener">Inspect</a></div></li>`));
    }
    ul.innerHTML = parts.join('');
  }

  async function autoConnect(btn) {
    if (btn) btn.disabled = true;
    setPill('warn', 'Connecting…');
    const st = $('#s-conn'); if (st) { st.dataset.busy = 1; st.textContent = 'Searching for the Wireless debugging port (a few seconds)…'; st.className = 'status'; }
    try {
      const r = await api('/api/connect', 'POST', {});
      log(r);
      if (st) { st.textContent = r.ok ? 'Connected and Chrome forwarded.' : (r.log || []).join(' ') || r.stage; st.className = 'status ' + (r.ok ? 'ok' : 'bad'); }
      if (r.stage === 'unpaired' && st) st.textContent = `Found adb on port ${r.port} but this tablet is not paired yet. Do step 2.`;
    } finally {
      if (st) delete st.dataset.busy;
      if (btn) btn.disabled = false;
      await refreshStatus(); await refreshTabs();
    }
  }

  document.addEventListener('click', async (e) => {
    const b = e.target.closest('button'); if (!b) return;
    if (b.id === 'btn-auto' || b.id === 'btn-auto2') return autoConnect(b);
    if (b.dataset.open) { b.disabled = true; await api(`/api/open/${b.dataset.open}`, 'POST', {}); b.disabled = false; return; }
    if (b.dataset.act) {
      const id = b.closest('li').dataset.id;
      await api(`/api/tabs/${id}/${b.dataset.act}`, 'POST', {});
      setTimeout(refreshTabs, 300);
    }
  });

  $('#newtab')?.addEventListener('submit', async (e) => {
    e.preventDefault();
    await api('/api/tabs', 'POST', { url: $('#newurl').value.trim() });
    $('#newurl').value = '';
    setTimeout(refreshTabs, 500);
  });

  $('#pairform')?.addEventListener('submit', async (e) => {
    e.preventDefault();
    const st = $('#s-pair'); st.textContent = 'Pairing…'; st.className = 'status';
    const r = await api('/api/pair', 'POST', { port: $('#pair-port').value, code: $('#pair-code').value });
    log(r);
    st.textContent = r.ok ? 'Paired! ' + (r.connect?.ok ? 'Connected and Chrome forwarded.' : 'Now tap Auto connect.') : ('Pairing failed: ' + r.out);
    st.className = 'status ' + (r.ok ? 'ok' : 'bad');
    refreshStatus();
  });

  $('#connform')?.addEventListener('submit', async (e) => {
    e.preventDefault();
    const port = $('#conn-port').value.trim(); if (!port) return autoConnect();
    const st = $('#s-conn'); st.dataset.busy = 1; st.textContent = `Connecting to port ${port}…`;
    const r = await api('/api/connect', 'POST', { port });
    log(r); delete st.dataset.busy;
    st.textContent = r.ok ? 'Connected.' : ('Failed: ' + r.out); st.className = 'status ' + (r.ok ? 'ok' : 'bad');
    refreshStatus();
  });

  $('#others')?.addEventListener('toggle', refreshBrowsers);

  if ('serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').catch(() => {});

  refreshStatus().then(refreshTabs);
  setInterval(async () => { await refreshStatus(); await refreshTabs(); }, 4000);
})();
