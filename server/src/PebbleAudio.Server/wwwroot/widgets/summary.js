// Compact widgets preview the summary; Expand reveals the full text and secondary details.
// Day results are server-shortened. Retrieve their full summary only after the person expands.
function summaryHtml(text, conversationId = null) {
  if (!text) return '';
  const remote = conversationId && text.endsWith('…');
  return `<div class="w-summary"${remote ? ` data-conversation="${esc(conversationId)}"` : ''}>
    <p class="w-sum">${esc(text)}</p><p class="summary-status" role="status" hidden></p>
  </div>`;
}

function expandButton(id) {
  return `<button type="button" class="summary-toggle" data-widget-expand aria-expanded="false" aria-controls="${id}">Expand</button>`;
}

async function loadExpandedSummaries(root) {
  if (!root.classList.contains('is-expanded')) return;
  for (const wrap of root.querySelectorAll('[data-conversation]')) {
    if (wrap.dataset.loading) continue;
    wrap.dataset.loading = 'true';
    const status = wrap.querySelector('.summary-status');
    status.textContent = 'Loading full summary…';
    status.hidden = false;
    try {
      const result = await callTool('get_conversation', { id: wrap.dataset.conversation, include: 'summary' });
      if (!wrap.isConnected) continue;
      if (!result?.structuredContent?.overview) throw new Error('No summary');
      wrap.querySelector('.w-sum').textContent = result.structuredContent.overview;
      delete wrap.dataset.conversation;
      status.hidden = true;
    } catch {
      if (!wrap.isConnected) continue;
      status.innerHTML = 'Open the conversation to read the full summary. <button type="button" class="summary-toggle" data-summary-retry>Try again</button>';
    } finally {
      delete wrap.dataset.loading;
    }
  }
}

document.addEventListener('click', (event) => {
  const button = event.target.closest('[data-widget-expand], [data-summary-retry]');
  if (!button) return;
  const root = button.closest('.w');
  if (button.hasAttribute('data-widget-expand')) {
    const expanded = root.classList.toggle('is-expanded');
    button.setAttribute('aria-expanded', String(expanded));
    button.textContent = expanded ? 'Collapse' : 'Expand';
  }
  loadExpandedSummaries(root);
});
