"use strict";
// Auckland Property Search — one page, hash routes: #/ home, #/search, #/site/<listing id>, #/saved.
// Data: data.json (the daily run's sites), suburbs.json (district -> suburbs), zone-codes.json, api/lists.php (saved lists).

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const money = n => n ? "$" + Math.round(n).toLocaleString("en-NZ") : "—";
const k = n => !n ? "—" : n >= 1e6 ? "$" + (n / 1e6).toFixed(2).replace(/0$/, "") + "m" : "$" + Math.round(n / 1000) + "k";
const pct = v => v == null ? "—" : (v > 0 ? "+" : "") + v + "%";
const dist = m => m == null ? "—" : m >= 1000 ? (m / 1000).toFixed(1) + " km" : Math.round(m) + " m";
const safeUrl = u => /^https?:\/\//.test(u || "") ? u : "#";
const norm = s => String(s || "").toLowerCase().replace(/^st\.? /, "saint ").replace(/^mt\.? /, "mount ").replace(/[^a-z]+/g, " ").trim();
const street = p => String(p.address || "").split(",")[0];
const priceOf = p => p.pricing?.expected || p.price_used || 0;
const zoneShort = z => String(z || "Unknown").replace("Residential - ", "").replace(" Zone", "").replace("Terrace Housing and Apartment Building", "Terrace Housing (THAB)");
const fails = p => (p.rule_fails || []).filter(Boolean);
const scoreCls = l => "s-" + String(l || "").split(" ")[0];
const ratingName = l => l === "Stretch" ? "Over budget" : l || "";
const bandRank = { High: 3, Medium: 2, Low: 1 };
const bestBand = list => { let b = null; [].concat(list || []).filter(s => s && s.band).forEach(s => { if (!b || bandRank[s.band] > bandRank[b]) b = s.band; }); return b; };
const bandOk = (v, list) => !v || (v === "HM" ? ["High", "Medium"].includes(bestBand(list)) : bestBand(list) === v);
const ls = { get(key, d) { try { const v = localStorage.getItem(key); return v == null ? d : JSON.parse(v); } catch (e) { return d; } }, set(key, v) { try { localStorage.setItem(key, JSON.stringify(v)); } catch (e) { } } };

// Aerial photo (Esri World Imagery) centred on a point; half = half-width in degrees of longitude.
function aerial(lat, lon, w = 480, h = 300, half = 0.0008) {
  const dy = half * (h / w) * Math.cos(lat * Math.PI / 180);
  return `https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/export?bbox=${(lon - half).toFixed(6)},${(lat - dy).toFixed(6)},${(lon + half).toFixed(6)},${(lat + dy).toFixed(6)}&bboxSR=4326&imageSR=3857&size=${w},${h}&format=jpg&f=image`;
}

// ---------- State ----------
const S = { data: null, sites: [], byId: new Map(), subs: {}, subDistrict: new Map(), zones: {}, saved: new Map(), lists: [], api: false };
const DEF = { rules: "pass", pmin: "", pmax: "", label: "", zone: "", title: "", flood: "", power: "", sh: "", sec: "", pri: "", pos: "", train: false, isNew: false, topzone: false, list: "", subs: [] };
let F = Object.assign({}, DEF, ls.get("aps-f", {}));
let Q = "", SORT = ls.get("aps-sort", "score");
const saveF = () => ls.set("aps-f", F);

const districtOf = p => S.subDistrict.get(norm(p.suburb)) || "Other";
const topZones = p => { const tz = S.data?.top_zones || {}; return [].concat(p.schools?.secondary || []).filter(s => s && tz[String(s.id)]).map(s => ({ id: String(s.id), ...tz[String(s.id)] })); };
const listsOf = id => S.saved.get(String(id)) || [];
const allLists = () => S.lists.length ? S.lists : [{ id: "main", name: "Shortlist", at: "" }];
const listName = id => (allLists().find(l => l.id === id) || { name: "Shortlist" }).name;

function match(p, f = F, q = Q) {
  if (q) return (p.address + " " + p.suburb).toLowerCase().replace(/[,\s]+/g, " ").includes(q.toLowerCase().replace(/[,\s]+/g, " ").trim());
  const nf = fails(p).length, price = priceOf(p);
  if (f.rules === "pass" && nf) return false;
  if (f.rules === "fail" && !nf) return false;
  if ((f.pmin || f.pmax) && !price) return false;
  if (f.pmin && price < +f.pmin) return false;
  if (f.pmax && price > +f.pmax) return false;
  if (f.label && p.label !== f.label) return false;
  if (f.zone && zoneShort(p.zone) !== f.zone) return false;
  if (f.title && (p.title || "Unknown") !== f.title) return false;
  if (f.flood === "none" && p.flood) return false;
  if (f.flood === "yes" && !p.flood) return false;
  const pl = p.power_lines?.level;
  if (f.power === "none" && pl && pl !== "None nearby") return false;
  if (f.power === "near" && !/Over|corridor|Within/.test(pl || "")) return false;
  const sh = p.state_housing?.level;
  if (f.sh && (f.sh === "LM" ? !["Low", "Medium"].includes(sh) : sh !== f.sh)) return false;
  if (!bandOk(f.sec, p.schools?.secondary) || !bandOk(f.pri, p.schools?.primary)) return false;
  const pos = p.land && typeof p.land === "object" ? p.land.position || "" : "";
  if (f.pos === "front" && !/^Road front/.test(pos)) return false;
  if (f.pos === "corner" && !/corner/.test(pos)) return false;
  if (f.pos === "rear" && !/^Rear/.test(pos)) return false;
  if (f.train && (p.transport?.train?.distance_m ?? 9e9) > 1200) return false;
  if (f.isNew && p.status !== "new") return false;
  if (f.topzone && !topZones(p).length) return false;
  if (f.list === "any" ? !S.saved.has(String(p.id)) : f.list && !listsOf(p.id).includes(f.list)) return false;
  if (f.subs.length && !f.subs.includes(norm(p.suburb))) return false;
  return true;
}
const SORTS = {
  score: ["Best match", (a, b) => (b.score || 0) - (a.score || 0)],
  priceLow: ["Price: low to high", (a, b) => (priceOf(a) || 9e9) - (priceOf(b) || 9e9)],
  priceHigh: ["Price: high to low", (a, b) => priceOf(b) - priceOf(a)],
  newest: ["New today first", (a, b) => (b.status === "new") - (a.status === "new") || (b.score || 0) - (a.score || 0)],
  land: ["Biggest land", (a, b) => (b.land_m2 || 0) - (a.land_m2 || 0)],
  cbd: ["Closest to the CBD", (a, b) => (a.transport?.cbd_km ?? 99) - (b.transport?.cbd_km ?? 99)],
  growth: ["Future growth", (a, b) => (b.growth?.outlook_5y_pct ?? -99) - (a.growth?.outlook_5y_pct ?? -99)]
};
const results = () => S.sites.filter(p => match(p)).sort(SORTS[SORT]?.[1] || SORTS.score[1]);
const activeCount = () => Object.keys(DEF).filter(key => key === "subs" ? F.subs.length : key === "rules" ? F.rules !== "pass" : F[key] !== DEF[key]).length;
const PRICE_STEPS = (() => { const s = []; for (let v = 300000; v <= 1500000; v += 100000) s.push(v); for (let v = 1750000; v <= 3000000; v += 250000) s.push(v); return s; })();
const opts = (list, cur) => list.map(([v, t]) => `<option value="${esc(v)}"${String(v) === String(cur) ? " selected" : ""}>${esc(t)}</option>`).join("");

