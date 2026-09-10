// Boot the compiled chrome in a real DOM (jsdom) and report runtime errors, like the WebView would.
const fs = require('fs'), path = require('path');
const { JSDOM } = require('jsdom');
const dir = path.resolve(process.argv[2]);              // build/stage/assets/ui
const html = fs.readFileSync(path.join(dir, 'ui.html'), 'utf8').replace('<script src="ui.js"></script>', '');
const dom = new JSDOM(html, { runScripts: 'outside-only', pretendToBeVisual: true });
const { window } = dom;
const sent = [];
window.host = { send: (j) => sent.push(JSON.parse(j)) };
const errors = [];
window.addEventListener('error', (e) => errors.push(String(e.error && e.error.stack || e.message)));
try {
  window.eval(fs.readFileSync(path.join(dir, 'ui.js'), 'utf8'));
} catch (e) { errors.push('eval: ' + (e.stack || e)); }
const doc = window.document;
const report = (label) => console.log(label, '| tabs:', doc.getElementById('tabs').innerHTML.length, 'toolbar:', doc.getElementById('toolbar').innerHTML.length, 'sent:', sent.map(s => s.ev).join(','));
report('after boot');
const st = {"tabs":[{"id":1,"url":"https://a.test/","title":"A","progress":100,"loading":false,"favicon":null}],"current":1,"url":"https://a.test/","progress":100,"loading":false,"desktop":true,"can_back":false,"can_forward":false,"bookmarks":{"bar":{"id":"bar","type":"folder","title":"Bookmarks bar","children":[{"id":"b1","type":"url","url":"https://a.test/","title":"A"},{"id":"b2","type":"folder","title":"Work","children":[{"id":"b3","type":"url","url":"https://w.test/","title":"W"}]}]},"other":{"id":"other","type":"folder","title":"Other bookmarks","children":[]}},"bookmarks_flat":[{"id":"b1","url":"https://a.test/","title":"A"},{"id":"b3","url":"https://w.test/","title":"W"}],"history":[{"url":"https://h.test/","title":"H","at":Math.floor(Date.now()/1000)}],"bookmarks_bar":true,"settings":{"search":"google","home":"https://www.google.com/","desktop_ua":true,"bookmarks_bar":true,"force_dark":false,"text_zoom":100,"javascript":true,"cookies_3p":true,"dock_side":"right","devtools_theme":"dark","devtools_screencast":false},"version":{"app":"0.6.0","ruby":"4.0.0"},"devtools":{"open":false,"side":"right","fraction":0.45}};
try { window.UI.receive(JSON.stringify(st)); } catch (e) { errors.push('receive: ' + (e.stack || e)); }
report('after receive');
const click = (el) => el.dispatchEvent(new window.MouseEvent('click', { bubbles: true, cancelable: true }));
try {
  click(doc.querySelector('[data-act="menu.toggle"]'));
  console.log('menu expands chrome:', sent.some(s => s.ev === 'chrome.height' && s.expand === true), '| menu visible:', !doc.getElementById('menu').hidden);
  click(doc.querySelector('[data-act="page:settings"]'));
  console.log('settings page:', doc.getElementById('page').innerHTML.includes('Search engine'));
  click(doc.querySelector('[data-act="section:privacy"]')); console.log('privacy section:', doc.getElementById('page').innerHTML.includes('JavaScript'));
  click(doc.querySelector('[data-act="page:close"]')); click(doc.querRelector ? null : doc.querySelector('[data-act="menu.toggle"]')); click(doc.querySelector('[data-act="page:history"]'));
  console.log('history page:', doc.getElementById('page').innerHTML.includes('h.test'));
  click(doc.querySelector('[data-act="page:close"]')); click(doc.querySelector('[data-act="menu.toggle"]')); click(doc.querySelector('[data-act="page:bookmarks"]'));
  const pg = doc.getElementById('page').innerHTML;
  console.log('bookmarks manager:', pg.includes('Work') && pg.includes('New folder') && pg.includes('class="tree"'));
  click(doc.querySelector('[data-act="mgr.folder"][data-id="b2"]'));
  console.log('into folder:', doc.getElementById('page').innerHTML.includes('w.test'));
  click(doc.querySelector('[data-act="page:close"]'));
  const fb = doc.querySelector('[data-act="bmfolder"]'); if (!fb) throw new Error('no folder button on bar'); click(fb);
  console.log('bar folder dropdown:', !doc.getElementById('bmdrop').hidden && doc.getElementById('bmdrop').innerHTML.includes('w.test'));
  click(doc.querySelector('[data-act="bookmark.toggle"]'));
  console.log('star popup:', !doc.getElementById('bmpop').hidden && doc.getElementById('bmpop').innerHTML.includes('Bookmark added'));
  click(doc.querySelector('[data-act="page:close"]')); click(doc.querySelector('[data-act="tab.new"]'));
  console.log('tab.new sent:', sent.some(s => s.ev === 'tab.new'));
} catch (e) { errors.push('interact: ' + (e.stack || e)); }
if (errors.length) { console.log('ERRORS:\n' + errors.join('\n---\n').slice(0, 3000)); process.exit(1); }
console.log('jsdom smoke ok');
