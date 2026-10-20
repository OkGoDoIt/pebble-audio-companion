/* Shared device chrome + the "where your data goes" diagram for the privacy-ladder mockups.
   Classic script (file:// cannot load ES modules). Each screen declares what it needs with
   data attributes; this fills in status bar, nav bar, tab bar, icons, and the flow diagram. */
(function () {
  if (location.hash === '#dark' || document.documentElement.dataset.theme === 'dark') {
    document.documentElement.dataset.theme = 'dark';
  }

  var S = 'stroke-linecap="round" stroke-linejoin="round"';
  var ICONS = {
    phone: '<svg viewBox="0 0 24 24"><rect x="6.5" y="2.5" width="11" height="19" rx="2.8"/><path d="M10.5 5.3h3"/></svg>',
    server: '<svg viewBox="0 0 24 24"><rect x="3.5" y="4" width="17" height="7" rx="2"/><rect x="3.5" y="13" width="17" height="7" rx="2"/><path d="M7.5 7.5h.01M7.5 16.5h.01" stroke-width="2.6"/><path d="M11 7.5h6M11 16.5h6" stroke-width="1.3"/></svg>',
    assist: '<svg viewBox="0 0 24 24"><path d="M10.5 3.5c.6 4.4 2.2 6 6.6 6.6-4.4.6-6 2.2-6.6 6.6-.6-4.4-2.2-6-6.6-6.6 4.4-.6 6-2.2 6.6-6.6z"/><path d="M18 14.5c.3 2 1 2.7 3 3-2 .3-2.7 1-3 3-.3-2-1-2.7-3-3 2-.3 2.7-1 3-3z"/></svg>',
    check: '<svg viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>',
    chev: '<svg class="chev" viewBox="0 0 8 13" fill="none" stroke-width="2" ' + S + '><path d="M1.5 1.5l5 5-5 5"/></svg>',
    back: '<svg width="12" height="20" viewBox="0 0 12 20" fill="none" stroke-width="2.6" ' + S + '><path d="M10 2L2 10l8 8"/></svg>',
    close: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke-width="2.4" ' + S + '><path d="M3 3l10 10M13 3L3 13"/></svg>',
    copy: '<svg width="16" height="16" viewBox="0 0 24 24" stroke-width="2" ' + S + '><rect x="8" y="8" width="12" height="12" rx="2.5"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/></svg>',
    camera: '<svg width="18" height="18" viewBox="0 0 24 24" stroke-width="2" ' + S + '><path d="M4 8.5A2.5 2.5 0 0 1 6.5 6h1.8l1.4-2h4.6l1.4 2h1.8A2.5 2.5 0 0 1 20 8.5v8a2.5 2.5 0 0 1-2.5 2.5h-11A2.5 2.5 0 0 1 4 16.5z"/><circle cx="12" cy="12.5" r="3.4"/></svg>',
    open: '<svg width="15" height="15" viewBox="0 0 24 24" stroke-width="2.2" ' + S + '><path d="M14 4h6v6M20 4l-9 9M18 14v4a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4"/></svg>',
    wave: '<svg viewBox="0 0 24 24" stroke-width="1.9" ' + S + '><path d="M3 12h1M6.5 8v8M10 4.5v15M13.5 8.5v7M17 6v12M20.5 10.5v3"/></svg>',
    history: '<svg viewBox="0 0 24 24" stroke-width="1.9" ' + S + '><path d="M4 12a8 8 0 1 0 2.4-5.7"/><path d="M4 4.5V8h3.5"/><path d="M12 8v4.5l3 2"/></svg>',
    list: '<svg viewBox="0 0 24 24" stroke-width="1.9" ' + S + '><path d="M4 6.5l1.5 1.5L8 5.5M4 13l1.5 1.5L8 12M11 7h9M11 13.5h9M11 19.5h9M5 19.5h.01"/></svg>',
    sparkles: '<svg viewBox="0 0 24 24" stroke-width="1.8" ' + S + '><path d="M10 3.5c.6 4.4 2.2 6 6.6 6.6-4.4.6-6 2.2-6.6 6.6-.6-4.4-2.2-6-6.6-6.6 4.4-.6 6-2.2 6.6-6.6z"/><path d="M18 14.5c.3 2 1 2.7 3 3-2 .3-2.7 1-3 3-.3-2-1-2.7-3-3 2-.3 2.7-1 3-3z"/></svg>',
    gear: '<svg viewBox="0 0 24 24" stroke-width="1.8" ' + S + '><circle cx="12" cy="12" r="3.2"/><path d="M12 2.8l1.6 2.3 2.7-.7.6 2.7 2.6 1-1 2.6 1.7 2.2-2.2 1.7.4 2.8-2.8.2-1.1 2.6-2.5-1.3L9.5 20l-1.1-2.6-2.8-.2.4-2.8-2.2-1.7 1.7-2.2-1-2.6 2.6-1 .6-2.7 2.7.7z"/></svg>'
  };
  window.ICONS = ICONS;

  function statusBar(light) {
    return '<div class="statusbar' + (light ? ' light-ink' : '') + '"><span>9:41</span><span class="icons">' +
      '<svg width="19" height="12" viewBox="0 0 19 12"><rect x="0" y="8" width="3.2" height="4" rx="1"/><rect x="5" y="5.5" width="3.2" height="6.5" rx="1"/><rect x="10" y="3" width="3.2" height="9" rx="1"/><rect x="15" y="0" width="3.2" height="12" rx="1"/></svg>' +
      '<svg width="17" height="12" viewBox="0 0 17 12"><path d="M8.5 2.3c2.4 0 4.6.9 6.2 2.5l1.2-1.2A10.4 10.4 0 0 0 8.5.6C5.6.6 3 1.7 1.1 3.6l1.2 1.2A8.7 8.7 0 0 1 8.5 2.3zm0 3.4c1.5 0 2.8.6 3.8 1.5l1.2-1.2a7 7 0 0 0-10 0l1.2 1.2c1-.9 2.3-1.5 3.8-1.5zm0 3.4c.6 0 1.1.2 1.5.6L8.5 11.2 7 9.7c.4-.4.9-.6 1.5-.6z"/></svg>' +
      '<svg width="27" height="13" viewBox="0 0 27 13"><rect x=".5" y=".5" width="23" height="12" rx="3.8" fill="none" stroke="currentColor" opacity=".4"/><rect x="2" y="2" width="20" height="9" rx="2.5"/><path d="M25 4.5v4c.8-.3 1.3-1.1 1.3-2s-.5-1.7-1.3-2z" opacity=".45"/></svg>' +
      '</span></div>';
  }

  function tabBar() {
    var tabs = [['wave', 'Today'], ['history', 'History'], ['list', 'Follow-ups'], ['sparkles', 'Ask'], ['gear', 'Settings']];
    return '<nav class="tabbar" aria-label="Tabs">' + tabs.map(function (t) {
      return '<button class="tab' + (t[1] === 'Settings' ? ' sel' : '') + '" aria-label="' + t[1] + '">' + ICONS[t[0]] + '<span>' + t[1] + '</span></button>';
    }).join('') + '</nav>';
  }

  /* The diagram. data-server: on | off | paused. data-who: comma list of assistants who can read
     (empty = none connected). data-clips / data-edits: on | off. data-host: shown under the server. */
  function flow(el) {
    var d = el.dataset;
    var server = d.server || 'off';
    var who = (d.who || '').split(',').map(function (s) { return s.trim(); }).filter(Boolean);
    var reading = server !== 'off' && who.length > 0;
    var mini = el.classList.contains('mini');
    var p1Top = server === 'on' ? 'Text' : server === 'paused' ? 'Paused' : 'Off';
    var p1Bot = server === 'off' ? '' : (d.clips === 'on' ? 'Clips if asked' : 'No audio');
    var p2Top = server === 'off' ? 'Off' : reading ? 'Read' : 'None yet';
    var p2Bot = reading && d.edits === 'on' ? 'Add notes' : '';
    var whoLine = who.length ? (who.length > 2 ? who.slice(0, 2).join(', ') + ' +' + (who.length - 2) : who.join(', ')) : '';
    function node(cls, icon, name, sub, badge) {
      return '<div class="node ' + cls + '"><div class="tile" aria-hidden="true">' + ICONS[icon] +
        (badge ? '<span class="badge">' + badge + '</span>' : '') + '</div><div class="name">' + name + '</div>' +
        (sub && !mini ? '<div class="who">' + sub + '</div>' : '') + '</div>';
    }
    function path(on, cls, top, bot) {
      return '<div class="path ' + (on ? 'on' : cls) + '" aria-hidden="true"><div class="lab top">' + top + '</div><div class="line"></div>' +
        (bot && !mini ? '<div class="lab bot' + (bot === 'No audio' ? ' no' : '') + '">' + bot + '</div>' : '') + '</div>';
    }
    el.innerHTML =
      node('on', 'phone', 'This iPhone', mini ? '' : (d.phoneSub || 'Audio and text'), '') +
      path(server === 'on', server === 'paused' ? 'paused' : 'off', p1Top, p1Bot) +
      node(server === 'off' ? 'off' : 'on', 'server', 'Your server', server === 'off' ? 'Not linked' : (d.host || ''), '') +
      path(reading && server === 'on', reading ? 'paused' : 'off', p2Top, p2Bot) +
      node(reading ? 'on' : 'off', 'assist', 'Assistants', reading ? whoLine : (server === 'off' ? 'Off' : 'None yet'), mini && who.length ? String(who.length) : '');
    var label = 'Where your data goes. ' + (server === 'off' ? 'Everything stays on this iPhone.' :
      'Text ' + (server === 'paused' ? 'is paused on its way' : 'goes') + ' to your server' + (d.host ? ', ' + d.host : '') + '. ' +
      (reading ? who.join(', ') + ' can read it there.' : 'No assistant can read it yet.') +
      (d.clips === 'on' ? ' Assistants can ask for clips.' : ' Audio stays on this iPhone.'));
    el.setAttribute('role', 'img');
    el.setAttribute('aria-label', label);
  }

  document.addEventListener('DOMContentLoaded', function () {
    var screen = document.querySelector('.screen');
    if (!screen) return;
    var d = screen.dataset;
    var html = statusBar(d.ink === 'light');
    if (d.nav !== undefined) {
      html += '<header class="navbar">' + (d.back === 'close' ? '<button class="back" aria-label="Close">' + ICONS.close + '</button>' : d.back !== 'none' ? '<button class="back" aria-label="Back">' + ICONS.back + '</button>' : '') +
        '<span class="title">' + d.nav + '</span>' + (d.trail ? '<button class="trail">' + d.trail + '</button>' : '') + '</header>';
    }
    screen.insertAdjacentHTML('afterbegin', html);
    if (d.tabs !== 'none') screen.insertAdjacentHTML('beforeend', '<div class="edge-fade" aria-hidden="true"></div>' + tabBar());
    screen.insertAdjacentHTML('beforeend', '<div class="home-ind" aria-hidden="true"></div>');
    document.querySelectorAll('[data-icon]').forEach(function (e) { e.insertAdjacentHTML('afterbegin', ICONS[e.dataset.icon]); });
    document.querySelectorAll('.flow').forEach(flow);
  });
})();
