// The MCP Apps host bridge, by hand (no SDK bundle): JSON-RPC 2.0 over postMessage with the host frame
// (ext-apps specification 2026-01-26), plus ChatGPT's window.openai where it is there. Included inline in each
// widget. See docs/research-verified-2026-10-20.md §3.
//
//   connectHost({ name, onResult })  renders from the host's tool result: { structuredContent, _meta }
//   openLink(url)                    leaves through the host (Claude asks the person first)
//   callTool(name, args)             reads more from the server through the host
//   watchSize()                      tells the host how tall the widget is

const HOST_PROTOCOL = '2026-01-26';
const hostPending = new Map();
let hostNextId = 1;
let hostReady = false;
let hostCapabilities = {};

function hostPost(message) {
  window.parent.postMessage({ jsonrpc: '2.0', ...message }, '*');
}

function hostRequest(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = hostNextId++;
    hostPending.set(id, { resolve, reject });
    hostPost({ id, method, params });
    setTimeout(() => {
      if (hostPending.delete(id)) reject(new Error(`${method} timed out`));
    }, 15000);
  });
}

function hostNotify(method, params = {}) {
  hostPost({ method, params });
}

/** The host's theme and fonts; our own tokens stay, only the font family and light or dark follow the host. */
function hostApply(context = {}) {
  const root = document.documentElement;
  const theme = context.theme ?? window.openai?.theme;
  if (theme === 'dark' || theme === 'light') root.dataset.theme = theme;
  const font = context.styles?.variables?.['--font-sans'];
  if (font) root.style.setProperty('--font-sans', font);
  if (context.styles?.css?.fonts && !document.getElementById('host-fonts')) {
    const style = document.createElement('style');
    style.id = 'host-fonts';
    style.textContent = context.styles.css.fonts;
    document.head.append(style);
  }
  const inset = context.safeAreaInsets;
  if (inset) Object.assign(document.body.style, { paddingTop: `${inset.top}px`, paddingRight: `${inset.right}px`, paddingBottom: `${inset.bottom}px`, paddingLeft: `${inset.left}px` });
}

export function connectHost({ name, onResult }) {
  let rendered = false;
  const render = (result) => {
    if (!result) return;
    rendered = true;
    onResult({ structuredContent: result.structuredContent ?? null, _meta: result._meta ?? {}, content: result.content ?? [] });
  };

  window.addEventListener('message', (event) => {
    if (event.source !== window.parent) return;
    const m = event.data;
    if (!m || m.jsonrpc !== '2.0') return;
    if (m.id !== undefined && !m.method) {
      const waiting = hostPending.get(m.id);
      if (!waiting) return;
      hostPending.delete(m.id);
      m.error ? waiting.reject(m.error) : waiting.resolve(m.result);
      return;
    }
    if (m.id !== undefined && m.method) {
      // ping and ui/resource-teardown: answered at once; a teardown stops the audio first.
      if (m.method === 'ui/resource-teardown') document.querySelectorAll('audio').forEach((a) => a.pause());
      hostPost({ id: m.id, result: {} });
      return;
    }
    if (m.method === 'ui/notifications/tool-result') render(m.params);
    else if (m.method === 'ui/notifications/host-context-changed') hostApply(m.params);
  });

  // ChatGPT sets its globals before or instead of the notification, and again when they change.
  const fromOpenAi = () => {
    if (window.openai?.toolOutput) render({ structuredContent: window.openai.toolOutput, _meta: window.openai.toolResponseMetadata ?? {} });
    hostApply({ theme: window.openai?.theme });
  };
  window.addEventListener('openai:set_globals', fromOpenAi);

  hostRequest('ui/initialize', {
    protocolVersion: HOST_PROTOCOL,
    appInfo: { name, version: '1.0.0' },
    appCapabilities: { availableDisplayModes: ['inline'] },
  }).then((init) => {
    hostReady = true;
    hostCapabilities = init?.hostCapabilities ?? {};
    hostApply(init?.hostContext);
    hostNotify('ui/notifications/initialized');
  }).catch(() => {
    // A host without the MCP Apps bridge: ChatGPT's globals, if any, are all there is.
  });

  if (window.openai) fromOpenAi();
  return { get rendered() { return rendered; } };
}

export async function openLink(url) {
  if (window.openai?.openExternal) {
    window.openai.openExternal({ href: url });
    return;
  }
  if (hostReady) {
    try {
      await hostRequest('ui/open-link', { url });
      return;
    } catch {
      // Fall through to the browser.
    }
  }
  window.open(url, '_blank', 'noopener');
}

/** A server tool through the host. Resolves to { structuredContent, content, _meta }. */
export async function callTool(name, args) {
  if (hostReady && hostCapabilities.serverTools) return hostRequest('tools/call', { name, arguments: args });
  if (window.openai?.callTool) {
    const r = await window.openai.callTool(name, args);
    return r?.structuredContent ? r : { structuredContent: r?.result ?? r, _meta: r?._meta ?? {} };
  }
  throw new Error('This host cannot call tools from a widget.');
}

export function watchSize() {
  let last = 0;
  const report = () => {
    const height = Math.ceil(document.documentElement.getBoundingClientRect().height);
    if (height === last) return;
    last = height;
    hostNotify('ui/notifications/size-changed', { width: Math.ceil(window.innerWidth), height });
    window.openai?.notifyIntrinsicHeight?.(height);
  };
  new ResizeObserver(report).observe(document.documentElement);
  report();
}
