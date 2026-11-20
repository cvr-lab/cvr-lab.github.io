#!/usr/bin/env python3
"""Importación semanal de publicaciones del laboratorio desde OpenAlex.

╔══════════════════════════════════════════════════════════════════════════╗
║  VISIÓN GENERAL: qué hace este script, de principio a fin               ║
╚══════════════════════════════════════════════════════════════════════════╝

Cada lunes, GitHub Actions ejecuta este script. Sigue siempre estos 7 pasos
(la función main() al final del archivo los va recorriendo en orden):

  1. LEER LA CONFIGURACIÓN
     Abre scripts/publications/sources.yaml: lista de investigadores (con su
     ORCID), palabras clave del laboratorio y umbral de puntuación.

  2. PREGUNTAR A OPENALEX
     Para cada investigador pide todos sus trabajos desde el año "since".
     OpenAlex es un catálogo abierto de publicaciones con API oficial.

  3. JUNTAR SIN REPETIR
     Si un trabajo lo firman dos investigadores del laboratorio, aparece dos
     veces; aquí se guarda una sola vez (por su identificador de OpenAlex).

  4. DESCARTAR LO QUE NO TOCA
     - tipos de documento que no interesan (erratas, datasets...)
     - DOIs que has puesto en exclude_dois
     - lo que YA está en la web (mismo DOI o mismo título) o ya se propuso
     - duplicados entre preprint y versión publicada (se queda la publicada)

  5. PUNTUAR LA RELEVANCIA
     Cada trabajo recibe puntos según las palabras clave del laboratorio que
     aparezcan en su título/resumen/temas, y si lo firman varios miembros.
     Si llega al umbral, se propone; si no, queda descartado.

  6. ESCRIBIR EL BIBTEX
     Los trabajos aceptados se escriben en un archivo .bib temporal. Luego el
     workflow lo convierte en páginas con `academic import`.

  7. ESCRIBIR EL INFORME Y LA MEMORIA
     - un informe en Markdown (será la descripción de la PR)
     - scripts/publications/seen.json: lista de lo ya propuesto, para no
       volver a proponerlo la semana siguiente.

Requisitos: Python 3.9+ y PyYAML. La clave de la API va en OPENALEX_API_KEY.
Uso en tu ordenador (simulación, no escribe nada):
    python scripts/publications/fetch_publications.py --dry-run
"""
from __future__ import annotations

# ── Librerías ────────────────────────────────────────────────────────────────
# Todas vienen con Python salvo "yaml" (PyYAML), que instala el workflow.
import argparse            # leer las opciones de la línea de comandos (--dry-run...)
import json                # leer/escribir JSON (respuesta de la API y seen.json)
import os                  # leer variables de entorno (la clave de la API)
import re                  # expresiones regulares (buscar patrones en texto)
import string              # string.ascii_lowercase = "abc...z" (sufijos a, b, c...)
import sys                 # salir con mensaje de error y escribir en stderr
import time                # esperar entre reintentos
import unicodedata         # quitar tildes ("Álvaro" -> "Alvaro")
import urllib.error        # errores de red
import urllib.parse        # construir la URL con sus parámetros
import urllib.request      # hacer la petición HTTP a OpenAlex
from datetime import date  # fecha de hoy, para anotarla en seen.json
from pathlib import Path   # manejar rutas de archivos de forma cómoda
from dotenv import load_dotenv, find_dotenv


import yaml                # leer sources.yaml

# ── Constantes ───────────────────────────────────────────────────────────────

# Dirección de la API de OpenAlex para consultar "works" (trabajos publicados).
API = "https://api.openalex.org/works"

# De todo lo que sabe OpenAlex de un trabajo, pedimos solo estos campos.
# Así las respuestas pesan menos y la consulta es más rápida.
SELECT = (
    "id,doi,title,display_name,publication_year,publication_date,type,"
    "authorships,primary_location,biblio,abstract_inverted_index,topics,keywords"
)

# Tipos de documento que se ignoran si sources.yaml no dice otra cosa.
DEFAULT_EXCLUDE = ["paratext", "peer-review", "erratum", "retraction",
                   "editorial", "letter", "dataset", "other"]

# Patrón que reconoce un DOI dentro de un texto. Un DOI tiene esta forma:
#   10.1016/j.patcog.2021.107954   (10.  +  4-9 dígitos  +  /  +  resto)
DOI_RE = re.compile(r"10\.\d{4,9}/[^\s\"'<>,}\]]+")


