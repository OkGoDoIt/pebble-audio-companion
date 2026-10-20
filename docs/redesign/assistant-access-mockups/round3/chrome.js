// Shared phone chrome for the round-3 mockups: status bar, floating tab bar, and icons.
// Purely presentational; runs from file:// with no network. `#dark` / `#light` in the URL force an
// appearance (the gallery uses it); otherwise the page follows prefers-color-scheme.
(() => {
  if (location.hash === '#dark') document.documentElement.dataset.theme = 'dark';
  if (location.hash === '#light') document.documentElement.dataset.theme = 'light';

  const s = (d) =>
    `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${d}</svg>`;

  const I = {
    chevR: '<svg class="chev" viewBox="0 0 8 14" fill="none" aria-hidden="true"><path d="M1 1l6 6-6 6" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    chevL: s('<path d="M15 4l-8 8 8 8" stroke-width="2.4"/>'),
    chevD: s('<path d="M6 9l6 6 6-6" stroke-width="2.2"/>'),
    chevU: s('<path d="M6 15l6-6 6 6" stroke-width="2.2"/>'),
    x: s('<path d="M6 6l12 12M18 6L6 18" stroke-width="2.3"/>'),
    check: s('<path d="M5 12.5l4.5 4.5L19 7.5" stroke-width="2.8"/>'),
    wave: s('<path d="M4 10v4M8 6v12M12 9v6M16 4v16M20 8v8" stroke-width="2.2"/>'),
    history: s('<path d="M3.5 12a8.5 8.5 0 1 0 2.6-6.1"/><path d="M3 4.5v4h4"/><path d="M12 7.5V12l3 2"/>'),
    checklist: s('<path d="M4 6.5l1.6 1.6L8.5 5M4 12.5l1.6 1.6 2.9-3.1M4 18.5l1.6 1.6 2.9-3.1"/><path d="M11.5 7h8.5M11.5 13h8.5M11.5 19h8.5"/>'),
    sparkles: s('<path d="M10 3.5c.7 3.9 2.6 5.8 6.5 6.5-3.9.7-5.8 2.6-6.5 6.5-.7-3.9-2.6-5.8-6.5-6.5 3.9-.7 5.8-2.6 6.5-6.5z"/><path d="M18 14.5c.3 1.8 1.2 2.7 3 3-1.8.3-2.7 1.2-3 3-.3-1.8-1.2-2.7-3-3 1.8-.3 2.7-1.2 3-3z"/>'),
    gear: s('<circle cx="12" cy="12" r="3.2"/><path d="M12 2.8v2.6M12 18.6v2.6M21.2 12h-2.6M5.4 12H2.8M18.5 5.5l-1.8 1.8M7.3 16.7l-1.8 1.8M18.5 18.5l-1.8-1.8M7.3 7.3L5.5 5.5"/>'),
    doc: s('<path d="M6.5 3h7l4 4v14h-11z"/><path d="M13.5 3v4h4M9 12h6M9 15.5h6M9 19h3.5"/>'),
    search: s('<circle cx="10.5" cy="10.5" r="6.5"/><path d="M15.5 15.5L20.5 20.5"/>'),
    calendar: s('<rect x="3.5" y="5" width="17" height="15.5" rx="2.4"/><path d="M3.5 9.8h17M8 3v3.5M16 3v3.5"/>'),
    chat: s('<path d="M4 5.5h16v10.5H9.5L5.5 19.5V16H4z"/>'),
    clock: s('<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/>'),
    phone: s('<rect x="7" y="2.8" width="10" height="18.4" rx="2.6"/><path d="M10.8 18h2.4"/>'),
    watch: s('<rect x="6.5" y="6" width="11" height="12" rx="3"/><path d="M9 6l.6-3h4.8l.6 3M9 18l.6 3h4.8l.6-3"/>'),
    camera: s('<path d="M3.5 8.5a2 2 0 0 1 2-2h2.2l1.6-2.2h5.4l1.6 2.2h2.2a2 2 0 0 1 2 2v9.5a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2z"/><circle cx="12" cy="13" r="3.6"/>'),
    copy: s('<rect x="8.5" y="8.5" width="11.5" height="11.5" rx="2.2"/><path d="M15.5 8.5V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v7.5a2 2 0 0 0 2 2h2.5"/>'),
    server: s('<rect x="3.5" y="4" width="17" height="6.5" rx="1.8"/><rect x="3.5" y="13.5" width="17" height="6.5" rx="1.8"/><path d="M7 7.25h.01M7 16.75h.01" stroke-width="2.8"/>'),
    browser: s('<rect x="3" y="4.5" width="18" height="15" rx="2.4"/><path d="M3 9h18"/><path d="M6 6.8h.01M8.5 6.8h.01" stroke-width="2.4"/>'),
    laptop: s('<rect x="5" y="5" width="14" height="10" rx="1.6"/><path d="M2.5 18.5h19"/>'),
    plus: s('<path d="M12 5v14M5 12h14" stroke-width="2.2"/>'),
    external: s('<path d="M14 4h6v6M20 4l-9 9"/><path d="M18 14v4.5a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 4 18.5v-11A1.5 1.5 0 0 1 5.5 6H10"/>'),
    audio: s('<path d="M4 12h2l1.5-4 3 9 3-12 2.5 7H20"/>'),
    text: s('<path d="M5 6h14M5 10.5h14M5 15h9"/>'),
    question: s('<path d="M4 5.5h16v10.5H9.5L5.5 19.5V16H4z"/><path d="M10 9.2a2 2 0 1 1 2.6 1.9c-.4.2-.6.5-.6.9v.3M12 14.4h.01"/>'),
    note: s('<path d="M5 4.5h14v15H5z"/><path d="M8.5 9h7M8.5 12.5h7M8.5 16h4"/>'),
    key: s('<circle cx="8" cy="15" r="4"/><path d="M11 12l8.5-8.5M16 7l2.5 2.5M14 9l2 2"/>'),
    terminal: s('<rect x="3" y="4.5" width="18" height="15" rx="2.4"/><path d="M7 9.5l3 2.5-3 2.5M12.5 15h4.5"/>'),
    lock: s('<rect x="5" y="10.5" width="14" height="10" rx="2.2"/><path d="M8 10.5V8a4 4 0 0 1 8 0v2.5"/>'),
    share: s('<path d="M12 3.5v11M8 7l4-3.5L16 7"/><path d="M6.5 11H5.5v9h13v-9h-1"/>'),
    dots: s('<circle cx="6" cy="12" r="1.3" fill="currentColor"/><circle cx="12" cy="12" r="1.3" fill="currentColor"/><circle cx="18" cy="12" r="1.3" fill="currentColor"/>'),
    tabs: s('<rect x="4" y="7" width="13" height="13" rx="2.4"/><path d="M8 4h9.5A2.5 2.5 0 0 1 20 6.5V16"/>'),
    signal: '<svg width="19" height="12" viewBox="0 0 19 12" aria-hidden="true"><rect x="0" y="8" width="3.2" height="4" rx="1" fill="currentColor"/><rect x="5" y="5.5" width="3.2" height="6.5" rx="1" fill="currentColor"/><rect x="10" y="3" width="3.2" height="9" rx="1" fill="currentColor"/><rect x="15" y="0" width="3.2" height="12" rx="1" fill="currentColor"/></svg>',
    wifi: '<svg width="17" height="12" viewBox="0 0 17 12" aria-hidden="true"><path d="M8.5 2.2c2.5 0 4.8 1 6.5 2.6l1.2-1.3A11 11 0 0 0 8.5.4 11 11 0 0 0 .8 3.5L2 4.8a9.2 9.2 0 0 1 6.5-2.6zm0 3.6c1.5 0 2.9.6 3.9 1.6l1.3-1.3a7.3 7.3 0 0 0-10.4 0l1.3 1.3c1-1 2.4-1.6 3.9-1.6zm0 3.6c.6 0 1.1.2 1.5.6L8.5 11.6 7 10c.4-.4.9-.6 1.5-.6z" fill="currentColor"/></svg>',
    battery: '<svg width="27" height="13" viewBox="0 0 27 13" aria-hidden="true"><rect x="0.5" y="0.5" width="23" height="12" rx="3.5" fill="none" stroke="currentColor" opacity="0.4"/><rect x="2" y="2" width="17" height="9" rx="2.2" fill="currentColor"/><path d="M25 4.5v4c.8-.3 1.4-1.1 1.4-2s-.6-1.7-1.4-2z" fill="currentColor" opacity="0.45"/></svg>',
  };
  window.ICONS = I;

  document.querySelectorAll('i[data-i]').forEach((el) => {
    const t = document.createElement('template');
    t.innerHTML = I[el.dataset.i] || '';
    const svg = t.content.firstElementChild;
    if (svg && el.className) svg.setAttribute('class', el.className + ' ' + (svg.getAttribute('class') || ''));
    if (svg && el.getAttribute('style')) svg.setAttribute('style', el.getAttribute('style'));
    el.replaceWith(t.content);
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
