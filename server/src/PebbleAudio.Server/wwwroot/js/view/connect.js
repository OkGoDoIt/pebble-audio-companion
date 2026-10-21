// The connect page: copy the command, and watch "Who can read" until the app shows up (a light poll while the
// page is open and in view; the server answers with the list as HTML).

for (const button of document.querySelectorAll('[data-copy]')) {
  const label = button.querySelector('span');
  const words = label.textContent;
  button.addEventListener('click', async () => {
    const text = document.querySelector(button.dataset.copy).textContent;
    try {
      await navigator.clipboard.writeText(text);
      label.textContent = 'Copied';
    } catch {
      // No clipboard permission: select the command so the person can copy it themselves.
      const range = document.createRange();
      range.selectNodeContents(document.querySelector(button.dataset.copy));
      getSelection().removeAllRanges();
      getSelection().addRange(range);
      label.textContent = 'Selected';
    }
    setTimeout(() => { label.textContent = words; }, 2000);
  });
}

const page = document.querySelector('[data-connect]');
const slot = document.querySelector('[data-who-slot]');
const wait = document.querySelector('[data-wait]');
let timer = 0;

function ready() {
  return slot.querySelector('[data-who]')?.dataset.ready === 'true';
}

function showReady() {
  const name = document.querySelector('.screen-title').textContent.replace(/^Connect /, '');
  wait.innerHTML = `<span class="check-badge small" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg></span><span class="note"></span>`;
  wait.querySelector('.note').textContent = `${name} is connected.`;
}

async function poll() {
  clearTimeout(timer);
  if (document.hidden || ready()) return;
  timer = setTimeout(async () => {
    try {
      const response = await fetch(`/connect/${page.dataset.tool}?handler=who&since=${page.dataset.since}`, { credentials: 'same-origin' });
      // Signed out meanwhile: the poll was sent to the sign-in page, so the page goes there too.
      if (response.redirected) return location.reload();
      if (response.ok && response.headers.get('content-type')?.includes('text/html')) {
        slot.innerHTML = await response.text();
        if (ready()) { showReady(); return; }
      }
    } catch {
      // The next round tries again.
    }
    poll();
  }, 4000);
}

document.addEventListener('visibilitychange', () => { if (!document.hidden) poll(); });
poll();
