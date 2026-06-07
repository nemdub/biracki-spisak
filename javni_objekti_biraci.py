#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Spaja јавне објекте (data/objekti.csv) са адресама на којима су уписани бирачи.

Цев (pipeline):
  1. Изгради индекс бирача по нормализованој адреси из свих
     biraci_po_adresi_*.csv фајлова (унија processed + output, без дупликата).
  2. Прочитај data/kucni_broj.csv (адресни регистар са координатама у UTM 34N)
     и геокодирај адресе на којима ИМА бирача.
  3. За сваки јавни објекат нађи најближу такву адресу (просторни grid индекс).
  4. Класификуј тип објекта (стамбено-могуће / нестамбено / непознато),
     претвори UTM -> WGS84 и испиши резултате.

Излаз:
  web/objekti_sa_biracima.csv   — табела свих поклапања
  web/objekti_report.json       — подаци + сажетак за веб-извештај
"""

import csv
import glob
import json
import math
import os
import re
import sys
import unicodedata
from collections import defaultdict

from pyproj import Transformer

# csv поља у kucni_broj.csv знају бити подужа (WKT, спискови) — подигни лимит.
csv.field_size_limit(10 * 1024 * 1024)

ROOT = os.path.dirname(os.path.abspath(__file__))
KUCNI_BROJ = os.path.join(ROOT, "data", "kucni_broj.csv")
OBJEKTI = os.path.join(ROOT, "data", "objekti.csv")
PROCESSED_GLOB = os.path.join(ROOT, "data", "processed", "biraci_po_adresi", "biraci_po_adresi_*.csv")
OUTPUT_GLOB = os.path.join(ROOT, "output", "biraci_po_adresi_*.csv")

OUT_CSV = os.path.join(ROOT, "web", "javni_objekti_sa_biracima.csv")
OUT_JSON = os.path.join(ROOT, "web", "javni_objekti_report.json")

# Просторно поклапање: задржи поклапања до MAX_RADIUS m; band ≤ HIGH_CONF = висока поузданост.
MAX_RADIUS = 50.0
HIGH_CONF = 15.0
CELL = MAX_RADIUS  # величина ћелије = радијус → довољан је 3x3 блок око упита

# --- Нормализација (исти TRANSLIT као web/app.js) ---------------------------
TRANSLIT = {
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "ђ": "dj", "е": "e",
    "ж": "z", "з": "z", "и": "i", "ј": "j", "к": "k", "л": "l", "љ": "lj",
    "м": "m", "н": "n", "њ": "nj", "о": "o", "п": "p", "р": "r", "с": "s",
    "т": "t", "ћ": "c", "у": "u", "ф": "f", "х": "h", "ц": "c", "ч": "c",
    "џ": "dz", "ш": "s",
    "č": "c", "ć": "c", "š": "s", "ž": "z", "đ": "dj",
}
_ws = re.compile(r"\s+")


def norm(s):
    if s is None:
        return ""
    s = str(s).lower()
    s = "".join(TRANSLIT.get(ch, ch) for ch in s)
    s = unicodedata.normalize("NFD", s)
    s = "".join(ch for ch in s if unicodedata.category(ch) != "Mn")
    return _ws.sub(" ", s).strip()


_paren = re.compile(r"\s*\(.*?\)\s*")


def norm_opstina(o):
    """Уједначи називе општина: 'БЕОГРАД-ЗЕМУН'->'zemun', 'СУБОТИЦА - ГРАД'->'subotica',
    'ВРАЊЕ-ВРАЊСКА БАЊА'->'vranje', 'ПАЛИЛУЛА (БЕОГРАД)'->'palilula'. kucni_broj
    некад носи град у загради, бирачки списак као префикс — оба своди на чист назив."""
    o = norm(_paren.sub(" ", str(o or ""))).replace(" - ", "-").replace(" -", "-").replace("- ", "-")
    if not o:
        return o
    parts = o.split("-")
    if len(parts) > 1 and parts[-1] == "grad":  # 'subotica-grad' -> 'subotica'
        parts = parts[:-1]
    if len(parts) > 1 and parts[0] == "beograd":  # 'beograd-zemun' -> 'zemun'
        parts = parts[1:]
    elif len(parts) > 1:  # 'vranje-vranjska banja' -> 'vranje'
        parts = parts[:1]
    return "-".join(parts).strip()


def norm_naselje(m):
    """'beograd (zemun)' -> 'beograd' (kucni_broj градско језгро носи општину у загради)."""
    return norm(_paren.sub(" ", str(m or "")))


_brsep = re.compile(r"[-.\s]+")


def norm_broj(b):
    """Кућни број: бирачки списак пише '9-Б', регистар '9Б'. Избаци раздвајаче
    (цртица/тачка/размак) па се '9-b' и '9b' поклапају. Регистар не користи
    раздвајаче, па нема ризика од лажног спајања."""
    return _brsep.sub("", norm(b))


def addr_key(opstina, mesto, ulica, broj):
    return (norm_opstina(opstina), norm_naselje(mesto), norm(ulica), norm_broj(broj))


_point = re.compile(r"POINT\s*\(\s*([-\d.eE]+)\s+([-\d.eE]+)\s*\)")


def parse_point(wkt):
    m = _point.search(wkt or "")
    if not m:
        return None
    return float(m.group(1)), float(m.group(2))


# --- Класификација типа објекта --------------------------------------------
# Стамбено-могуће: места где људи стварно бораве и легитимно гласају.
RESIDENTIAL_SUBSTR = [
    "дом за стар", "стара лица", "социјалне заштите", "социјалну заштиту",
    "манастир", "студентски дом", "ученички дом", "дом ученика", "дом за децу",
    "интернат", "казнено", "затвор", "прихватилиш",
]


def classify(tip):
    t = (tip or "").strip()
    if not t:
        return "nepoznato"
    tl = t.lower()
    for sub in RESIDENTIAL_SUBSTR:
        if sub in tl:
            return "stambeno-moguce"
    return "nestambeno"


def log(msg):
    print(msg, file=sys.stderr, flush=True)


# --- 1. Индекс бирача -------------------------------------------------------
def build_voter_index():
    files = {}  # id -> путања (processed има предност)
    for path in glob.glob(OUTPUT_GLOB):
        m = re.search(r"_(\d+)\.csv$", path)
        if m:
            files[m.group(1)] = path
    for path in glob.glob(PROCESSED_GLOB):
        m = re.search(r"_(\d+)\.csv$", path)
        if m:
            files[m.group(1)] = path  # прегази output ако постоји processed

    # key -> [preb, borav, lokalitet_id, Mesto, Ulica, KucniBroj] (изворни облик
    # из бирачког списка — потребан да дугме у извештају отвори тачну адресу у прегледу).
    index = {}
    localities = set()
    rows = 0
    skipped_stan = 0
    for lid, path in files.items():
        localities.add(lid)
        with open(path, encoding="utf-8", newline="") as f:
            for r in csv.DictReader(f):
                rows += 1
                # Бирачи са бројем стана су станари (нпр. „Вука Караџића 21/4”).
                # objekti.csv нема број стана, па их не рачунамо као поклапање —
                # рачунамо само бираче уписане на голу адресу зграде (без стана).
                if (r.get("Stan") or "").strip():
                    skipped_stan += 1
                    continue
                try:
                    preb = int(float(r.get("BiracaPrebivaliste") or 0))
                    borav = int(float(r.get("BiracaBoraviste") or 0))
                except ValueError:
                    preb = borav = 0
                if preb == 0 and borav == 0:
                    continue
                k = addr_key(r.get("Opstina"), r.get("Mesto"), r.get("Ulica"), r.get("KucniBroj"))
                ent = index.get(k)
                if ent is None:
                    index[k] = [preb, borav, int(lid), r.get("Mesto", ""),
                                r.get("Ulica", ""), r.get("KucniBroj", "")]
                else:
                    ent[0] += preb
                    ent[1] += borav
    log(f"[1] Бирачи: {len(files)} локалитета, {rows} редова "
        f"({skipped_stan} прескочено због броја стана), "
        f"{len(index)} адреса са бирачима (без стана).")
    return dict(index), sorted(localities, key=int), skipped_stan


# --- 2. Геокодирање адреса са бирачима --------------------------------------
def geocode_voter_addresses(voter_index):
    grid = defaultdict(list)  # (cx,cy) -> list of point dict
    matched_keys = set()
    total = 0
    with open(KUCNI_BROJ, encoding="utf-8", newline="") as f:
        for r in csv.DictReader(f):
            total += 1
            if total % 500000 == 0:
                log(f"    ... {total} адреса прочитано")
            k = addr_key(r.get("opstina_ime"), r.get("naselje_ime"),
                         r.get("ulica_ime"), r.get("kucni_broj"))
            v = voter_index.get(k)
            if v is None:
                continue
            pt = parse_point(r.get("wkt"))
            if pt is None:
                continue
            x, y = pt
            matched_keys.add(k)
            grid[(int(x // CELL), int(y // CELL))].append({
                "x": x, "y": y,
                "opstina": r.get("opstina_ime", ""),
                "mesto": r.get("naselje_ime", ""),
                "ulica": r.get("ulica_ime", ""),
                "broj": r.get("kucni_broj", ""),
                "preb": v[0], "borav": v[1],
                "loc": v[2], "vmesto": v[3], "vulica": v[4], "vbroj": v[5],
            })
    rate = 100.0 * len(matched_keys) / max(1, len(voter_index))
    log(f"[2] Адресни регистар: {total} редова. Геокодирано "
        f"{len(matched_keys)}/{len(voter_index)} адреса са бирачима ({rate:.1f}%).")
    geo_stats = {
        "voter_addresses": len(voter_index),
        "geocoded": len(matched_keys),
        "geocode_rate": round(rate, 1),
    }
    return grid, geo_stats


def nearest_in_grid(grid, x, y):
    cx, cy = int(x // CELL), int(y // CELL)
    best = None
    best_d2 = MAX_RADIUS * MAX_RADIUS
    for gx in (cx - 1, cx, cx + 1):
        for gy in (cy - 1, cy, cy + 1):
            for p in grid.get((gx, gy), ()):
                d2 = (p["x"] - x) ** 2 + (p["y"] - y) ** 2
                if d2 <= best_d2:
                    best_d2 = d2
                    best = p
    if best is None:
        return None, None
    return best, math.sqrt(best_d2)


# --- 3. + 4. Поклапање објеката и излаз -------------------------------------
def main():
    voter_index, localities, skipped_stan = build_voter_index()
    grid, geo_stats = geocode_voter_addresses(voter_index)
    geo_stats["preskoceno_stan"] = skipped_stan

    transformer = Transformer.from_crs("EPSG:32634", "EPSG:4326", always_xy=True)

    matches = []
    objekti_total = 0
    with open(OBJEKTI, encoding="utf-8", newline="") as f:
        for r in csv.DictReader(f):
            objekti_total += 1
            pt = parse_point(r.get("geometry"))
            if pt is None:
                continue
            x, y = pt
            p, dist = nearest_in_grid(grid, x, y)
            if p is None:
                continue
            lon, lat = transformer.transform(x, y)
            tip = r.get("tip_ustanove", "") or ""
            matches.append({
                "geoid": r.get("geoidentifikator", ""),
                "naziv": r.get("name_1", "") or r.get("name_2", ""),
                "tip": tip,
                "kategorija": classify(tip),
                "opstina": p["opstina"],
                "mesto": p["mesto"],
                "ulica": p["ulica"],
                "broj": p["broj"],
                "rastojanje_m": round(dist, 1),
                "preb": p["preb"],
                "borav": p["borav"],
                "ukupno": p["preb"] + p["borav"],
                "lat": round(lat, 6),
                "lon": round(lon, 6),
                # дубоки линк ка прегледу: ид локалитета + изворна адреса бирача
                "loc": p["loc"],
                "vmesto": p["vmesto"],
                "vulica": p["vulica"],
                "vbroj": p["vbroj"],
            })

    matches.sort(key=lambda m: m["ukupno"], reverse=True)
    log(f"[3] Објеката: {objekti_total}. Поклапања (≤{MAX_RADIUS:.0f}m, бирача>0): "
        f"{len(matches)}.")

    write_csv(matches)
    write_json(matches, localities, objekti_total, geo_stats)


def write_csv(matches):
    cols = ["geoid", "naziv", "tip", "kategorija", "opstina", "mesto", "ulica",
            "broj", "rastojanje_m", "preb", "borav", "ukupno", "lat", "lon"]
    header = ["geoidentifikator", "naziv", "tip_ustanove", "kategorija", "opstina",
              "mesto", "ulica", "kucni_broj", "rastojanje_m", "biraca_prebivaliste",
              "biraca_boraviste", "biraca_ukupno", "lat", "lon"]
    with open(OUT_CSV, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        for m in matches:
            w.writerow([m[c] for c in cols])
    log(f"[4] CSV: {OUT_CSV} ({len(matches)} редова).")


def write_json(matches, localities, objekti_total, geo_stats):
    by_tip = defaultdict(lambda: {"objekata": 0, "biraca": 0})
    by_opstina = defaultdict(lambda: {"objekata": 0, "biraca": 0})
    by_kat = defaultdict(lambda: {"objekata": 0, "biraca": 0})
    high_conf = 0
    total_biraca = 0
    for m in matches:
        by_tip[m["tip"] or "(непознато)"]["objekata"] += 1
        by_tip[m["tip"] or "(непознато)"]["biraca"] += m["ukupno"]
        by_opstina[m["opstina"]]["objekata"] += 1
        by_opstina[m["opstina"]]["biraca"] += m["ukupno"]
        by_kat[m["kategorija"]]["objekata"] += 1
        by_kat[m["kategorija"]]["biraca"] += m["ukupno"]
        total_biraca += m["ukupno"]
        if m["rastojanje_m"] <= HIGH_CONF:
            high_conf += 1

    def top(d, n=None):
        items = sorted(d.items(), key=lambda kv: kv[1]["biraca"], reverse=True)
        return [{"naziv": k, **v} for k, v in (items[:n] if n else items)]

    summary = {
        "objekata_ukupno": objekti_total,
        "poklapanja": len(matches),
        "biraca_ukupno": total_biraca,
        "visoka_pouzdanost": high_conf,
        "max_radius": MAX_RADIUS,
        "high_conf_radius": HIGH_CONF,
        "lokaliteta_sa_biracima": len(localities),
        "geokodirano_rate": geo_stats.get("geocode_rate"),
        "geokodirano": geo_stats.get("geocoded"),
        "adresa_sa_biracima": geo_stats.get("voter_addresses"),
        "preskoceno_stan": geo_stats.get("preskoceno_stan"),
        "po_kategoriji": {k: v for k, v in by_kat.items()},
        "po_tipu": top(by_tip),
        "po_opstini": top(by_opstina),
    }
    payload = {"summary": summary, "matches": matches}
    with open(OUT_JSON, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, separators=(",", ":"))
    log(f"[4] JSON: {OUT_JSON}.")
    # Сажетак на конзоли
    log("")
    log(f"    Поклапања: {len(matches)}  |  бирача укупно: {total_biraca}  |  "
        f"висока поузданост (≤{HIGH_CONF:.0f}m): {high_conf}")
    log(f"    По категорији: " + ", ".join(
        f"{k}={v['objekata']} ({v['biraca']} бир.)" for k, v in by_kat.items()))
    log("    Топ 8 типова по броју бирача:")
    for t in top(by_tip, 8):
        log(f"      {t['biraca']:>6} бир. | {t['objekata']:>4} обј. | {t['naziv']}")


if __name__ == "__main__":
    main()
