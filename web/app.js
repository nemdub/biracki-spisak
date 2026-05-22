"use strict";

const DATA_BASE = "../data";
const CSV_DIR = DATA_BASE + "/processed/biraci_po_adresi";

const COLUMNS = [
  { key: "Mesto", label: "Место", type: "text" },
  { key: "Ulica", label: "Улица", type: "text" },
  { key: "KucniBroj", label: "Број", type: "house" },
  { key: "Sprat", label: "Спрат", type: "text" },
  { key: "Stan", label: "Стан", type: "text" },
  { key: "BiracaPrebivaliste", label: "Пребивалиште", type: "num" },
  { key: "BiracaBoraviste", label: "Боравиште", type: "num" },
];

const collator = new Intl.Collator("sr", { numeric: true, sensitivity: "base" });

// Fold Serbian Cyrillic + Latin (with diacritics) to a common ASCII base
// so Latin and Cyrillic queries match the Cyrillic data interchangeably.
const TRANSLIT = {
  "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "ђ": "dj", "е": "e",
  "ж": "z", "з": "z", "и": "i", "ј": "j", "к": "k", "л": "l", "љ": "lj",
  "м": "m", "н": "n", "њ": "nj", "о": "o", "п": "p", "р": "r", "с": "s",
  "т": "t", "ћ": "c", "у": "u", "ф": "f", "х": "h", "ц": "c", "ч": "c",
  "џ": "dz", "ш": "s",
  "č": "c", "ć": "c", "š": "s", "ž": "z", "đ": "dj",
};

function normalizeText(s) {
  s = String(s).toLowerCase();
  let out = "";
  for (const ch of s) out += TRANSLIT[ch] !== undefined ? TRANSLIT[ch] : ch;
  return out.normalize("NFD").replace(/[̀-ͯ]/g, "");
}

const state = {
  localities: [],          // [{id, name}]
  processed: new Map(),     // id -> {rows}
  selectedId: null,
  allRows: [],              // parsed rows for selected locality
  viewRows: [],             // filtered + sorted
  sort: { key: null, dir: 1 },
  rowHeight: 29,
};

// ---------- CSV parsing (quote-aware, UTF-8) ----------
function parseCSV(text) {
  const rows = [];
  let field = "";
  let record = [];
  let inQuotes = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQuotes) {
      if (c === '"') {
        if (text[i + 1] === '"') { field += '"'; i++; }
        else inQuotes = false;
      } else field += c;
    } else {
      if (c === '"') inQuotes = true;
      else if (c === ",") { record.push(field); field = ""; }
      else if (c === "\n") { record.push(field); rows.push(record); field = ""; record = []; }
      else if (c === "\r") { /* skip */ }
      else field += c;
    }
  }
  if (field.length > 0 || record.length > 0) { record.push(field); rows.push(record); }
  if (!rows.length) return { header: [], data: [] };
  const header = rows[0];
  const data = [];
  for (let i = 1; i < rows.length; i++) {
    const r = rows[i];
    if (r.length === 1 && r[0] === "") continue;
    const obj = {};
    for (let j = 0; j < header.length; j++) obj[header[j]] = r[j] !== undefined ? r[j] : "";
    data.push(obj);
  }
  return { header, data };
}

// ---------- Init ----------
async function init() {
  try {
    const [locs, proc] = await Promise.all([
      fetch(DATA_BASE + "/localities.json").then(r => r.json()),
      fetch("processed_localities.json").then(r => r.json()),
    ]);
    state.localities = locs.slice().sort((a, b) => collator.compare(a.name, b.name));
    for (const p of proc) state.processed.set(p.id, p);
    updateCoverage();
    renderLocalityList();
  } catch (e) {
    document.getElementById("coverage").textContent = "Грешка при учитавању: " + e.message;
  }
}

function updateCoverage() {
  document.getElementById("coverage").textContent =
    `Обрађено: ${state.processed.size} / ${state.localities.length} локалитета`;
}

// ---------- Locality picker ----------
function renderLocalityList() {
  const q = normalizeText(document.getElementById("localitySearch").value.trim());
  const onlyProc = document.getElementById("onlyProcessed").checked;
  const ul = document.getElementById("localityList");
  ul.innerHTML = "";
  const frag = document.createDocumentFragment();

  for (const loc of state.localities) {
    const isProc = state.processed.has(loc.id);
    if (onlyProc && !isProc) continue;
    if (q && !normalizeText(loc.name).includes(q)) continue;

    const li = document.createElement("li");
    li.textContent = loc.name;
    if (!isProc) li.classList.add("disabled");
    if (loc.id === state.selectedId) li.classList.add("active");

    const count = document.createElement("span");
    count.className = "count";
    count.textContent = isProc ? state.processed.get(loc.id).rows.toLocaleString("sr") : "—";
    li.appendChild(count);

    if (isProc) li.addEventListener("click", () => selectLocality(loc));
    frag.appendChild(li);
  }
  ul.appendChild(frag);
}

// ---------- Load a locality ----------
async function selectLocality(loc) {
  if (loc.id === state.selectedId) return;
  state.selectedId = loc.id;
  state.sort = { key: null, dir: 1 };
  renderLocalityList();

  document.getElementById("placeholder").hidden = true;
  document.getElementById("tableView").hidden = true;
  document.getElementById("loading").hidden = false;

  try {
    const text = await fetch(`${CSV_DIR}/biraci_po_adresi_${loc.id}.csv`).then(r => {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.text();
    });
    const { data } = parseCSV(text);
    for (const r of data) { r._nm = normalizeText(r.Mesto); r._nu = normalizeText(r.Ulica); }
    state.allRows = data;
    document.getElementById("filterMesto").value = "";
    document.getElementById("filterUlica").value = "";
    setupTable(loc);
    applyFilterSort();
  } catch (e) {
    document.getElementById("loading").textContent = "Грешка: " + e.message;
    return;
  }
  document.getElementById("loading").hidden = true;
  document.getElementById("tableView").hidden = false;
}