# ══════════════════════════════════════════════════════════════════════════════
# UTILIDADES DE TEXTO
# Funciones pequeñas para "normalizar" textos y poder compararlos.
# Dos escrituras distintas del mismo título o nombre deben dar el mismo
# resultado, y así detectamos duplicados.
# ══════════════════════════════════════════════════════════════════════════════

def strip_accents(s: str) -> str:
    """Quita las tildes: 'Álvaro Pérez' -> 'Alvaro Perez'.

    Descompone cada letra acentuada en letra + acento (NFD) y descarta los
    acentos (categoría 'Mn')."""
    return "".join(c for c in unicodedata.normalize("NFD", s or "")
                   if unicodedata.category(c) != "Mn")


def norm_title(s: str) -> str:
    """Título 'comparable': minúsculas, sin tildes, solo letras y números.

    'Event-Camera Tracking: a Survey!' -> 'eventcameratrackingasurvey'
    Sirve para saber si dos títulos son el mismo aunque cambie la puntuación."""
    return re.sub(r"[^a-z0-9]+", "", strip_accents(s).lower())


def norm_name(s: str) -> str:
    """Nombre 'comparable': minúsculas, sin tildes, sin signos (deja espacios).

    'Álvaro  Pérez-López' -> 'alvaro perezlopez'"""
    return re.sub(r"[^a-z ]+", "", strip_accents(s).lower()).strip()


def norm_doi(d: str | None) -> str:
    """DOI limpio y en minúsculas, sin 'https://doi.org/' delante.

    'https://doi.org/10.1000/ABC.' -> '10.1000/abc'"""
    d = (d or "").lower().strip()
    d = re.sub(r"^https?://(dx\.)?doi\.org/", "", d)
    return d.rstrip(".;)")


def norm_orcid(o: str | None) -> str:
    """ORCID sin la URL: 'https://orcid.org/0000-0001-2345-6789' -> '0000-0001-2345-6789'."""
    return (o or "").replace("https://orcid.org/", "").strip()


def norm_oaid(i: str | None) -> str:
    """Identificador de OpenAlex sin la URL: 'https://openalex.org/A123' -> 'A123'."""
    return (i or "").rsplit("/", 1)[-1]

def norm_ror(r: str | None) -> str:
    """ROR sin la URL: 'https://ror.org/04njjy449' -> '04njjy449'."""
    return (r or "").replace("https://ror.org/", "").strip().lower()


def tex(s: str | None) -> str:
    """Prepara un texto para meterlo en un archivo BibTeX.

    - quita llaves y barras invertidas (rompen el formato)
    - protege & % # _ $ poniéndoles una barra delante (son caracteres especiales)
    - junta espacios y saltos de línea repetidos en un solo espacio"""
    s = re.sub(r"[{}\\]", "", s or "")
    s = re.sub(r"([&%#_$])", r"\\\1", s)
    return re.sub(r"\s+", " ", s).strip()


def abstract_text(inv: dict | None) -> str:
    """Reconstruye el resumen (abstract) de un trabajo.

    OpenAlex no entrega el resumen como texto corrido, sino como un "índice
    invertido": cada palabra con la lista de posiciones donde aparece.
        {"We": [0], "propose": [1], "a": [2, 5], ...}
    Aquí se coloca cada palabra en su posición y se vuelve a unir en una frase."""
    if not inv:
        return ""
    pos = {}
    for word, idxs in inv.items():
        for i in idxs:
            pos[i] = word
    return " ".join(pos[i] for i in sorted(pos))


# ══════════════════════════════════════════════════════════════════════════════
# API DE OPENALEX  (paso 2)
# ══════════════════════════════════════════════════════════════════════════════

def api_get(params: dict, retries: int = 4) -> dict:
    """Hace UNA petición a OpenAlex y devuelve la respuesta ya convertida a dict.

    Si falla por algo pasajero (servidor ocupado, 429 = demasiadas peticiones,
    errores 5xx, o red caída), espera y reintenta: 2 s, 4 s, 8 s... hasta
    `retries` veces. Si el error es definitivo (clave mala, filtro inválido),
    se detiene con un mensaje claro."""
    url = f"{API}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={"User-Agent": "cvr-lab-site/1.0"})
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            # Errores "pasajeros": se reintenta, salvo que ya sea el último intento.
            if e.code in (429, 500, 502, 503, 504) and attempt < retries - 1:
                time.sleep(2 ** (attempt + 1))
                continue
            body = e.read().decode("utf-8", "replace")[:300]
            sys.exit(f"Error de OpenAlex {e.code}: {body}")
        except urllib.error.URLError as e:
            if attempt < retries - 1:
                time.sleep(2 ** (attempt + 1))
                continue
            sys.exit(f"Error de red: {e}")
    return {}


