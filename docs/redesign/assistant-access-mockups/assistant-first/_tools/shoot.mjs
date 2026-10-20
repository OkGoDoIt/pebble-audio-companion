// Minimal CDP driver: screenshots + audits for the design candidates.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
const SCR = '/Users/roger/Repos/pebble/pebble-audio-companion/docs/redesign/assistant-access-mockups/assistant-first/_tools/.tmp';const OUT = '/Users/roger/Repos/pebble/pebble-audio-companion/docs/redesign/assistant-access-mockups/assistant-first/png';
fs.mkdirSync(SCR, { recursive: true });
const BASE = '/Users/roger/Repos/pebble/pebble-audio-companion/docs/redesign/assistant-access-mockups/assistant-first';
const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
  '--headless=new', '--remote-debugging-port=9347', `--user-data-dir=${SCR}/chrome-prof`,
  '--no-first-run', '--no-default-browser-check', '--allow-file-access-from-files', '--hide-scrollbars', '--autoplay-policy=no-user-gesture-required',
], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let ver;
for (let i = 0; i < 50; i++) { try { ver = await (await fetch('http://127.0.0.1:9347/json/version')).json(); break; } catch { await sleep(200); } }
const ws = new WebSocket(ver.webSocketDebuggerUrl);
await new Promise((r) => (ws.onopen = r));
let id = 0; const pending = new Map(); const listeners = [];
ws.onmessage = (e) => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } else listeners.forEach((f) => f(m)); };
const send = (method, params = {}, sessionId) => new Promise((r) => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params, sessionId })); });

const jobs = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const report = [];
for (const j of jobs) {
  const { result: { targetId } } = await send('Target.createTarget', { url: 'about:blank' });
  const { result: { sessionId } } = await send('Target.attachToTarget', { targetId, flatten: true });
  const logs = []; const net = [];
  const fn = (m) => {
    if (m.sessionId !== sessionId) return;
    if (m.method === 'Runtime.exceptionThrown') logs.push('EXC ' + (m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text));
    if (m.method === 'Runtime.consoleAPICalled' && ['error', 'warning'].includes(m.params.type)) logs.push(m.params.type + ' ' + m.params.args.map((a) => a.value ?? a.description).join(' '));
    if (m.method === 'Log.entryAdded' && ['error', 'warning'].includes(m.params.entry.level)) logs.push('log ' + m.params.entry.text + ' ' + (m.params.entry.url || ''));
    if (m.method === 'Network.requestWillBeSent') { const u = m.params.request.url; if (!/^(file|data|blob|about):/.test(u)) net.push(u); }
  };
  listeners.push(fn);
  await send('Runtime.enable', {}, sessionId); await send('Log.enable', {}, sessionId); await send('Network.enable', {}, sessionId); await send('Page.enable', {}, sessionId);
  await send('Emulation.setDeviceMetricsOverride', { width: j.w, height: j.h || 900, deviceScaleFactor: j.dpr || 1, mobile: j.w < 600 }, sessionId);
  await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: j.dark ? 'dark' : 'light' }, { name: 'prefers-reduced-motion', value: 'no-preference' }] }, sessionId);
  await send('Page.navigate', { url: 'file://' + BASE + '/' + j.url }, sessionId);
  await sleep(j.wait || 1800);
  if (j.js) await send('Runtime.evaluate', { expression: j.js, awaitPromise: true }, sessionId);
  if (j.js) await sleep(j.wait2 || 800);
  const audit = await send('Runtime.evaluate', { returnByValue: true, expression: `(() => {
    const small = [];
    const sel = 'button, a[href], input, select, [role=slider], [role=option], [role=button], [tabindex]:not([tabindex="-1"])';
    for (const el of document.querySelectorAll(sel)) {
      const r = el.getBoundingClientRect(); if (!r.width || !r.height) continue;
      const cs = getComputedStyle(el); if (cs.visibility === 'hidden' || cs.display === 'none' || +cs.opacity === 0 && el.tagName !== 'INPUT') continue;
      // include ::after expansion heuristically: check pseudo
      const af = getComputedStyle(el, '::after'); const expanded = af.content !== 'none' && af.position === 'absolute';
      if ((r.width < 44 || r.height < 44) && !expanded) small.push((el.className && typeof el.className === 'string' ? el.tagName.toLowerCase() + '.' + el.className.split(' ')[0] : el.tagName.toLowerCase()) + ' ' + Math.round(r.width) + 'x' + Math.round(r.height) + ' "' + (el.getAttribute('aria-label') || el.textContent || '').trim().slice(0, 30) + '"');
    }
    const uniq = {}; small.forEach((s) => { const k = s.replace(/ "[^"]*"$/, '').replace(/\\d+x\\d+/, (m) => m); uniq[s.split(' ')[0]+' '+s.split(' ')[1]] = (uniq[s.split(' ')[0]+' '+s.split(' ')[1]] || 0) + 1; });
    return { overflowX: document.documentElement.scrollWidth > innerWidth + 1 ? document.documentElement.scrollWidth : 0, docH: document.documentElement.scrollHeight, smallTargets: uniq, scrollY };
  })()` }, sessionId);
  const shot = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: !!j.full, clip: j.full ? { x: 0, y: 0, width: j.w, height: Math.min(audit.result.result.value.docH, j.maxH || 4000), scale: 1 } : undefined }, sessionId);
  fs.writeFileSync(`${OUT}/${j.name}.png`, Buffer.from(shot.result.data, 'base64'));
  report.push({ name: j.name, ...audit.result.result.value, logs, net });
  listeners.splice(listeners.indexOf(fn), 1);
  await send('Target.closeTarget', { targetId });
}
fs.writeFileSync(`${SCR}/report.json`, JSON.stringify(report, null, 1));
console.log(JSON.stringify(report, null, 1));
ws.close(); chrome.kill();
