// Compact widgets preview the summary; Expand reveals the full text and secondary details.
// Day results are server-shortened. Retrieve their full summary only after the person expands.
function summaryHtml(text, conversationId = null) {
  if (!text && !conversationId) return '';
  const missing = !text;
  const remote = conversationId && (missing || text.endsWith('…'));
  text ||= 'Loading summary…';
  return `<div class="w-summary"${remote ? ` data-conversation="${esc(conversationId)}"${missing ? ' data-summary-missing' : ''}` : ''}>
    <p class="w-sum">${esc(text)}</p><p class="summary-status" role="status" hidden></p>
  </div>`;
}

function expandButton(id, label = 'Expand', collapse = 'Collapse') {
  return `<button type="button" class="summary-toggle" data-widget-expand aria-expanded="false" aria-controls="${id}" data-expand-label="${esc(label)}" data-collapse-label="${esc(collapse)}">${esc(label)}</button>`;
}

async function loadExpandedSummaries(root) {
  const selector = root.classList.contains('is-expanded') ? '[data-conversation]' : '[data-summary-missing][data-conversation]';
  for (const wrap of root.querySelectorAll(selector)) {
    if (wrap.dataset.loading) continue;
    wrap.dataset.loading = 'true';
    const status = wrap.querySelector('.summary-status');
    status.textContent = 'Loading full summary…';
    status.hidden = false;
    try {
      const result = await callTool('get_conversation', { id: wrap.dataset.conversation, include: 'summary' });
      if (!wrap.isConnected) continue;
      if (!result?.structuredContent?.found) throw new Error('Conversation unavailable');
      wrap.querySelector('.w-sum').textContent = result.structuredContent.overview || 'A summary isn’t available for this conversation yet.';
      wrap.removeAttribute('data-summary-missing');
      delete wrap.dataset.conversation;
      status.hidden = true;
    } catch {
      if (!wrap.isConnected) continue;
      if (wrap.hasAttribute('data-summary-missing')) wrap.querySelector('.w-sum').textContent = 'The summary could not be loaded.';
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
    button.textContent = expanded ? button.dataset.collapseLabel : button.dataset.expandLabel;
  }
  loadExpandedSummaries(root);
});
