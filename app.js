"use strict";
// PropertyHunte — one page, hash routes: #/ home, #/search, #/site/<id>, #/feas/<id>, #/saved, #/account, #/admin, #/reset.
// Data: data.json (the daily run's sites), suburbs.json (district -> suburbs), zone-codes.json, api/lists.php (saved lists).

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const money = n => n ? (n < 0 ? "−$" : "$") + Math.round(Math.abs(n)).toLocaleString("en-NZ") : "—";
const k = n => !n ? "—" : n >= 1e6 ? "$" + (n / 1e6).toFixed(2).replace(/0$/, "") + "m" : "$" + Math.round(n / 1000) + "k";
const isNum = v => typeof v === "number" && isFinite(v);
const pct = v => !isNum(v) ? "—" : (v > 0 ? "+" : "") + v + "%";
const rentOf = p => isNum(p.numbers?.weekly_rent) && p.numbers.weekly_rent > 0 ? p.numbers.weekly_rent : 0;
// The signed-in person's own budget (Account page), compared with the expected price and the low case.
const fitOf = p => {
  const b = S.budget, pr = priceOf(p), low = p.pricing?.low_case || 0;
  if (!b.max) return ""; if (!pr) return "Price unknown";
  if (b.ideal && pr <= b.ideal) return "Ideal range";
  if (pr <= b.max) return "In budget";
  if (low && low <= b.max) return "Possible: below CV";
  return pr <= b.max * 1.15 ? "Stretch: slightly over" : "Over budget";
};
const yieldOf = p => { const r = rentOf(p), pr = priceOf(p); return r && pr ? Math.round(1000 * r * 52 / pr) / 10 : 0; };
const dist = m => m == null ? "—" : m >= 1000 ? (m / 1000).toFixed(1) + " km" : Math.round(m) + " m";
const safeUrl = u => /^https?:\/\//.test(u || "") ? u : "#";
const norm = s => String(s || "").toLowerCase().replace(/^st\.? /, "saint ").replace(/^mt\.? /, "mount ").replace(/[^a-z]+/g, " ").trim();
const street = p => String(p.address || "").split(",")[0];
const priceOf = p => p.pricing?.expected || p.price_used || 0;
const zoneShort = z => String(z || "Unknown").replace("Residential - ", "").replace(" Zone", "").replace("Terrace Housing and Apartment Building", "Terrace Housing (THAB)");
const scoreCls = l => "s-" + String(l || "").split(" ")[0];
const ratingName = l => l || "";
// Rating from the score alone (older data still carries budget/rules labels).
const rate = s => (s || 0) >= 60 ? "Strong" : (s || 0) >= 45 ? "Worth a look" : "Marginal";
const bandRank = { High: 3, Medium: 2, Low: 1 };
const bestBand = list => { let b = null; [].concat(list || []).filter(s => s && s.band).forEach(s => { if (!b || bandRank[s.band] > bandRank[b]) b = s.band; }); return b; };
const bandOk = (v, list) => !v || (v === "HM" ? ["High", "Medium"].includes(bestBand(list)) : bestBand(list) === v);
const ls = { get(key, d) { try { const v = localStorage.getItem(key); return v == null ? d : JSON.parse(v); } catch (e) { return d; } }, set(key, v) { try { localStorage.setItem(key, JSON.stringify(v)); } catch (e) { } } };

// Aerial photo (Esri World Imagery) centred on a point; half = half-width in degrees of longitude.
function aerial(lat, lon, w = 480, h = 300, half = 0.0008) {
  const dy = half * (h / w) * Math.cos(lat * Math.PI / 180);
  return `https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/export?bbox=${(lon - half).toFixed(6)},${(lat - dy).toFixed(6)},${(lon + half).toFixed(6)},${(lat + dy).toFixed(6)}&bboxSR=4326&imageSR=3857&size=${w},${h}&format=jpg&f=image`;
}

// ---------- Cities ----------
// Each city has its own daily data (api/data.php?city=) and suburb groups; the choice is remembered per browser.
const CITIES = {
  akl: { name: "Auckland", center: [-36.88, 174.76], zoom: 10, subs: "suburbs.json", hero: "174.66,-36.93,174.86,-36.83" },
  chc: { name: "Christchurch", center: [-43.53, 172.62], zoom: 11, subs: "suburbs-chc.json", hero: "172.55,-43.57,172.72,-43.49" }
};
let CITY = CITIES[ls.get("aps-city", "akl")] ? ls.get("aps-city", "akl") : "akl";
const C = () => CITIES[CITY];

// ---------- State ----------
const S = { data: null, sites: [], byId: new Map(), subs: {}, subDistrict: new Map(), zones: {}, saved: new Map(), lists: [], api: false, budget: {} };
const DEF = { lmin: "", lmax: "", bmin: "", ptype: "", ymin: "", inBudget: false, pmin: "", pmax: "", label: "", zone: "", title: "", flood: "", power: "", sh: "", sec: "", pri: "", pos: "", train: false, isNew: false, topzone: false, list: "", subs: [] };
let F = Object.assign({}, DEF, ls.get("aps-f-" + CITY, CITY === "akl" ? ls.get("aps-f", {}) : {}));
let Q = "", SORT = ls.get("aps-sort", "score");
const saveF = () => ls.set("aps-f-" + CITY, F);

const districtOf = p => S.subDistrict.get(norm(p.suburb)) || "Other";
const topZones = p => { const tz = S.data?.top_zones || {}; return [].concat(p.schools?.secondary || []).filter(s => s && tz[String(s.id)]).map(s => ({ id: String(s.id), ...tz[String(s.id)] })); };
const listsOf = id => S.saved.get(String(id)) || [];
const allLists = () => S.lists.length ? S.lists : [{ id: "main", name: "Shortlist", at: "" }];
const listName = id => (allLists().find(l => l.id === id) || { name: "Shortlist" }).name;

function match(p, f = F, q = Q) {
  if (q) return (p.address + " " + p.suburb).toLowerCase().replace(/[,\s]+/g, " ").includes(q.toLowerCase().replace(/[,\s]+/g, " ").trim());
  const price = priceOf(p);
  if (f.lmin && !((+p.land_m2 || 0) >= +f.lmin)) return false;
  if (f.lmax && !((+p.land_m2 || 0) < +f.lmax)) return false;
  if (f.bmin && !((+p.beds || 0) >= +f.bmin)) return false;
  if (f.ptype && typeOf(p) !== f.ptype) return false;
  if (f.ymin && yieldOf(p) < +f.ymin) return false;
  if (f.inBudget && S.budget.max && !/Ideal|In budget|Possible/.test(fitOf(p))) return false;
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
  yield: ["Highest rental yield", (a, b) => yieldOf(b) - yieldOf(a)],
  land: ["Biggest land", (a, b) => (b.land_m2 || 0) - (a.land_m2 || 0)],
  cbd: ["Closest to the CBD", (a, b) => (a.transport?.cbd_km ?? 99) - (b.transport?.cbd_km ?? 99)],
  growth: ["Future growth", (a, b) => (b.growth?.outlook_5y_pct ?? -99) - (a.growth?.outlook_5y_pct ?? -99)]
};
const results = () => S.sites.filter(p => match(p)).sort(SORTS[SORT]?.[1] || SORTS.score[1]);
const activeCount = () => Object.keys(DEF).filter(key => key === "subs" ? F.subs.length : F[key] !== DEF[key]).length;
const PRICE_STEPS = (() => { const s = []; for (let v = 100000; v <= 1500000; v += 100000) s.push(v); for (let v = 1750000; v <= 3000000; v += 250000) s.push(v); s.push(3500000, 4000000, 5000000); return s; })();
// Listing type from realestate.co.nz's sub-type; older records (houses only) have none.
function typeOf(p) {
  const t = String(p.ptype || "");
  if (/apartment|studio/i.test(t)) return "Apartment";
  if (/townhouse/i.test(t)) return "Townhouse";
  if (/unit|flat/i.test(t)) return "Unit";
  if (/section|land/i.test(t)) return "Section";
  return "House";
}
const opts = (list, cur) => list.map(([v, t]) => `<option value="${esc(v)}"${String(v) === String(cur) ? " selected" : ""}>${esc(t)}</option>`).join("");