// ---------- Cards ----------
function chips(p) {
  const c = [];
  if (fails(p).length) c.push(`<span class="chip warn">Outside your rules</span>`);
  if (/plain|prone/i.test(p.flood || "")) c.push(`<span class="chip blue">${esc(p.flood.replace(/ \(.*\)/, ""))}</span>`);
  if ((p.transport?.train?.distance_m ?? 9e9) <= 1200) c.push(`<span class="chip accent">Train ${dist(p.transport.train.distance_m)}</span>`);
  if (topZones(p).length) c.push(`<span class="chip good">Top school zone</span>`);
  [].concat(p.sale_type || []).filter(t => /Mortgagee|Estate|Private/.test(t)).forEach(t => c.push(`<span class="chip bad">${esc(t)}</span>`));
  return c.slice(0, 4).join("");
}
function saveButton(p) {
  if (!S.api) return "";
  const on = S.saved.has(String(p.id));
  return `<button type="button" class="savebtn${on ? " on" : ""}" data-save="${esc(p.id)}" aria-label="${on ? "Saved: change lists" : "Save this site"}" title="${on ? esc("Saved in: " + listsOf(p.id).map(listName).join(", ")) : "Save"}">${on ? "♥" : "♡"}</button>`;
}
// variant "row": the compact card used in search results (photo left, key details right).
function card(p, variant = "") {
  const href = `#/site/${encodeURIComponent(p.id)}`;
  return `<article class="card ${variant}" data-id="${esc(p.id)}">
    <a class="cimg" href="${href}" aria-label="${esc(p.address)}">${p.lat ? `<img loading="lazy" alt="" src="${aerial(p.lat, p.lon)}"><span class="pin"></span>` : ""}
      <span class="tags">${p.status === "new" ? `<span class="chip accent">New</span>` : ""}${p.status === "price_change" ? `<span class="chip warn">Price change</span>` : ""}</span>
      <span class="score ${scoreCls(p.label)}" title="${esc(ratingName(p.label))}">${p.score ?? "–"}</span></a>
    ${saveButton(p)}
    <a class="cbody" href="${href}">
      <div class="cprice">${k(priceOf(p))} <small>expected · ${esc(p.price_text || "price not stated")}</small></div>
      <div class="caddr">${esc(street(p))}</div><div class="csub">${esc(p.suburb)}</div>
      <div class="cfacts"><span><b>${p.land_m2 ? Math.round(p.land_m2) + " m²" : "—"}</b> land</span><span><b>${p.beds ?? "–"}</b> bd</span><span>${esc(zoneShort(p.zone))}</span></div>
      <div class="cchips">${chips(p)}</div>
    </a>
  </article>`;
}

// ---------- Maps ----------
const AC = "https://services1.arcgis.com/n4yPwebTjJCmXB6W/arcgis/rest/services/";
const TITLES = "https://services.arcgis.com/xdsHIIxuCWByZiCB/arcgis/rest/services/LINZ_NZ_Property_Titles/FeatureServer/0";
const CROSL = "https://services.arcgis.com/xdsHIIxuCWByZiCB/arcgis/rest/services/CRoSL_Layer_N/FeatureServer/0";
const SCHOOL_ZONES = "https://services.arcgis.com/XTtANUDT8Va4DLwI/arcgis/rest/services/NZ_School_Zone_boundaries/FeatureServer/0";
const dotColor = l => ({ "Strong": "#1f7a4c", "Worth a look": "#c08000", "Stretch": "#1f6fd1", "Outside your rules": "#a7b0ad" }[l] || "#75807d");
const zoneColor = n => /Single House/.test(n) ? "#f3e2a9" : /Suburban/.test(n) ? "#f2c45a" : /Mixed Housing Urban/.test(n) ? "#e8964a" : /Terrace/.test(n) ? "#c0562f" : /Business|Centre/.test(n) ? "#8e6ac8" : /Rural|Countryside/.test(n) ? "#8fbf6b" : /Open Space/.test(n) ? "#4f9a5b" : /Large Lot/.test(n) ? "#e9dfc3" : "#9aa5a2";
let maps = [];
function makeMap(el, { aerialFirst = false, floodOn = true } = {}) {
  if (!window.L || !L.esri) { el.innerHTML = `<div class="empty">The map couldn't load.</div>`; return null; }
  const map = L.map(el, { preferCanvas: true, zoomControl: true }).setView([-36.88, 174.76], 10);
  const street = L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", { maxZoom: 19, attribution: "&copy; OpenStreetMap contributors" });
  const air = L.tileLayer("https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}", { maxZoom: 19, attribution: "Imagery &copy; Esri" });
  (aerialFirst ? air : street).addTo(map);
  // Council polygons are heavy, so each layer only draws from street/suburb zoom.
  const layer = (svc, color, minZoom) => L.esri.featureLayer({ url: AC + svc + "/FeatureServer/0", minZoom, simplifyFactor: 0.5, precision: 6, interactive: false, style: () => ({ color, weight: 1, fillColor: color, fillOpacity: 0.35 }) });
  const zoning = L.esri.featureLayer({ url: AC + "Unitary_Plan_Base_Zone/FeatureServer/0", minZoom: 15, simplifyFactor: 0.5, precision: 6, fields: ["OBJECTID", "ZONE"],
    style: f => { const c = zoneColor(S.zones[String(f.properties.ZONE)] || ""); return { color: c, weight: 0.6, fillColor: c, fillOpacity: 0.3 }; } });
  zoning.bindPopup(l => esc(S.zones[String(l.feature.properties.ZONE)] || "Zone"));
  const overlays = {
    "Flood plains": layer("Flood_Plains", "#1f6fd1", 14), "Flood prone areas": layer("Flood_Prone_Areas", "#4fa3e0", 14),
    "Flood sensitive areas": layer("Flood_Sensitive_Areas", "#9ccff0", 14), "Zoning (Unitary Plan)": zoning,
    "Special Character Areas": layer("Special_Character_Areas_Overlay_Residential_and_Business", "#a05ac8", 14),
    "Historic heritage": layer("Historic_Heritage_Overlay_Extent_of_Place", "#b03a2e", 15),
    "National Grid corridor": layer("National_Grid_Corridor_Overlay", "#e5b153", 13)
  };
  // Kāinga Ora (state housing) land, from the national Crown property layer the hunt also counts.
  overlays["State housing (Kāinga Ora)"] = L.esri.featureLayer({ url: CROSL, minZoom: 14, simplifyFactor: 0.5, precision: 6, fields: ["OBJECTID", "Managed_By"],
    where: "(Managed_By LIKE '%Housing New Zealand%' OR Managed_By LIKE '%Kainga%' OR Managed_By LIKE '%Kāinga%') AND Shape__Area > 150",
    style: () => ({ color: "#d1495b", weight: 1, fillColor: "#d1495b", fillOpacity: 0.45 }) }).bindPopup("Kāinga Ora (state housing) land");
  // Enrolment zones of the top-10 state secondary schools (config top_schools), one colour each.
  const tz = S.data?.top_zones || {}, tzIds = Object.keys(tz).filter(x => /^\d+$/.test(x));
  if (tzIds.length) {
    const pal = ["#1f6fd1", "#1f7a4c", "#a05ac8", "#c0562f", "#c08000", "#0b6e5f", "#d1495b", "#5b6ee1", "#7a8b2e", "#8a5a44"];
    const col = id => pal[tzIds.indexOf(String(id)) % pal.length];
    overlays["Top-10 school zones"] = L.esri.featureLayer({ url: SCHOOL_ZONES, where: `School_ID IN (${tzIds.join(",")})`, simplifyFactor: 0.6, precision: 5, fields: ["OBJECTID", "School_ID", "School_name"],
      style: f => ({ color: col(f.properties.School_ID), weight: 2, fillColor: col(f.properties.School_ID), fillOpacity: 0.08 }) })
      .bindPopup(l => { const z = tz[String(l.feature.properties.School_ID)] || {}; return `<b>${esc(z.name || l.feature.properties.School_name)}</b><br>Enrolment zone · NCEA L3 ${esc(z.ncea_l3_pct ?? "—")}%`; });
  }
  if (floodOn) { overlays["Flood plains"].addTo(map); overlays["Flood prone areas"].addTo(map); }
  L.control.layers({ "Street map": street, "Aerial photo": air }, overlays, { collapsed: true }).addTo(map);
  // Quick on/off buttons for the layers people use most.
  const quick = [["Flood", ["Flood plains", "Flood prone areas"]], ["Zoning", ["Zoning (Unitary Plan)"]], ["School zones", ["Top-10 school zones"]], ["State housing", ["State housing (Kāinga Ora)"]]]
    .filter(([, names]) => names.every(nm => overlays[nm]));
  const qc = L.control({ position: "topleft" });
  qc.onAdd = () => {
    const d = L.DomUtil.create("div", "mapchips"); L.DomEvent.disableClickPropagation(d);
    d.innerHTML = quick.map(([t, names]) => `<button type="button" data-l="${esc(names.join("|"))}" aria-pressed="${names.every(nm => map.hasLayer(overlays[nm]))}">${esc(t)}</button>`).join("");
    d.addEventListener("click", e => {
      const b = e.target.closest("button"); if (!b) return;
      const names = b.dataset.l.split("|"), on = b.getAttribute("aria-pressed") !== "true";
      names.forEach(nm => on ? overlays[nm].addTo(map) : map.removeLayer(overlays[nm]));
      b.setAttribute("aria-pressed", String(on));
    });
    return d;
  };
  qc.addTo(map);
  map.on("overlayadd overlayremove", () => $$(".mapchips button", map.getContainer()).forEach(b => b.setAttribute("aria-pressed", String(b.dataset.l.split("|").every(nm => map.hasLayer(overlays[nm]))))));
  L.control.scale({ imperial: false }).addTo(map);
  const note = L.control({ position: "bottomleft" });
  note.onAdd = () => L.DomUtil.create("div", "zoomnote");
  note.addTo(map);
  const upd = () => { const d = note.getContainer(); d.textContent = "Zoom in to see flood and zoning layers"; d.style.display = map.getZoom() < 14 ? "" : "none"; };
  map.on("zoomend", upd); upd();
  maps.push(map);
  return map;
}
function destroyMaps() { maps.forEach(m => m.remove()); maps = []; }
async function drawParcel(map, p, style = { color: "#ff5a3c", weight: 3, fill: false }) {
  try {
    const u = `${TITLES}/query?geometry=${p.lon},${p.lat}&geometryType=esriGeometryPoint&inSR=4326&spatialRel=esriSpatialRelIntersects&outFields=title_no&returnGeometry=true&outSR=4326&f=json`;
    const f = ((await (await fetch(u)).json()).features || [])[0]; if (!f) return null;
    return L.polygon(f.geometry.rings.map(r => r.map(([x, y]) => [y, x])), { ...style, interactive: false }).addTo(map);
  } catch (e) { return null; }
}
const popup = p => `<div class="mpop">${p.lat ? `<img alt="" src="${aerial(p.lat, p.lon, 440, 220)}">` : ""}<b>${k(priceOf(p))}</b><div class="a">${esc(street(p))}</div>
  <div class="m">${esc(p.suburb)} · ${p.land_m2 ? Math.round(p.land_m2) + " m² · " : ""}score ${p.score ?? "–"}${p.flood ? " · " + esc(p.flood) : ""}</div><a class="btn primary sm" href="#/site/${encodeURIComponent(p.id)}">View details</a></div>`;

