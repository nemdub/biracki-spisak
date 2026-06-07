"use strict";

const ASSET_V = "20260607d"; // подигни верзију кад се подаци/код промене (руши кеш)

const COLORS = {
  "nestambeno": "#dc2626",
  "stambeno-moguce": "#d97706",
  "nepoznato": "#6b7280",
};
const KAT_LABEL = {
  "nestambeno": "нестамбено",
  "stambeno-moguce": "стамбено-могуће",
  "nepoznato": "непознато",
};

const nf = new Intl.NumberFormat("sr-RS");
const esc = (s) => String(s == null ? "" : s)
  .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

let DATA = null;
let cluster = null;
let PROCESSED = new Set(); // ид-ови локалитета доступних у прегледу (index.html)

Promise.all([
  fetch("javni_objekti_report.json?v=" + ASSET_V).then((r) => r.json()),
  fetch("processed_localities.json?v=" + ASSET_V).then((r) => (r.ok ? r.json() : [])).catch(() => []),
])
  .then(([d, proc]) => {
    DATA = d;
    PROCESSED = new Set((proc || []).map((p) => p.id));
    render();
  })
  .catch((e) => {
    document.getElementById("lead").textContent = "Грешка при учитавању података: " + e;
  });

// Линк ка прегледу бирача (index.html) за тачну адресу — само ако је локалитет обрађен.
// compact=true: кратко дугме (иконица) за табелу; иначе пуно дугме за искачући прозор.
function viewerLink(m, compact) {
  if (m.loc == null) return "";
  if (!PROCESSED.has(m.loc)) {
    return compact
      ? `<span class="popup-note" title="Локалитет није у прегледу бирача">—</span>`
      : `<span class="popup-note">Локалитет није у прегледу бирача</span>`;
  }
  const q = `loc=${m.loc}&mesto=${encodeURIComponent(m.vmesto || "")}` +
    `&ulica=${encodeURIComponent(m.vulica || "")}&broj=${encodeURIComponent(m.vbroj || "")}`;
  const cls = compact ? "popup-btn compact" : "popup-btn";
  const label = compact ? "🔍 Нађи" : "🔍 Нађи адресу у прегледу";
  const title = compact ? ' title="Нађи адресу у прегледу бирача"' : "";
  return `<a class="${cls}" href="index.html?${q}" target="_blank" rel="noopener"${title}>${label}</a>`;
}

function render() {
  const s = DATA.summary;
  document.getElementById("hcR").textContent = s.high_conf_radius;

  document.getElementById("lead").innerHTML =
    `Овај извештај укршта <strong>адресни регистар</strong> (kucni_broj.csv), ` +
    `<strong>јавне објекте</strong> (objekti.csv) и <strong>бираче по адреси</strong>. ` +
    `Сваки јавни објекат је просторно спојен са најближом адресом на којој постоје уписани бирачи ` +
    `(у радијусу до ${s.max_radius} m). Рачунају се само бирачи уписани на <strong>голу адресу зграде</strong> ` +
    `(без броја стана), пошто objekti.csv не садржи број стана — станари са бројем стана се не рачунају. ` +
    `Приказано је <strong>${nf.format(s.poklapanja)}</strong> ` +
    `поклапања из ${nf.format(s.lokaliteta_sa_biracima)} обрађена локалитета.`;

  renderCards(s);
  renderTop(DATA.matches);
  renderBreakdown("tipBody", s.po_tipu, "naziv");
  renderBreakdown("opBody", s.po_opstini, "naziv");
  renderCaveats(s);
  initMap();
}

function renderCards(s) {
  const k = s.po_kategoriji || {};
  const nes = k["nestambeno"] || { objekata: 0, biraca: 0 };
  const sta = k["stambeno-moguce"] || { objekata: 0, biraca: 0 };
  const cards = [
    { cls: "blue", num: nf.format(s.poklapanja), lbl: "јавних објеката са уписаним бирачима" },
    { cls: "blue", num: nf.format(s.biraca_ukupno), lbl: "бирача укупно на тим адресама" },
    { cls: "red", num: nf.format(nes.objekata), lbl: `нестамбених објеката (${nf.format(nes.biraca)} бирача)` },
    { cls: "amber", num: nf.format(sta.objekata), lbl: `стамбено-могућих (домови, манастири…) — ${nf.format(sta.biraca)} бирача` },
    { cls: "", num: nf.format(s.visoka_pouzdanost), lbl: `поклапања високе поузданости (≤${s.high_conf_radius} m)` },
    { cls: "", num: (s.geokodirano_rate != null ? s.geokodirano_rate + "%" : "—"), lbl: `адреса бирача геокодирано (${nf.format(s.geokodirano || 0)} од ${nf.format(s.adresa_sa_biracima || 0)})` },
  ];
  document.getElementById("cards").innerHTML = cards.map((c) =>
    `<div class="card ${c.cls}"><div class="num">${c.num}</div><div class="lbl">${c.lbl}</div></div>`
  ).join("");
}

function adresa(m) {
  const street = [m.ulica, m.broj].filter(Boolean).join(" ");
  return [street, m.mesto, m.opstina].filter(Boolean).join(", ");
}

