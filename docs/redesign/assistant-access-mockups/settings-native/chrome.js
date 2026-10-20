// Shared phone chrome for the mockups: theme from ?theme=dark, the status bar, the tab bar,
// and a tiny SF-Symbol-like glyph set (<i data-i="name"></i>). No network, no framework.
(function () {
  try {
    const t = new URLSearchParams(location.search).get('theme');
    if (t === 'dark' || t === 'light') document.documentElement.setAttribute('data-theme', t);
  } catch (e) { /* file:// without search is fine */ }

  const S = (d, vb = '0 0 24 24') => `<svg viewBox="${vb}" aria-hidden="true">${d}</svg>`;
  const G = {
    chev: S('<path d="M1.5 1.5 6.5 7l-5 5.5"/>', '0 0 8 14'),
    back: S('<path d="M10 2 2 10l8 8"/>', '0 0 12 20'),
    waveform: S('<path d="M3 12h1M7 8v8M11 4v16M15 7v10M19 10v4M21 12h0"/>'),
    clock: S('<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/>'),
    checklist: S('<path d="M4 6.5l1.6 1.6L8.5 5M4 12.5l1.6 1.6 2.9-3.1M4 18.5l1.6 1.6 2.9-3.1M11.5 7h8.5M11.5 13h8.5M11.5 19h8.5"/>'),
    sparkles: S('<path d="M10 3.5l1.6 4.4L16 9.5l-4.4 1.6L10 15.5l-1.6-4.4L4 9.5l4.4-1.6zM17.5 14l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8z"/>'),
    gear: S('<circle cx="12" cy="12" r="3.2"/><path d="M12 2.8v2.4M12 18.8v2.4M2.8 12h2.4M18.8 12h2.4M5.5 5.5l1.7 1.7M16.8 16.8l1.7 1.7M5.5 18.5l1.7-1.7M16.8 7.2l1.7-1.7"/><circle cx="12" cy="12" r="6.6"/>'),
    watch: S('<rect x="6.5" y="6" width="11" height="12" rx="3"/><path d="M9 6l.6-3h4.8l.6 3M9 18l.6 3h4.8l.6-3"/>'),
    text: S('<path d="M6 3.5h8l4 4v13H6z"/><path d="M14 3.5v4h4M9 12h6M9 15.5h6"/>'),
    mic: S('<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21"/>'),
    chat: S('<path d="M4 5.5h16v10H10l-4.5 3.5v-3.5H4z"/>'),
    laptop: S('<rect x="4.5" y="5" width="15" height="10" rx="1.5"/><path d="M2.5 18.5h19"/>'),
    trash: S('<path d="M4.5 6.5h15M9.5 6.5V4h5v2.5M6.5 6.5l1 13.5h9l1-13.5"/>'),
    server: S('<rect x="4" y="4" width="16" height="7" rx="2"/><rect x="4" y="13" width="16" height="7" rx="2"/><path d="M7.5 7.5h.01M7.5 16.5h.01"/>'),
    hand: S('<path d="M12 21c-4.4 0-7-3-7-7.5V8.5"/><path d="M12 21c4.4 0 7-3 7-7.5V5.5"/><path d="M5 4.5 12 3l7 2.5"/><path d="M9 12l2 2 4-4"/>'),
    check: S('<circle cx="12" cy="12" r="10" fill="currentColor" stroke="none"/><path d="M7.5 12.3l3 3 6-6.3" stroke="#fff" stroke-width="2.2" fill="none" stroke-linecap="round" stroke-linejoin="round"/>'),
    qr: S('<rect x="3.5" y="3.5" width="6.5" height="6.5" rx="1"/><rect x="14" y="3.5" width="6.5" height="6.5" rx="1"/><rect x="3.5" y="14" width="6.5" height="6.5" rx="1"/><path d="M14 14h2.5v2.5H14zM18 18h2.5v2.5H18zM18 14h2.5M14 20.5h2.5"/>'),
    open: S('<path d="M14 4.5h5.5V10M19.5 4.5 11 13M17 14v5.5H4.5V7H10"/>'),
    clip: S('<path d="M4 12h1.5M7.5 9v6M11 6.5v11M14.5 9.5v5M18 11v2M20 12h0"/>'),
    note: S('<path d="M5 4.5h14v15H5z"/><path d="M8.5 9h7M8.5 12.5h7M8.5 16h4"/>'),
  };

  function icons(root) {
    root.querySelectorAll('i[data-i]').forEach((el) => {
      const g = G[el.dataset.i];
      if (!g) return;
      el.outerHTML = g.replace('<svg', `<svg class="${el.className || ''}"`);
    });
  }

  const bar = document.querySelector('.statusbar');
  if (bar) {
    bar.innerHTML = `<span>9:41</span><span class="icons">
      <svg width="18" height="12" viewBox="0 0 18 12" aria-hidden="true"><rect x="0" y="8" width="3" height="4" rx="1"/><rect x="5" y="5.5" width="3" height="6.5" rx="1"/><rect x="10" y="3" width="3" height="9" rx="1"/><rect x="15" y="0" width="3" height="12" rx="1"/></svg>
      <svg width="16" height="12" viewBox="0 0 16 12" aria-hidden="true"><path d="M8 2.2c2.4 0 4.6.9 6.2 2.5l1.2-1.3A10.4 10.4 0 0 0 8 .4C5.2.4 2.6 1.5.6 3.4l1.2 1.3A8.7 8.7 0 0 1 8 2.2zm0 3.6c1.4 0 2.7.5 3.7 1.4l1.2-1.3A7.1 7.1 0 0 0 8 4a7.1 7.1 0 0 0-4.9 1.9l1.2 1.3c1-.9 2.3-1.4 3.7-1.4zm0 3.5c-.6 0-1.2.2-1.6.6L8 11.6l1.6-1.7c-.4-.4-1-.6-1.6-.6z"/></svg>
      <svg width="27" height="13" viewBox="0 0 27 13" aria-hidden="true"><rect x="0.5" y="0.5" width="22" height="12" rx="3.8" fill="none" stroke="currentColor" stroke-opacity="0.4"/><rect x="2" y="2" width="17" height="9" rx="2.4"/><path d="M24.5 4.5v4c.8-.3 1.5-1.1 1.5-2s-.7-1.7-1.5-2z" fill-opacity="0.45"/></svg>
    </span>`;
  }

  const tabbar = document.querySelector('.tabbar');
  if (tabbar) {
    const on = tabbar.dataset.on;
    const tabs = [['today', 'Today', 'waveform'], ['history', 'History', 'clock'], ['followups', 'Follow-ups', 'checklist'], ['ask', 'Ask', 'sparkles'], ['settings', 'Settings', 'gear']];
    tabbar.innerHTML = tabs.map(([k, l, i]) => `<button class="tab${k === on ? ' on' : ''}" aria-label="${l}"><i data-i="${i}"></i>${l}</button>`).join('');
  }
  icons(document);
})();