// ---------- Server ----------
// GET without a body, POST with one. The X-Requested-With header is what the PHP side checks against forged requests.
let ME = null;
async function api(path, body) {
  const r = await fetch("api/" + path, body ? { method: "POST", headers: { "Content-Type": "application/json", "X-Requested-With": "aps" }, body: JSON.stringify(body) } : { cache: "no-store" });
  const j = await r.json().catch(() => ({}));
  if (r.status === 401 && ME && path !== "auth.php") { ME = null; loginPage(false); }
  if (!r.ok) throw Object.assign(new Error(j.error || `Something went wrong (${r.status})`), { status: r.status });
  return j;
}

// ---------- Save to list ----------
let menuFor = null;
async function postStore(body) { applyStore(await api("lists.php", body)); }
function applyStore(s) {
  S.saved = new Map(Object.entries(s.shortlist || {}).map(([id, d]) => [id, Array.isArray(d.lists) && d.lists.length ? d.lists.map(String) : ["main"]]));
  S.lists = Object.entries(s.lists || {}).map(([id, d]) => ({ id, name: String(d.name || "Untitled"), at: String(d.at || "") }))
    .sort((a, b) => a.id === "main" ? -1 : b.id === "main" ? 1 : a.at.localeCompare(b.at));
  const n = $("#savedCount"); n.hidden = !S.saved.size; n.textContent = S.saved.size;
  // Refresh hearts in place, so the page doesn't jump.
  $$("[data-save]").forEach(b => { const on = S.saved.has(b.dataset.save); b.classList.toggle("on", on); if (b.classList.contains("savebtn")) b.textContent = on ? "♥" : "♡"; else b.textContent = on ? "♥ Saved" : "♡ Save"; });
  if (menuFor) fillMenu();
  if (location.hash.startsWith("#/saved")) savedPage();
}
function loadStore() {
  return api("lists.php").then(s => { S.api = true; applyStore(s); }).catch(() => { });
}
async function setSiteLists(id, lists) {
  const p = S.byId.get(String(id)) || {};
  await postStore(lists.length ? { op: "set", col: "shortlist", id: String(id), data: { address: p.address, url: p.url, suburb: p.suburb, at: new Date().toISOString(), lists } } : { op: "delete", col: "shortlist", id: String(id) });
}
async function newList(name) {
  name = String(name || "").trim().slice(0, 40); if (!name) return null;
  if (!S.lists.length) await postStore({ op: "set", col: "lists", id: "main", data: { name: "Shortlist", at: new Date().toISOString() } });
  const id = "l" + Date.now().toString(36);
  await postStore({ op: "set", col: "lists", id, data: { name, at: new Date().toISOString() } });
  return id;
}
function fillMenu() {
  const on = listsOf(menuFor);
  $("#savemenu").innerHTML = `<b>Save to a list</b>${allLists().map(l => `<label><input type="checkbox" data-l="${esc(l.id)}"${on.includes(l.id) ? " checked" : ""}>${esc(l.name)}<small>${[...S.saved.values()].filter(x => x.includes(l.id)).length}</small></label>`).join("")}
    <form id="menuNew"><input type="text" maxlength="40" placeholder="New list name" aria-label="New list name"><button class="btn sm primary" type="submit">Add</button></form>`;
}
function openMenu(btn) {
  menuFor = btn.dataset.save; fillMenu();
  const m = $("#savemenu"), r = btn.getBoundingClientRect();
  m.hidden = false;
  m.style.top = (r.bottom + window.scrollY + 8) + "px";
  m.style.left = Math.max(12, Math.min(r.right + window.scrollX - m.offsetWidth, document.documentElement.clientWidth - m.offsetWidth - 12)) + "px";
}
function closeMenu() { menuFor = null; $("#savemenu").hidden = true; }
document.addEventListener("click", e => {
  const b = e.target.closest("[data-save]");
  if (b) { e.preventDefault(); e.stopPropagation(); menuFor === b.dataset.save ? closeMenu() : openMenu(b); return; }
  if (menuFor && !$("#savemenu").contains(e.target)) closeMenu();
});
document.addEventListener("keydown", e => { if (e.key === "Escape") { closeMenu(); closeDrawer(); } });
$("#savemenu").addEventListener("change", e => {
  const lid = e.target.dataset.l; if (!lid || !menuFor) return;
  const next = listsOf(menuFor).filter(x => x !== lid); if (e.target.checked) next.push(lid);
  setSiteLists(menuFor, next).catch(err => alert(err.message));
});
$("#savemenu").addEventListener("submit", async e => {
  e.preventDefault(); const id = menuFor, name = e.target.querySelector("input").value;
  try { const lid = await newList(name); if (lid && id) await setSiteLists(id, listsOf(id).concat([lid])); } catch (err) { alert(err.message); }
});