def person_filter(p: dict) -> str | None:
    """Construye el filtro de OpenAlex para una persona.

    Prefiere el ORCID (lo más fiable). Si no hay, usa su identificador de
    OpenAlex. Si no hay ninguno, devuelve None y esa persona se omite."""
    if p.get("orcid"):
        return "author.orcid:" + norm_orcid(p["orcid"])
    if p.get("openalex"):
        return "author.id:" + norm_oaid(p["openalex"])
    return None


def fetch_person_works(p: dict, key: str, mailto: str) -> list[dict]:
    """Descarga TODOS los trabajos de una persona desde su año 'since'.

    OpenAlex devuelve los resultados por páginas de hasta 100. Se usa un
    "cursor": cada respuesta trae un cursor para pedir la página siguiente, y
    se repite hasta que no quedan más (con un tope de 20 páginas por seguridad)."""
    flt = person_filter(p)
    since = int(p.get("since") or 2000)
    # id_ugr = "I173304897"  # Mejor después de coger los trabajos, para evitar aquellos fallos de OpenAlex en los que no ha asociado la institución bien
    filters = [
        flt,
        f"from_publication_date:{since}-01-01",
        #f"institutions.id:{id_ugr}"
    ]
    params = {"filter": ",".join(filters),
              "per-page": 100, "select": SELECT, "cursor": "*"}
    if key:
        params["api_key"] = key          # clave gratuita de OpenAlex
    if mailto:
        params["mailto"] = mailto        # opcional: tu correo, por cortesía
    out = []
    for _ in range(20):
        data = api_get(params)
        results = data.get("results") or []
        out += results
        cursor = (data.get("meta") or {}).get("next_cursor")
        if not cursor or not results:    # no hay más páginas
            break
        params["cursor"] = cursor
    return out


# ══════════════════════════════════════════════════════════════════════════════
# MIEMBROS DEL LABORATORIO
# Sirve para reconocer, dentro de la lista de autores de un trabajo, cuáles son
# gente del laboratorio (y usar su nombre "oficial" para que enlace con su ficha).
# ══════════════════════════════════════════════════════════════════════════════

class Members:
    """Guarda a los investigadores indexados de tres formas, para encontrarlos
    por ORCID, por identificador de OpenAlex o por nombre."""

    def __init__(self, people: list[dict]):
        self.by_orcid, self.by_oaid, self.by_name = {}, {}, {}
        for p in people:
            if p.get("orcid"):
                self.by_orcid[norm_orcid(p["orcid"])] = p
            if p.get("openalex"):
                self.by_oaid[norm_oaid(p["openalex"])] = p
            # El nombre y sus alias ("F. Barranco") apuntan a la misma persona.
            for n in [p["name"]] + list(p.get("aliases") or []):
                self.by_name[norm_name(n)] = p

    def match(self, authorship: dict) -> dict | None:
        """¿Este autor de un trabajo es alguien del laboratorio?

        Se prueba por ORCID, luego por ID de OpenAlex y, como último recurso,
        por nombre. Devuelve su ficha de sources.yaml o None."""
        a = authorship.get("author") or {}
        return (self.by_orcid.get(norm_orcid(a.get("orcid")))
                or self.by_oaid.get(norm_oaid(a.get("id")))
                or self.by_name.get(norm_name(a.get("display_name", ""))))


def bib_name(display: str) -> str:
    """Pasa 'Nombre Apellido' al formato BibTeX 'Apellido, Nombre'.

    Toma la ÚLTIMA palabra como apellido. Por eso existe el campo `bib_name`
    en sources.yaml para apellidos compuestos ('García López, Ana')."""
    parts = display.split()
    return f"{parts[-1]}, {' '.join(parts[:-1])}" if len(parts) > 1 else display


def author_list(w: dict, members: Members) -> tuple[list[str], list[str]]:
    """Devuelve dos listas para un trabajo:
      1) los autores en formato BibTeX, en el orden original del artículo
      2) los nombres oficiales de los miembros del laboratorio que lo firman

    A los miembros se les pone el nombre de sources.yaml (que debe coincidir
    con su ficha en data/authors/), y al resto el nombre que da OpenAlex."""
    bib, lab = [], []
    for au in w.get("authorships") or []:
        m = members.match(au)
        if m:
            lab.append(m["name"])
            bib.append(m.get("bib_name") or bib_name(m["name"]))
        else:
            bib.append(bib_name((au.get("author") or {}).get("display_name", "")))
    return [b for b in bib if b], lab

