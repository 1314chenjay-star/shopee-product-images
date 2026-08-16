importScripts('background_v18.js');

const __baseVisitRouteV18 = visitRoute;
visitRoute = async function(tabId, route, fullProducts) {
  if (route.id === 'products' && !fullProducts) {
    await chrome.tabs.update(tabId, { url: route.href, active: true });
    await waitStable(tabId, 18000);
    await sleep(800);
    await snapshot(tabId, `quick_products_${Date.now()}`);
    const page = await extractProductPage(tabId);
    const capture = await loadCapture();
    capture.monitor.quickProduct = page ? {
      capturedAt: page.capturedAt,
      visibleRows: page.rows?.length || 0,
      expectedTotal: page.expectedTotal,
      currentPage: page.currentPage,
      pageSize: page.pageSize
    } : null;
    await saveCapture(capture);
    return page;
  }
  return __baseVisitRouteV18(tabId, route, fullProducts);
};

const __baseGoToNextProductPageV18 = goToNextProductPage;
goToNextProductPage = async function(tabId, targetPage) {
  try {
    const result = await chrome.scripting.executeScript({
      target: { tabId },
      func: wantedPage => {
        const target = String(wantedPage);
        const visible = el => {
          const r = el.getBoundingClientRect();
          const s = getComputedStyle(el);
          return r.width > 0 && r.height > 0 && s.display !== 'none' && s.visibility !== 'hidden';
        };
        const selects = [...document.querySelectorAll('select')].filter(visible);
        const candidates = [];
        for (const select of selects) {
          const option = [...select.options].find(o => String(o.value).trim() === target || String(o.textContent || '').trim() === target);
          if (!option) continue;
          const r = select.getBoundingClientRect();
          const score = (r.left > window.innerWidth * 0.5 ? 100 : 0) + (r.top > window.innerHeight * 0.45 ? 100 : 0);
          candidates.push({ select, option, score });
        }
        candidates.sort((a, b) => b.score - a.score);
        const best = candidates[0];
        if (!best) return { clicked: false };
        best.select.value = best.option.value;
        best.select.dispatchEvent(new Event('input', { bubbles: true }));
        best.select.dispatchEvent(new Event('change', { bubbles: true }));
        return { clicked: true, found: true, method: 'page_select', label: target };
      },
      args: [targetPage]
    });
    const selected = result?.[0]?.result;
    if (selected?.clicked) return selected;
  } catch {}
  return __baseGoToNextProductPageV18(tabId, targetPage);
};
