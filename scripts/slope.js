// Land slope for Auckland sites from Auckland Council's 1 m LiDAR DEM (2024), measured inside the LINZ title boundary.
// Run in the built-in browser on the DEM service page itself (no CSP; navigate to the ImageServer URL below), via javascript_tool:
//   1. paste this whole file (defines window.__slope and loads the LERC decoder),
//   2. then:  await window.__slope([{id:'42957077', lat:-36.8918, lon:174.6835}, ...])
// Returns [{id, fall_m, avg_slope_pct, p90_slope_pct, max_slope_pct, area_m2, cells, class}] — class: Flat / Gentle / Moderate / Steep.
// Large batches: run in chunks of ~15 sites per call (tool calls time out at ~45 s).
(() => {
  const DEM = 'https://tiledimageservices1.arcgis.com/n4yPwebTjJCmXB6W/arcgis/rest/services/Auckland_Region_Digital_Elevation_Model__DEM__2024/ImageServer';
  const TITLES = 'https://services.arcgis.com/xdsHIIxuCWByZiCB/arcgis/rest/services/LINZ_NZ_Property_Titles/FeatureServer/0/query';
  const ORIGIN = { x: -4020763.26772284, y: 19997963.9429363 }, LEVEL = 9, RES = 1, TS = 256;
  const tiles = new Map();

  // The tiles are Lerc2 v2.6, which needs the WebAssembly decoder (lerc 4.x); older pure-JS builds fail.
  const loadLerc = async () => {
    if (!window.Lerc || !window.Lerc.load) await new Promise((ok, fail) => {
      const s = document.createElement('script');
      s.src = 'https://cdn.jsdelivr.net/npm/lerc@4.0.4/LercDecode.min.js';
      s.onload = ok; s.onerror = fail; document.head.appendChild(s);
    });
    await Lerc.load({ locateFile: () => 'https://cdn.jsdelivr.net/npm/lerc@4.0.4/lerc-wasm.wasm' });
  };

  async function tile(row, col) {
    const k = row + '/' + col;
    if (!tiles.has(k)) tiles.set(k, (async () => {
      const buf = await fetch(`${DEM}/tile/${LEVEL}/${row}/${col}`).then(r => r.arrayBuffer());
      const d = Lerc.decode(buf);
      return { px: d.pixels[0], mask: d.mask, w: d.width };
    })());
    return tiles.get(k);
  }
  async function z(x, y) { // elevation at NZTM x,y (nearest 1 m cell)
    const gx = Math.floor((x - ORIGIN.x) / RES), gy = Math.floor((ORIGIN.y - y) / RES);
    const t = await tile(Math.floor(gy / TS), Math.floor(gx / TS));
    const i = (gy % TS) * t.w + (gx % TS);
    return t.mask && !t.mask[i] ? null : t.px[i];
  }
  const inside = (x, y, ring) => { let c = false; for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) { const [xi, yi] = ring[i], [xj, yj] = ring[j]; if ((yi > y) !== (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) c = !c; } return c; };
  const pct = (a, p) => { const s = [...a].sort((m, n) => m - n); return s.length ? s[Math.min(s.length - 1, Math.floor(p * s.length))] : null; };

  async function one(site) {
    const q = `${TITLES}?geometry=${site.lon},${site.lat}&geometryType=esriGeometryPoint&inSR=4326&spatialRel=esriSpatialRelIntersects&returnGeometry=true&outSR=2193&f=json`;
    const f = (await fetch(q).then(r => r.json())).features?.[0];
    if (!f) return { id: site.id, error: 'no title parcel' };
    // Main parcel = largest ring (ignores small shared access lots).
    const ring = f.geometry.rings.sort((a, b) => b.length - a.length)[0];
    const xs = ring.map(p => p[0]), ys = ring.map(p => p[1]);
    const x0 = Math.floor(Math.min(...xs)), x1 = Math.ceil(Math.max(...xs)), y0 = Math.floor(Math.min(...ys)), y1 = Math.ceil(Math.max(...ys));
    const step = 2; // 2 m sampling grid; slope from neighbouring samples
    const grid = new Map(), cellsIn = [];
    for (let x = x0 - step; x <= x1 + step; x += step) for (let y = y0 - step; y <= y1 + step; y += step) {
      const v = await z(x + 0.5, y + 0.5);
      if (v != null && v > -50) grid.set(x + ',' + y, v);
      if (inside(x + 0.5, y + 0.5, ring)) cellsIn.push([x, y]);
    }
    const elev = [], slopes = [];
    for (const [x, y] of cellsIn) {
      const c = grid.get(x + ',' + y); if (c == null) continue; elev.push(c);
      const e = grid.get((x + step) + ',' + y), w = grid.get((x - step) + ',' + y), n = grid.get(x + ',' + (y + step)), s = grid.get(x + ',' + (y - step));
      if ([e, w, n, s].some(v => v == null)) continue;
      const dzdx = (e - w) / (2 * step), dzdy = (n - s) / (2 * step);
      slopes.push(100 * Math.hypot(dzdx, dzdy));
    }
    if (!elev.length) return { id: site.id, error: 'no elevation data' };
    const fall = Math.max(...elev) - Math.min(...elev);
    const avg = slopes.reduce((a, b) => a + b, 0) / (slopes.length || 1);
    const p90 = pct(slopes, 0.9);
    const cls = avg < 5 ? 'Flat' : avg < 10 ? 'Gentle' : avg < 20 ? 'Moderate' : 'Steep';
    return { id: site.id, fall_m: +fall.toFixed(1), avg_slope_pct: +avg.toFixed(1), p90_slope_pct: p90 == null ? null : +p90.toFixed(1),
             max_slope_pct: slopes.length ? +Math.max(...slopes).toFixed(1) : null, area_m2: cellsIn.length * step * step, cells: elev.length, class: cls };
  }

  window.__slope = async (sites) => { await loadLerc(); const out = []; for (const s of sites) { try { out.push(await one(s)); } catch (e) { out.push({ id: s.id, error: String(e) }); } } return out; };
})();
'slope ready';