def lab_affiliated(w: dict, members: Members, ror: str) -> bool:
    """¿Algún miembro del laboratorio figura en este trabajo con la institución `ror`?
 
    Cada autor de un trabajo trae su lista de instituciones (con su ROR). Aquí se
    mira SOLO la afiliación de las personas del laboratorio EN ESTE trabajo: así un
    homónimo, o un artículo escrito antes de entrar a la UGR con otra afiliación,
    queda fuera. Se activa poniendo `institution_ror` en sources.yaml."""
    target = norm_ror(ror)
    for au in w.get("authorships") or []:
        if members.match(au):
            for inst in au.get("institutions") or []:
                if norm_ror(inst.get("ror")) == target:
                    return True
    return False

# ══════════════════════════════════════════════════════════════════════════════
# PUNTUACIÓN DE RELEVANCIA  (paso 5)
# ══════════════════════════════════════════════════════════════════════════════

def term_regex(term: str) -> re.Pattern:
    """Patrón para buscar una palabra clave como palabra completa (admite plural).

    'drone' encuentra 'drone' y 'drones', pero NO 'syndrome'.
    '\\b' marca el límite de palabra, y (s|es)? permite el plural."""
    return re.compile(r"\b" + re.escape(term.lower()) + r"(s|es)?\b")


def score_work(w: dict, title: str, n_lab: int, cfg: dict, thr: int,
               kw_res, topics, weak_res=(), excl_res=()) -> tuple[int, list[str]]:
    """Calcula los puntos de un trabajo y explica de dónde salen.
 
    Tres tipos de palabras (todas en sources.yaml):
      keywords          PRINCIPALES: lo que define al laboratorio.
                        título -> title_weight (3), resumen -> abstract_weight (1,
                        con tope abstract_cap)
      weak_keywords     GENÉRICAS (robot, ros...): suman poco, como mucho weak_cap
                        puntos en total, así que nunca bastan por sí solas.
      exclude_keywords  de OTRAS áreas (cerebelo...): restan exclude_penalty puntos
                        cada una. Se buscan en título, resumen y temas de OpenAlex.
 
    Además:
      - un tema de OpenAlex que coincida con `topics`        -> topic_weight (2)
      - 2 o más miembros del laboratorio como autores        -> lab_coauthors_bonus (3)
      - require_strong_keyword: si está activo y el trabajo no contiene NINGUNA
        palabra principal (y no lo firman 2+ miembros), la puntuación se limita
        para que no llegue al umbral.
 
    Devuelve (puntos, lista de motivos)."""
    st = cfg.get("settings", {})
    t = title.lower()
    ab = abstract_text(w.get("abstract_inverted_index")).lower()
    topic_names = " ".join((x.get("display_name") or "") for x in (w.get("topics") or [])).lower()
    topic_names += " " + " ".join((x.get("display_name") or "") for x in (w.get("keywords") or [])).lower()
    score, reasons, ab_pts, strong_hit = 0, [], 0, False
 
    # Palabras principales (cada una cuenta como mucho una vez).
    for term, rx in kw_res:
        if rx.search(t):
            strong_hit = True
            score += st.get("title_weight", 3)
            reasons.append(f"título: {term}")
        elif ab and rx.search(ab):
            strong_hit = True
            if ab_pts < st.get("abstract_cap", 3):
                ab_pts += st.get("abstract_weight", 1)
                score += st.get("abstract_weight", 1)
                reasons.append(f"resumen: {term}")
 
    # Palabras genéricas: aportan poco y tienen un tope.
    weak_pts = 0
    for term, rx in weak_res:
        if weak_pts >= st.get("weak_cap", 1):
            break
        if rx.search(t) or (ab and rx.search(ab)):
            weak_pts += st.get("weak_weight", 1)
            score += st.get("weak_weight", 1)
            reasons.append(f"genérica: {term}")
 
    # Segunda opinión: los temas y palabras clave que OpenAlex asigna al trabajo.
    for tp in topics:
        if tp in topic_names:
            score += st.get("topic_weight", 2)
            reasons.append(f"tema: {tp}")
            break                        # un solo acierto de tema basta
 
    if n_lab >= 2:
        score += st.get("lab_coauthors_bonus", 3)
        reasons.append(f"{n_lab} miembros del lab")
 
    # Palabras de otras áreas: restan puntos.
    everything = f"{t} {ab} {topic_names}"
    for term, rx in excl_res:
        if rx.search(everything):
            score -= st.get("exclude_penalty", 4)
            reasons.append(f"excluida: {term}")
 
    # Exigir al menos una palabra principal (los coautorados por 2+ miembros se libran).
    if st.get("require_strong_keyword") and not strong_hit and n_lab < 2:
        score = min(score, thr - 1)
        reasons.append("sin palabra clave principal")
    return score, reasons