// ---------- Cards ----------
function chips(p) {
  const c = [];
  if (/plain|prone|hazard|management/i.test(p.flood || "")) c.push(`<span class="chip blue">${esc(p.flood.replace(/ \(.*\)/, ""))}</span>`);
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
      <div class="cfacts"><span><b>${p.land_m2 ? Math.round(p.land_m2) + " m²" : "—"}</b> land</span><span><b>${p.beds ?? "–"}</b> bd</span>${rentOf(p) ? `<span><b>$${rentOf(p)}</b>/wk · <b>${yieldOf(p).toFixed(1)}%</b> yield</span>` : ""}<span>${esc(zoneShort(p.zone))}</span></div>
      <div class="cchips">${chips(p)}</div>
    </a>
  </article>`;
}

// ---------- Maps ----------
const AC = "https://services1.arcgis.com/n4yPwebTjJCmXB6W/arcgis/rest/services/";
const TITLES = "https://services.arcgis.com/xdsHIIxuCWByZiCB/arcgis/rest/services/LINZ_NZ_Property_Titles/FeatureServer/0";
const CROSL = "https://services.arcgis.com/xdsHIIxuCWByZiCB/arcgis/rest/services/CRoSL_Layer_N/FeatureServer/0";
const CCC = "https://gis.ccc.govt.nz/server/rest/services/OpenData/";
const SCHOOL_ZONES ="https://services.arcgis.com/XTtANUDT8Va4DLwI/arcgis/rest/services/NZ_School_Zone_boundaries/FeatureServer/0";
const dotColor = l => ({ "Strong": "#1f7a4c", "Worth a look": "#c08000", "Marginal": "#8a9592" }[l] || "#75807d");
const zoneColor = n => /Single House/.test(n) ? "#f3e2a9" : /Suburban/.test(n) ? "#f2c45a" : /Mixed Housing Urban/.test(n) ? "#e8964a" : /Terrace/.test(n) ? "#c0562f" : /Business|Centre/.test(n) ? "#8e6ac8" : /Rural|Countryside/.test(n) ? "#8fbf6b" : /Open Space/.test(n) ? "#4f9a5b" : /Large Lot/.test(n) ? "#e9dfc3" : "#9aa5a2";
let maps = [];
function makeMap(el, { aerialFirst = false, floodOn = true } = {}) {
  if (!window.L || !L.esri) { el.innerHTML = `<div class="empty">The map couldn't load.</div>`; return null; }
  const map = L.map(el, { preferCanvas: true, zoomControl: true }).setView(C().center, C().zoom);
  const street = L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", { maxZoom: 19, attribution: "&copy; OpenStreetMap contributors" });
  const air = L.tileLayer("https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}", { maxZoom: 19, attribution: "Imagery &copy; Esri" });
  (aerialFirst ? air : street).addTo(map);
  // Council polygons are heavy, so each layer only draws from street/suburb zoom.
  const layer = (svc, color, minZoom) => L.esri.featureLayer({ url: AC + svc + "/FeatureServer/0", minZoom, simplifyFactor: 0.5, precision: 6, interactive: false, style: () => ({ color, weight: 1, fillColor: color, fillOpacity: 0.35 }) });
  const zoning = L.esri.featureLayer({ url: AC + "Unitary_Plan_Base_Zone/FeatureServer/0", minZoom: 15, simplifyFactor: 0.5, precision: 6, fields: ["OBJECTID", "ZONE"],
    style: f => { const c = zoneColor(S.zones[String(f.properties.ZONE)] || ""); return { color: c, weight: 0.6, fillColor: c, fillOpacity: 0.3 }; } });
  zoning.bindPopup(l => esc(S.zones[String(l.feature.properties.ZONE)] || "Zone"));
  // Christchurch: the City Council's District Plan layers, under the same names so the quick buttons work for both cities.
  const ccc = (path, color, minZoom, where) => L.esri.featureLayer({ url: CCC + path, minZoom, where, simplifyFactor: 0.5, precision: 6, interactive: false, style: () => ({ color, weight: 1, fillColor: color, fillOpacity: 0.35 }) });
  const overlays = CITY === "chc" ? {
    "Flood plains": ccc("DistrictPlanB/FeatureServer/25", "#1f6fd1", 14), "Flood prone areas": ccc("DistrictPlanB/FeatureServer/30", "#4fa3e0", 14),
    "Flood sensitive areas": ccc("DistrictPlan/FeatureServer/89", "#9ccff0", 14),
    "Zoning (Unitary Plan)": L.esri.featureLayer({ url: CCC + "DistrictPlan/FeatureServer/78", minZoom: 15, where: "RemovedByPlanChangeIdentifier IS NULL", simplifyFactor: 0.5, precision: 6, fields: ["OBJECTID", "Type"],
      style: f => { const t = String(f.properties.Type || ""), c = /High density/i.test(t) ? "#c0562f" : /Medium density|Medium Density/.test(t) ? "#e8964a" : /Density Transition/.test(t) ? "#f2c45a" : /Residential/.test(t) ? "#f3e2a9" : /Transport/.test(t) ? "#d9d9d9" : zoneColor(t); return { color: c, weight: 0.6, fillColor: c, fillOpacity: 0.3 }; } })
      .bindPopup(l => esc(l.feature.properties.Type || "Zone")),
    "Special Character Areas": ccc("DistrictPlan/FeatureServer/59", "#a05ac8", 14),
    "Historic heritage": ccc("DistrictPlanB/FeatureServer/32", "#b03a2e", 15)
  } : {
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
  // Public pipes: Auckland Council stormwater and Watercare wastewater. Dense, so only from street level.
  const pipeTip = (l, what, dia) => `<b>${what}</b>${dia && dia < 990 ? `<br>${dia} mm` : ""}`;
  if (CITY === "chc") {
    const cw = "ServiceStatus='In Service' AND Ownership='CCC'";
    overlays["Stormwater pipes"] = L.esri.featureLayer({ url: CCC + "StormWater/FeatureServer/1", where: cw, minZoom: 16, precision: 6, fields: ["OBJECTID", "NominalDiameter"],
      style: () => ({ color: "#1f9ad6", weight: 3, opacity: 0.9 }) }).bindPopup(l => pipeTip(l, "Stormwater pipe", l.feature.properties.NominalDiameter));
    overlays["Wastewater pipes"] = L.esri.featureLayer({ url: CCC + "WasteWater/FeatureServer/1", where: cw, minZoom: 16, precision: 6, fields: ["OBJECTID", "NominalDiameter"],
      style: () => ({ color: "#8a5a2b", weight: 3, opacity: 0.9, dashArray: "6 4" }) }).bindPopup(l => pipeTip(l, "Wastewater pipe", l.feature.properties.NominalDiameter));
  } else {
  overlays["Stormwater pipes"] = L.esri.featureLayer({ url: AC + "Stormwater_Pipe/FeatureServer/0", minZoom: 16, precision: 6, fields: ["OBJECTID", "SW_DIAMETER_MM"],
    style: () => ({ color: "#1f9ad6", weight: 3, opacity: 0.9 }) }).bindPopup(l => pipeTip(l, "Stormwater pipe", l.feature.properties.SW_DIAMETER_MM));
  overlays["Wastewater pipes"] = L.esri.featureLayer({ url: "https://services5.arcgis.com/PnnKqtqi3qfxnaPc/arcgis/rest/services/Wastewater_Network/FeatureServer/5",
    where: "STATUS='OP' AND UNITTYPE LIKE 'PIPE%'", minZoom: 16, precision: 6, fields: ["OBJECTID", "NOM_DIA_MM"],
    style: () => ({ color: "#8a5a2b", weight: 3, opacity: 0.9, dashArray: "6 4" }) }).bindPopup(l => pipeTip(l, "Wastewater pipe", l.feature.properties.NOM_DIA_MM));
  }
  if (floodOn) { overlays["Flood plains"].addTo(map); overlays["Flood prone areas"].addTo(map); }
  const labels = CITY === "chc" ? { "Flood plains": "High flood hazard", "Flood prone areas": "Flood management areas", "Flood sensitive areas": "Fixed floor level areas",
    "Zoning (Unitary Plan)": "Zoning (District Plan)", "Special Character Areas": "Residential character areas", "Historic heritage": "Heritage settings" } : {};
  L.control.layers({ "Street map": street, "Aerial photo": air }, Object.fromEntries(Object.entries(overlays).map(([key, v]) => [labels[key] || key, v])), { collapsed: true }).addTo(map);
  // Quick on/off buttons for the layers people use most.
  const quick = [["Flood", ["Flood plains", "Flood prone areas"]], ["Zoning", ["Zoning (Unitary Plan)"]], ["School zones", ["Top-10 school zones"]], ["State housing", ["State housing (Kāinga Ora)"]], ["Stormwater", ["Stormwater pipes"]], ["Wastewater", ["Wastewater pipes"]]]
    .filter(([, names]) => names.every(nm => overlays[nm]));
  const qc = L.control({ position: "topleft" });
  qc.onAdd = () => {
    const d = L.DomUtil.create("div", "mapchips"); L.DomEvent.disableClickPropagation(d);
    d.innerHTML = quick.map(([t, names]) => `<button type="button" data-l="${esc(names.join("|"))}" aria-pressed="${names.every(nm => map.hasLayer(overlays[nm]))}">${esc(t)}</button>`).join("");
    d.addEventListener("click", e => {
      const b = e.target.closest("button"); if (!b) return;
      const names = b.dataset.l.split("|"), on = b.getAttribute("aria-pressed") !== "true";
      names.forEach(nm => on ? overlays[nm].addTo(map) : map.removeLayer(overlays[nm]));
      b.setAttribute("aria-pressed", String(on)); map.fire("overlayadd");
    });
    return d;
  };
  qc.addTo(map);
  map.on("overlayadd overlayremove", () => $$(".mapchips button", map.getContainer()).forEach(b => b.setAttribute("aria-pressed", String(b.dataset.l.split("|").every(nm => map.hasLayer(overlays[nm]))))));
  L.control.scale({ imperial: false }).addTo(map);
  const note = L.control({ position: "bottomleft" });
  note.onAdd = () => L.DomUtil.create("div", "zoomnote");
  note.addTo(map);
  const pipesOn = () => map.hasLayer(overlays["Stormwater pipes"]) || map.hasLayer(overlays["Wastewater pipes"]);
  const upd = () => { const d = note.getContainer(), z = map.getZoom();
    d.textContent = z < 14 ? "Zoom in to see flood and zoning layers" : "Zoom in further to see pipes";
    d.style.display = z < 14 || (z < 16 && pipesOn()) ? "" : "none"; };
  map.on("zoomend overlayadd overlayremove", upd); upd();
  maps.push(map);
  return map;
}
function destroyMaps() { maps.forEach(m => m.remove()); maps = []; }
async function drawParcel(map, p, style = { color: "#ff5a3c", weight: 3, fill: false }) {
  try {
    const u = `${TITLES}/query?geometry=${p.lon},${p.lat}&geometryType=esriGeometryPoint&inSR=4326&spatialRel=esriSpatialRelIntersects&outFields=title_no&returnGeometry=true&outSR=4326&f=json`;
    const f = ((await (await fetch(u)).json()).features || [])[0]; if (!f) return null;
    const rings = f.geometry.rings.map(r => r.map(([x, y]) => [y, x]));
    const poly = L.polygon(rings, { ...style, interactive: false }).addTo(map);
    // Boundary dimensions: each side's length in metres, shown from close zoom so they stay readable.
    const dims = L.layerGroup();
    rings.forEach(r => {
      // Merge nearly straight runs (survey rings often split one side into short pieces).
      const pts = r.slice(0, r.length > 1 && r[0][0] === r[r.length - 1][0] && r[0][1] === r[r.length - 1][1] ? -1 : undefined);
      const bearing = (a, b) => Math.atan2(b[1] - a[1], b[0] - a[0]);
      const corners = pts.filter((pt, i) => { const a = pts[(i - 1 + pts.length) % pts.length], c = pts[(i + 1) % pts.length]; let d = Math.abs(bearing(a, pt) - bearing(pt, c)); if (d > Math.PI) d = 2 * Math.PI - d; return d > 0.12; });
      const cs = corners.length >= 3 ? corners : pts;
      cs.forEach((a, i) => {
        const b = cs[(i + 1) % cs.length], len = map.distance(a, b);
        if (len < 1) return;
        dims.addLayer(L.marker([(a[0] + b[0]) / 2, (a[1] + b[1]) / 2], { interactive: false, keyboard: false,
          icon: L.divIcon({ className: "dimicon", html: `<span class="dimlbl">${len < 10 ? len.toFixed(1) : Math.round(len * 10) / 10} m</span>`, iconSize: [0, 0] }) }));
      });
    });
    const sync = () => map.getZoom() >= 17 && map.hasLayer(poly) ? dims.addTo(map) : dims.remove();
    map.on("zoomend", sync); poly.on("remove", () => { dims.remove(); map.off("zoomend", sync); }); sync();
    return poly;
  } catch (e) { return null; }
}
const popup = p => `<div class="mpop">${p.lat ? `<img alt="" src="${aerial(p.lat, p.lon, 440, 220)}">` : ""}<b>${k(priceOf(p))}</b><div class="a">${esc(street(p))}</div>
  <div class="m">${esc(p.suburb)} · ${p.land_m2 ? Math.round(p.land_m2) + " m² · " : ""}score ${p.score ?? "–"}${p.flood ? " · " + esc(p.flood) : ""}</div><a class="btn primary sm" href="#/site/${encodeURIComponent(p.id)}">View details</a></div>`;

// ---------- Server ----------
// GET without a body, POST with one. The X-Requested-With header is what the PHP side checks against forged requests.
let ME = null;
// ---------- Saved searches (per person, stored with their lists) ----------
// A saved search = name + city + sort + every filter value, so each person can keep several (e.g. one per suburb group).
function toast(msg) {
  let el = $("#toast"); if (!el) { el = document.createElement("div"); el.id = "toast"; el.setAttribute("role", "status"); document.body.appendChild(el); }
  el.textContent = msg; el.classList.add("on"); clearTimeout(toast.t); toast.t = setTimeout(() => el.classList.remove("on"), 2500);
}
function renderMySearches() {
  const sel = $("#mySel"); if (!sel) return;
  const list = S.searches || [];
  $("#saveS").hidden = !S.api; sel.hidden = !S.api || !list.length;
  const cityTag = s => s.city === CITY ? "" : ` (${CITIES[s.city].name})`;
  sel.innerHTML = `<option value="">Saved searches (${list.length})</option>` + list.map(s => `<option value="${esc(s.id)}">${esc(s.name + cityTag(s))}</option>`).join("")
    + (list.length ? `<optgroup label="Delete">${list.map(s => `<option value="del:${esc(s.id)}">Delete "${esc(s.name)}"</option>`).join("")}</optgroup>` : "");
}
async function saveSearch() {
  if (!activeCount()) { alert("Set some filters first (area, price, land size...), then save them."); return; }
  const area = F.subs.length ? (Object.entries(S.subs).find(([, l]) => l.length === F.subs.length && l.every(s => F.subs.includes(norm(s))))?.[0] || `${F.subs.length} suburbs`) : C().name;
  const name = (prompt("Name this search (for example: North Shore under $1m)", area) || "").trim();
  if (!name) return;
  const same = (S.searches || []).find(s => s.name.toLowerCase() === name.toLowerCase() && s.city === CITY);
  if (same && !confirm(`Replace your saved search "${same.name}" with these filters?`)) return;
  const id = same ? same.id : "s" + Date.now().toString(36);
  try { await postStore({ op: "set", col: "searches", id, data: { name, city: CITY, sort: SORT, at: new Date().toISOString(), f: F } }); toast(`Saved "${name}"`); }
  catch (e) { alert(e.message); }
}
function applySearch(id) {
  const s = (S.searches || []).find(x => x.id === id); if (!s) return;
  const f = Object.assign({}, DEF, s.f); f.subs = Array.isArray(f.subs) ? f.subs : [];
  if (s.sort && SORTS[s.sort]) { SORT = s.sort; ls.set("aps-sort", SORT); }
  Q = "";
  if (s.city !== CITY) { ls.set("aps-f-" + s.city, f); location.hash = "#/search"; setCity(s.city); return; }
  F = f; saveF();
  if (location.hash.startsWith("#/search")) search(new URLSearchParams()); else location.hash = "#/search";
  toast(`Showing "${s.name}"`);
}
async function deleteSearch(id) {
  const s = (S.searches || []).find(x => x.id === id); if (!s || !confirm(`Delete your saved search "${s.name}"?`)) return;
  try { await postStore({ op: "delete", col: "searches", id }); } catch (e) { alert(e.message); }
}

// The site list holds a light record per site; the full one (schools, services, title, questions...) comes from one of
// 64 detail parts, loaded when a property or feasibility page opens. Same bucket hash as scripts/split-data.ps1.
const PARTS = new Map();
const partOf = id => { let h = 0; for (const ch of String(id)) h = (h * 31 + ch.charCodeAt(0)) % 1000003; return String(h % 64).padStart(2, "0"); };
async function withFull(id, render) {
  const p = S.byId.get(String(id));
  if (!p || p._full || !S.data?.parts) return render(id);
  const hash = location.hash, part = partOf(id);
  $("#app").innerHTML = `<div class="container"><div class="empty"><p>Loading the site details…</p></div></div>`;
  try {
    if (!PARTS.has(part)) PARTS.set(part, api("data.php?" + (CITY === "akl" ? "" : "city=" + CITY + "&") + "part=" + part));
    const rec = (await PARTS.get(part))[String(id)];
    if (rec) Object.assign(p, rec);
    p._full = true;
  } catch (e) { PARTS.delete(part); }   // show what the list has; the next visit tries again
  if (location.hash === hash) render(id);
}
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
  const bd = s.prefs?.budget || {}; S.budget = { max: +bd.max || 0, ideal: +bd.ideal || 0 };
  S.searches = Object.entries(s.searches || {}).filter(([, d]) => d && typeof d === "object").map(([id, d]) => ({ id, name: String(d.name || "My search"), city: d.city === "chc" ? "chc" : "akl", sort: String(d.sort || ""), at: String(d.at || ""), f: d.f || {} }))
    .sort((a, b) => a.name.localeCompare(b.name));
  if ($("#mySel")) renderMySearches();
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
  const ok = S.sites;
  const newOk = ok.filter(p => p.status === "new").sort(SORTS.score[1]);
  const top = ok.filter(p => ["Strong", "Worth a look"].includes(p.label)).sort(SORTS.score[1]);
  const byD = {}; ok.forEach(p => { const d = districtOf(p); (byD[d] = byD[d] || []).push(p); });
  const dTiles = Object.keys(S.subs).filter(d => byD[d]?.length).sort((a, b) => byD[b].length - byD[a].length).map(d => {
    const pts = byD[d].filter(p => p.lat), lat = pts.reduce((a, p) => a + p.lat, 0) / pts.length, lon = pts.reduce((a, p) => a + p.lon, 0) / pts.length;
    return `<a class="district" href="#/search?district=${encodeURIComponent(d)}" style="background-image:url('${aerial(lat, lon, 420, 260, 0.03)}')"><div><b>${esc(d)}</b><span>${byD[d].length} sites</span></div></a>`;
  }).join("");
  const run = S.data.run_date ? new Date(S.data.run_date + "T08:00:00").toLocaleDateString("en-NZ", { weekday: "long", day: "numeric", month: "long" }) : "";
  $("#app").innerHTML = `
  <section class="hero" style="background-image:url('https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/export?bbox=${C().hero}&bboxSR=4326&imageSR=3857&size=1600,800&format=jpg&f=image')">
    <div class="container">
      <h1>Find ${C().name}'s next development site</h1>
      <p>Every home and section for sale across ${C().name}, checked each morning for zoning, flood, title, schools, services and real sale prices.</p>
      <form class="bigsearch" id="homeSearch"><input id="homeQ" type="search" placeholder="Search an address, suburb or district" aria-label="Search an address, suburb or district" autocomplete="off"><button class="btn primary" type="submit">Search</button></form>
      <div class="quick">
        <a href="#/search?preset=ideal">Under $900k</a><a href="#/search?preset=strong">Strong sites</a>${CITY === "akl" ? `<a href="#/search?preset=train">Near a train</a>` : ""}
        ${CITY === "akl" ? `<a href="#/search?preset=top">Top school zones</a>` : ""}<a href="#/search?preset=new">New today</a><a href="#/saved">Saved</a>
      </div>
    </div>
  </section>
  <div class="container">
    <div class="stats">
      <div class="stat"><b class="num">${ok.length}</b><span>sites for sale</span></div>
      <div class="stat"><b class="num">${newOk.length}</b><span>new today</span></div>
      ${S.budget.max ? `<div class="stat"><b class="num">${ok.filter(p => /Ideal|In budget|Possible/.test(fitOf(p))).length}</b><span>within your budget</span></div>` : `<div class="stat"><b class="num">${ok.filter(p => priceOf(p) && priceOf(p) <= 1000000).length}</b><span>under $1m</span></div>`}
      <div class="stat"><b class="num">${ok.filter(p => yieldOf(p) >= 4).length}</b><span>yield 4%+</span></div>
      <div class="stat"><b>${esc(run || "—")}</b><span>last updated</span></div>
    </div>
    ${newOk.length ? `<section class="section"><div class="section-head"><div><h2>New today</h2><p>Fresh listings since yesterday.</p></div><a class="btn" href="#/search?preset=new">See all ${newOk.length}</a></div><div class="rail">${newOk.slice(0, 8).map(card).join("")}</div></section>` : ""}
    <section class="section"><div class="section-head"><div><h2>Top picks</h2><p>The highest-scoring sites right now.</p></div><a class="btn" href="#/search">Browse all</a></div><div class="rail">${top.slice(0, 8).map(card).join("")}</div></section>
    <section class="section" style="padding-bottom:56px"><div class="section-head"><div><h2>Browse by district</h2><p>Sites for sale in each part of ${C().name}.</p></div></div><div class="districts">${dTiles}</div></section>
  </div>`;
  $("#homeSearch").addEventListener("submit", e => { e.preventDefault(); location.hash = "#/search?q=" + encodeURIComponent($("#homeQ").value.trim()); });
}

