#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Нормализује катастарске листе непокретности (data/liste_nekretnina/) у компактан
индекс намене по парцели, погодан за коришћење у CI-у.

Извор (локални, ~11 GB, ~2.6M JSON фајлова — НЕ иде у git/CI):
  data/liste_nekretnina/<ОПШТИНА>/KO_<катастарска општина>/LN/<парцела>.json
  Сваки фајл: листа парцела -> parcelParts -> buildings (са useType = намена)
  -> buildingParts (посебни делови, нпр. STAN / POSLOVNI PROSTOR).

Излаз (компактан, ИДЕ у git, чита га javni_objekti_biraci.py):
  data/processed/nekretnine_parcele.csv      — једна врста по парцели са зградом
  data/processed/nekretnine_ko_coverage.csv  — обухват по катастарској општини (KO)

Спој са адресним регистром (kucni_broj.csv) се ради код потрошача по кључу
  (cadmunId == ko_maticni_broj, parcelNumber == broj_parcele).

Класификација и правила обележавања су документовани у data/processed/NEKRETNINE.md.
Покрени локално после освежавања data/liste_nekretnina/, па комитуј излазне CSV-ове.
"""

import csv
import glob
import gzip
import json
import os
import re
import sys
import time
from collections import Counter
from multiprocessing import Pool

from geo_norm import norm

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, "data", "liste_nekretnina")
# Парцела CSV је ~136 MB → пишемо gzip (~10 MB) да стане у git; потрошач чита .gz.
OUT_PARCELE = os.path.join(ROOT, "data", "processed", "nekretnine_parcele.csv.gz")
OUT_COVERAGE = os.path.join(ROOT, "data", "processed", "nekretnine_ko_coverage.csv")

# --- Класификација намене зграде --------------------------------------------
# Поређење иде преко geo_norm.norm() (транслитерација + lowercase), па правила
# пишемо латиницом без дијакритике. Подниз се тражи у нормализованом useType-у.
# Редослед провере: СТАНОВАЊЕ -> ПОМОЋНО -> НЕПОЗНАТО -> иначе НЕСТАМБЕНО.

# Становање (на парцели ПОСТОЈИ стан → не обележавамо).
RESIDENTIAL = [
    "stambena zgrada",      # porodicna / kolektivna stambena zgrada
    "stambeno-poslovna",    # мешовита — садржи станове
    "stambeno poslovna",
    "vikend kuca",          # викендица — рачуна се као стамбено (одлука корисника)
    "za stanovanje",
]

# Помоћне/економске зграде (нема стана). Ако парцела има САМО ове → обележи.
AUXILIARY = [
    "pomocna zgrada",
    "garaza",
    "ekonomski objekat",
    "poljoprivrede",        # zgrada/objekat poljoprivrede
    "za proizvodnju stocne hrane",
    "silos",
]

# Непознато (не обележавамо, али пријављујемо).
UNKNOWN = [
    "ostale zgrade",
    "nije poznata namena",
    "nepoznat",
]


def classify_building(use_type):
    """Врати једну од: stambeno / pomocno / nestambeno / nepoznato."""
    u = norm(use_type)
    if not u:
        return "nepoznato"
    for s in RESIDENTIAL:
        if s in u:
            return "stambeno"
    for s in AUXILIARY:
        if s in u:
            return "pomocno"
    for s in UNKNOWN:
        if s in u:
            return "nepoznato"
    return "nestambeno"


def is_stan_part(part_use_type):
    """Део зграде који је стан (не пословни простор) → доказ становања.
    Толерише шум као и класификација зграде: префикс 'PREDBELEŽBA:' и суфиксе
    иза цртице/размака (нпр. 'STAN-ДУПЛЕКС', 'STAN-СУТЕРЕН II', 'PREDBELEŽBA: STAN')
    — гледа само водећу реч. 'POSLOVNI PROSTOR' остаје негативан."""
    u = norm(part_use_type).replace("predbelezba:", "").strip()
    head = re.split(r"[-\s]", u, maxsplit=1)[0]
    return head == "stan"


def has_structure_land(part_use_type):
    """Тип земљишта парцеле БЕЗ зграде који ипак значи да објекат постоји (уписан
    на суседној парцели): 'ZEMLJIŠTE POD ZGRADOM/DELOM OBJEKTA', 'UZ ZGRADU' и сл.
    Њиве/воћњаци/пашњаци/'GRAĐEVINSKA PARCELA' немају ни 'zgrad' ни 'objek'."""
    u = norm(part_use_type)
    return "zgrad" in u or "objek" in u


# Земљиште које носи ПРЕТЕЖНИ/ОСТАЛИ ДЕО ОБЈЕКТА — јавља се кад је један објекат
# подељен преко више парцела (једна добија „претежни”, друга „остали” део). Зграда
# је уписана на суседној парцели; помоћни објекат (гаража/шупа) не може бити
# „претежни део објекта”, па је класификација такве парцеле непоуздана.
_SPILL = ("preteznim delom objekta", "ostalim delom objekta")


def has_spillover_land(part_use_type):
    u = norm(part_use_type)
    return any(s in u for s in _SPILL)


def parcel_category(n_buildings, building_cats, has_stan, struct_land,
                    spill_land=False):
    """Сажми категорије свих зграда на парцели у једну категорију парцеле.
    Без зграде: ако земљиште носи траг објекта (нпр. 'pod delom objekta' — зграда
    је уписана на суседној парцели) → 'nepoznato' (постоји структура, намена
    непозната → не обележавамо); иначе → 'bez-objekta' (стварно празна парцела,
    нпр. њива/плац са адресом). Стан увек побеђује; затим нестамбено; помоћно.

    Изузетак (избегавање лажног обележавања): ако је парцела САМО помоћна (гаража/
    шупа), а земљиште носи 'претежни/остали део објекта' → стварна зграда је на
    суседној парцели (нпр. стамбени блок преко више парцела), па → 'nepoznato'."""
    if n_buildings == 0:
        return "nepoznato" if struct_land else "bez-objekta"
    if has_stan or "stambeno" in building_cats:
        return "stambeno"
    if "nestambeno" in building_cats:
        return "nestambeno"
    if "pomocno" in building_cats:
        return "nepoznato" if spill_land else "pomocno"
    return "nepoznato"


def process_locality(loc_dir):
    """Обради једну општину; врати (parcele_rows, coverage_rows, n_files).
    Парцеле су по (cadmunId, parcelNumber) — јединствене унутар једне општине,
    па се резултати радника спајају просто надовезивањем."""
    parcele = {}   # (ko, parcelNumber) -> dict
    coverage = {}  # ko -> dict
    n_files = 0
    pattern = os.path.join(loc_dir, "**", "LN", "*.json")
    for path in glob.iglob(pattern, recursive=True):
        n_files += 1
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            continue
        # Извор нема поље датума, па се старост снимка изводи из времена измене
        # фајла (скидање са geoSrbija писало је сваки ЛН фајл у тренутку преузимања).
        # Служи као доња граница свежине: катастар може и иначе да каска за стварношћу
        # (нова градња неуписана), али овим бар знамо кад смо снимили затечено стање.
        scraped = time.strftime("%Y-%m-%d", time.localtime(os.path.getmtime(path)))
        for parcel in data:
            ko = str(parcel.get("cadmunId") or "").strip()
            pno = str(parcel.get("parcelNumber") or "").strip()
            if not ko or not pno:
                continue
            cov = coverage.get(ko)
            if cov is None:
                cov = coverage[ko] = {
                    "ko_maticni_broj": ko,
                    "municipalityName": parcel.get("municipalityName", "") or "",
                    "cadmunName": parcel.get("cadmunName", "") or "",
                    "parcels_total": 0,
                    "parcels_with_buildings": 0,
                    "scraped_min": scraped,
                    "scraped_max": scraped,
                }
            cov["parcels_total"] += 1
            if scraped < cov["scraped_min"]:
                cov["scraped_min"] = scraped
            if scraped > cov["scraped_max"]:
                cov["scraped_max"] = scraped

            cats = set()
            raw = Counter()
            n_buildings = 0
            has_stan = False
            struct_land = False
            spill_land = False
            for pp in parcel.get("parcelParts", []):
                if has_structure_land(pp.get("useType")):
                    struct_land = True
                if has_spillover_land(pp.get("useType")):
                    spill_land = True
                for b in pp.get("buildings", []):
                    n_buildings += 1
                    ut = (b.get("useType") or "").strip()
                    cats.add(classify_building(ut))
                    raw[ut] += 1
                    for bp in b.get("buildingParts", []):
                        if is_stan_part(bp.get("useType")):
                            has_stan = True
            if n_buildings:
                cov["parcels_with_buildings"] += 1
            # Емитуј СВЕ парцеле (и без зграде) — да потрошач разликује „парцела
            # постоји у катастру али нема објекат” (bez-objekta) од „парцеле нема
            # у катастру” (нема података → не обележава се).
            key = (ko, pno)
            parcele[key] = {
                "ko_maticni_broj": ko,
                "parcelNumber": pno,
                "n_buildings": n_buildings,
                "kategorija": parcel_category(n_buildings, cats, has_stan,
                                              struct_land, spill_land),
                "kategorije_raw": "|".join(sorted(raw)),
                "has_residential": int(("stambeno" in cats) or has_stan),
                "has_stan_parts": int(has_stan),
                "scraped": scraped,
            }
    return list(parcele.values()), list(coverage.values()), n_files


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def main():
    if not os.path.isdir(SRC):
        log(f"ГРЕШКА: нема директоријума {SRC}")
        sys.exit(1)
    loc_dirs = sorted(
        os.path.join(SRC, d) for d in os.listdir(SRC)
        if os.path.isdir(os.path.join(SRC, d))
    )
    log(f"[нек] {len(loc_dirs)} општина у {SRC}")

    os.makedirs(os.path.dirname(OUT_PARCELE), exist_ok=True)
    t0 = time.time()

    workers = min(os.cpu_count() or 4, 8)
    all_parcele = []
    coverage_merged = {}  # ko -> dict
    total_files = 0
    done = 0
    with Pool(workers) as pool:
        for parc_rows, cov_rows, n_files in pool.imap_unordered(process_locality, loc_dirs):
            all_parcele.extend(parc_rows)
            total_files += n_files
            for c in cov_rows:
                coverage_merged[c["ko_maticni_broj"]] = c
            done += 1
            log(f"    ... {done}/{len(loc_dirs)} општина, "
                f"{total_files} фајлова, {len(all_parcele)} парцела")

    # Парцеле
    all_parcele.sort(key=lambda r: (r["ko_maticni_broj"], r["parcelNumber"]))
    pcols = ["ko_maticni_broj", "parcelNumber", "n_buildings", "kategorija",
             "kategorije_raw", "has_residential", "has_stan_parts", "scraped"]
    with gzip.open(OUT_PARCELE, "wt", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(pcols)
        for r in all_parcele:
            w.writerow([r[c] for c in pcols])

    # Обухват по KO
    cov_list = sorted(coverage_merged.values(), key=lambda c: c["ko_maticni_broj"])
    ccols = ["ko_maticni_broj", "municipalityName", "cadmunName",
             "parcels_total", "parcels_with_buildings", "scraped_min", "scraped_max"]
    with open(OUT_COVERAGE, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(ccols)
        for c in cov_list:
            w.writerow([c[col] for col in ccols])

    # Сажетак
    by_kat = Counter(r["kategorija"] for r in all_parcele)
    dt = time.time() - t0
    log("")
    log(f"[нек] готово за {dt:.0f}s: {total_files} фајлова, "
        f"{len(cov_list)} KO, {len(all_parcele)} парцела.")
    log(f"    По категорији парцеле: " +
        ", ".join(f"{k}={v}" for k, v in by_kat.most_common()))
    scraped_all = [r["scraped"] for r in all_parcele if r.get("scraped")]
    if scraped_all:
        log(f"    Старост снимка (mtime фајлова): {min(scraped_all)} … {max(scraped_all)}")
    log(f"    CSV: {OUT_PARCELE}")
    log(f"    CSV: {OUT_COVERAGE}")


if __name__ == "__main__":
    main()
