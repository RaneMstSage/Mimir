// Minimal DOM stub to boot the Opal chrome bundle in Node and surface runtime errors.
const els = {};
function mk(id){ return { id, innerHTML:'', hidden:false, style:{}, dataset:{}, value:'', listeners:{}, addEventListener(t,f){ (this.listeners[t] ||= []).push(f); }, select(){}, blur(){}, focus(){}, closest(){ return null; } }; }
global.document = { activeElement:null, getElementById(id){ return els[id] ||= mk(id); }, addEventListener(){}, };
global.window = global; global.host = { send(j){ console.log('host.send', j.slice(0,120)); } };
global.setTimeout = (f)=>f();
try {
  require(require('path').resolve(process.argv[2]));
  if (!(els.tabs && els.tabs.innerHTML.length)) throw new Error('tabs did not render');
  const st = {"tabs":[{"id":1,"url":"https://a.test/","title":"A","progress":100,"loading":false,"favicon":null}],"current":1,"url":"https://a.test/","progress":100,"loading":false,"desktop":true,"can_back":false,"can_forward":false,"bookmarks":[],"history":[],"bookmarks_bar":true,"devtools":{"open":false,"side":"right","fraction":0.45}};
  global.UI.receive(JSON.stringify(st));
  if (!els.toolbar.innerHTML.includes('id="url"')) throw new Error('toolbar did not render'); console.log('ui smoke ok');
} catch (e) { console.log('UI RUNTIME ERROR:', e && (e.stack || e)); process.exit(1); }
