# -*- coding: utf-8 -*-
"""Заједничка нормализација адреса/геометрије.

Користе је и javni_objekti_biraci.py (спајање бирача и објеката) и
nekretnine_normalize.py (катастарски подаци), па обе стране своде адресе
на исти кључ. Понашање мора остати идентично — TRANSLIT и правила су иста
као некада инлајн у javni_objekti_biraci.py и у web/app.js.
"""

import re
import unicodedata

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