# ══════════════════════════════════════════════════════════════════════════════
# LO QUE YA EXISTE EN EL REPOSITORIO  (paso 4)
# Para no proponer dos veces lo mismo, el script mira qué hay ya en la web.
# ══════════════════════════════════════════════════════════════════════════════

class Existing:
    """Recoge, al crearse, todo lo que ya está publicado o propuesto:
      - dois / titles : DOIs y títulos (normalizados) de las publicaciones
      - keys          : nombres de carpeta ya usados (barranco2021a...)
      - seen_ids/seen : lo que figura en seen.json (propuesto en semanas anteriores)"""

    def __init__(self, root: Path, bib: Path, seen: Path):
        self.dois, self.titles, self.keys = set(), set(), set()
        self.seen_ids, self.seen = set(), {}

        # 1) Las publicaciones que ya tiene la web: content/publications/<clave>/
        pubdir = root / "content" / "publications"
        if pubdir.is_dir():
            for d in pubdir.iterdir():
                if not d.is_dir():
                    continue
                self.keys.add(d.name)                       # la carpeta ocupa esa clave
                for fn in ("index.md", "cite.bib"):         # busca DOI y título dentro
                    f = d / fn
                    if f.is_file():
                        self._scan(f.read_text(encoding="utf-8", errors="replace"))

        # 2) Un publications.bib antiguo, si alguien lo dejó (solo lectura).
        if bib.is_file():
            txt = bib.read_text(encoding="utf-8", errors="replace")
            self.keys |= set(re.findall(r"@\w+\{([^,\s]+),", txt))
            self._scan(txt)

        # 3) La "memoria" del propio script: lo que ya propuso otras semanas.
        if seen.is_file():
            self.seen = json.loads(seen.read_text(encoding="utf-8") or "{}")
            for wid, rec in self.seen.items():
                self.seen_ids.add(wid)
                if rec.get("doi"):
                    self.dois.add(rec["doi"])
                if rec.get("title"):
                    self.titles.add(norm_title(rec["title"]))

    def _scan(self, text: str):
        """Saca de un texto los DOIs y los títulos y los apunta como 'ya vistos'."""
        for m in DOI_RE.findall(text):
            self.dois.add(norm_doi(m))
        # Título en el encabezado de una página:   title: Mi artículo
        for m in re.finditer(r"^title:\s*['\"]?(.+?)['\"]?\s*$", text, re.M):
            self.titles.add(norm_title(m.group(1)))
        # Título en un archivo BibTeX:             title = {Mi artículo},
        for m in re.finditer(r"\btitle\s*=\s*[{\"]+(.+?)[}\"]+\s*,?\s*$", text, re.M | re.I):
            self.titles.add(norm_title(m.group(1)))


# ══════════════════════════════════════════════════════════════════════════════
# BIBTEX  (paso 6)
# ══════════════════════════════════════════════════════════════════════════════

def make_key(first_author: str, year, taken: set[str]) -> str:
    """Inventa la clave (y nombre de carpeta) de una publicación: apellido+año+letra.

    Primer autor 'Isern, Juan', año 2025 -> 'isern2025a'. Si 'isern2025a' ya
    existe, prueba 'isern2025b', 'isern2025c'... Así no se pisa ninguna carpeta."""
    surname = re.sub(r"[^a-z0-9]", "", strip_accents(first_author.split(",")[0]).lower()) or "anon"
    base = f"{surname}{year}"
    for c in string.ascii_lowercase:
        if base + c not in taken:
            taken.add(base + c)
            return base + c
    raise SystemExit(f"Sin claves libres para {base}")


