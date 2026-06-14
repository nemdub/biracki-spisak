#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Spaja јавне објекте (data/objekti.csv) са адресама на којима су уписани бирачи,
и одвојено укршта бираче са катастарском наменом парцеле (data/processed/
nekretnine_parcele.csv.gz) да нађе бираче уписане на нестамбеним адресама.

Цев (pipeline):
  1. Изгради индекс бирача по нормализованој адреси из свих
     biraci_po_adresi_*.csv фајлова (унија processed + output, без дупликата).
  2. Прочитај data/kucni_broj.csv (адресни регистар са координатама у UTM 34N)
     и геокодирај адресе на којима ИМА бирача; уз координате упамти и парцелу
     (ko_maticni_broj + broj_parcele) ради споја с катастром.
  3a. За сваки јавни објекат нађи најближу такву адресу (просторни grid индекс).
  3b. За сваку геокодирану адресу нађи намену парцеле у катастру и обележи
      бираче на нестамбеним/помоћним/празним парцелама (само у покривеним KO).
  4. Класификуј, претвори UTM -> WGS84 и испиши резултате.

Излаз:
  web/javni_objekti_sa_biracima.csv     — табела спојева са објектима
  web/javni_objekti_report.json         — подаци + сажетак (објекти)
  web/biraci_nestambeno.csv             — бирачи на нестамбеним адресама (катастар)
  web/biraci_nestambeno_report.json     — подаци + сажетак (катастар)