// ---------- Home ----------
function home() {
  const ok = S.sites.filter(p => !fails(p).length);
  const newOk = ok.filter(p => p.status === "new").sort(SORTS.score[1]);
  const top = ok.filter(p => ["Strong", "Worth a look"].includes(p.label)).sort(SORTS.score[1]);
  const byD = {}; ok.forEach(p => { const d = districtOf(p); (byD[d] = byD[d] || []).push(p); });
  const dTiles = Object.keys(S.subs).filter(d => byD[d]?.length).sort((a, b) => byD[b].length - byD[a].length).map(d => {
    const pts = byD[d].filter(p => p.lat), lat = pts.reduce((a, p) => a + p.lat, 0) / pts.length, lon = pts.reduce((a, p) => a + p.lon, 0) / pts.length;
    return `<a class="district" href="#/search?district=${encodeURIComponent(d)}" style="background-image:url('${aerial(lat, lon, 420, 260, 0.03)}')"><div><b>${esc(d)}</b><span>${byD[d].length} sites</span></div></a>`;
  }).join("");
  const run = S.data.run_date ? new Date(S.data.run_date + "T08:00:00").toLocaleDateString("en-NZ", { weekday: "long", day: "numeric", month: "long" }) : "";
  $("#app").innerHTML = `
  <section class="hero" style="background-image:url('https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/export?bbox=174.66,-36.93,174.86,-36.83&bboxSR=4326&imageSR=3857&size=1600,800&format=jpg&f=image')">
    <div class="container">
      <h1>Find Auckland's next development site</h1>
      <p>Every house on 600 m²+ for sale across Auckland, checked each morning for zoning, flood, title, schools, services and real sale prices.</p>
      <form class="bigsearch" id="homeSearch"><input id="homeQ" type="search" placeholder="Search an address, suburb or district" aria-label="Search an address, suburb or district" autocomplete="off"><button class="btn primary" type="submit">Search</button></form>
      <div class="quick">
        <a href="#/search?preset=ideal">Under $900k</a><a href="#/search?preset=strong">Strong sites</a><a href="#/search?preset=train">Near a train</a>
        <a href="#/search?preset=top">Top school zones</a><a href="#/search?preset=new">New today</a><a href="#/saved">Saved</a>
      </div>
    </div>
  </section>
  <div class="container">
    <div class="stats">
      <div class="stat"><b class="num">${ok.length}</b><span>sites meet your rules</span></div>
      <div class="stat"><b class="num">${newOk.length}</b><span>new today</span></div>
      <div class="stat"><b class="num">${ok.filter(p => priceOf(p) && priceOf(p) <= 1100000).length}</b><span>within $1.1m</span></div>
      <div class="stat"><b class="num">${S.sites.length}</b><span>sites checked in total</span></div>
      <div class="stat"><b>${esc(run || "—")}</b><span>last updated</span></div>
    </div>
    ${newOk.length ? `<section class="section"><div class="section-head"><div><h2>New today</h2><p>Fresh listings that meet your rules.</p></div><a class="btn" href="#/search?preset=new">See all ${newOk.length}</a></div><div class="rail">${newOk.slice(0, 8).map(card).join("")}</div></section>` : ""}
    <section class="section"><div class="section-head"><div><h2>Top picks</h2><p>The highest-scoring sites right now.</p></div><a class="btn" href="#/search">Browse all</a></div><div class="rail">${top.slice(0, 8).map(card).join("")}</div></section>
    <section class="section" style="padding-bottom:56px"><div class="section-head"><div><h2>Browse by district</h2><p>Sites meeting your rules in each part of Auckland.</p></div></div><div class="districts">${dTiles}</div></section>
  </div>`;
  $("#homeSearch").addEventListener("submit", e => { e.preventDefault(); location.hash = "#/search?q=" + encodeURIComponent($("#homeQ").value.trim()); });
}

// ---------- Search ----------
let shown = 24, sMap = null, sMarkers = new Map(), lastSig = "";
function search(params) {
  // Links from the home page carry a one-off preset; apply it, then drop it from the address.
  if ([...params.keys()].length) {
    const pre = params.get("preset"), d = params.get("district");
    Q = params.get("q") || "";
    if (pre || d) { F = Object.assign({}, DEF); Q = ""; }
    if (pre === "ideal") F.pmax = "900000";
    if (pre === "strong") F.label = "Strong";
    if (pre === "train") F.train = true;
    if (pre === "top") F.topzone = true;
    if (pre === "new") F.isNew = true;
    if (d && S.subs[d]) F.subs = S.subs[d].map(norm);
    saveF(); history.replaceState(null, "", "#/search");
  }
  const zonesList = [...new Set(S.sites.map(p => zoneShort(p.zone)))].sort();
  $("#app").innerHTML = `
  <div class="fbar"><div class="container">
    <label class="fsearch"><span aria-hidden="true">⌕</span><input id="fq" type="search" placeholder="Address or suburb" aria-label="Search an address or suburb" value="${esc(Q)}" autocomplete="off"></label>
    <select class="fsel" id="f-pmin" aria-label="Minimum price">${opts([["", "Min price"], ...PRICE_STEPS.map(v => [v, k(v)])], F.pmin)}</select>
    <select class="fsel" id="f-pmax" aria-label="Maximum price">${opts([["", "Max price"], ...PRICE_STEPS.map(v => [v, k(v)])], F.pmax)}</select>
    <select class="fsel" id="f-rules" aria-label="Your rules">${opts([["pass", "Meets my rules"], ["all", "Show everything"], ["fail", "Breaks a rule"]], F.rules)}</select>
    <select class="fsel" id="f-zone" aria-label="Zone">${opts([["", "Any zone"], ...zonesList.map(z => [z, z])], F.zone)}</select>
    <select class="fsel" id="f-sort" aria-label="Sort">${opts(Object.entries(SORTS).map(([key, v]) => [key, v[0]]), SORT)}</select>
    <button class="btn sm" id="moreF" type="button">More filters</button>
    <button class="btn sm viewtoggle" id="vt" type="button">Map</button>
  </div></div>
  <div class="split" id="split">
    <div class="results"><div class="rhead"><div><h1 id="rtitle"></h1><p id="rsub"></p></div><button class="btn sm" id="clearF" type="button">Clear filters</button></div>
      <div class="grid" id="grid"></div><button class="btn more" id="moreBtn" type="button" hidden></button></div>
    <div class="mapcol"><div class="map" id="smap"></div></div>
  </div>`;
  sMap = makeMap($("#smap")); lastSig = ""; shown = 24;
  const bind = (id, key) => $(id).addEventListener("change", e => { F[key] = e.target.value; saveF(); renderResults(); });
  bind("#f-pmin", "pmin"); bind("#f-pmax", "pmax"); bind("#f-rules", "rules"); bind("#f-zone", "zone");
  $("#f-sort").addEventListener("change", e => { SORT = e.target.value; ls.set("aps-sort", SORT); renderResults(); });
  $("#fq").addEventListener("input", e => { Q = e.target.value; renderResults(); });
  $("#moreF").addEventListener("click", openDrawer);
  $("#clearF").addEventListener("click", () => { F = Object.assign({}, DEF); Q = ""; saveF(); search(new URLSearchParams()); });
  $("#vt").addEventListener("click", () => { const s = $("#split"); s.classList.toggle("show-map"); $("#vt").textContent = s.classList.contains("show-map") ? "List" : "Map"; sMap?.invalidateSize(); });
  $("#moreBtn").addEventListener("click", () => { shown += 24; renderResults(false); });
  $("#grid").addEventListener("mouseover", e => { const c = e.target.closest(".card"); hiMarker(c?.dataset.id); });
  $("#grid").addEventListener("mouseleave", () => hiMarker(null));
  renderResults();
}
let hiId = null;
function hiMarker(id) {
  if (hiId === id) return;
  const old = sMarkers.get(hiId); if (old) old.setStyle({ radius: 6, weight: 1.2, color: "#fff" });
  hiId = id; const m = sMarkers.get(id); if (m) { m.setStyle({ radius: 10, weight: 3, color: "#14201d" }); m.bringToFront(); }
}
function renderResults(resetPaging = true) {
  const items = results();
  const sig = JSON.stringify([F, Q, SORT]);
  if (resetPaging && sig !== lastSig) shown = 24;
  const n = activeCount(); $("#moreF").textContent = n ? `More filters (${n})` : "More filters";
  ["#f-pmin", "#f-pmax", "#f-zone"].forEach(s => $(s).classList.toggle("on", !!$(s).value)); $("#f-rules").classList.toggle("on", F.rules !== "pass");
  const area = F.subs.length ? (Object.entries(S.subs).find(([, list]) => list.length === F.subs.length && list.every(s => F.subs.includes(norm(s))))?.[0] || `${F.subs.length} suburbs`) : "Auckland";
  $("#rtitle").textContent = Q ? `Results for "${Q}"` : `${items.length.toLocaleString()} site${items.length === 1 ? "" : "s"} in ${area}`;
  $("#rsub").textContent = Q ? `${items.length} match across all ${S.sites.length} sites (other filters paused while searching)` : F.rules === "pass" ? "Meeting your rules · " + SORTS[SORT][0] : SORTS[SORT][0];
  $("#grid").innerHTML = items.length ? items.slice(0, shown).map(p => card(p, "row")).join("") : `<div class="empty">No sites match. Try clearing a filter or two.</div>`;
  const mb = $("#moreBtn"); mb.hidden = items.length <= shown; mb.textContent = `Show more (${items.length - shown} left)`;
  // Map: every matching site, coloured by rating; fit to them when the filters change.
  if (!sMap) return;
  if (sig !== lastSig) {
    sMarkers.forEach(m => m.remove()); sMarkers.clear(); hiId = null;
    const pts = [];
    [...items].reverse().forEach(p => {
      if (!p.lat) return;
      const m = L.circleMarker([p.lat, p.lon], { radius: 6, color: "#fff", weight: 1.2, fillColor: dotColor(p.label), fillOpacity: .95 }).bindPopup(() => popup(p), { maxWidth: 260 }).addTo(sMap);
      m.on("click", () => { const c = $(`.card[data-id="${CSS.escape(String(p.id))}"]`); $$(".card.hl").forEach(x => x.classList.remove("hl")); if (c) { c.classList.add("hl"); c.scrollIntoView({ behavior: "smooth", block: "nearest" }); } });
      sMarkers.set(String(p.id), m); pts.push([p.lat, p.lon]);
    });
    if (pts.length) sMap.fitBounds(pts, { padding: [30, 30], maxZoom: Q ? 17 : 14 });
    lastSig = sig;
  }
}