function renderTop(matches) {
  const rows = matches.slice(0, 200).map((m) =>
    `<tr>
       <td>${esc(m.naziv)}</td>
       <td><span class="tag ${m.kategorija}">${esc(m.tip || "—")}</span></td>
       <td>${esc(adresa(m))}</td>
       <td class="num">${m.rastojanje_m}</td>
       <td class="num"><b>${nf.format(m.ukupno)}</b></td>
       <td>${viewerLink(m, true)}</td>
     </tr>`
  ).join("");
  document.getElementById("topBody").innerHTML = rows;
}

function renderBreakdown(id, list, key) {
  document.getElementById(id).innerHTML = list.map((r) =>
    `<tr><td>${esc(r[key] || "—")}</td><td class="num">${nf.format(r.objekata)}</td><td class="num">${nf.format(r.biraca)}</td></tr>`
  ).join("");
}

function renderCaveats(s) {
  const items = [
    `<strong>Само гола адреса зграде — станари се не рачунају.</strong> Бирачки списак некада уз број зграде носи и број стана; objekti.csv нема број стана. Бирачи са бројем стана су станари и <em>не</em> улазе у поклапање — рачунају се само бирачи уписани на голу адресу (без стана). Тако вртић у згради са становима не постаје поклапање због станара.${s.preskoceno_stan != null ? ` Изостављено ${nf.format(s.preskoceno_stan)} редова са бројем стана.` : ""}`,
    `<strong>Просторно поклапање, не идентитет.</strong> Поклапање значи да се адреса са уписаним бирачима налази у радијусу до ${s.max_radius} m од објекта — растојање је дато по реду. ${nf.format(s.visoka_pouzdanost)} поклапања је на ≤${s.high_conf_radius} m (готово сигурно иста парцела/адреса).`,
    `<strong>Категорија „стамбено-могуће”.</strong> Домови за старе, манастири, ученички/студентски домови и сл. су издвојени јер у њима људи легитимно бораве и гласају — нису знак неправилности.`,
    `<strong>objekti.csv није исцрпан.</strong> Садржи само део јавних објеката; одсуство објекта не значи да га нема.`,
    `<strong>Делимична покривеност бирача — прикупљање у току.</strong> Обрађено је ${nf.format(s.lokaliteta_sa_biracima)} локалитета са ${nf.format(s.adresa_sa_biracima || 0)} адреса (без станова).${s.ocekivano_adresa ? ` Када се заврши прикупљање бирачких података (засебан процес), очекује се укупно <strong>${nf.format(s.ocekivano_adresa)}</strong> адреса — тренутно је покривено ~${Math.round(100 * (s.adresa_sa_biracima || 0) / s.ocekivano_adresa)}%.` : ""} Објекти у још необрађеним општинама не могу бити спојени, па ће број поклапања растити како прикупљање одмиче.`,
    `<strong>Геокодирање по адреси.</strong> Адресе бирача се спајају са регистром преко нормализованог кључа (општина/место/улица/број уз уједначавање облика — нпр. „БЕОГРАД-ЗЕМУН”↔„zemun”, „9-Б”↔„9Б”, „ПАЛИЛУЛА (БЕОГРАД)”↔„palilula”). Тренутно се споји ${s.geokodirano_rate != null ? `<strong>${s.geokodirano_rate}%</strong>` : "већина"} адреса са бирачима; остатак су углавном стварне празнине у регистру (нпр. Косово, села без назива улице), па је стварни број поклапања нешто већи од приказаног.`,
  ];
  document.getElementById("caveats").innerHTML = items.map((t) => `<li>${t}</li>`).join("");
}

function initMap() {
  const map = L.map("map").setView([44.0, 20.9], 7); // центар Србије
  L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
    maxZoom: 19,
    attribution: "© OpenStreetMap",
  }).addTo(map);
  cluster = L.markerClusterGroup({ chunkedLoading: true, maxClusterRadius: 50 });
  map.addLayer(cluster);
  populate();

  document.getElementById("fltNestambeno").addEventListener("change", populate);
  document.getElementById("fltHighConf").addEventListener("change", populate);
}

function populate() {
  const onlyNes = document.getElementById("fltNestambeno").checked;
  const onlyHC = document.getElementById("fltHighConf").checked;
  const hcR = DATA.summary.high_conf_radius;
  cluster.clearLayers();
  const markers = [];
  for (const m of DATA.matches) {
    if (onlyNes && m.kategorija !== "nestambeno") continue;
    if (onlyHC && m.rastojanje_m > hcR) continue;
    const color = COLORS[m.kategorija] || COLORS.nepoznato;
    const radius = Math.min(14, 4 + Math.sqrt(m.ukupno));
    const mk = L.circleMarker([m.lat, m.lon], {
      radius, color: "#fff", weight: 1, fillColor: color, fillOpacity: 0.85,
    });
    mk.bindPopup(
      `<b>${esc(m.naziv)}</b><br>` +
      `<span class="tag ${m.kategorija}" style="background:${color}">${esc(m.tip || "—")}</span> ` +
      `· ${KAT_LABEL[m.kategorija] || ""}<br>` +
      `${esc(adresa(m))}<br>` +
      `Растојање: ${m.rastojanje_m} m<br>` +
      `Бирача: <b>${nf.format(m.ukupno)}</b> ` +
      `(преб. ${nf.format(m.preb)}, борав. ${nf.format(m.borav)})` +
      viewerLink(m)
    );
    markers.push(mk);
  }
  cluster.addLayers(markers);
}
