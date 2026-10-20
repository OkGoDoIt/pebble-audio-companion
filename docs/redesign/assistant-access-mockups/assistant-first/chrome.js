// Shared phone chrome for the mockups: status bar, floating tab bar, icons, and assistant marks.
// Purely presentational; runs from file:// with no network. `#dark` in the URL forces the dark
// appearance (the gallery uses it); otherwise the page follows prefers-color-scheme.
(() => {
  if (location.hash === '#dark') document.documentElement.dataset.theme = 'dark';
  if (location.hash === '#light') document.documentElement.dataset.theme = 'light';

  const s = (d, extra = '') =>
    `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" ${extra}>${d}</svg>`;

  const I = {
    chevR: '<svg class="chev" viewBox="0 0 8 14" fill="none" aria-hidden="true"><path d="M1 1l6 6-6 6" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    chevL: s('<path d="M15 4l-8 8 8 8" stroke-width="2.4"/>'),
    chevD: s('<path d="M6 9l6 6 6-6" stroke-width="2.2"/>'),
    chevU: s('<path d="M6 15l6-6 6 6" stroke-width="2.2"/>'),
    x: s('<path d="M6 6l12 12M18 6L6 18" stroke-width="2.3"/>'),
    check: s('<path d="M5 12.5l4.5 4.5L19 7.5" stroke-width="2.8"/>'),
    checkThin: s('<path d="M5 12.5l4.5 4.5L19 7.5" stroke-width="2.2"/>'),
    wave: s('<path d="M4 10v4M8 6v12M12 9v6M16 4v16M20 8v8" stroke-width="2.2"/>'),
    history: s('<path d="M3.5 12a8.5 8.5 0 1 0 2.6-6.1"/><path d="M3 4.5v4h4"/><path d="M12 7.5V12l3 2"/>'),
    checklist: s('<path d="M4 6.5l1.6 1.6L8.5 5M4 12.5l1.6 1.6 2.9-3.1M4 18.5l1.6 1.6 2.9-3.1"/><path d="M11.5 7h8.5M11.5 13h8.5M11.5 19h8.5"/>'),
    sparkles: s('<path d="M10 3.5c.7 3.9 2.6 5.8 6.5 6.5-3.9.7-5.8 2.6-6.5 6.5-.7-3.9-2.6-5.8-6.5-6.5 3.9-.7 5.8-2.6 6.5-6.5z"/><path d="M18 14.5c.3 1.8 1.2 2.7 3 3-1.8.3-2.7 1.2-3 3-.3-1.8-1.2-2.7-3-3 1.8-.3 2.7-1.2 3-3z"/>'),
    gear: s('<circle cx="12" cy="12" r="3.2"/><path d="M12 2.8v2.6M12 18.6v2.6M21.2 12h-2.6M5.4 12H2.8M18.5 5.5l-1.8 1.8M7.3 16.7l-1.8 1.8M18.5 18.5l-1.8-1.8M7.3 7.3L5.5 5.5"/>'),
    doc: s('<path d="M6.5 3h7l4 4v14h-11z"/><path d="M13.5 3v4h4M9 12h6M9 15.5h6M9 19h3.5"/>'),
    lockPhone: s('<rect x="6.5" y="2.5" width="11" height="19" rx="2.6"/><path d="M10.5 18.5h3"/>'),
    person: s('<circle cx="12" cy="8" r="3.6"/><path d="M4.5 20c.8-4 3.8-6 7.5-6s6.7 2 7.5 6"/>'),
    personCheck: s('<circle cx="10" cy="8" r="3.6"/><path d="M3 20c.8-4 3.6-6 7-6 1.6 0 3 .4 4.2 1.2"/><path d="M15 18l2 2 4-4.5"/>'),
    qr: s('<rect x="3.5" y="3.5" width="6.5" height="6.5" rx="1"/><rect x="14" y="3.5" width="6.5" height="6.5" rx="1"/><rect x="3.5" y="14" width="6.5" height="6.5" rx="1"/><path d="M14 14h2.5v2.5H14zM18 18h2.5v2.5H18zM18 14h2.5M14 20.5h2.5"/>'),
    camera: s('<path d="M3.5 8.5a2 2 0 0 1 2-2h2.2l1.6-2.2h5.4l1.6 2.2h2.2a2 2 0 0 1 2 2v9.5a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2z"/><circle cx="12" cy="13" r="3.6"/>'),
    copy: s('<rect x="8.5" y="8.5" width="11.5" height="11.5" rx="2.2"/><path d="M15.5 8.5V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v7.5a2 2 0 0 0 2 2h2.5"/>'),
    server: s('<rect x="3.5" y="4" width="17" height="6.5" rx="1.8"/><rect x="3.5" y="13.5" width="17" height="6.5" rx="1.8"/><path d="M7 7.25h.01M7 16.75h.01" stroke-width="2.8"/>'),
    laptop: s('<rect x="5" y="5" width="14" height="10" rx="1.6"/><path d="M2.5 18.5h19"/>'),
    plus: s('<path d="M12 5v14M5 12h14" stroke-width="2.2"/>'),
    external: s('<path d="M14 4h6v6M20 4l-9 9"/><path d="M18 14v4.5a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 4 18.5v-11A1.5 1.5 0 0 1 5.5 6H10"/>'),
    clip: s('<path d="M4 12h2l1.5-4 3 9 3-12 2.5 7H20"/>'),
    note: s('<path d="M5 4.5h14v15H5z"/><path d="M8.5 9h7M8.5 12.5h7M8.5 16h4"/>'),
    calendar: s('<rect x="3.5" y="5" width="17" height="15.5" rx="2.4"/><path d="M3.5 9.8h17M8 3v3.5M16 3v3.5"/>'),
    arrowR: s('<path d="M4 12h15M14 6.5L19.5 12 14 17.5" stroke-width="1.8"/>'),
    signal: '<svg width="19" height="12" viewBox="0 0 19 12" aria-hidden="true"><rect x="0" y="8" width="3.2" height="4" rx="1" fill="currentColor"/><rect x="5" y="5.5" width="3.2" height="6.5" rx="1" fill="currentColor"/><rect x="10" y="3" width="3.2" height="9" rx="1" fill="currentColor"/><rect x="15" y="0" width="3.2" height="12" rx="1" fill="currentColor"/></svg>',
    wifi: '<svg width="17" height="12" viewBox="0 0 17 12" aria-hidden="true"><path d="M8.5 2.2c2.5 0 4.8 1 6.5 2.6l1.2-1.3A11 11 0 0 0 8.5.4 11 11 0 0 0 .8 3.5L2 4.8a9.2 9.2 0 0 1 6.5-2.6zm0 3.6c1.5 0 2.9.6 3.9 1.6l1.3-1.3a7.3 7.3 0 0 0-10.4 0l1.3 1.3c1-1 2.4-1.6 3.9-1.6zm0 3.6c.6 0 1.1.2 1.5.6L8.5 11.6 7 10c.4-.4.9-.6 1.5-.6z" fill="currentColor"/></svg>',
    battery: '<svg width="27" height="13" viewBox="0 0 27 13" aria-hidden="true"><rect x="0.5" y="0.5" width="23" height="12" rx="3.5" fill="none" stroke="currentColor" opacity="0.4"/><rect x="2" y="2" width="17" height="9" rx="2.2" fill="currentColor"/><path d="M25 4.5v4c.8-.3 1.4-1.1 1.4-2s-.6-1.7-1.4-2z" fill="currentColor" opacity="0.45"/></svg>',
  };

  // Stand-in marks. Each is a plain geometric figure in the vendor's colour family, so the
  // squint test still sorts "which assistant" by colour and shape; production uses the real
  // marks under each vendor's brand guidelines.
  const M = {
    chatgpt: '<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.7" aria-hidden="true"><ellipse cx="12" cy="12" rx="4.2" ry="9"/><ellipse cx="12" cy="12" rx="4.2" ry="9" transform="rotate(60 12 12)"/><ellipse cx="12" cy="12" rx="4.2" ry="9" transform="rotate(120 12 12)"/></svg>',
    claude: '<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.3" stroke-linecap="round" aria-hidden="true">' +
      Array.from({ length: 10 }, (_, i) => { const a = (i * 36) * Math.PI / 180; const r1 = 2.6, r2 = i % 2 ? 8.2 : 10.2; return `<path d="M${(12 + r1 * Math.cos(a)).toFixed(2)} ${(12 + r1 * Math.sin(a)).toFixed(2)}L${(12 + r2 * Math.cos(a)).toFixed(2)} ${(12 + r2 * Math.sin(a)).toFixed(2)}"/>`; }).join('') + '</svg>',
    codex: '<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 7.5l4.5 4.5L5 16.5M12.5 17h7"/></svg>',
    gemini: '<svg viewBox="0 0 24 24" aria-hidden="true"><defs><linearGradient id="gm" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#3D7BF4"/><stop offset="1" stop-color="#A66CF2"/></linearGradient></defs><path d="M12 1.5c.6 5.6 4.9 9.9 10.5 10.5-5.6.6-9.9 4.9-10.5 10.5C11.4 16.9 7.1 12.6 1.5 12 7.1 11.4 11.4 7.1 12 1.5z" fill="url(#gm)"/></svg>',
    pa: '<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.6" stroke-linecap="round" aria-hidden="true"><path d="M4 10v4M8 6v12M12 9v6M16 4v16M20 8v8"/></svg>',
  };

  document.querySelectorAll('i[data-i]').forEach((el) => {
    const t = document.createElement('template');
    t.innerHTML = I[el.dataset.i] || '';
    const svg = t.content.firstElementChild;
    if (svg && el.className) svg.setAttribute('class', el.className + ' ' + (svg.getAttribute('class') || ''));
    if (svg && el.getAttribute('style')) svg.setAttribute('style', el.getAttribute('style'));
    el.replaceWith(t.content);
  });
  document.querySelectorAll('.mark[data-m]').forEach((el) => {
    el.innerHTML = M[el.dataset.m] || '';
    el.classList.add(el.dataset.m);
    el.setAttribute('aria-hidden', 'true');
  });
  document.querySelectorAll('.statusbar').forEach((el) => {
    el.innerHTML = `<span>9:41</span><span class="icons">${I.signal}${I.wifi}${I.battery}</span>`;
  });
  document.querySelectorAll('.tabbar[data-on]').forEach((el) => {
    const tabs = [['today', 'Today', 'wave'], ['history', 'History', 'history'], ['followups', 'Follow-ups', 'checklist'], ['ask', 'Ask', 'sparkles'], ['settings', 'Settings', 'gear']];
    el.innerHTML = tabs.map(([k, l, i]) => `<button class="tab${el.dataset.on === k ? ' on' : ''}" aria-label="${l}">${I[i]}<span>${l}</span></button>`).join('');
    el.setAttribute('role', 'tablist');
  });
  document.querySelectorAll('.phone').forEach((p) => {
    if (!p.querySelector('.home-ind')) { const h = document.createElement('div'); h.className = 'home-ind'; p.appendChild(h); }
  });
})();