// Filter drawer
function closeDrawer() { $(".drawer")?.remove(); $(".drawer-back")?.remove(); }
function openDrawer() {
  closeDrawer();
  const seg = (key, list) => `<div class="seg" data-seg="${key}">${list.map(([v, t]) => `<button type="button" data-v="${esc(v)}" aria-pressed="${String(F[key]) === String(v)}">${esc(t)}</button>`).join("")}</div>`;
  const sel = (key, list) => `<select data-k="${key}">${opts(list, F[key])}</select>`;
  const titles = [...new Set(S.sites.map(p => p.title || "Unknown"))].sort();
  const counts = {}; S.sites.forEach(p => { const s = norm(p.suburb); counts[s] = (counts[s] || 0) + 1; });
  const area = Object.entries(S.subs).map(([d, subs]) => {
    const n = subs.reduce((a, s) => a + (counts[norm(s)] || 0), 0);
    return `<div class="dgrp" data-d="${esc(d)}"><div class="drow"><input type="checkbox" data-dist="${esc(d)}" aria-label="All of ${esc(d)}"><button type="button" class="tog">${esc(d)} ▸</button><small>${n}</small></div>
      <div class="sub" hidden>${subs.map(s => `<label class="${counts[norm(s)] ? "" : "zero"}"><input type="checkbox" value="${esc(norm(s))}">${esc(s)}<small>${counts[norm(s)] || ""}</small></label>`).join("")}</div></div>`;
  }).join("");
  document.body.insertAdjacentHTML("beforeend", `<div class="drawer-back"></div>
  <aside class="drawer" role="dialog" aria-label="Filters"><header><h2>Filters</h2><button class="btn sm" type="button" data-close>Close</button></header>
  <div class="body">
    <div class="fgroup"><h3>Area</h3><input type="search" id="dq" placeholder="Find a suburb"><div class="dlist">${area}</div></div>
    <div class="fgroup"><h3>Your rules</h3>${seg("rules", [["pass", "Meets my rules"], ["all", "Everything"], ["fail", "Breaks a rule"]])}<p class="muted" style="font-size:12.5px;margin:8px 0 0">Rules: freehold title, Mixed Housing or Terrace Housing zone, and a secondary school not rated Low.</p></div>
    <div class="fgroup"><h3>Price</h3><div class="row2"><label class="f">From${sel("pmin", [["", "Any"], ...PRICE_STEPS.map(v => [v, k(v)])])}</label><label class="f">Up to${sel("pmax", [["", "Any"], ...PRICE_STEPS.map(v => [v, k(v)])])}</label></div></div>
    <div class="fgroup"><h3>Rating</h3>${seg("label", [["", "Any"], ["Strong", "Strong"], ["Worth a look", "Worth a look"], ["Stretch", "Over budget"], ["Marginal", "Marginal"]])}</div>
    <div class="fgroup"><h3>Handy filters</h3><div class="seg" data-tg>
      <button type="button" data-t="train" aria-pressed="${F.train}">Near a train (1.2 km)</button><button type="button" data-t="topzone" aria-pressed="${F.topzone}">Top-10 school zone</button><button type="button" data-t="isNew" aria-pressed="${F.isNew}">New today</button></div></div>
    <div class="fgroup"><h3>Flood</h3>${seg("flood", [["", "Any"], ["none", "No flood overlay"], ["yes", "Flood overlay"]])}</div>
    <div class="fgroup"><h3>Power lines</h3>${seg("power", [["", "Any"], ["none", "None nearby"], ["near", "Near or over site"]])}</div>
    <div class="fgroup"><h3>Land and title</h3><div class="row2"><label class="f">Position${sel("pos", [["", "Any"], ["front", "Road front"], ["corner", "Corner site"], ["rear", "Rear site"]])}</label><label class="f">Title${sel("title", [["", "Any"], ...titles.map(t => [t, t])])}</label></div></div>
    <div class="fgroup"><h3>Schools and neighbourhood</h3><div class="row2">
      <label class="f">Secondary school${sel("sec", [["", "Any"], ["High", "High"], ["Medium", "Medium"], ["Low", "Low"], ["HM", "High or Medium"]])}</label>
      <label class="f">Primary school${sel("pri", [["", "Any"], ["High", "High"], ["Medium", "Medium"], ["Low", "Low"], ["HM", "High or Medium"]])}</label>
      <label class="f">State housing nearby${sel("sh", [["", "Any"], ["Low", "Low"], ["Medium", "Medium"], ["High", "High"], ["LM", "Low or Medium"]])}</label>
      <label class="f">Saved list${sel("list", [["", "Any"], ["any", "On any list"], ...allLists().map(l => [l.id, l.name])])}</label></div></div>
  </div>
  <footer><button class="btn" type="button" data-clear>Clear all</button><button class="btn primary" type="button" data-close id="showN"></button></footer></aside>`);
  const dr = $(".drawer");
  const syncArea = () => {
    $$(".dgrp", dr).forEach(g => {
      const boxes = $$(".sub input", g), on = boxes.filter(b => F.subs.includes(b.value)).length, d = $("[data-dist]", g);
      boxes.forEach(b => b.checked = F.subs.includes(b.value)); d.checked = on && on === boxes.length; d.indeterminate = on > 0 && on < boxes.length;
    });
    $("#showN").textContent = `Show ${results().length} sites`;
  };
  const changed = () => { saveF(); syncArea(); if ($("#grid")) renderResults(); };
  dr.addEventListener("click", e => {
    const t = e.target;
    if (t.closest("[data-close]")) return closeDrawer();
    if (t.closest("[data-clear]")) { F = Object.assign({}, DEF); saveF(); closeDrawer(); return search(new URLSearchParams()); }
    if (t.classList.contains("tog")) { const s = $(".sub", t.closest(".dgrp")); s.hidden = !s.hidden; t.textContent = t.textContent.replace(/[▸▾]/, s.hidden ? "▸" : "▾"); return; }
    const sb = t.closest("[data-seg] button"); if (sb) { F[sb.parentElement.dataset.seg] = sb.dataset.v; $$("button", sb.parentElement).forEach(b => b.setAttribute("aria-pressed", String(b === sb))); return changed(); }
    const tb = t.closest("[data-t]"); if (tb) { F[tb.dataset.t] = !F[tb.dataset.t]; tb.setAttribute("aria-pressed", String(F[tb.dataset.t])); return changed(); }
  });
  dr.addEventListener("change", e => {
    const t = e.target;
    if (t.dataset.k) { F[t.dataset.k] = t.value; return changed(); }
    if (t.dataset.dist) { const vals = S.subs[t.dataset.dist].map(norm); F.subs = t.checked ? [...new Set(F.subs.concat(vals))] : F.subs.filter(s => !vals.includes(s)); return changed(); }
    if (t.closest(".sub")) { F.subs = t.checked ? [...new Set(F.subs.concat([t.value]))] : F.subs.filter(s => s !== t.value); return changed(); }
  });
  $("#dq", dr).addEventListener("input", e => {
    const q = e.target.value.trim().toLowerCase();
    $$(".dgrp", dr).forEach(g => { const labels = $$(".sub label", g); let any = false; labels.forEach(l => { const m = !q || l.textContent.toLowerCase().includes(q); l.hidden = !m; any = any || m; }); g.hidden = !any && !g.dataset.d.toLowerCase().includes(q); $(".sub", g).hidden = !q; });
  });
  $(".drawer-back").addEventListener("click", closeDrawer);
  syncArea();
}