def build_entry(key: str, w: dict, title: str, authors: list[str]) -> str:
    """Convierte un trabajo de OpenAlex en una entrada BibTeX (texto).

    Elige el tipo de entrada según de dónde venga:
      preprint / repositorio -> @misc          (campo howpublished)
      capítulo de libro      -> @incollection  (campo booktitle)
      congreso               -> @inproceedings (campo booktitle)
      revista                -> @article       (campo journal)
      otro, sin lugar        -> @misc
    y añade título, autores, año, lugar, volumen, número, páginas, DOI
    (o la URL si no hay DOI) y resumen, solo si existen."""
    loc = w.get("primary_location") or {}
    src = loc.get("source") or {}
    venue = src.get("display_name") or ""       # nombre de la revista o congreso
    stype = src.get("type") or ""               # journal, conference, repository...
    wtype = w.get("type") or ""                 # article, preprint, book-chapter...
    if wtype == "preprint" or stype == "repository":
        etype, vfield = "misc", "howpublished"
    elif wtype == "book-chapter":
        etype, vfield = "incollection", "booktitle"
    elif stype == "conference":
        etype, vfield = "inproceedings", "booktitle"
    elif venue:
        etype, vfield = "article", "journal"
    else:
        etype, vfield = "misc", "howpublished"
    bib = w.get("biblio") or {}                 # volumen, número, páginas
    # Doble llave en el título ({{...}}) para que BibTeX respete las mayúsculas.
    fields = [("title", "{" + tex(title) + "}"), ("author", " and ".join(authors)),
              ("year", str(w.get("publication_year") or ""))]
    if venue:
        fields.append((vfield, tex(venue)))
    if etype == "misc" and wtype == "preprint":
        fields.append(("note", "Preprint"))
    for f, v in (("volume", bib.get("volume")), ("number", bib.get("issue"))):
        if v:
            fields.append((f, tex(str(v))))
    fp, lp = bib.get("first_page"), bib.get("last_page")
    if fp:
        fields.append(("pages", f"{fp}--{lp}" if lp and lp != fp else str(fp)))
    doi = norm_doi(w.get("doi"))
    if doi:
        fields.append(("doi", doi))
    elif loc.get("landing_page_url"):
        fields.append(("url", loc["landing_page_url"]))
    ab = abstract_text(w.get("abstract_inverted_index"))
    if ab:
        fields.append(("abstract", tex(ab)))
    # Une los campos con coma y salto de línea; los vacíos se omiten.
    body = ",\n".join(f"  {k} = {{{v}}}" for k, v in fields if v)
    return f"@{etype}{{{key},\n{body}\n}}\n"


# ══════════════════════════════════════════════════════════════════════════════
# INFORME  (paso 7)
# ══════════════════════════════════════════════════════════════════════════════

def build_report(accepted, near, discard, threshold, skipped, n_people) -> str:
    """Escribe el informe en Markdown que se verá como descripción de la PR.

    Tiene tres partes: un resumen con cifras, la tabla de propuestas (con su
    carpeta y los motivos de su puntuación) y, plegada, la lista de trabajos
    que se quedaron cerca del umbral por si alguno merece añadirse a mano."""
    L = ["## Publicaciones candidatas (OpenAlex)", "",
         f"Revisados {n_people} investigadores. **{len(accepted)}** propuestas nuevas "
         f"(umbral {threshold}); {skipped} ya existían o se habían propuesto antes.", ""]
    if accepted:
        L += ["### Propuestas (páginas incluidas en esta PR)", "",
              "| Punt. | Año | Título | Carpeta | Autores del lab | Motivos |", "|---|---|---|---|---|---|"]
        for c in sorted(accepted, key=lambda c: -(c["year"] or 0)):
            L.append(f"| {c['score']} | {c['year']} | {c['title'].replace('|', '/')} | "
                     f"`{c['key']}` | {', '.join(c['lab'])} | {'; '.join(c['reasons'][:5])} |")
        L += ["", "**Cómo revisar:** esta PR ya contiene las páginas en "
              "`content/publications/<carpeta>/`. Para descartar una, borra su carpeta en "
              "esta PR (botón de los tres puntos en *Files changed*) y fusiona. Las "
              "descartadas no volverán a proponerse.", ""]
    else:
        L += ["No hay propuestas nuevas esta semana.", ""]
    if near:
        L += ["<details><summary>Cerca del umbral (no añadidas)</summary>", "",
              "| Punt. | Año | Título | Motivos |", "|---|---|---|---|"]
        for c in sorted(near, key=lambda c: -c["score"])[:40]:
            L.append(f"| {c['score']} | {c['year']} | {c['title'].replace('|', '/')} | "
                     f"{'; '.join(c['reasons'][:4])} |")
        L += ["", "Si alguna es del laboratorio, añade su DOI a `include_dois` o una "
              "palabra clave en `sources.yaml`.", "", "</details>", ""]

    if discard:
            L += ["<details><summary>Fuera del umbral (Puntuaciones muy bajas)</summary>", "",
                  "| Punt. | Año | Título | Motivos |", "|---|---|---|---|"]
            for c in sorted(discard, key=lambda c: -c["score"])[:40]:
                L.append(f"| {c['score']} | {c['year']} | {c['title'].replace('|', '/')} | "
                         f"{'; '.join(c['reasons'][:4])} |")
            L += ["", "Si alguna es del laboratorio, añade su DOI a `include_dois` o una "
                  "palabra clave en `sources.yaml`.", "", "</details>", ""]

    return "\n".join(L)