"""

import csv
import glob
import gzip
import json
import math
import os
import re
import sys
from collections import defaultdict

from pyproj import Transformer

from geo_norm import addr_key, norm, norm_broj, norm_naselje, norm_opstina, parse_point

# csv поља у kucni_broj.csv знају бити подужа (WKT, спискови) — подигни лимит.
csv.field_size_limit(10 * 1024 * 1024)

ROOT = os.path.dirname(os.path.abspath(__file__))
KUCNI_BROJ = os.path.join(ROOT, "data", "kucni_broj.csv")
OBJEKTI = os.path.join(ROOT, "data", "objekti.csv")
PROCESSED_GLOB = os.path.join(ROOT, "data", "processed", "biraci_po_adresi", "biraci_po_adresi_*.csv")
OUTPUT_GLOB = os.path.join(ROOT, "output", "biraci_po_adresi_*.csv")

# Катастарски индекс намене (генерише nekretnine_normalize.py локално).
NEKRETNINE_PARCELE = os.path.join(ROOT, "data", "processed", "nekretnine_parcele.csv.gz")
NEKRETNINE_KO = os.path.join(ROOT, "data", "processed", "nekretnine_ko_coverage.csv")

OUT_CSV = os.path.join(ROOT, "web", "javni_objekti_sa_biracima.csv")
OUT_JSON = os.path.join(ROOT, "web", "javni_objekti_report.json")
OUT_NES_CSV = os.path.join(ROOT, "web", "biraci_nestambeno.csv")
OUT_NES_JSON = os.path.join(ROOT, "web", "biraci_nestambeno_report.json")

# Парцеле обележене као нестамбене за бираче. Не обележавамо стамбено/непознато.
FLAG_CATEGORIES = {"nestambeno", "pomocno", "bez-objekta"}
# JSON (мапа/табела) увек носи СВА поуздана спајања (намена зграде: nestambeno/
# pomocno), а 'bez-objekta' (шумовито — зграда зна бити уписана на суседној
# парцели) ограничавамо на топ N по броју бирача. Пуна листа иде у CSV.
BEZ_OBJEKTA_JSON_CAP = 2000

# Просторно спајање: задржи спајања до MAX_RADIUS m (јединствена прецизност).
MAX_RADIUS = 15.0
CELL = MAX_RADIUS  # величина ћелије = радијус → довољан је 3x3 блок око упита

# Очекивани укупан број адреса (без бројева станова) кад се заврши прикупљање
# бирачких података (засебан, текући процес). Користи се као именилац покривености.
EXPECTED_ADDRESSES = 1374393

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


_ADR_DIGIT = re.compile(r"\d")


def parse_adresa_broj(adresa):
    """Издвоји (улица, кућни_број) из споја у objekti.csv ('Михајла Валтровића
    36 А' -> ('Михајла Валтровића', '36 А')). Број је на крају: скупљамо завршне
    токене док садрже цифру, уз евентуални једнословни/двословни суфикс ('А','Б').
    Враћа (улица, број) или (adresa, None) ако нема препознатљивог броја — тада
    број не упоређујемо (ослањамо се само на координате)."""
    toks = (adresa or "").strip().split()
    if not toks:
        return "", None
    i = len(toks)
    seen_digit = False
    while i > 0:
        t = toks[i - 1]
        if _ADR_DIGIT.search(t):           # '36', '10-10' — језгро броја
            seen_digit = True
            i -= 1
            continue
        if len(t) <= 2 and t.isalpha() and not seen_digit:  # суфикс 'А' у '36 А'
            i -= 1
            continue
        break
    if not seen_digit:
        return (adresa or "").strip(), None
    return " ".join(toks[:i]).strip(), " ".join(toks[i:]).strip()


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
                # objekti.csv нема број стана, па их не рачунамо као спој —
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
    grid = defaultdict(list)  # (cx,cy) -> list of point dict (за најближе објекте)
    # Дедупликована геокодирана адреса по addr_key (за катастарски укрштај). Иста
    # адреса зна да се у регистру јави на више редова/парцела; бирачи су исти, па
    # их не смемо двоструко рачунати — чувамо их једном уз СКУП парцела.
    voter_geo = {}
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
                "key": k,  # ради споја са катастром (намена парцеле адресе)
                "opstina": r.get("opstina_ime", ""),
                "mesto": r.get("naselje_ime", ""),
                "ulica": r.get("ulica_ime", ""),
                "broj": r.get("kucni_broj", ""),
                "preb": v[0], "borav": v[1],
                "loc": v[2], "vmesto": v[3], "vulica": v[4], "vbroj": v[5],
            })
            ko = str(r.get("ko_maticni_broj") or "").strip()
            parcela = str(r.get("broj_parcele") or "").strip()
            g = voter_geo.get(k)
            if g is None:
                g = voter_geo[k] = {
                    "x": x, "y": y,
                    "opstina": r.get("opstina_ime", ""),
                    "mesto": r.get("naselje_ime", ""),
                    "ulica": r.get("ulica_ime", ""),
                    "broj": r.get("kucni_broj", ""),
                    "preb": v[0], "borav": v[1],
                    "loc": v[2], "vmesto": v[3], "vulica": v[4], "vbroj": v[5],
                    "parcels": set(),
                }
            if ko and parcela:
                g["parcels"].add((ko, parcela))
    rate = 100.0 * len(matched_keys) / max(1, len(voter_index))
    log(f"[2] Адресни регистар: {total} редова. Геокодирано "
        f"{len(matched_keys)}/{len(voter_index)} адреса са бирачима ({rate:.1f}%).")
    geo_stats = {
        "voter_addresses": len(voter_index),
        "geocoded": len(matched_keys),
        "geocode_rate": round(rate, 1),
    }
    return grid, voter_geo, geo_stats


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


# --- Катастар: учитавање и укрштање ----------------------------------------
def load_nekretnine():
    """Учитај индекс намене парцела. Враћа (parcele, ko_pokriveno):
      parcele[(ko, parcelNumber)] = {"kategorija", "kategorije_raw"}
      Индекс садржи СВЕ парцеле из катастра (и оне без зграде, kategorija=
      'bez-objekta'), па одсуство кључа значи 'нема катастарских података'.
      ko_pokriveno = број катастарских општина (само за извештавање)."""
    if not (os.path.exists(NEKRETNINE_PARCELE) and os.path.exists(NEKRETNINE_KO)):
        log("[нек] катастарски индекс није нађен — прескачем нестамбену анализу.")
        return None, 0
    ko_pokriveno = 0
    with open(NEKRETNINE_KO, encoding="utf-8", newline="") as f:
        ko_pokriveno = sum(1 for _ in csv.DictReader(f))
    parcele = {}
    with gzip.open(NEKRETNINE_PARCELE, "rt", encoding="utf-8", newline="") as f:
        for r in csv.DictReader(f):
            parcele[(r["ko_maticni_broj"], r["parcelNumber"])] = {
                "kategorija": r["kategorija"],
                "kategorije_raw": r["kategorije_raw"],
                "scraped": r.get("scraped", ""),
            }
    log(f"[нек] Катастар: {ko_pokriveno} KO, {len(parcele)} парцела.")
    return parcele, ko_pokriveno


# Приоритет при сажимању адресе са више парцела (виши број јачи):
# стан побеђује → не обележавамо; затим нестамбено; помоћно; празна парцела.
_RANK = {"nepoznato": 0, "bez-objekta": 1, "pomocno": 2, "nestambeno": 3, "stambeno": 4}


def classify_address_parcel(parcels, parcele):
    """Намена адресе на основу њених парцела. Враћа (kategorija, kategorije_raw,
    scraped) или None ако НИЈЕДНА парцела адресе није у катастру (нема података).
    Конзервативно: ако ИКОЈА парцела има стан → стамбено (не обележава се).
    scraped = НАЈСТАРИЈИ снимак међу парцелама адресе (доња граница свежине —
    ако је иједна парцела стара, обележавање може каснити за стварношћу)."""
    best = None
    raws = []
    scraped_min = None
    for key in parcels:
        p = parcele.get(key)
        if not p:
            continue
        kat = p["kategorija"]
        if best is None or _RANK[kat] > _RANK[best]:
            best = kat
        if p["kategorije_raw"]:
            raws.append(p["kategorije_raw"])
        s = p.get("scraped") or ""
        if s and (scraped_min is None or s < scraped_min):
            scraped_min = s
    if best is None:
        return None                        # ниједна парцела адресе није у катастру
    return best, " | ".join(sorted(set(raws))), (scraped_min or "")


def analyze_nekretnine(voter_geo, transformer, parcele, ko_pokriveno):
    """Прођи кроз геокодиране адресе бирача и обележи нестамбене (катастар)."""
    if parcele is None:
        return None
    matches = []
    u_pokrivenim = 0
    for g in voter_geo.values():
        res = classify_address_parcel(g["parcels"], parcele)
        if res is None:
            continue
        u_pokrivenim += 1
        kat, raw, scraped = res
        if kat not in FLAG_CATEGORIES:
            continue
        lon, lat = transformer.transform(g["x"], g["y"])
        matches.append({
            "kategorija": kat,
            "namena": raw,
            "scraped": scraped,
            "opstina": g["opstina"],
            "mesto": g["mesto"],
            "ulica": g["ulica"],
            "broj": g["broj"],
            "preb": g["preb"],
            "borav": g["borav"],
            "ukupno": g["preb"] + g["borav"],
            "lat": round(lat, 6),
            "lon": round(lon, 6),
            "loc": g["loc"], "vmesto": g["vmesto"],
            "vulica": g["vulica"], "vbroj": g["vbroj"],
        })
    matches.sort(key=lambda m: m["ukupno"], reverse=True)
    log(f"[3b] Катастар: {u_pokrivenim} адреса у покривеним KO, "
        f"{len(matches)} обележено као нестамбено (бирача "
        f"{sum(m['ukupno'] for m in matches)}).")
    write_nestambeno_csv(matches)
    write_nestambeno_json(matches, len(voter_geo), u_pokrivenim, ko_pokriveno)
    return matches


def write_nestambeno_csv(matches):
    cols = ["kategorija", "namena", "scraped", "opstina", "mesto", "ulica", "broj",
            "preb", "borav", "ukupno", "lat", "lon"]
    header = ["kategorija", "namena_katastar", "katastar_snimljen", "opstina",
              "mesto", "ulica", "kucni_broj", "biraca_prebivaliste",
              "biraca_boraviste", "biraca_ukupno", "lat", "lon"]
    with open(OUT_NES_CSV, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        for m in matches:
            w.writerow([m[c] for c in cols])
    log(f"[4] CSV: {OUT_NES_CSV} ({len(matches)} редова).")


def write_nestambeno_json(matches, adresa_ukupno, u_pokrivenim, ko_pokriveno):
    by_kat = defaultdict(lambda: {"adresa": 0, "biraca": 0})
    by_opstina = defaultdict(lambda: {"adresa": 0, "biraca": 0})
    total_biraca = 0
    for m in matches:
        by_kat[m["kategorija"]]["adresa"] += 1
        by_kat[m["kategorija"]]["biraca"] += m["ukupno"]
        by_opstina[m["opstina"]]["adresa"] += 1
        by_opstina[m["opstina"]]["biraca"] += m["ukupno"]
        total_biraca += m["ukupno"]

    def top(d, n=None):
        items = sorted(d.items(), key=lambda kv: kv[1]["biraca"], reverse=True)
        return [{"naziv": k, **v} for k, v in (items[:n] if n else items)]

    # Увек прикажи сва поуздана (намена зграде); 'bez-objekta' ограничи на топ N.
    pouzdana = [m for m in matches if m["kategorija"] != "bez-objekta"]
    bez = [m for m in matches if m["kategorija"] == "bez-objekta"][:BEZ_OBJEKTA_JSON_CAP]
    prikazane = sorted(pouzdana + bez, key=lambda m: m["ukupno"], reverse=True)

    # Свежина катастарског снимка (mtime ЛН фајлова) — потрошач у извештају рачуна
    # старост у односу на данас и упозорава да катастар може каснити за стварношћу.
    sd = sorted(m["scraped"] for m in matches if m.get("scraped"))
    snimljeno = {
        "min": sd[0], "max": sd[-1], "median": sd[len(sd) // 2],
    } if sd else None

    summary = {
        "biraca_adresa_ukupno": adresa_ukupno,
        "adresa_u_pokrivenim_ko": u_pokrivenim,
        "ko_pokriveno": ko_pokriveno,
        "obelezeno": len(matches),
        "biraca_obelezeno": total_biraca,
        "prikazano": len(prikazane),
        "bez_objekta_cap": BEZ_OBJEKTA_JSON_CAP,
        "snimljeno": snimljeno,
        "po_kategoriji": {k: v for k, v in by_kat.items()},
        "po_opstini": top(by_opstina),
    }
    payload = {"summary": summary, "matches": prikazane}
    with open(OUT_NES_JSON, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, separators=(",", ":"))
    log(f"[4] JSON: {OUT_NES_JSON}.")
    log("")
    log(f"    Нестамбено: {len(matches)} адреса  |  бирача: {total_biraca}")
    log(f"    По категорији: " + ", ".join(
        f"{k}={v['adresa']} ({v['biraca']} бир.)" for k, v in by_kat.items()))


# --- 3. + 4. Спајање објеката и излаз -------------------------------------
def main():
    voter_index, localities, skipped_stan = build_voter_index()
    grid, voter_geo, geo_stats = geocode_voter_addresses(voter_index)
    geo_stats["preskoceno_stan"] = skipped_stan

    transformer = Transformer.from_crs("EPSG:32634", "EPSG:4326", always_xy=True)

    # Катастар се учитава једном: користи га и нестамбена анализа (део 2) и
    # филтер лажних позитива у поклапању објеката (део 1, испод).
    parcele, ko_pokriveno = load_nekretnine()
    analyze_nekretnine(voter_geo, transformer, parcele, ko_pokriveno)

    matches = []
    objekti_total = 0
    excluded_broj = 0   # одбачени лажни позитиви (иста улица, други кућни број)
    excluded_stambeno = 0  # одбачени: катастар каже да адреса ИМА стамбену зграду
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
            # Лажни позитив: координате нађу најближу зграду, али objekti.csv има
            # СОПСТВЕНУ адресу — ако је иста улица а ДРУГИ кућни број, спој везује
            # бираче суседне зграде (нпр. објекат на бр. 41, најближа уписана на
            # бр. 39). Разлика само у облику броја ('36 А'↔'36А') се НЕ одбацује
            # (norm_broj их изједначи). Без препознатог броја или на другој улици
            # се ослањамо само на координате.
            o_ulica, o_broj = parse_adresa_broj(r.get("adresa"))
            if (o_broj is not None
                    and norm(o_ulica) == norm(p["ulica"])
                    and norm_broj(o_broj) != norm_broj(p["broj"])):
                excluded_broj += 1
                continue
            # Лажни позитив (мешовита стамбено-пословна зграда): ако катастар каже
            # да адреса бирача ИМА стамбену зграду, бирачи ту легитимно станују, па
            # јавни објекат (нпр. ветеринарска амбуланта у приземљу стамбене зграде)
            # није аномалија. Изостављамо такве — задржавамо само адресе које по
            # катастру немају стамбену зграду (или нису у покривеној KO).
            if parcele is not None:
                g = voter_geo.get(p["key"])
                cad = classify_address_parcel(g["parcels"], parcele) if g else None
                if cad is not None and cad[0] == "stambeno":
                    excluded_stambeno += 1
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
    log(f"[3] Објеката: {objekti_total}. Спојева (≤{MAX_RADIUS:.0f}m, бирача>0): "
        f"{len(matches)} (одбачено {excluded_broj} — други кућни број, "
        f"{excluded_stambeno} — стамбена зграда по катастру).")

    geo_stats["iskljuceno_broj"] = excluded_broj
    geo_stats["iskljuceno_stambeno"] = excluded_stambeno
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
    total_biraca = 0
    for m in matches:
        by_tip[m["tip"] or "(непознато)"]["objekata"] += 1
        by_tip[m["tip"] or "(непознато)"]["biraca"] += m["ukupno"]
        by_opstina[m["opstina"]]["objekata"] += 1
        by_opstina[m["opstina"]]["biraca"] += m["ukupno"]
        by_kat[m["kategorija"]]["objekata"] += 1
        by_kat[m["kategorija"]]["biraca"] += m["ukupno"]
        total_biraca += m["ukupno"]

    def top(d, n=None):
        items = sorted(d.items(), key=lambda kv: kv[1]["biraca"], reverse=True)
        return [{"naziv": k, **v} for k, v in (items[:n] if n else items)]

    summary = {
        "objekata_ukupno": objekti_total,
        "poklapanja": len(matches),
        "biraca_ukupno": total_biraca,
        "max_radius": MAX_RADIUS,
        "lokaliteta_sa_biracima": len(localities),
        "geokodirano_rate": geo_stats.get("geocode_rate"),
        "geokodirano": geo_stats.get("geocoded"),
        "adresa_sa_biracima": geo_stats.get("voter_addresses"),
        "ocekivano_adresa": EXPECTED_ADDRESSES,
        "preskoceno_stan": geo_stats.get("preskoceno_stan"),
        "iskljuceno_broj": geo_stats.get("iskljuceno_broj"),
        "iskljuceno_stambeno": geo_stats.get("iskljuceno_stambeno"),
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
    log(f"    Спојева (≤{MAX_RADIUS:.0f}m): {len(matches)}  |  бирача укупно: {total_biraca}")
    log(f"    По категорији: " + ", ".join(
        f"{k}={v['objekata']} ({v['biraca']} бир.)" for k, v in by_kat.items()))
    log("    Топ 8 типова по броју бирача:")
    for t in top(by_tip, 8):
        log(f"      {t['biraca']:>6} бир. | {t['objekata']:>4} обј. | {t['naziv']}")


if __name__ == "__main__":
    main()