// ---------- Property page ----------
function svc(s) {
  if (!s || typeof s !== "object") return "Unknown";
  if (s.on_site) return `On site${s.diameter_mm ? " · " + s.diameter_mm + " mm" : ""}`;
  if (s.distance_m == null) return esc(s.note || "None found nearby");
  return `${Math.round(s.distance_m)} m away${s.diameter_mm ? " · " + s.diameter_mm + " mm" : ""}`;
}
const dl = rows => `<dl class="dl">${rows.filter(r => r && r[1] != null && r[1] !== "").map(([a, b]) => `<div><dt>${a}</dt><dd>${b}</dd></div>`).join("")}</dl>`;
const bandChip = b => b ? `<span class="chip ${b === "High" ? "good" : b === "Medium" ? "warn" : "bad"}">${esc(b)}</span>` : "—";
function sitePage(id) {
  const p = S.byId.get(String(id));
  if (!p) { $("#app").innerHTML = `<div class="container"><div class="empty"><h2>Site not found</h2><p>It may have sold or been withdrawn since the last update.</p><a class="btn primary" href="#/search">Back to search</a></div></div>`; return; }
  const pr = p.pricing || {}, l = p.land && typeof p.land === "object" ? p.land : {}, c = p.construction, t = p.transport || {}, g = p.growth, n = p.numbers || {}, sh = p.state_housing, pw = p.power_lines;
  const sch = z => [].concat(z || []).filter(Boolean);
  const schoolRows = [["Primary", sch(p.schools?.primary)], ["Intermediate", sch(p.schools?.intermediate)], ["Secondary", sch(p.schools?.secondary)]]
    .flatMap(([lvl, list]) => list.map(s => `<tr><td>${lvl}</td><td><a href="${esc(safeUrl(s.ero))}" target="_blank" rel="noopener">${esc(s.name)}</a>${/Integrated/.test(s.authority || "") ? " <small class='muted'>(integrated)</small>" : ""}</td><td>${bandChip(s.band)}</td><td class="num">${/^[\d.]+$/.test(String(s.ncea_l3_pct ?? "")) ? s.ncea_l3_pct + "% NCEA L3" : "—"}</td></tr>`)).join("");
  const onLists = listsOf(p.id);
  $("#app").innerHTML = `<div class="container">
    <div class="crumbs"><a href="#/search">← Back to search</a> <span class="muted">· ${esc(districtOf(p))} · ${esc(p.suburb)}</span></div>
    <div class="phead">
      <div><div style="display:flex;gap:8px;align-items:center;margin-bottom:8px;flex-wrap:wrap"><span class="score ${scoreCls(p.label)}">${p.score ?? "–"}</span><span class="chip ${p.label === "Strong" ? "good" : p.label === "Worth a look" ? "warn" : "accent"}">${esc(ratingName(p.label))}</span>${p.status === "new" ? `<span class="chip accent">New today</span>` : ""}${p.status === "price_change" ? `<span class="chip warn">Price changed${p.price_text_prev ? " (was " + esc(p.price_text_prev) + ")" : ""}</span>` : ""}${onLists.length ? `<span class="chip bad">♥ ${esc(onLists.map(listName).join(", "))}</span>` : ""}</div>
        <h1>${esc(street(p))}</h1><div class="sub">${esc(p.suburb)}, Auckland · ${esc(p.price_text || "Price not stated")}</div></div>
      <div class="acts"><a class="btn primary" href="${esc(safeUrl(p.url))}" target="_blank" rel="noopener">View listing ↗</a>${S.api ? `<button class="btn" type="button" data-save="${esc(p.id)}">${onLists.length ? "♥ Saved" : "♡ Save"}</button>` : ""}<a class="btn" href="https://www.google.com/maps/search/?api=1&query=${p.lat},${p.lon}" target="_blank" rel="noopener">Google Maps ↗</a></div>
    </div>
    <div class="pgrid"><div>
      <section class="panel"><h2>Price</h2><div class="pricebox">
        <div><span>Expected price</span><b class="num">${money(pr.expected || p.price_used)}</b><small>${esc(p.price_basis || "")}</small></div>
        <div><span>Low case</span><b class="num">${money(pr.low_case)}</b><small>bottom quarter of sales vs CV here</small></div>
        <div><span>Typical sale vs CV</span><b class="num">${pr.ratio_likely ? Math.round(pr.ratio_likely * 100) + "%" : "—"}</b><small>${esc(pr.ratio_basis || "")}</small></div>
        <div><span>Your budget</span><b style="font-size:16px">${esc(pr.fit || "—")}</b><small>CV ${k(p.cv)} · land ${k(p.land_value)}${p.estimate ? " · estimate " + k(p.estimate.low) + "–" + k(p.estimate.high) : ""}</small></div></div></section>
      <section class="panel"><h2>Key facts</h2><div class="kf">
        <div><span>Land</span><b class="num">${p.land_m2 ? Math.round(p.land_m2) + " m²" : "—"}</b></div><div><span>Floor</span><b class="num">${p.floor_m2 ? p.floor_m2 + " m²" : "—"}</b></div>
        <div><span>Beds / baths</span><b>${p.beds ?? "–"} / ${p.baths ?? "–"}</b></div><div><span>Built</span><b>${esc(p.decade_built || "Unknown")}</b></div>
        <div><span>Zone</span><b>${esc(zoneShort(p.zone))}</b></div><div><span>Title</span><b>${esc(p.title || "Unknown")}</b></div>
        <div><span>Flood</span><b style="color:${p.flood ? "var(--bad)" : "var(--good)"}">${esc(p.flood || "None found")}</b></div><div><span>Slope</span><b>${p.slope && !p.slope.error ? esc(p.slope.class) + " · " + p.slope.fall_m + " m fall" : "Unknown"}</b></div>
      </div></section>
      <section class="panel"><h2>Development potential</h2>${p.dev_angle ? `<div class="angle"><b>Development angle</b>${esc(p.dev_angle)}</div>` : ""}${p.why ? `<p>${esc(p.why)}</p>` : ""}
        ${fails(p).length || (p.flags || []).length ? `<ul class="flags">${fails(p).map(f => `<li class="rule"><b>Outside your rules:</b> ${esc(f)}</li>`).join("")}${(p.flags || []).map(f => `<li>${esc(f)}</li>`).join("")}</ul>` : ""}</section>
      <section class="panel"><h2>Land and building</h2>${dl([
        ["Shape", l.shape ? esc(l.shape) + (l.width_m ? ` · ${l.width_m} × ${l.depth_m} m` : "") : null], ["Position", esc(l.position)], ["Road frontage", l.frontage_m ? l.frontage_m + " m" : l.position ? "None" : null],
        ["Beside walkway", l.path_frontage_m ? `${l.path_frontage_m} m · ${esc(l.path_names)}` : null], ["Access width", l.access_width_m != null ? l.access_width_m + " m" : null], ["Driveway rule", esc(l.driveway_rule)],
        ["Title (LINZ)", esc(p.title_estate || p.title)], ["Cladding", c ? esc((c.cladding || []).join(", ") || "Not stated") : null], ["Roof", c ? esc((c.roof || []).join(", ") || "Not stated") : null],
        ["Building risk", c ? esc(c.risk) + ((c.issues || []).length ? " · " + esc(c.issues.join("; ")) : "") : null]])}</section>
      <section class="panel"><h2>Schools</h2>${schoolRows ? `<table class="sch"><thead><tr><th>Zone</th><th>School</th><th>Rating</th><th>Results</th></tr></thead><tbody>${schoolRows}</tbody></table>` : `<p class="muted">No school zones found.</p>`}
        ${topZones(p).map(z => `<p style="margin:12px 0 0"><span class="chip good">Top-10 zone</span> ${esc(z.name)} (NCEA L3 ${z.ncea_l3_pct}%)</p>`).join("")}</section>
      <section class="panel"><h2>Services, hazards and neighbourhood</h2>${dl([
        ["Wastewater", svc(p.services?.wastewater)], ["Stormwater", svc(p.services?.stormwater)], ["Flood", esc(p.flood || "No flood overlay on the site")],
        ["High-voltage lines", pw && typeof pw === "object" ? esc(pw.level === "None nearby" ? "None nearby" : `${pw.level} · ${pw.line || ""} ${pw.kv ? pw.kv + " kV" : ""}`) : null],
        ["State housing nearby", sh && !sh.error ? `${esc(sh.level)} · ${sh.within_100m} within 100 m, ${sh.within_400m} within 400 m` : null]])}</section>
      ${g ? `<section class="panel"><h2>Growth outlook</h2><div class="pricebox"><div><span>Next 5 years (indicative)</span><b>${pct(g.outlook_5y_pct)}</b><small>range ${pct(g.outlook_low_pct)} to ${pct(g.outlook_high_pct)}</small></div><div><span>Suburb, last 12 months</span><b>${pct(g.suburb_12m_pct)}</b></div><div><span>Suburb, 10 years</span><b>${pct(g.suburb_10y_pct)}</b></div><div><span>From 2021 peak</span><b>${pct(g.suburb_from_peak_pct)}</b></div></div>
        ${(g.drivers || []).length ? `<ul style="margin:14px 0 0;padding-left:20px">${g.drivers.map(x => `<li>${esc(x)}</li>`).join("")}</ul>` : ""}</section>` : ""}
      <section class="panel"><h2>Numbers</h2>${dl([["Deposit", money(n.deposit)], ["Loan", money(n.loan)], ["Repayment / week", money(n.weekly_repayment)], ["Estimated rent / week", money(n.weekly_rent)],
        ["Gross yield", n.gross_yield_pct ? n.gross_yield_pct.toFixed(1) + "%" : "—"], ["Land share of CV", n.land_value_share_pct ? Math.round(n.land_value_share_pct) + "%" : "—"], ["Second dwelling (est.)", money(n.second_dwelling_cost)]])}</section>
      ${(p.questions || []).length ? `<section class="panel"><h2>Questions for the agent</h2><ol class="qs">${p.questions.map(q => `<li>${esc(q)}</li>`).join("")}</ol></section>` : ""}
    </div>
    <div class="sticky"><div class="pmap" id="pmap"></div>
      <section class="panel" style="margin-top:18px"><h2>Location</h2>${dl([["To the CBD", t.cbd_km != null ? t.cbd_km + " km" : null], ["Nearest train", t.train ? esc(t.train.name) + " · " + dist(t.train.distance_m) : null],
        ["Nearest bus stop", t.bus && t.bus.distance_m != null ? dist(t.bus.distance_m) : "None within 800 m"], ["Motorway on-ramp", p.motorway?.on_ramp ? p.motorway.on_ramp.distance_km + " km" : null]])}</section></div>
    </div></div>`;
  if (p.lat) {
    const m = makeMap($("#pmap"), { aerialFirst: true });
    if (m) { m.setView([p.lat, p.lon], 18); L.circleMarker([p.lat, p.lon], { radius: 6, color: "#fff", weight: 2, fillColor: "#ff5a3c", fillOpacity: 1 }).addTo(m); drawParcel(m, p).then(poly => { if (poly) m.fitBounds(poly.getBounds(), { padding: [40, 40], maxZoom: 19 }); }); }
  }
}

