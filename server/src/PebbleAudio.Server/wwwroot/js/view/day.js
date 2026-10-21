// The day page: a long recap shows its first lines on a phone, with "Show more".

for (const text of document.querySelectorAll('[data-brief].long')) {
  const button = text.parentElement.querySelector('[data-brief-more]');
  if (!button) continue;
  const fit = () => {
    const open = text.classList.contains('open');
    button.hidden = !open && text.scrollHeight <= text.clientHeight + 1;
  };
  button.addEventListener('click', () => {
    const open = text.classList.toggle('open');
    button.textContent = open ? 'Show less' : 'Show more';
    button.setAttribute('aria-expanded', String(open));
  });
  button.setAttribute('aria-expanded', 'false');
  new ResizeObserver(fit).observe(text);
  fit();
}
