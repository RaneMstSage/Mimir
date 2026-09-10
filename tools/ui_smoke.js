// Minimal DOM stub to boot the Opal chrome bundle in Node and surface runtime errors.
const els = {};
function mk(id){ return { id, innerHTML:'', hidden:false, style:{}, dataset:{}, value:'', listeners:{}, addEventListener(t,f){ (this.listeners[t] ||= []).push(f); }, select(){}, blur(){}, focus(){}, closest(){ return null; } }; }
const docListeners = {};
global.document = { activeElement:null, getElementById(id){ return els[id] ||= mk(id); }, addEventListener(t,f){ (docListeners[t] ||= []).push(f); }, };
global.window = global; global.host = { send(j){ console.log('host.send', j.slice(0,120)); } };
global.setTimeout = (f)=>f();
try {
  require(require('path').resolve(process.argv[2]));
  if (!(els.tabs && els.tabs.innerHTML.length)) throw new Error('tabs did not render');
  const st = {"tabs":[{"id":1,"url":"https://a.test/","title":"A","progress":100,"loading":false,"favicon":null}],"current":1,"url":"https://a.test/","progress":100,"loading":false,"desktop":true,"can_back":false,"can_forward":false,"bookmarks":[],"history":[],"bookmarks_bar":true,"devtools":{"open":false,"side":"right","fraction":0.45}};
  global.UI.receive(JSON.stringify(st));
  if (!els.toolbar.innerHTML.includes('id="url"')) throw new Error('toolbar did not render');
  // simulate a tap on the "+" (new tab) button
  let sent = [];
  global.host.send = (j) => sent.push(JSON.parse(j));
  const btn = { dataset: { act: 'tab.new' }, closest(sel){ return sel === '[data-act]' ? btn : null; } };
  const ev = { target: btn, preventDefault(){}, stopPropagation(){} };
  (docListeners.click || []).forEach(f => f(ev));
  if (!sent.some(e => e.ev === 'tab.new')) throw new Error('tap on + did not emit tab.new; sent=' + JSON.stringify(sent));
  console.log('ui smoke ok (render + tap)');
} catch (e) { console.log('UI RUNTIME ERROR:', e && (e.stack || e)); process.exit(1); }