// ---------- Saved ----------
let savedTab = "all";
function savedPage() {
  if (!S.api) { $("#app").innerHTML = `<div class="container"><div class="empty"><h2>Saved lists aren't available</h2><p>The site couldn't reach its list storage. Try reloading.</p></div></div>`; return; }
  const ids = savedTab === "all" ? [...S.saved.keys()] : [...S.saved.entries()].filter(([, l]) => l.includes(savedTab)).map(([id]) => id);
  const sites = ids.map(id => S.byId.get(id)).filter(Boolean).sort(SORTS.score[1]);
  const gone = ids.length - sites.length;
  const cnt = lid => [...S.saved.values()].filter(x => x.includes(lid)).length;
  $("#app").innerHTML = `<div class="container" style="padding:28px 20px 56px">
    <h1 style="font-size:30px">Saved</h1>
    <div class="tabs"><button type="button" data-tab="all" aria-pressed="${savedTab === "all"}">All saved (${S.saved.size})</button>${allLists().map(l => `<button type="button" data-tab="${esc(l.id)}" aria-pressed="${savedTab === l.id}">${esc(l.name)} (${cnt(l.id)})</button>`).join("")}</div>
    ${sites.length ? `<div class="rail">${sites.map(card).join("")}</div>` : `<div class="empty">Nothing saved here yet. Tap ♡ on any site to save it.</div>`}
    ${gone ? `<p class="muted">${gone} saved site${gone > 1 ? "s are" : " is"} no longer listed (sold or withdrawn).</p>` : ""}
    <section class="panel" style="margin-top:36px;max-width:640px"><h2>Manage lists</h2><div class="lmanage">
      ${allLists().map(l => `<div class="r"><input type="text" maxlength="40" value="${esc(l.name)}" data-rename="${esc(l.id)}" aria-label="List name"><span class="muted">${cnt(l.id)}</span><button class="btn sm" type="button" data-del="${esc(l.id)}">Delete</button></div>`).join("")}
      <form class="r" id="newListForm"><input type="text" maxlength="40" placeholder="New list name" aria-label="New list name"><button class="btn sm primary" type="submit">Add list</button></form></div></section>
  </div>`;
  const app = $("#app");
  app.querySelectorAll("[data-tab]").forEach(b => b.addEventListener("click", () => { savedTab = b.dataset.tab; savedPage(); }));
  app.querySelectorAll("[data-rename]").forEach(i => i.addEventListener("change", () => { const name = i.value.trim().slice(0, 40); if (name) postStore({ op: "set", col: "lists", id: i.dataset.rename, data: { name, at: (S.lists.find(x => x.id === i.dataset.rename) || {}).at || new Date().toISOString() } }).catch(e => alert(e.message)); }));
  app.querySelectorAll("[data-del]").forEach(b => b.addEventListener("click", async () => {
    if (b.dataset.armed !== "1") { b.dataset.armed = "1"; b.textContent = "Click again to delete"; return; }
    const lid = b.dataset.del;
    try { for (const [id, l] of [...S.saved.entries()]) if (l.includes(lid)) await setSiteLists(id, l.filter(x => x !== lid)); await postStore({ op: "delete", col: "lists", id: lid }); if (savedTab === lid) savedTab = "all"; savedPage(); } catch (e) { alert(e.message); }
  }));
  $("#newListForm").addEventListener("submit", e => { e.preventDefault(); newList(e.target.querySelector("input").value).catch(err => alert(err.message)); });
}