# ══════════════════════════════════════════════════════════════════════════════
# NÚCLEO: decide qué se propone  (pasos 3 a 7, sin tocar la red)
# Está separado de main() a propósito: así se puede probar con datos inventados
# sin conectarse a OpenAlex.
# ══════════════════════════════════════════════════════════════════════════════

def run(cfg: dict, works: dict, existing: Existing, new_bib: Path,
        seen_path: Path, dry_run: bool) -> tuple[str, int]:
    """Filtra, puntúa y escribe. Devuelve (texto del informe, nº de entradas nuevas)."""
    st = cfg.get("settings", {})
    threshold = st.get("threshold", 3)
    people = [p for p in cfg.get("people") or [] if p and p.get("name")]
    members = Members(people)
    # Se preparan una sola vez las palabras clave, los temas y las listas manuales.
    kw_res = [(k, term_regex(k)) for k in cfg.get("keywords") or []]
    topics = [t.lower() for t in cfg.get("topics") or []]
    excl_types = set(st.get("exclude_types") or DEFAULT_EXCLUDE)
    excl = {norm_doi(d) for d in cfg.get("exclude_dois") or []}
    forced = {norm_doi(d) for d in cfg.get("include_dois") or []}
    inst_ror = st.get("institution_ror") or ""   # vacío = no se exige ninguna institución
    weak_res = [(k, term_regex(k)) for k in cfg.get("weak_keywords") or []]
    excl_res = [(k, term_regex(k)) for k in cfg.get("exclude_keywords") or []]

    # ── PASO 4: descartar lo que no toca ──────────────────────────────────────
    # by_title guarda un solo trabajo por título normalizado. Si hay un preprint
    # y una versión publicada con el mismo título, se queda la publicada.
    by_title, skipped, no_institution = {}, 0, 0
    for w in works.values():
        title = (w.get("title") or w.get("display_name") or "").strip()
        doi = norm_doi(w.get("doi"))
        # Sin título, de un tipo excluido o con DOI en exclude_dois: se ignora.
        if not title or w.get("type") in excl_types or doi in excl:
            continue
        nt = norm_title(title)
        # ¿Ya está en la web o se propuso otra semana? (por DOI, título o ID)
        if (doi and doi in existing.dois) or nt in existing.titles or w["id"] in existing.seen_ids:
            skipped += 1
            continue
        # Si se exige una institución (p. ej. la UGR), se descartan los trabajos en
        # los que ningún miembro del laboratorio figura con esa afiliación.
        if inst_ror and not lab_affiliated(w, members, inst_ror):
            no_institution += 1
            print("Descartado: " + title)
            continue
        prev = by_title.get(nt)
        if prev is None or (prev[0].get("type") == "preprint" and w.get("type") != "preprint"):
            by_title[nt] = (w, title, doi)

    # ── PASO 5: puntuar y clasificar ──────────────────────────────────────────
    accepted, near, discard = [], [], []          # near = cerca del umbral (1 o 2 puntos)
    for w, title, doi in by_title.values():
        authors, lab = author_list(w, members)
        # Miembros del laboratorio que firman este trabajo (para ajustes por persona):
        # umbral propio (`threshold`) y palabras excluidas propias (`exclude_keywords`).
        here = [m for au in w.get("authorships") or [] if (m := members.match(au))]
        thr = min([m.get("threshold", threshold) for m in here] or [threshold])
        own_excl = [(k, term_regex(k)) for m in here for k in (m.get("exclude_keywords") or [])]

        score, reasons = score_work(w, title, len(set(lab)), cfg, thr, kw_res, topics, weak_res, excl_res + own_excl)
        
        if doi in forced:            # include_dois: se propone aunque no llegue
            score, reasons = max(score, thr), reasons + ["incluida a mano"]
        rec = {"w": w, "title": title, "doi": doi, "authors": authors,
               "lab": sorted(set(lab)), "score": score, "reasons": reasons,
               "year": w.get("publication_year")}
        if score >= thr:
            accepted.append(rec)
        elif score >= 1:
            near.append(rec)
        elif score < 1:
            discard.append(rec)
        # con 0 puntos se descarta sin más y ni siquiera aparece en el informe

    # ── PASO 6: generar el BibTeX de los aceptados ────────────────────────────
    taken = set(existing.keys)       # claves ya ocupadas (carpetas existentes)
    entries = []
    for c in sorted(accepted, key=lambda c: (c["year"] or 0, c["title"])):
        c["key"] = make_key(c["authors"][0] if c["authors"] else "anon", c["year"], taken)
        entries.append(build_entry(c["key"], c["w"], c["title"], c["authors"]))
    report = build_report(accepted, near, discard, threshold, skipped, len(people))

    # ── PASO 7: escribir archivos (salvo en simulación) ───────────────────────
    if entries and not dry_run:
        new_bib.write_text("\n".join(entries), encoding="utf-8")
        # Se amplía la "memoria" con lo propuesto hoy: así, aunque alguien borre
        # una carpeta en la PR, esa publicación no vuelve a aparecer.
        seen = dict(existing.seen)
        for c in accepted:
            seen[c["w"]["id"]] = {"doi": c["doi"], "title": c["title"],
                                  "added": date.today().isoformat()}
        seen_path.write_text(json.dumps(seen, indent=1, ensure_ascii=False, sort_keys=True) + "\n",
                             encoding="utf-8")
    return report, len(entries)


