// Weekly sold tracker: which screened listings have sold, and for how much. Run in a realestate.co.nz tab via javascript_tool.
//   1. paste this file, then
//   2. window.__track([{id:'42957077', expected:950000, low:717970}, ...])   // ids from seen.json (shortlisted + screened)
//   3. poll  ({done: window.__trackDone, n: window.__trackOut.length})  until done, then read window.__trackOut
// Each result: {id, status, sale_date, sale_price, cv, land, sale_vs_cv, sale_vs_expected, address, suburb}
// Only listings that are no longer active are returned. Save them to C:\Claude\Personal\property-hunt\sold-outcomes.json
// (keyed by id; keep earlier entries) and summarise accuracy in the report notes.
window.__track = (items) => {
  window.__trackOut = []; window.__trackDone = false;
  let qi = 0;
  const worker = async () => {
    while (qi < items.length) {
      const it = items[qi++];
      try {
        const l = (await fetch('https://platform.realestate.co.nz/search/v1/listings/' + it.id).then(r => r.json())).data?.attributes;
        if (!l || l['listing-status'] === 'active') continue;
        const p = l['property-short-id'] ? (await fetch('https://platform.realestate.co.nz/search/v1/properties/' + l['property-short-id']).then(r => r.json())).data.attributes : {};
        const s = p['latest-sale'] || {};
        const listed = (l['published-date'] || '').slice(0, 10);
        const sold = s['sale-date'] && s['sale-date'] >= listed ? s : null;   // a sale after this listing went live
        const cv = p['council-information']?.['capital-value'];
        window.__trackOut.push({
          id: it.id, status: l['listing-status'], address: l.address?.['full-address'], suburb: l.address?.suburb,
          listed, sale_date: sold?.['sale-date'] || null, sale_price: sold?.['sale-price'] || null, sale_method: sold?.['sale-method'] || null,
          cv, land: l['land-area'], sale_vs_cv: sold && cv ? +(sold['sale-price'] / cv).toFixed(3) : null,
          expected: it.expected || null, sale_vs_expected: sold && it.expected ? +(sold['sale-price'] / it.expected).toFixed(3) : null,
          low: it.low || null
        });
      } catch (e) { }
      await new Promise(r => setTimeout(r, 120));
    }
  };
  Promise.all([worker(), worker(), worker()]).then(() => { window.__trackDone = true; });
  return 'tracking ' + items.length;
};
'track ready';