// ---------- Search ----------
let shown = 24, sMap = null, sMarkers = new Map(), lastSig = "", selPoly = null;
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
    <select class="fsel desk" id="f-pmin" aria-label="Minimum price">${opts([["", "Min price"], ...PRICE_STEPS.map(v => [v, k(v)])], F.pmin)}</select>
    <select class="fsel desk" id="f-pmax" aria-label="Maximum price">${opts([["", "Max price"], ...PRICE_STEPS.map(v => [v, k(v)])], F.pmax)}</select>
    <select class="fsel desk" id="f-zone" aria-label="Zone">${opts([["", "Any zone"], ...zonesList.map(z => [z, z])], F.zone)}</select>
    <select class="fsel" id="f-sort" aria-label="Sort">${opts(Object.entries(SORTS).map(([key, v]) => [key, v[0]]), SORT)}</select>
    <button class="btn sm" id="moreF" type="button">Filters</button>
    <button class="btn sm" id="saveS" type="button" hidden>Save search</button><select class="fsel" id="mySel" aria-label="Saved searches" hidden></select>
    <button class="btn sm viewtoggle" id="vt" type="button">Map</button>
  </div></div>
  <div class="split" id="split">
    <div class="results"><div class="rhead"><div><h1 id="rtitle"></h1><p id="rsub"></p></div><button class="btn sm" id="clearF" type="button">Clear filters</button></div>
      <div class="grid" id="grid"></div><button class="btn more" id="moreBtn" type="button" hidden></button></div>
    <div class="mapcol"><div class="map" id="smap"></div></div>
  </div>`;
  sMap = makeMap($("#smap")); lastSig = ""; shown = 24;
  const bind = (id, key) => $(id).addEventListener("change", e => { F[key] = e.target.value; saveF(); renderResults(); });
  bind("#f-pmin", "pmin"); bind("#f-pmax", "pmax"); bind("#f-zone", "zone");
  $("#f-sort").addEventListener("change", e => { SORT = e.target.value; ls.set("aps-sort", SORT); renderResults(); });
  $("#fq").addEventListener("input", e => { Q = e.target.value; renderResults(); });
  $("#moreF").addEventListener("click", openDrawer);
  $("#saveS").addEventListener("click", saveSearch);
  $("#mySel").addEventListener("change", e => { const v = e.target.value; e.target.value = ""; if (v.startsWith("del:")) deleteSearch(v.slice(4)); else if (v) applySearch(v); });
  renderMySearches();
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
  const n = activeCount(); $("#moreF").textContent = n ? `Filters (${n})` : "Filters";
  [["#f-pmin", "pmin"], ["#f-pmax", "pmax"], ["#f-zone", "zone"]].forEach(([s, key]) => { $(s).value = F[key]; $(s).classList.toggle("on", !!F[key]); });
  const area = F.subs.length ? (Object.entries(S.subs).find(([, list]) => list.length === F.subs.length && list.every(s => F.subs.includes(norm(s))))?.[0] || `${F.subs.length} suburbs`) : C().name;
  $("#rtitle").textContent = Q ? `Results for "${Q}"` : `${items.length.toLocaleString()} site${items.length === 1 ? "" : "s"} in ${area}`;
  $("#rsub").textContent = Q ? `${items.length} match across all ${S.sites.length} sites (other filters paused while searching)` : SORTS[SORT][0];
  $("#grid").innerHTML = items.length ? items.slice(0, shown).map(p => card(p, "row")).join("") : `<div class="empty">No sites match. Try clearing a filter or two.</div>`;
  const mb = $("#moreBtn"); mb.hidden = items.length <= shown; mb.textContent = `Show more (${items.length - shown} left)`;
  // Map: every matching site, coloured by rating; fit to them when the filters change.
  if (!sMap) return;
  if (sig !== lastSig) {
    sMarkers.forEach(m => m.remove()); sMarkers.clear(); hiId = null; selPoly?.remove(); selPoly = null;
    const pts = [];
    [...items].reverse().forEach(p => {
      if (!p.lat) return;
      const m = L.circleMarker([p.lat, p.lon], { radius: 6, color: "#fff", weight: 1.2, fillColor: dotColor(p.label), fillOpacity: .95 }).bindPopup(() => popup(p), { maxWidth: 260 }).addTo(sMap);
      m.on("click", () => {
        // Outline the selected site's title boundary with its dimensions.
        selPoly?.remove(); selPoly = null; const map0 = sMap;
        drawParcel(sMap, p, { color: "#ff5a3c", weight: 3, fillOpacity: 0.08 }).then(poly => { if (sMap !== map0) return poly?.remove(); selPoly?.remove(); selPoly = poly; });
        const c = $(`.card[data-id="${CSS.escape(String(p.id))}"]`); $$(".card.hl").forEach(x => x.classList.remove("hl")); if (c) { c.classList.add("hl"); c.scrollIntoView({ behavior: "smooth", block: "nearest" }); } });
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
    <div class="fgroup mob"><h3>Price and zone</h3><div class="row2"><label class="f">From${sel("pmin", [["", "Any"], ...PRICE_STEPS.map(v => [v, k(v)])])}</label><label class="f">Up to${sel("pmax", [["", "Any"], ...PRICE_STEPS.map(v => [v, k(v)])])}</label>
      <label class="f">Zone${sel("zone", [["", "Any zone"], ...[...new Set(S.sites.map(p => zoneShort(p.zone)))].sort().map(z => [z, z])])}</label></div></div>
    <div class="fgroup"><h3>Property type</h3>${seg("ptype", [["", "Any"], ["House", "House"], ["Townhouse", "Townhouse"], ["Unit", "Unit"], ["Apartment", "Apartment"], ["Section", "Section"]])}</div>
    <div class="fgroup"><h3>Land size from</h3>${seg("lmin", [["", "Any"], ["300", "300 m²+"], ["400", "400 m²+"], ["500", "500 m²+"], ["600", "600 m²+"], ["800", "800 m²+"], ["1000", "1000 m²+"]])}</div>
    <div class="fgroup"><h3>Land size under</h3>${seg("lmax", [["", "Any"], ["400", "400 m²"], ["600", "600 m²"], ["800", "800 m²"], ["1000", "1000 m²"], ["2000", "2000 m²"]])}</div>
    <div class="fgroup"><h3>Bedrooms</h3>${seg("bmin", [["", "Any"], ["1", "1+"], ["2", "2+"], ["3", "3+"], ["4", "4+"], ["5", "5+"]])}</div>
    <div class="fgroup"><h3>Rating</h3>${seg("label", [["", "Any"], ["Strong", "Strong"], ["Worth a look", "Worth a look"], ["Marginal", "Marginal"]])}</div>
    <div class="fgroup"><h3>Rental yield</h3>${seg("ymin", [["", "Any"], ["3", "3%+"], ["3.5", "3.5%+"], ["4", "4%+"], ["5", "5%+"]])}</div>
    <div class="fgroup"><h3>Handy filters</h3><div class="seg" data-tg>
      ${S.budget.max ? `<button type="button" data-t="inBudget" aria-pressed="${F.inBudget}">Within my budget</button>` : ""}${CITY === "akl" ? `<button type="button" data-t="train" aria-pressed="${F.train}">Near a train (1.2 km)</button><button type="button" data-t="topzone" aria-pressed="${F.topzone}">Top-10 school zone</button>` : ""}<button type="button" data-t="isNew" aria-pressed="${F.isNew}">New today</button></div>
      ${S.budget.max ? "" : `<p class="muted" style="font-size:12.5px;margin:8px 0 0"><a href="#/account">Set your budget</a> to filter to sites within it.</p>`}</div>
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
        <h1>${esc(street(p))}</h1><div class="sub">${esc(p.suburb)}, ${C().name} · ${esc(p.price_text || "Price not stated")}</div></div>
      <div class="acts"><a class="btn primary" href="${esc(safeUrl(p.url))}" target="_blank" rel="noopener">View listing ↗</a>${S.api ? `<button class="btn" type="button" data-save="${esc(p.id)}">${onLists.length ? "♥ Saved" : "♡ Save"}</button>` : ""}<a class="btn" href="https://www.google.com/maps/search/?api=1&query=${p.lat},${p.lon}" target="_blank" rel="noopener">Google Maps ↗</a></div>
    </div>
    <div class="pgrid"><div>
      <section class="panel"><h2>Price</h2><div class="pricebox">
        <div><span>Expected price</span><b class="num">${money(pr.expected || p.price_used)}</b><small>${esc(p.price_basis || "")}</small></div>
        <div><span>Low case</span><b class="num">${money(pr.low_case)}</b><small>bottom quarter of sales vs CV here</small></div>
        <div><span>Typical sale vs CV</span><b class="num">${pr.ratio_likely ? Math.round(pr.ratio_likely * 100) + "%" : "—"}</b><small>${esc(pr.ratio_basis || "")}</small></div>
        <div><span>Your budget</span>${S.budget.max ? `<b style="font-size:16px">${esc(fitOf(p))}</b><small>your max ${k(S.budget.max)}${S.budget.ideal ? " · ideal under " + k(S.budget.ideal) : ""} · <a href="#/account">change</a></small>` : `<b style="font-size:16px">Not set</b><small><a href="#/account">Set your budget</a> to see if this fits</small>`}</div>
        <div><span>Council valuation (CV)</span><b class="num">${money(p.cv)}</b><small>land ${k(p.land_value)}${p.estimate ? " · estimate " + k(p.estimate.low) + "–" + k(p.estimate.high) : ""}</small></div>
        <div><span>Rent you could get</span><b class="num">${rentOf(p) ? money(rentOf(p)) + "/wk" : "—"}</b><small>${rentOf(p) ? "estimate for the current house" : "no rent estimate"}</small></div>
        <div><span>Gross rental yield</span><b class="num">${yieldOf(p) ? yieldOf(p).toFixed(1) + "%" : "—"}</b><small>yearly rent ÷ expected price</small></div></div></section>
      <section class="panel"><h2>Key facts</h2><div class="kf">
        <div><span>Land</span><b class="num">${p.land_m2 ? Math.round(p.land_m2) + " m²" : "—"}</b></div><div><span>Floor</span><b class="num">${p.floor_m2 ? p.floor_m2 + " m²" : "—"}</b></div>
        <div><span>Beds / baths</span><b>${p.beds ?? "–"} / ${p.baths ?? "–"}</b></div><div><span>Built</span><b>${esc(p.decade_built || "Unknown")}</b></div>
        <div><span>Zone</span><b>${esc(zoneShort(p.zone))}</b></div><div><span>Title</span><b>${esc(p.title || "Unknown")}</b></div>
        <div><span>Flood</span><b style="color:${p.flood ? "var(--bad)" : "var(--good)"}">${esc(p.flood || "None found")}</b></div><div><span>Slope</span><b>${p.slope && !p.slope.error ? esc(p.slope.class) + " · " + p.slope.fall_m + " m fall" : "Unknown"}</b></div>
      </div></section>
      <section class="panel"><h2>Development potential</h2>${p.dev_angle ? `<div class="angle"><b>Development angle</b>${esc(p.dev_angle)}</div>` : ""}${p.why ? `<p>${esc(p.why)}</p>` : ""}
        ${(p.flags || []).length ? `<ul class="flags">${p.flags.map(f => `<li>${esc(f)}</li>`).join("")}</ul>` : ""}
        <p style="margin:14px 0 0"><a class="btn primary sm" href="#/feas/${encodeURIComponent(p.id)}">Feasibility study from the LIM →</a></p></section>
      <section class="panel"><h2>Land and building</h2>${dl([
        ["Shape", l.shape ? esc(l.shape) + (l.width_m ? ` · ${l.width_m} × ${l.depth_m} m` : "") : null], ["Position", esc(l.position)], ["Road frontage", l.frontage_m ? l.frontage_m + " m" : l.position ? "None" : null],
        ["Beside walkway", isNum(l.path_frontage_m) ? `${l.path_frontage_m} m${typeof l.path_names === "string" && l.path_names ? " · " + esc(l.path_names) : ""}` : null], ["Access width", l.access_width_m != null ? l.access_width_m + " m" : null], ["Driveway rule", esc(l.driveway_rule)],
        ["Title (LINZ)", esc(p.title_estate || p.title)], ["Cladding", c ? esc((c.cladding || []).join(", ") || "Not stated") : null], ["Roof", c ? esc((c.roof || []).join(", ") || "Not stated") : null],
        ["Building risk", c ? esc(c.risk) + ((c.issues || []).length ? " · " + esc(c.issues.join("; ")) : "") : null]])}</section>
      <section class="panel"><h2>Schools</h2>${schoolRows ? `<table class="sch"><thead><tr><th>Zone</th><th>School</th><th>Rating</th><th>Results</th></tr></thead><tbody>${schoolRows}</tbody></table>` : `<p class="muted">No school zones found.</p>`}
        ${topZones(p).map(z => `<p style="margin:12px 0 0"><span class="chip good">Top-10 zone</span> ${esc(z.name)} (NCEA L3 ${z.ncea_l3_pct}%)</p>`).join("")}</section>
      <section class="panel"><h2>Services, hazards and neighbourhood</h2>${dl([
        ["Wastewater", svc(p.services?.wastewater)], ["Stormwater", svc(p.services?.stormwater)], ["Flood", esc(p.flood || "No flood overlay on the site")],
        ["High-voltage lines", pw && typeof pw === "object" ? esc(pw.level === "None nearby" ? "None nearby" : `${pw.level} · ${pw.line || ""} ${pw.kv ? pw.kv + " kV" : ""}`) : null],
        ["State housing nearby", sh && !sh.error ? `${esc(sh.level)} · ${sh.within_100m} within 100 m, ${sh.within_400m} within 400 m` : null]])}</section>
      ${g ? `<section class="panel"><h2>Growth outlook</h2><div class="pricebox"><div><span>Next 5 years (indicative)</span><b>${pct(g.outlook_5y_pct)}</b><small>range ${pct(g.outlook_low_pct)} to ${pct(g.outlook_high_pct)}</small></div>
        ${[["Suburb, last 12 months", g.suburb_12m_pct], ["Suburb, 10 years", g.suburb_10y_pct], ["From 2021 peak", g.suburb_from_peak_pct]].filter(([, v]) => isNum(v)).map(([t, v]) => `<div><span>${t}</span><b>${pct(v)}</b></div>`).join("")}
        ${isNum(g.suburb_median) ? `<div><span>Suburb median, last 12 months</span><b class="num">${k(g.suburb_median)}</b></div>` : ""}</div>
        ${[g.suburb_12m_pct, g.suburb_10y_pct, g.suburb_from_peak_pct].some(isNum) ? "" : `<p class="muted" style="font-size:13px;margin:10px 0 0">No suburb price history on file for ${esc(p.suburb)} yet, so only the 5-year outlook is shown.</p>`}
        ${(g.drivers || []).length ? `<ul style="margin:14px 0 0;padding-left:20px">${g.drivers.map(x => `<li>${esc(x)}</li>`).join("")}</ul>` : ""}</section>` : ""}
      <section class="panel"><h2>Numbers</h2>${dl([["Deposit (20%)", money(n.deposit)], ["Loan", money(n.loan)], ["Repayment / week", money(n.weekly_repayment)], ["Estimated rent / week", money(rentOf(p))],
        ["Rent covers repayment", rentOf(p) && isNum(n.weekly_repayment) && n.weekly_repayment ? Math.round(100 * rentOf(p) / n.weekly_repayment) + "%" : null],
        ["Gross yield", yieldOf(p) ? yieldOf(p).toFixed(1) + "%" : "—"], ["Land share of CV", n.land_value_share_pct ? Math.round(n.land_value_share_pct) + "%" : "—"], ["Second dwelling (est.)", money(n.second_dwelling_cost)]])}</section>
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

// ---------- Feasibility (free: the LIM is read in the browser, nothing is uploaded) ----------
// Screening assumptions for residential development (Auckland figures; Christchurch build costs run a little lower), ex GST (same as the site-feasibility skill).
const FA = {
  margin: 20, rate: { standalone: 3700, duplex: 3500, terrace: 3300 }, gfa: { standalone: 120, duplex: 110, terrace: 105 },
  demolition: 30000, earthworks: { Flat: 15000, Gentle: 40000, Moderate: 110000, Steep: 250000 }, civilPer: 30000,
  subdivPer: 25000, dcPer: 23000, igcPer: 17000, profPct: 10, consentPct: 2.5, contPct: 7.5, acqPct: 1.5, interest: 7.5,
  months: { a: 15, b: 24 }, drawnPct: 50, sellPct: 3.5, retainedPct: 75
};
const ZONES = {
  "Single House": { lpd: 600, type: "standalone", note: "One dwelling per site (sometimes a minor dwelling). Low development potential." },
  "Mixed Housing Suburban": { lpd: 200, type: "duplex", note: "Up to 3 dwellings permitted; 4+ need resource consent." },
  "Mixed Housing Urban": { lpd: 140, type: "terrace", note: "Up to 3 dwellings permitted; 4+ need resource consent. 11 m height." },
  "Terrace Housing (THAB)": { lpd: 95, type: "terrace", note: "Intensive terraces and apartments; 4+ need resource consent. 16 m height." },
  // Christchurch District Plan (after Plan Change 14).
  "Residential Suburban": { lpd: 450, type: "standalone", note: "Christchurch: about 450 m² per dwelling; more needs resource consent." },
  "Residential Suburban Density Transition": { lpd: 300, type: "duplex", note: "Christchurch: about 300 m² per dwelling; townhouses and duplexes common." },
  "Residential Medium Density": { lpd: 150, type: "terrace", note: "Christchurch: medium density (up to 3 storeys, 14 m in some areas); 4+ need resource consent." },
  "Residential High Density": { lpd: 90, type: "terrace", note: "Christchurch: high density near the central city and centres; taller buildings allowed." }
};
// What to look for in a LIM. Each hit shows the text around it, because LIMs often say "no ..." too.
const LIM_CHECKS = [
  ["bad", "Contaminated land / HAIL", /contaminat|\bHAIL\b|hazardous activit/i],
  ["bad", "Unconsented work, notices or missing code compliance", /notice to fix|unauthori[sz]ed|without (a )?(building )?consent|no code compliance|code compliance certificate (has )?not|CCC (not|has not)|outstanding (requisition|notice)|dangerous|insanitary/i],
  ["bad", "Designation (land may be needed for public works)", /designation/i],
  ["warn", "Flooding or overland flow", /flood (plain|prone|sensitive|hazard)|overland flow|ponding|inundation/i],
  ["warn", "Land stability, erosion or geotech", /land ?slip|instability|unstable|erosion|subsidence|liquefaction|geotech/i],
  ["warn", "Heritage, special character or protected trees", /special character|historic heritage|notable tree|scheduled tree/i],
  ["warn", "Consent notices, covenants or encumbrances", /consent notice|covenant|encumbrance/i],
  ["warn", "Public pipes on or near the site (building over / near)", /build(ing)? over|trunk (sewer|main)|public (stormwater|wastewater|drain)/i],
  ["warn", "Aircraft noise or coastal hazard", /aircraft noise|coastal (inundation|erosion)|sea level/i],
  ["warn", "Rates or charges owing", /rates (arrears|outstanding|owing)|outstanding (rates|charges|development contribution)/i],
  ["info", "Easements or rights of way", /easement|right of way/i],
  ["info", "Swimming pool", /swimming pool|pool barrier/i],
  ["info", "Resource consents on file", /resource consent/i]
];
let pdfReady = null;
function loadPdfJs() {
  return pdfReady ||= new Promise((ok, no) => {
    const s = document.createElement("script");
    s.src = "https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.min.js";
    s.onload = () => { pdfjsLib.GlobalWorkerOptions.workerSrc = "https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.worker.min.js"; ok(); };
    s.onerror = () => { pdfReady = null; no(new Error("The PDF reader couldn't load. Check your connection and try again.")); };
    document.head.appendChild(s);
  });
}
async function pdfText(file) {
  await loadPdfJs();
  const doc = await pdfjsLib.getDocument({ data: await file.arrayBuffer() }).promise;
  let t = "";
  for (let i = 1; i <= doc.numPages; i++) t += (await (await doc.getPage(i)).getTextContent()).items.map(x => x.str).join(" ") + "\n";
  return t.replace(/[ \t]+/g, " ");
}
function limFindings(text) {
  const out = [];
  LIM_CHECKS.forEach(([sev, label, re]) => {
    const g = new RegExp(re.source, "gi"); let m, n = 0, snip = "";
    while ((m = g.exec(text)) && n < 50) { if (!n) snip = text.slice(Math.max(0, m.index - 90), m.index + 110).replace(/\s+/g, " ").trim(); n++; }
    if (n) out.push({ sev, label, n, snip });
  });
  const z = text.match(/Residential\s*-\s*(Single House|Mixed Housing Suburban|Mixed Housing Urban|Terrace Housing and Apartment Buildings?)/i);
  const zc = text.match(/(Residential (Suburban Density Transition|Suburban|Medium Density|High Density)|(Medium|High) Density Residential)/i);
  const title = s => s.toLowerCase().replace(/\b\w/g, c => c.toUpperCase());
  const chcZone = zc ? (/high/i.test(zc[0]) ? "Residential High Density" : /medium/i.test(zc[0]) ? "Residential Medium Density" : /transition/i.test(zc[0]) ? "Residential Suburban Density Transition" : "Residential Suburban") : "";
  return { out, zone: z ? (/Terrace/i.test(z[1]) ? "Terrace Housing (THAB)" : title(z[1])) : chcZone };
}
function feasCalc(v) {
  const z = ZONES[v.zone] || ZONES["Mixed Housing Suburban"], type = z.type;
  const sv = v.services, ext = (sv.ww > 50 ? 80000 : sv.ww > 20 ? 40000 : 0) + (sv.sw > 20 ? 25000 : 0);
  const earth = FA.earthworks[v.slope] ?? FA.earthworks.Gentle, r = FA.interest / 100;
  const run = (n, keep) => {
    const gfa = (keep ? FA.gfa.standalone : v.gfa) * n, rate = keep ? FA.rate.standalone : v.rate;
    const build = gfa * rate, civil = FA.civilPer * n + ext, ew = keep ? earth * 0.5 : earth;
    const fees = build * (FA.profPct + FA.consentPct) / 100, cont = (build + civil + ew) * FA.contPct / 100;
    const contribs = (FA.dcPer + FA.igcPer) * (keep ? n : Math.max(0, n - 1)), subdiv = FA.subdivPer * (keep ? n : Math.max(0, n - 1));
    const months = keep ? FA.months.a : FA.months.b;
    const grv = n * v.endValue + (keep ? v.price * FA.retainedPct / 100 : 0), sell = grv * FA.sellPct / 100;
    const nonLand = build + civil + ew + fees + cont + contribs + subdiv + (keep ? 0 : FA.demolition) + sell + build * FA.drawnPct / 100 * r * months / 12;
    const landFactor = 1 + FA.acqPct / 100 + r * months / 12;
    const tdc = v.price * landFactor + nonLand, profit = grv - tdc, margin = 100 * profit / tdc;
    const rlv = (grv / (1 + v.margin / 100) - nonLand) / landFactor;
    return { n, gfa, build, civil: civil + ew, fees, contribs: contribs + subdiv, tdc, grv, profit, margin, rlv, months };
  };
  const a = run(1, true);
  const maxN = Math.max(1, Math.min(12, Math.floor(v.land / z.lpd)));
  const b = maxN >= 2 ? run(v.units && v.units >= 2 ? Math.min(v.units, 20) : maxN, false) : null;
  return { a, b, maxN, z };
}
function feasPage(id) {
  const p = S.byId.get(String(id));
  if (!p) { $("#app").innerHTML = `<div class="container"><div class="empty"><h2>Site not found</h2><a class="btn primary" href="#/search">Back to search</a></div></div>`; return; }
  const key = "aps-feas-" + p.id, saved = ls.get(key, {});
  const zs = zoneShort(p.zone), zGuess = ZONES[zs] ? zs : Object.keys(ZONES).find(z => zs.includes(z.split(" (")[0])) || (CITY === "chc" ? "Residential Suburban" : "Mixed Housing Suburban");
  const typeOf = z => (ZONES[z] || ZONES["Mixed Housing Suburban"]).type;
  const base = (p.cv || priceOf(p) || 900000);
  const v = Object.assign({
    price: priceOf(p) || p.cv || 0, land: Math.round(p.land_m2 || 0), zone: zGuess, slope: p.slope?.class || "Gentle", units: 0,
    gfa: FA.gfa[typeOf(zGuess)], rate: FA.rate[typeOf(zGuess)], endValue: Math.round(Math.max(750000, Math.min(1500000, base * 0.8)) / 10000) * 10000, margin: FA.margin
  }, saved.v || {});
  v.services = { ww: p.services?.wastewater?.on_site ? 0 : p.services?.wastewater?.distance_m ?? 0, sw: p.services?.stormwater?.on_site ? 0 : p.services?.stormwater?.distance_m ?? 0 };
  let lim = saved.lim || null; // {name, out, zone, chars}
  const num = (id, label, val, step = 1000) => `<label>${label}<input type="number" id="${id}" value="${val}" step="${step}" min="0" inputmode="numeric"></label>`;
  const row = (t, x) => `<div><dt>${t}</dt><dd class="num">${x}</dd></div>`;
  const scen = (title, s, note) => !s ? `<div><h3 style="font-size:16px">${title}</h3><p class="muted">Not possible at this land size and zone.</p></div>` : `<div><h3 style="font-size:16px;margin-bottom:6px">${title}</h3><p class="muted" style="margin:0 0 8px;font-size:13px">${note}</p>
    <dl class="dl">${row("Dwellings", s.n)}${row("Floor area", Math.round(s.gfa) + " m²")}${row("Build", money(s.build))}${row("Civil, services, earthworks", money(s.civil))}${row("Fees and consents", money(s.fees))}${row("Contributions and subdivision", money(s.contribs))}
    ${row("Total cost (incl. land, finance, selling)", money(s.tdc))}${row("End value (GRV)", money(s.grv))}${row("Profit", `<b style="color:${s.profit >= 0 ? "var(--good)" : "var(--bad)"}">${money(s.profit)}</b>`)}${row("Margin on cost", `<b>${s.margin.toFixed(1)}%</b>`)}${row(`Most you could pay for ${v.margin}% margin`, money(Math.max(0, s.rlv)))}</dl></div>`;
  const draw = () => {
    const c = feasCalc(v), best = [c.a, c.b].filter(Boolean).sort((x, y) => y.margin - x.margin)[0];
    const bad = (lim?.out || []).filter(f => f.sev === "bad").length;
    let verdict = best.margin >= v.margin ? "go" : best.margin >= 12 ? "caution" : "no";
    if (bad && verdict === "go") verdict = "caution";
    $("#fOut").innerHTML = `<section class="panel"><h2>Result <span class="verdict ${verdict}">${verdict === "go" ? "Go" : verdict === "caution" ? "Caution" : "No-go"}</span></h2>
      <p style="margin:0 0 14px">${verdict === "go" ? `Best option makes about <b>${best.margin.toFixed(0)}%</b> on cost at ${money(v.price)}.` : verdict === "caution" ? `Best option makes about <b>${best.margin.toFixed(0)}%</b> on cost${bad ? ", and the LIM has items to check first" : ""}. Possible if you can buy cheaper or the numbers firm up.` : `Best option makes about <b>${best.margin.toFixed(0)}%</b> on cost. At ${money(v.price)} the numbers don't stack up for development.`}
        ${c.b ? ` To get ${v.margin}% from the ${c.b.n}-dwelling option you could pay up to <b>${money(Math.max(0, c.b.rlv))}</b>.` : ""}</p>
      <div class="scen">${scen("A · Keep the house, add one", c.a, "Subdivide and build one new standalone home; the existing house is kept and valued at " + FA.retainedPct + "% of the price.")}
        ${scen(`B · Demolish and build ${c.b ? c.b.n : ""}`, c.b, `${esc(v.zone)}: ${esc(c.z.note)} About ${c.z.lpd} m² of land per dwelling → up to ${c.maxN} here.`)}</div></section>`;
    ls.set(key, { v, lim });
  };
  $("#app").innerHTML = `<div class="container" style="padding-bottom:56px">
    <div class="crumbs"><a href="#/site/${encodeURIComponent(p.id)}">← Back to ${esc(street(p))}</a></div>
    <h1 style="font-size:clamp(24px,3.4vw,32px)">Feasibility study</h1><p class="muted" style="margin:6px 0 20px">${esc(p.address)} · free, quick screening (not a QS or planner's report). Your LIM is read on this device and never uploaded.</p>
    <section class="panel"><h2>1 · The LIM report</h2>
      <label class="drop" id="drop"><input type="file" id="limFile" accept="application/pdf" multiple hidden>
        <span class="dropbtn">Choose the LIM PDF</span><span class="droptxt">or drag the file here. You can add the record of title too.</span>
        <small class="muted">Works with the PDF the council emails you. A LIM that was printed and scanned, or a photo of one, has no text to read, so it won't work.</small></label>
      <div id="limOut" style="margin-top:14px"></div></section>
    <section class="panel"><h2>2 · Your numbers</h2><p class="muted" style="margin:-6px 0 12px;font-size:13.5px">Pre-filled from the site. Change anything; it's remembered on this device. <b>End value</b> matters most: use recent sales of new homes in ${esc(p.suburb)}.</p>
      <div class="fin">${num("vPrice", "Purchase price ($)", v.price, 10000)}${num("vLand", "Land (m²)", v.land, 1)}
        <label>Zone<select id="vZone">${opts(Object.keys(ZONES).filter(z => (CITY === "chc") === z.startsWith("Residential ")).map(z => [z, z]), v.zone)}</select></label>
        <label>Slope<select id="vSlope">${opts(Object.keys(FA.earthworks).map(z => [z, z]), v.slope)}</select></label>
        ${num("vUnits", "Dwellings for option B (0 = auto)", v.units, 1)}${num("vEnd", "End value per new home ($)", v.endValue, 10000)}
        ${num("vGfa", "Floor area per home (m²)", v.gfa, 5)}${num("vRate", "Build cost ($/m², ex GST)", v.rate, 100)}${num("vMargin", "Target margin (%)", v.margin, 1)}</div>
      <p class="muted" style="font-size:12.5px;margin:12px 0 0">Also included: demolition ${money(FA.demolition)}, earthworks by slope, ${money(FA.civilPer)} civil per new home, services extension if pipes are far (wastewater ${dist(v.services.ww)}, stormwater ${dist(v.services.sw)}), ${CITY === "chc" ? "development contributions" : "development contributions + Watercare charges"} ${money(FA.dcPer + FA.igcPer)} per new home, ${FA.profPct}% fees, ${FA.contPct}% contingency, ${FA.interest}% interest, ${FA.sellPct}% selling costs.</p></section>
    <div id="fOut"></div>
    <p><button class="btn" type="button" onclick="window.print()">Print or save as PDF</button></p></div>`;
  const showLim = () => {
    if (!lim) { $("#limOut").innerHTML = ""; return; }
    const ord = { bad: 0, warn: 1, info: 2 };
    $("#limOut").innerHTML = `<p style="margin:0 0 10px"><b>${esc(lim.name)}</b> · ${lim.chars < 400 ? `<span class="chip bad">Can't read this file</span></p><p class="muted" style="margin:0 0 10px;font-size:13.5px">It has almost no text, which usually means it was scanned or photographed. Ask the council (or your lawyer) for the original emailed LIM PDF and try that. The numbers below still work without it.` : `${lim.out.length} topic${lim.out.length === 1 ? "" : "s"} mentioned${lim.zone ? ` · zone in LIM: <b>${esc(lim.zone)}</b>` : ""}`}</p>
      ${lim.out.length ? `<ul class="finds">${lim.out.sort((a, b) => ord[a.sev] - ord[b.sev]).map(f => `<li class="${f.sev === "info" ? "" : f.sev}"><b>${esc(f.label)}</b> <small class="muted">· mentioned ${f.n}×</small><q>${esc(f.snip)}</q></li>`).join("")}</ul>
      <p class="muted" style="font-size:12.5px;margin:10px 0 0">A mention isn't always a problem ("no flood hazard identified" also matches). Read each quote, and have your lawyer check the full LIM and title.</p>` : lim.chars >= 400 ? `<p class="authok">None of the usual red flags were mentioned.</p>` : ""}`;
  };
  const readFiles = async files => {
    const pdfs = [...files].filter(f => /pdf$/i.test(f.type) || /\.pdf$/i.test(f.name)); if (!pdfs.length) return;
    $("#limOut").innerHTML = `<p class="muted">Reading ${pdfs.length > 1 ? pdfs.length + " files" : esc(pdfs[0].name)}…</p>`;
    try {
      let text = ""; for (const f of pdfs) text += await pdfText(f) + "\n";
      const r = limFindings(text);
      lim = { name: pdfs.map(f => f.name).join(", "), out: r.out, zone: r.zone, chars: text.trim().length };
      if (r.zone && ZONES[r.zone] && r.zone !== v.zone) { v.zone = r.zone; $("#vZone").value = r.zone; v.gfa = FA.gfa[typeOf(r.zone)]; v.rate = FA.rate[typeOf(r.zone)]; $("#vGfa").value = v.gfa; $("#vRate").value = v.rate; }
      showLim(); draw();
    } catch (e) { $("#limOut").innerHTML = `<p class="autherr">${esc(e.message || "That PDF couldn't be read.")}</p>`; }
  };
  $("#limFile").addEventListener("change", e => readFiles(e.target.files));
  const drop = $("#drop");
  ["dragover", "dragenter"].forEach(t => drop.addEventListener(t, e => { e.preventDefault(); drop.classList.add("over"); }));
  ["dragleave", "drop"].forEach(t => drop.addEventListener(t, () => drop.classList.remove("over")));
  drop.addEventListener("drop", e => { e.preventDefault(); readFiles(e.dataTransfer.files); });
  const map = { vPrice: "price", vLand: "land", vUnits: "units", vEnd: "endValue", vGfa: "gfa", vRate: "rate", vMargin: "margin" };
  $(".fin").addEventListener("input", e => {
    const t = e.target;
    if (map[t.id]) v[map[t.id]] = +t.value || 0;
    if (t.id === "vSlope") v.slope = t.value;
    if (t.id === "vZone") { v.zone = t.value; v.gfa = FA.gfa[typeOf(v.zone)]; v.rate = FA.rate[typeOf(v.zone)]; $("#vGfa").value = v.gfa; $("#vRate").value = v.rate; }
    draw();
  });
  showLim(); draw();
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
  $("#citySel").hidden = !signedIn;
  if (ME) $("#navMe").textContent = ME.name || ME.username;
}
// setup = no accounts exist yet: the first person to sign up becomes the admin.
function loginPage(setup, mode = setup ? "setup" : "login") {
  ME = null; destroyMaps(); showNav(); closeMenu(); closeDrawer();
  const field = (id, label, type = "text", extra = "") => `<label class="f">${label}<input id="${id}" type="${type}" ${extra}></label>`;
  $("#app").innerHTML = `<div class="authwrap"><div class="authcard">
    <h1>${mode === "setup" ? "Set up your site" : mode === "register" ? "Create your account" : mode === "forgot" ? "Forgot your password?" : mode === "reset" ? "Choose a new password" : "Sign in"}</h1>
    <p class="muted">${mode === "setup" ? "No accounts exist yet. Create the admin account: you'll manage invites and users." : mode === "register" ? "You'll need the invite code you were given." : mode === "forgot" ? "Enter your username or email. If your account has an email address we'll send a reset link; otherwise the site admin is told and will help." : mode === "reset" ? "Pick a new password of 8 or more characters." : "PropertyHunte is private. Sign in to continue."}</p>
    ${mode === "forgot" ? `<form id="forgotForm" class="authform">${field("fWho", "Username or email", "text", 'maxlength="120" autocapitalize="none" spellcheck="false" required')}
      <p class="authok" id="fMsg" role="status" hidden></p><button class="btn primary" type="submit">Send reset link</button></form>
      <p class="authalt"><a href="#" data-mode="login">Back to sign in</a></p>` : mode === "reset" ? `<form id="resetForm" class="authform">${field("rPass", "New password", "password", 'minlength="8" autocomplete="new-password" required')}
      <p class="autherr" id="rErr" role="alert" hidden></p><button class="btn primary" type="submit">Save and sign in</button></form>` : `
    <form id="authForm" class="authform">
      ${mode !== "login" ? field("aName", "Your name", "text", 'maxlength="60" autocomplete="name"') : ""}
      ${field("aUser", "Username", "text", 'maxlength="30" autocomplete="username" autocapitalize="none" spellcheck="false" required')}
      ${field("aPass", "Password", "password", `minlength="${mode === "login" ? 1 : 8}" autocomplete="${mode === "login" ? "current-password" : "new-password"}" required`)}
      ${mode !== "login" ? field("aEmail", "Email (optional, for password resets)", "email", 'maxlength="120" autocomplete="email"') : ""}
      ${mode === "register" ? field("aCode", "Invite code", "text", 'maxlength="20" autocapitalize="characters" autocomplete="off" required') : ""}
      <p class="autherr" id="authErr" role="alert" hidden></p>
      <button class="btn primary" type="submit">${mode === "login" ? "Sign in" : "Create account"}</button>
    </form>
    ${mode === "login" ? `<p class="authalt"><a href="#" data-mode="forgot">Forgot password?</a></p><p class="authalt" style="margin-top:6px">Have an invite code? <a href="#" data-mode="register">Create an account</a></p>` : mode === "register" ? `<p class="authalt">Already have an account? <a href="#" data-mode="login">Sign in</a></p>` : ""}`}
  </div></div>`;
  $$("[data-mode]").forEach(a => a.addEventListener("click", e => { e.preventDefault(); loginPage(false, a.dataset.mode); }));
  $("#forgotForm")?.addEventListener("submit", async e => {
    e.preventDefault(); const m = $("#fMsg"), b = $("#forgotForm button"); b.disabled = true;
    try { await api("auth.php", { op: "forgot", who: $("#fWho").value }); m.className = "authok"; m.textContent = "Done. If that account has an email address, a reset link is on its way (check spam). If not, the admin has been told and will send you a temporary password."; }
    catch (ex) { m.className = "autherr"; m.textContent = ex.message; b.disabled = false; }
    m.hidden = false;
  });
  $("#resetForm")?.addEventListener("submit", async e => {
    e.preventDefault(); const err = $("#rErr");
    try { ME = (await api("auth.php", { op: "reset", token: new URLSearchParams(location.hash.split("?")[1] || "").get("t") || "", password: $("#rPass").value })).user; history.replaceState(null, "", "#/"); await start(); }
    catch (ex) { err.textContent = ex.message; err.hidden = false; }
  });
  if (!$("#authForm")) return;
  $("#authForm").addEventListener("submit", async e => {
    e.preventDefault();
    const btn = $("#authForm button"), err = $("#authErr"); btn.disabled = true; err.hidden = true;
    try {
      const body = { op: mode, username: $("#aUser").value, password: $("#aPass").value };
      if (mode !== "login") { body.name = $("#aName").value; body.email = $("#aEmail").value; }
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
    <section class="panel" style="margin-top:18px"><h2>${esc(ME.name)}</h2>${dl([["Username", esc(ME.username)], ["Role", ME.admin ? "Admin" : "Member"]])}
      <form id="eForm" class="authform" style="margin-top:14px"><label class="f">Email, for password resets<input id="eMail" type="email" maxlength="120" autocomplete="email" value="${esc(ME.email || "")}"></label>
        <p class="authok" id="eMsg" role="status" hidden></p><button class="btn" type="submit">Save email</button></form></section>
    <section class="panel"><h2>My budget</h2><p class="muted" style="margin:-6px 0 12px;font-size:13.5px">Only you see this. Each property then shows whether it fits your budget, and you can filter to sites within it.</p>
      <form id="bForm" class="authform"><div class="row2" style="display:grid;grid-template-columns:1fr 1fr;gap:10px">
        <label class="f">Ideal price, up to<input id="bIdeal" type="number" min="0" step="10000" inputmode="numeric" placeholder="e.g. 900000" value="${S.budget.ideal || ""}"></label>
        <label class="f">Maximum price<input id="bMax" type="number" min="0" step="10000" inputmode="numeric" placeholder="e.g. 1100000" value="${S.budget.max || ""}"></label></div>
        <p class="authok" id="bMsg" role="status" hidden></p><button class="btn primary" type="submit">Save budget</button></form></section>
    <section class="panel"><h2>Change password</h2><form id="pwForm" class="authform">
      <label class="f">Current password<input id="pOld" type="password" autocomplete="current-password" required></label>
      <label class="f">New password (8+ characters)<input id="pNew" type="password" minlength="8" autocomplete="new-password" required></label>
      <p class="autherr" id="pMsg" role="status" hidden></p><button class="btn primary" type="submit">Change password</button></form></section>
    <button class="btn" type="button" id="signOut">Sign out</button></div>`;
  $("#eForm").addEventListener("submit", async e => {
    e.preventDefault(); const m = $("#eMsg");
    try { ME = (await api("auth.php", { op: "email", email: $("#eMail").value })).user; m.textContent = "Email saved."; m.className = "authok"; }
    catch (ex) { m.textContent = ex.message; m.className = "autherr"; }
    m.hidden = false;
  });
  $("#bForm").addEventListener("submit", async e => {
    e.preventDefault(); const m = $("#bMsg");
    try { await postStore({ op: "set", col: "prefs", id: "budget", data: { ideal: +$("#bIdeal").value || 0, max: +$("#bMax").value || 0 } }); m.textContent = "Budget saved."; m.className = "authok"; }
    catch (ex) { m.textContent = ex.message; m.className = "autherr"; }
    m.hidden = false;
  });
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
      ${d.users.map(u => `<tr><td>${esc(u.name)} ${u.admin ? `<span class="chip accent">Admin</span>` : ""}${u.asked ? ` <span class="chip bad" title="Asked ${esc(when(u.asked))}">Forgot password</span>` : ""}</td><td>${esc(u.username)}${u.email ? `<br><small class="muted">${esc(u.email)}</small>` : ""}</td><td>${when(u.created)}</td><td>${when(u.last)}</td>
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
  closeMenu(); closeDrawer(); destroyMaps(); sMap = null; sMarkers.clear(); selPoly = null;
  const [path, qs] = (location.hash.slice(1) || "/").split("?");
  const parts = path.split("/").filter(Boolean), page = parts[0] || "home";
  $$("[data-nav]").forEach(a => a.dataset.nav === page ? a.setAttribute("aria-current", "page") : a.removeAttribute("aria-current"));
  document.querySelector("footer.site").hidden = page === "search";
  if (!ME || !S.data) return;
  if (page === "search") search(new URLSearchParams(qs || ""));
  else if (page === "site") withFull(decodeURIComponent(parts[1] || ""), sitePage);
  else if (page === "feas") withFull(decodeURIComponent(parts[1] || ""), feasPage);
  else if (page === "saved") savedPage();
  else if (page === "account") accountPage();
  else if (page === "admin") adminPage();
  else home();
  if (page !== "search") window.scrollTo(0, 0);
  const tp = S.byId.get(decodeURIComponent(parts[1] || ""));
  document.title = (page === "site" || page === "feas") && tp ? (page === "feas" ? "Feasibility · " : "") + street(tp) + " · PropertyHunte" : "PropertyHunte";
}
window.addEventListener("hashchange", route);
window.addEventListener("focus", () => { if (!menuFor && S.api && ME) loadStore(); });

// Sign-in first; the site data is only served to signed-in users (api/data.php).
async function start() {
  showNav();
  $("#app").innerHTML = `<div class="loading">Loading sites…</div>`;
  try {
    $("#citySel").value = CITY;
    const [d, subs, zones] = await Promise.all([
      api("data.php" + (CITY === "akl" ? "" : "?city=" + CITY)),
      fetch(C().subs).then(r => r.ok ? r.json() : {}).catch(() => ({})),
      fetch("zone-codes.json").then(r => r.ok ? r.json() : {}).catch(() => ({}))
    ]);
    // One card per property: the same listing (or the same address listed twice) keeps its best-scoring copy.
    const seen = new Set();
    S.sites = (d.shortlist || []).filter(p => p && p.id).sort((a, b) => (b.score || 0) - (a.score || 0)).filter(p => {
      const keys = ["id:" + p.id, "addr:" + String(p.address || "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim() + "|" + Math.round(p.land_m2 || 0)];
      if (keys.some(key => seen.has(key))) return false;
      keys.forEach(key => seen.add(key)); return true;
    });
    // byId keeps every listing, so a saved or linked duplicate still opens its page.
    (d.shortlist || []).forEach(p => { if (p) p.label = rate(p.score); });
    S.data = d; S.byId = new Map((d.shortlist || []).filter(p => p && p.id).map(p => [String(p.id), p]));
    S.subs = subs || {}; S.zones = zones || {}; S.subDistrict.clear();
    Object.entries(S.subs).forEach(([dname, list]) => list.forEach(s => S.subDistrict.set(norm(s), dname)));
    route(); loadStore();
  } catch (e) { if (ME) $("#app").innerHTML = `<div class="loading">${esc(e.message)}${CITY !== "akl" ? `<p><button class="btn" type="button" onclick="setCity('akl')">Switch to Auckland</button></p>` : ". Try reloading the page."}</div>`; }
}
function setCity(c) {
  if (!CITIES[c] || c === CITY) return;
  CITY = c; ls.set("aps-city", c); PARTS.clear(); F = Object.assign({}, DEF, ls.get("aps-f-" + c, {})); Q = "";
  S.data = null; S.sites = []; S.byId = new Map(); location.hash = "#/"; start();
}
$("#citySel").addEventListener("change", e => setCity(e.target.value));
async function boot() {
  // A reset link from the forgot-password email opens the new-password form, signed in or not.
  if (location.hash.startsWith("#/reset")) return loginPage(false, "reset");
  try { const a = await api("auth.php"); ME = a.user; ME ? start() : loginPage(a.setup); }
  catch (e) { $("#app").innerHTML = `<div class="loading">The site couldn't reach its server. Try reloading the page.</div>`; }
}
boot();