# ══════════════════════════════════════════════════════════════════════════════
# PROGRAMA PRINCIPAL: lo que se ejecuta al lanzar el script  (pasos 1 y 2)
# ══════════════════════════════════════════════════════════════════════════════

def main(argv=None) -> int:
    # Opciones de la línea de comandos. Todas tienen valor por defecto, así que
    # normalmente solo se usa --dry-run (y el workflow pasa --report y --new-bib).
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=".")
    ap.add_argument("--config", default="scripts/publications/sources.yaml")
    ap.add_argument("--bib", default="publications.bib",
                    help="solo se lee, para no repetir lo que ya hubiera en un .bib antiguo")
    ap.add_argument("--new-bib", default="new-publications.bib",
                    help="BibTeX temporal con las entradas nuevas (no se sube al repositorio)")
    ap.add_argument("--seen", default="scripts/publications/seen.json")
    ap.add_argument("--report", default="publications-report.md")
    ap.add_argument("--dry-run", action="store_true",
                    help="simulación: no escribe el .bib nuevo ni seen.json")
    ap.add_argument("--env", default=".env")
    a = ap.parse_args(argv)
    root = Path(a.root)

    # PASO 1: leer sources.yaml y las claves de entorno.
    cfg = yaml.safe_load((root / a.config).read_text(encoding="utf-8")) or {}
    
    load_dotenv(Path(a.env))                       # Secreto
    key = os.environ.get("OPENALEX_API_KEY")
    mailto = os.environ.get("OPENALEX_MAILTO", "")  # opcional
    
    if not key:
        print("AVISO: falta OPENALEX_API_KEY (sin clave solo hay ~100 consultas de prueba al día).",
              file=sys.stderr)
    else:
        print("OPENALEX_API_KEY cargada correctamente.")

    # PASOS 2 y 3: pedir los trabajos de cada persona y juntarlos sin repetir.
    # `works` es un diccionario {id del trabajo: datos}; setdefault guarda la
    # primera vez que se ve un trabajo e ignora las siguientes.
    works = {}
    for p in cfg.get("people") or []:
        if not p or not p.get("name"):
            continue
        if not person_filter(p):
            print(f"AVISO: {p['name']} no tiene orcid ni openalex; se omite.", file=sys.stderr)
            continue
        got = fetch_person_works(p, key, mailto)
        print(f"{p['name']}: {len(got)} trabajos desde {p.get('since', 2000)}")
        for w in got:
            works.setdefault(w["id"], w)

    # PASOS 4 a 7: lo hace run(). Después se guarda el informe y se muestra.
    existing = Existing(root, root / a.bib, root / a.seen)
    report, n = run(cfg, works, existing, Path(a.new_bib), root / a.seen, a.dry_run)
    Path(a.report).write_text(report, encoding="utf-8")
    print(report)
    print(f"\n{n} entradas nuevas {'(simulación, no escritas)' if a.dry_run else 'escritas en ' + a.new_bib}")
    return 0


if __name__ == "__main__":
    sys.exit(main())