function setupTable(loc) {
  document.getElementById("localityTitle").textContent = loc.name;
  const opstina = state.allRows.length ? state.allRows[0].Opstina : "";
  let maxTs = 0;
  for (const r of state.allRows) { const t = +r.Timestamp; if (t > maxTs) maxTs = t; }
  const dateStr = maxTs ? new Date(maxTs * 1000).toLocaleDateString("sr") : "—";
  document.getElementById("localityMeta").textContent =
    `Општина: ${opstina} · ID: ${loc.id} · Адреса: ${state.allRows.length.toLocaleString("sr")} · Ажурирано: ${dateStr}`;

  const headRow = document.getElementById("headRow");
  headRow.innerHTML = "";
  for (const col of COLUMNS) {
    const th = document.createElement("th");
    th.textContent = col.label;
    if (col.type === "num" || col.type === "house") th.classList.add("num");
    th.addEventListener("click", () => onSort(col.key));
    th.dataset.key = col.key;
    headRow.appendChild(th);
  }
}

// ---------- Filter + sort ----------
function houseNum(v) { const m = String(v).match(/^\d+/); return m ? +m[0] : Infinity; }

function applyFilterSort() {
  const mq = normalizeText(document.getElementById("filterMesto").value.trim());
  const uq = normalizeText(document.getElementById("filterUlica").value.trim());

  let rows = state.allRows;
  if (mq || uq) {
    rows = rows.filter(r =>
      (!mq || r._nm.includes(mq)) &&
      (!uq || r._nu.includes(uq)));
  }

  const { key, dir } = state.sort;
  if (key) {
    const col = COLUMNS.find(c => c.key === key);
    const sorted = rows.slice();
    sorted.sort((a, b) => {
      let cmp;
      if (col.type === "num") cmp = (+a[key] || 0) - (+b[key] || 0);
      else if (col.type === "house") {
        cmp = houseNum(a[key]) - houseNum(b[key]);
        if (cmp === 0) cmp = collator.compare(a[key], b[key]);
      } else cmp = collator.compare(a[key], b[key]);
      return cmp * dir;
    });
    rows = sorted;
  }

  state.viewRows = rows;
  updateSortIndicators();
  renderSummary();
  renderWindow();
}

function onSort(key) {
  if (state.sort.key === key) state.sort.dir *= -1;
  else state.sort = { key, dir: 1 };
  applyFilterSort();
}

function updateSortIndicators() {
  for (const th of document.querySelectorAll("#headRow th")) {
    const base = COLUMNS.find(c => c.key === th.dataset.key).label;
    if (th.dataset.key === state.sort.key) {
      th.innerHTML = base + ' <span class="arrow">' + (state.sort.dir === 1 ? "▲" : "▼") + "</span>";
    } else th.textContent = base;
  }
}

function renderSummary() {
  let preb = 0, borav = 0;
  for (const r of state.viewRows) { preb += +r.BiracaPrebivaliste || 0; borav += +r.BiracaBoraviste || 0; }
  document.getElementById("rowSummary").textContent =
    `${state.viewRows.length.toLocaleString("sr")} адреса · Σ пребивалиште ${preb.toLocaleString("sr")} · Σ боравиште ${borav.toLocaleString("sr")}`;
}

// ---------- Virtualized rendering ----------
function renderWindow() {
  const scroller = document.getElementById("scroller");
  const tbody = document.getElementById("dataBody");
  const total = state.viewRows.length;
  const rh = state.rowHeight;
  const viewH = scroller.clientHeight || 600;
  const buffer = 10;
  const start = Math.max(0, Math.floor(scroller.scrollTop / rh) - buffer);
  const visible = Math.ceil(viewH / rh) + buffer * 2;
  const end = Math.min(total, start + visible);

  const padTop = start * rh;
  const padBottom = Math.max(0, (total - end) * rh);

  let html = "";
  if (padTop) html += `<tr style="height:${padTop}px"><td colspan="${COLUMNS.length}"></td></tr>`;
  for (let i = start; i < end; i++) {
    const r = state.viewRows[i];
    html += "<tr>";
    for (const col of COLUMNS) {
      const cls = (col.type === "num" || col.type === "house") ? ' class="num"' : "";
      html += `<td${cls}>${escapeHtml(r[col.key])}</td>`;
    }
    html += "</tr>";
  }
  if (padBottom) html += `<tr style="height:${padBottom}px"><td colspan="${COLUMNS.length}"></td></tr>`;
  tbody.innerHTML = html;

  // Calibrate row height once from a real rendered row.
  if (!state._calibrated && end > start) {
    const sampleRow = tbody.querySelector("tr:not([style])");
    if (sampleRow && sampleRow.offsetHeight) {
      const h = sampleRow.offsetHeight;
      state._calibrated = true;
      if (Math.abs(h - rh) > 1) { state.rowHeight = h; renderWindow(); }
    }
  }
}

function escapeHtml(s) {
  if (s == null) return "";
  return String(s).replace(/[&<>]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
}

// ---------- Events ----------
document.getElementById("localitySearch").addEventListener("input", renderLocalityList);
document.getElementById("onlyProcessed").addEventListener("change", renderLocalityList);
document.getElementById("filterMesto").addEventListener("input", applyFilterSort);
document.getElementById("filterUlica").addEventListener("input", applyFilterSort);
document.getElementById("scroller").addEventListener("scroll", renderWindow);

init();
