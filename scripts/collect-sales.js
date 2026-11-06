// Sale-price vs CV collector for realestate.co.nz (run WEEKLY). Paste into javascript_tool on a realestate.co.nz tab.
// Step 1 (this file) starts a background job and returns at once (~6 minutes with 4 workers).
// Step 2: poll with  ({done: window.__done, n: Object.keys(window.__sales).length})  every ~40 s.
// Step 3: when done, run  window.__ratios()  and save the returned JSON to C:\Claude\Personal\property-hunt\market-ratios.json
// SINCE = 12 months before the run date (rolling window), so every suburb has enough sales for its own figures.
const SINCE = new Date(Date.now() - 365 * 864e5).toISOString().slice(0, 10);
const SUBURBS = [
  ['auckland-city', ['avondale', 'new-windsor', 'blockhouse-bay', 'mount-roskill', 'mount-albert', 'mount-wellington',
    'lynfield', 'hillsborough', 'onehunga', 'glen-innes', 'point-chevalier', 'sandringham', 'mount-eden', 'epsom',
    'royal-oak', 'ellerslie', 'three-kings', 'grey-lynn', 'saint-johns', 'orakei', 'kohimarama', 'remuera',
    'meadowbank', 'greenlane', 'one-tree-hill', 'westmere', 'waterview', 'glendowie', 'saint-heliers', 'stonefields',
    'penrose', 'kingsland', 'ponsonby', 'herne-bay', 'mission-bay', 'parnell', 'western-springs', 'morningside',
    'grafton', 'eden-terrace', 'newmarket', 'freemans-bay']],
  ['manukau-city', ['botany-downs', 'sunnyhills', 'cockle-bay', 'half-moon-bay', 'mellons-bay', 'somerville']]
];

window.__sales = {}; window.__done = false;
const jobs = []; for (const [d, ss] of SUBURBS) for (const s of ss) jobs.push([d, s]);
let qi = 0;
const worker = async () => {
  while (qi < jobs.length) {
    const [d, s] = jobs[qi++]; const ids = new Set();
    for (let p = 1; p <= 5; p++) {
      try {
        const h = await fetch(`/residential/sold/auckland/${d}/${s}?page=${p}`).then(r => r.text());
        const m = [...h.matchAll(/\/property\/[a-z0-9-]+\/([a-z0-9]{6,12})/g)]; if (!m.length) break; m.forEach(x => ids.add(x[1]));
      } catch (e) { }
    }
    const out = [];
    for (const id of ids) {
      try {
        const a = (await fetch('https://platform.realestate.co.nz/search/v1/properties/' + id).then(r => r.json())).data.attributes;
        const sale = a['latest-sale'], cv = a['council-information']?.['capital-value'];
        if (sale && sale['sale-price'] && cv && sale['sale-date'] >= SINCE && /Residence|Home and Income/i.test(sale.category || ''))
          out.push({ d: sale['sale-date'], p: sale['sale-price'], cv, land: a['land-area'] || 0, r: sale['sale-price'] / cv });
      } catch (e) { }
    }
    window.__sales[s] = out;
  }
};
Promise.all([worker(), worker(), worker(), worker()]).then(() => { window.__done = true; });

window.__ratios = () => {
  const q = (a, p) => { const s = [...a].sort((x, y) => x - y); return s.length ? +s[Math.floor(p * (s.length - 1))].toFixed(3) : null; };
  const stats = rows => {
    const big = rows.filter(x => x.land >= 600), r = rows.map(x => x.r), b = big.map(x => x.r);
    return { n: rows.length, median: q(r, .5), p25: q(r, .25), p10: q(r, .1),
             big_n: big.length, big_median: q(b, .5), big_p25: q(b, .25), big_p10: q(b, .1), big_under_75pct: big.filter(x => x.r < .75).length };
  };
  const suburbs = {}; for (const [k, v] of Object.entries(window.__sales)) suburbs[k] = stats(v);
  return JSON.stringify({ updated: new Date().toISOString().slice(0, 10), since: SINCE, all: stats(Object.values(window.__sales).flat()), suburbs });
};
'started ' + jobs.length + ' suburbs since ' + SINCE;