// ---------- Sign in, account, admin ----------
function showNav() {
  const signedIn = !!ME;
  $$(".nav a").forEach(a => a.hidden = !signedIn || (a.dataset.nav === "admin" && !ME.admin));
  if (ME) $("#navMe").textContent = ME.name || ME.username;
}
// setup = no accounts exist yet: the first person to sign up becomes the admin.
function loginPage(setup, mode = setup ? "setup" : "login") {
  ME = null; destroyMaps(); showNav(); closeMenu(); closeDrawer();
  const field = (id, label, type = "text", extra = "") => `<label class="f">${label}<input id="${id}" type="${type}" ${extra}></label>`;
  $("#app").innerHTML = `<div class="authwrap"><div class="authcard">
    <h1>${mode === "setup" ? "Set up your site" : mode === "register" ? "Create your account" : "Sign in"}</h1>
    <p class="muted">${mode === "setup" ? "No accounts exist yet. Create the admin account: you'll manage invites and users." : mode === "register" ? "You'll need the invite code you were given." : "Auckland Property Search is private. Sign in to continue."}</p>
    <form id="authForm" class="authform">
      ${mode !== "login" ? field("aName", "Your name", "text", 'maxlength="60" autocomplete="name"') : ""}
      ${field("aUser", "Username", "text", 'maxlength="30" autocomplete="username" autocapitalize="none" spellcheck="false" required')}
      ${field("aPass", "Password", "password", `minlength="${mode === "login" ? 1 : 8}" autocomplete="${mode === "login" ? "current-password" : "new-password"}" required`)}
      ${mode === "register" ? field("aCode", "Invite code", "text", 'maxlength="20" autocapitalize="characters" autocomplete="off" required') : ""}
      <p class="autherr" id="authErr" role="alert" hidden></p>
      <button class="btn primary" type="submit">${mode === "login" ? "Sign in" : "Create account"}</button>
    </form>
    ${mode === "login" ? `<p class="authalt">Have an invite code? <a href="#" data-mode="register">Create an account</a></p>` : mode === "register" ? `<p class="authalt">Already have an account? <a href="#" data-mode="login">Sign in</a></p>` : ""}
  </div></div>`;
  $$("[data-mode]").forEach(a => a.addEventListener("click", e => { e.preventDefault(); loginPage(false, a.dataset.mode); }));
  $("#authForm").addEventListener("submit", async e => {
    e.preventDefault();
    const btn = $("#authForm button"), err = $("#authErr"); btn.disabled = true; err.hidden = true;
    try {
      const body = { op: mode, username: $("#aUser").value, password: $("#aPass").value };
      if (mode !== "login") body.name = $("#aName").value;
      if (mode === "register") body.invite = $("#aCode").value;
      ME = (await api("auth.php", body)).user;
      await start();
    } catch (ex) { err.textContent = ex.message; err.hidden = false; btn.disabled = false; }
  });
  $("#aName, #aUser")?.focus();
}
function accountPage() {
  $("#app").innerHTML = `<div class="container" style="padding:28px 20px 56px;max-width:640px">
    <h1 style="font-size:30px">Your account</h1>
    <section class="panel" style="margin-top:18px"><h2>${esc(ME.name)}</h2>${dl([["Username", esc(ME.username)], ["Role", ME.admin ? "Admin" : "Member"]])}</section>
    <section class="panel"><h2>Change password</h2><form id="pwForm" class="authform">
      <label class="f">Current password<input id="pOld" type="password" autocomplete="current-password" required></label>
      <label class="f">New password (8+ characters)<input id="pNew" type="password" minlength="8" autocomplete="new-password" required></label>
      <p class="autherr" id="pMsg" role="status" hidden></p><button class="btn primary" type="submit">Change password</button></form></section>
    <button class="btn" type="button" id="signOut">Sign out</button></div>`;
  $("#pwForm").addEventListener("submit", async e => {
    e.preventDefault(); const m = $("#pMsg");
    try { await api("auth.php", { op: "password", old: $("#pOld").value, new: $("#pNew").value }); m.textContent = "Password changed."; m.className = "authok"; e.target.reset(); }
    catch (ex) { m.textContent = ex.message; m.className = "autherr"; }
    m.hidden = false;
  });
  $("#signOut").addEventListener("click", async () => { await api("auth.php", { op: "logout" }).catch(() => { }); S.data = null; S.saved = new Map(); location.hash = "#/"; boot(); });
}
async function adminPage() {
  if (!ME.admin) { location.hash = "#/"; return; }
  $("#app").innerHTML = `<div class="loading">Loading users…</div>`;
  let d; try { d = await api("admin.php"); } catch (e) { $("#app").innerHTML = `<div class="loading">${esc(e.message)}</div>`; return; }
  const when = s => s ? new Date(s).toLocaleDateString("en-NZ", { day: "numeric", month: "short", year: "numeric" }) : "—";
  const site = location.origin + location.pathname;
  $("#app").innerHTML = `<div class="container" style="padding:28px 20px 56px;max-width:900px">
    <h1 style="font-size:30px">Admin</h1>
    <section class="panel" style="margin-top:18px"><h2>Invite code ${d.invite.enabled ? `<span class="chip good">Sign-up open</span>` : `<span class="chip">Sign-up closed</span>`}</h2>
      <p style="font-size:28px;font-weight:800;letter-spacing:.12em;margin:0 0 8px" class="num">${esc(d.invite.code || "—")}</p>
      <p class="muted">Send people this: <i>Go to ${esc(site)}, choose "Create an account" and use invite code ${esc(d.invite.code)}.</i> Make a new code to stop the old one working; close sign-up when everyone has joined.</p>
      <div style="display:flex;gap:8px;flex-wrap:wrap"><button class="btn primary" type="button" data-a="invite_new">New code</button><button class="btn" type="button" data-a="invite_enabled" data-on="${d.invite.enabled ? "" : "1"}">${d.invite.enabled ? "Close sign-up" : "Open sign-up"}</button></div></section>
    <section class="panel"><h2>Users (${d.users.length})</h2><p class="autherr" id="admMsg" hidden></p>
      <div style="overflow-x:auto"><table class="sch"><thead><tr><th>Name</th><th>Username</th><th>Joined</th><th>Last sign-in</th><th></th></tr></thead><tbody>
      ${d.users.map(u => `<tr><td>${esc(u.name)} ${u.admin ? `<span class="chip accent">Admin</span>` : ""}</td><td>${esc(u.username)}</td><td>${when(u.created)}</td><td>${when(u.last)}</td>
        <td style="white-space:nowrap;text-align:right"><button class="btn sm" type="button" data-a="reset" data-u="${esc(u.username)}">Reset password</button>
        ${u.username !== ME.username ? `<button class="btn sm" type="button" data-a="admin" data-u="${esc(u.username)}" data-on="${u.admin ? "" : "1"}">${u.admin ? "Remove admin" : "Make admin"}</button><button class="btn sm" type="button" data-a="delete" data-u="${esc(u.username)}">Remove</button>` : ""}</td></tr>`).join("")}
      </tbody></table></div></section></div>`;
  // The listener sits on this render's own container, so re-rendering never stacks handlers.
  $("#app > .container").addEventListener("click", async e => {
    const b = e.target.closest("[data-a]"); if (!b) return;
    const a = b.dataset.a, msg = $("#admMsg");
    if (a === "delete" && b.dataset.armed !== "1") { b.dataset.armed = "1"; b.textContent = "Click again to remove"; return; }
    try {
      const r = await api("admin.php", { op: a, username: b.dataset.u, enabled: !!b.dataset.on, on: !!b.dataset.on });
      if (r.password) { await adminPage(); const m = $("#admMsg"); m.className = "authok"; m.textContent = `New temporary password for ${b.dataset.u}: ${r.password}  (send it to them; they can change it under Account)`; m.hidden = false; return; }
      adminPage();
    } catch (ex) { msg.textContent = ex.message; msg.className = "autherr"; msg.hidden = false; }
  });
}

// ---------- Router ----------
function route() {
  closeMenu(); closeDrawer(); destroyMaps(); sMap = null; sMarkers.clear();
  const [path, qs] = (location.hash.slice(1) || "/").split("?");
  const parts = path.split("/").filter(Boolean), page = parts[0] || "home";
  $$("[data-nav]").forEach(a => a.dataset.nav === page ? a.setAttribute("aria-current", "page") : a.removeAttribute("aria-current"));
  document.querySelector("footer.site").hidden = page === "search";
  if (!ME || !S.data) return;
  if (page === "search") search(new URLSearchParams(qs || ""));
  else if (page === "site") sitePage(decodeURIComponent(parts[1] || ""));
  else if (page === "saved") savedPage();
  else if (page === "account") accountPage();
  else if (page === "admin") adminPage();
  else home();
  if (page !== "search") window.scrollTo(0, 0);
  document.title = page === "site" && S.byId.get(decodeURIComponent(parts[1] || "")) ? street(S.byId.get(decodeURIComponent(parts[1]))) + " · Auckland Property Search" : "Auckland Property Search";
}
window.addEventListener("hashchange", route);
window.addEventListener("focus", () => { if (!menuFor && S.api && ME) loadStore(); });

// Sign-in first; the site data is only served to signed-in users (api/data.php).
async function start() {
  showNav();
  $("#app").innerHTML = `<div class="loading">Loading Auckland sites…</div>`;
  try {
    const [d, subs, zones] = await Promise.all([
      api("data.php"),
      fetch("suburbs.json").then(r => r.ok ? r.json() : {}).catch(() => ({})),
      fetch("zone-codes.json").then(r => r.ok ? r.json() : {}).catch(() => ({}))
    ]);
    S.data = d; S.sites = (d.shortlist || []).filter(p => p && p.id); S.byId = new Map(S.sites.map(p => [String(p.id), p]));
    S.subs = subs || {}; S.zones = zones || {}; S.subDistrict.clear();
    Object.entries(S.subs).forEach(([dname, list]) => list.forEach(s => S.subDistrict.set(norm(s), dname)));
    route(); loadStore();
  } catch (e) { if (ME) $("#app").innerHTML = `<div class="loading">${esc(e.message)}. Try reloading the page.</div>`; }
}
async function boot() {
  try { const a = await api("auth.php"); ME = a.user; ME ? start() : loginPage(a.setup); }
  catch (e) { $("#app").innerHTML = `<div class="loading">The site couldn't reach its server. Try reloading the page.</div>`; }
}
boot();
