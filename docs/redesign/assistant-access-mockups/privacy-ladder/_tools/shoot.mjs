// CDP screenshot driver for the privacy-ladder mockups (adapted from the session's cdp.mjs).
// Usage: node shoot.mjs <file.html>[#dark] ...   → ../shots/<file>[-dark].png at 390x844 @2x
// Also: node shoot.mjs --page index.html 1600 → full-page shot of a wide page.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
const DIR = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const OUT = path.join(DIR, 'shots');
const PROF = fs.mkdtempSync(path.join(process.env.TMPDIR || os.tmpdir(), 'ladder-chrome-'));
const PORT = 9300 + Math.floor(Math.random() * 300);
const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
  '--headless=new', `--remote-debugging-port=${PORT}`, `--user-data-dir=${PROF}`,
  '--no-first-run', '--no-default-browser-check', '--allow-file-access-from-files', '--hide-scrollbars',
], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let ver;
for (let i = 0; i < 60; i++) { try { ver = await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json(); break; } catch { await sleep(200); } }
const ws = new WebSocket(ver.webSocketDebuggerUrl);
await new Promise((r) => (ws.onopen = r));
let id = 0; const pending = new Map(); const listeners = [];
ws.onmessage = (e) => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } else listeners.forEach((f) => f(m)); };
const send = (method, params = {}, sessionId) => new Promise((r) => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params, sessionId })); });

const args = process.argv.slice(2);
const jobs = [];
if (args[0] === '--page') jobs.push({ url: args[1], w: +args[2] || 1600, h: 900, full: true, dpr: 1, out: args[3] || args[1].replace('.html', '.png') });
else for (const a of args) { const dark = a.endsWith('#dark'); const f = a.replace('#dark', ''); jobs.push({ url: a, w: 390, h: 844, dpr: 2, dark, out: 'shots/' + f.replace('.html', '') + (dark ? '-dark' : '') + '.png' }); }

const report = [];
for (const j of jobs) {
  const { result: { targetId } } = await send('Target.createTarget', { url: 'about:blank' });
  const { result: { sessionId } } = await send('Target.attachToTarget', { targetId, flatten: true });
  const logs = []; const net = [];
  const fn = (m) => {
    if (m.sessionId !== sessionId) return;
    if (m.method === 'Runtime.exceptionThrown') logs.push('EXC ' + (m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text));
    if (m.method === 'Runtime.consoleAPICalled' && ['error', 'warning'].includes(m.params.type)) logs.push(m.params.type + ' ' + m.params.args.map((a) => a.value ?? a.description).join(' '));
    if (m.method === 'Log.entryAdded' && ['error', 'warning'].includes(m.params.entry.level)) logs.push('log ' + m.params.entry.text);
    if (m.method === 'Network.requestWillBeSent') { const u = m.params.request.url; if (!/^(file|data|blob|about):/.test(u)) net.push(u); }
  };
  listeners.push(fn);
  for (const d of ['Runtime', 'Log', 'Network', 'Page']) await send(d + '.enable', {}, sessionId);
  await send('Emulation.setDeviceMetricsOverride', { width: j.w, height: j.h, deviceScaleFactor: j.dpr, mobile: j.w < 600 }, sessionId);
  await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: j.dark ? 'dark' : 'light' }] }, sessionId);
  await send('Page.navigate', { url: 'file://' + DIR + '/' + j.url }, sessionId);
  await sleep(j.full ? 3500 : 1200);
  const audit = await send('Runtime.evaluate', { returnByValue: true, expression: `(() => {
    const small = [];
    for (const el of document.querySelectorAll('button, a[href], [role=switch]')) {
      const r = el.getBoundingClientRect(); if (!r.width) continue;
      if (r.height < 44 && !el.classList.contains('switch') && !el.closest('.tabbar')) small.push(el.className + ' ' + Math.round(r.width) + 'x' + Math.round(r.height));
    }
    const sc = document.querySelector('.scroll'); const over = [];
    if (sc) for (const el of sc.querySelectorAll('*')) { const r = el.getBoundingClientRect(); if (r.right > 390.5 && r.width) over.push(el.className || el.tagName); }
    return { docH: document.documentElement.scrollHeight, contentBottom: sc ? Math.round(Math.max(...[...sc.children].map(c => c.getBoundingClientRect().bottom))) : 0, small, over: over.slice(0, 5) };
  })()` }, sessionId);
  const v = audit.result.result.value;
  const shot = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: !!j.full, clip: j.full ? { x: 0, y: 0, width: j.w, height: v.docH, scale: 1 } : undefined }, sessionId);
  fs.writeFileSync(path.join(DIR, j.out), Buffer.from(shot.result.data, 'base64'));
  report.push({ name: j.out, ...v, logs, net });
  listeners.splice(listeners.indexOf(fn), 1);
  await send('Target.closeTarget', { targetId });
}
console.log(JSON.stringify(report));
ws.close(); chrome.kill(); await sleep(600); try { fs.rmSync(PROF, { recursive: true, force: true, maxRetries: 5 }); } catch {}
