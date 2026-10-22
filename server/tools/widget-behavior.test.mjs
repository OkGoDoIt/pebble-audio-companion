// Run with: node --test server/tools/widget-behavior.test.mjs
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import { test } from 'node:test';
import assert from 'node:assert/strict';

const bridge = readFileSync(new URL('../src/PebbleAudio.Server/wwwroot/widgets/bridge.js', import.meta.url), 'utf8')
  .replace(/^export /gm, '');

function host() {
  const events = new Map(), renders = [];
  const document = { documentElement: { dataset: {}, style: {} } };
  const window = {
    parent: { postMessage() {} },
    openai: { theme: 'light', toolOutput: { found: true, overview: 'First summary' } },
    addEventListener: (name, callback) => events.set(name, callback),
  };
  runInNewContext(bridge + '\nconnectHost({name:"test",onResult:result=>renders.push(result)});', {
    window, document, renders, setTimeout() {},
  });
  return { window, document, events, renders };
}

test('repeated host results preserve the current view while applying theme changes', () => {
  const h = host();
  assert.equal(h.renders.length, 1);
  h.window.openai.theme = 'dark';
  h.events.get('openai:set_globals')();
  assert.equal(h.document.documentElement.dataset.theme, 'dark');
  h.events.get('message')({ source: h.window.parent, data: {
    jsonrpc: '2.0', method: 'ui/notifications/tool-result', params: { structuredContent: h.window.openai.toolOutput },
  } });
  assert.equal(h.renders.length, 1);
});

test('changed content or a renewed signed audio link still reaches the widget', () => {
  const h = host();
  h.window.openai.toolOutput = { found: true, overview: 'Updated summary' };
  h.events.get('openai:set_globals')();
  assert.equal(h.renders.length, 2);
  h.window.openai.toolResponseMetadata = { 'pebbleaudio/audio': { url: 'https://example.invalid/new' } };
  h.events.get('openai:set_globals')();
  assert.equal(h.renders.length, 3);
});

const summary = readFileSync(new URL('../src/PebbleAudio.Server/wwwroot/widgets/summary.js', import.meta.url), 'utf8');
test('a legacy transcript result retrieves its missing summary while still collapsed', async () => {
  const paragraph = { textContent: 'Loading summary…' }, status = { hidden: true };
  let missing = true, calls = 0;
  const wrap = {
    dataset: { conversation: 'conversation-id' }, isConnected: true,
    querySelector: selector => selector === '.w-sum' ? paragraph : status,
    removeAttribute: () => { missing = false; },
  };
  const root = {
    classList: { contains: () => false },
    querySelectorAll: selector => missing && selector.includes('data-summary-missing') ? [wrap] : [],
  };
  const context = {
    document: { addEventListener() {} }, root,
    callTool: async (name, args) => {
      calls++;
      assert.equal(name, 'get_conversation');
      assert.equal(args.include, 'summary');
      assert.equal(args.id, 'conversation-id');
      return { structuredContent: { found: true, overview: 'The useful conversation summary.' } };
    },
  };
  await runInNewContext(summary + '\nloadExpandedSummaries(root)', context);
  assert.equal(paragraph.textContent, 'The useful conversation summary.');
  assert.equal(status.hidden, true);
  await runInNewContext(summary + '\nloadExpandedSummaries(root)', context);
  assert.equal(calls, 1);
});
