"""Las tres fuentes del reporte, leidas sin Power BI:

1. Forma (ACC)  -> publicaciones: cada version de cada .rvt dentro de 011_WIP.
2. RevitSyncLog -> modificaciones: CSV del add-in (y los historicos capturados a mano).
3. Excel        -> integrantes y equipos (Equipos e integrantes - VENTAS.xlsx).
"""
import csv
import json
import logging
import re
import unicodedata
from datetime import datetime, timedelta, timezone
from pathlib import Path

log = logging.getLogger("pub_sync.fuentes")


# ================================================================
# NORMALIZACION (misma logica que las consultas de Power Query)
# ================================================================

def modelo_key(nombre):
    """'11_ARQ_CONJUNTO.rvt' -> '11_ARQ_CONJUNTO'  (NormalizarModelo)"""
    s = re.sub(r"[\x00-\x1f\x7f]", "", str(nombre or "")).strip().upper()
    return s[:-4] if s.endswith(".RVT") else s


def modelo_sin_ext(nombre):
    s = str(nombre or "").strip()
    return s[:-4] if s.lower().endswith(".rvt") else s


def proyecto_norm(v):
    """'GRANJAS_JESSY' -> 'GRANJAS JESSY'"""
    return re.sub(r"\s+", " ", str(v or "").replace("_", " ")).strip()


def persona_norm(v):
    """NormalizarPersona: mayusculas, sin acentos (incluye N), puntuacion como espacio."""
    s = re.sub(r"[\x00-\x1f\x7f]", "", str(v or "")).strip().upper()
    s = "".join(c for c in unicodedata.normalize("NFD", s) if unicodedata.category(c) != "Mn")
    s = re.sub(r"[.,;:\-_/\\]", " ", s)
    return " ".join(s.split())


def persona_compacta(v):
    """CompactarPersona: 'Juan Pablo Reyes' y 'JUANPABLOREYES' dan la misma llave."""
    return persona_norm(v).replace(" ", "")


def disciplina(modelo):
    """Misma regla que HISTORIAL_PUBLICACIONES_MODELOS (por palabras en el nombre del archivo)."""
    a = str(modelo or "").upper()
    if "ARQ" in a or "ARC" in a:
        return "ARQUITECTURA"
    if "EST" in a or "STR" in a:
        return "ESTRUCTURA"
    if "ELE" in a:
        return "ELECTRICA"
    if "ESP" in a or "SPE" in a:
        return "ESPECIALES"
    if "MEC" in a:
        return "MECANICA"
    if "PLO" in a or "PLU" in a:
        return "PLOMERIA"
    return "SIN DISCIPLINA"


def parse_fecha(texto, tz):
    """ISO 8601 con o sin zona ('2026-05-04T21:34:07.000Z', '...-06:00', 7 decimales)
    -> datetime en la zona local del reporte (tz). Sin zona se asume UTC."""
    if not texto:
        return None
    s = str(texto).strip().replace("Z", "+00:00")
    m = re.match(r"^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2})?)(\.\d+)?([+-]\d{2}:?\d{2})?$", s)
    if not m:
        return None
    base, frac, zona = m.groups()
    frac = (frac or ".0")[:7].ljust(7, "0")
    dt = datetime.fromisoformat(base.replace(" ", "T") + frac + (zona or "+00:00"))
    return dt.astimezone(tz).replace(tzinfo=None)


# ================================================================
# 1. FORMA: PUBLICACIONES
# ================================================================

class Cache:
    def __init__(self, ruta):
        self.p = Path(ruta)
        try:
            self.d = json.loads(self.p.read_text(encoding="utf-8"))
        except Exception:
            self.d = {}

    def save(self):
        self.p.parent.mkdir(parents=True, exist_ok=True)
        self.p.write_text(json.dumps(self.d, ensure_ascii=False), encoding="utf-8")


def _buscar_subcarpetas(aps, pid, folder_id, nombre, ruta, max_prof=6):
    """Todas las carpetas llamadas 'nombre' (p.ej. 011_WIP) dentro del proyecto, en cualquier nivel
    (p.ej. HOWA/01_D&I/011_WIP). No se detiene en la primera: un proyecto puede tener mas de una.
    No se desciende dentro de una 011_WIP encontrada (su contenido se recorre despues)."""
    nivel, obj, encontradas = [(folder_id, ruta)], nombre.strip().lower(), []
    for _ in range(max_prof):
        sig = []
        for fid, r in nivel:
            carpetas, _ = aps.contenido(pid, fid)
            for c in carpetas:
                rc = f"{r}/{c['name']}"
                if c["name"].strip().lower() == obj:
                    encontradas.append({**c, "ruta": rc})
                else:
                    sig.append((c["id"], rc))
        nivel = sig
        if not nivel:
            break
    return encontradas


def _rvt_recursivo(aps, pid, folder_id, excluir_re, ruta):
    carpetas, items = aps.contenido(pid, folder_id)
    for it in items:
        if it["name"].lower().endswith(".rvt") and not (excluir_re and re.search(excluir_re, it["name"], re.I)):
            yield {**it, "ruta": ruta}
    for c in carpetas:
        yield from _rvt_recursivo(aps, pid, c["id"], excluir_re, f"{ruta}/{c['name']}")


def leer_forma(aps, cfg, tz, cache_path):
    """-> (modelos, publicaciones, avisos)
    modelos: {urn: {proyecto, modelo}}  (catalogo de .rvt en Forma, para resolver el proyecto)
    publicaciones: una fila por version de cada .rvt."""
    a = cfg["aps"]
    hub, pid = aps.con_b(a["account_id"]), aps.con_b(a["project_id"])
    raices = [n.lower() for n in cfg.get("raiz_nombres", ["Project Files"])]
    tops = aps.top_folders(hub, pid)
    raiz = next((t for t in tops if t["name"].strip().lower() in raices), None)
    if not raiz:
        raise ValueError(f"No se encontro la carpeta raiz {raices} entre {[t['name'] for t in tops]}")

    sub = cfg.get("subcarpeta_datos", "011_WIP")
    excl = {x.lower() for x in cfg.get("excluir_proyectos", [])}
    excluir_re = cfg.get("excluir_rvt_regex")
    cache = Cache(cache_path)
    modelos, pubs, avisos = {}, [], []

    proyectos, _ = aps.contenido(pid, raiz["id"])
    log.info("Carpetas en %s segun APS (%d): %s", raiz["name"], len(proyectos),
             ", ".join(repr(p["name"]) for p in proyectos))
    for p in proyectos:
        nombre_p = p["name"].strip()
        if nombre_p.upper().startswith("Z_") or nombre_p.lower() in excl:
            log.info("  %-28s omitido (plantilla o excluido)", nombre_p)
            continue
        ruta_p = f"{raiz['name']}/{nombre_p}"
        wips = _buscar_subcarpetas(aps, pid, p["id"], sub, ruta_p) if sub else [{**p, "ruta": ruta_p}]
        if not wips:
            log.info("  %-28s sin carpeta %s", nombre_p, sub)
            avisos.append(f"Proyecto '{nombre_p}': sin carpeta '{sub}', se omitio.")
            continue
        rvts = [it for w in wips for it in _rvt_recursivo(aps, pid, w["id"], excluir_re, w["ruta"])]
        log.info("  %-28s %d .rvt en %s", nombre_p, len(rvts), ", ".join(w["ruta"] for w in wips) or "-")
        if not rvts:
            avisos.append(f"Proyecto '{nombre_p}': {sub} sin modelos .rvt ({', '.join(w['ruta'] for w in wips)}).")
        for it in rvts:
            urn = it["item_id"]
            modelos[urn] = {"proyecto": nombre_p, "modelo": modelo_sin_ext(it["name"]),
                            "ruta": it["ruta"], "archivo": it["name"], "versiones": it["tip_version"]}
            c = cache.d.get(urn)
            if not c or c.get("tip") != it["tip_version"]:
                c = {"tip": it["tip_version"], "versiones": aps.versiones(pid, urn)}
                cache.d[urn] = c
            for v in c["versiones"]:
                fh = parse_fecha(v["creado"], tz)
                if fh is None:
                    continue
                pubs.append({"urn": urn, "proyecto": nombre_p, "modelo": modelo_sin_ext(it["name"]),
                             "version": v["numero"], "version_id": v["version_id"],
                             "fecha_hora": fh, "publicado_por": v["creado_por"] or ""})
    cache.save()
    log.info("Forma: %d modelos .rvt, %d publicaciones (versiones)", len(modelos), len(pubs))
    return modelos, pubs, avisos


# ================================================================
# 2. REVIT: MODIFICACIONES
# ================================================================

def leer_revit(carpeta, tz):
    """Todas las sincronizaciones exitosas de los CSV de RevitSyncLog."""
    filas = []
    for f in sorted(Path(carpeta).glob("*.csv")):
        with open(f, encoding="utf-8-sig", newline="") as fh:
            for r in csv.DictReader(fh):
                if (r.get("SyncStatus") or "").strip() != "Succeeded":
                    continue
                dt = parse_fecha(r.get("SyncCompletedAtLocal"), tz)
                if dt is None:
                    continue
                filas.append({"urn": (r.get("ModelUrn") or "").strip(),
                              "proyecto_csv": proyecto_norm(r.get("ProjectLabel")),
                              "modelo": modelo_sin_ext(r.get("ModelName")),
                              "fecha_hora": dt,
                              "usuario": (r.get("RevitUser") or "").strip(),
                              "origen": (r.get("SourceType") or "").strip(),
                              "archivo": f.name})
    log.info("Revit: %d sincronizaciones exitosas en %s", len(filas), carpeta)
    return filas


# ================================================================
# 3. EQUIPOS E INTEGRANTES
# ================================================================

def leer_equipos(ruta, hoja="Integrantes"):
    """-> lista de {integrante, equipo, compacta} (distinta por llave compacta)."""
    from openpyxl import load_workbook
    ws = load_workbook(ruta, data_only=True, read_only=True)[hoja]
    filas = list(ws.iter_rows(values_only=True))
    enc = [str(c or "").strip() for c in filas[0]]
    ie, ii = enc.index("Equipo"), enc.index("Integrante")
    out, vistos = [], set()
    for r in filas[1:]:
        eq = str(r[ie] or "").replace("\xa0", " ").strip()
        it = str(r[ii] or "").replace("\xa0", " ").strip()
        if not eq or not it:
            continue
        k = persona_compacta(it)
        if k in vistos:
            continue
        vistos.add(k)
        out.append({"integrante": it, "equipo": eq, "compacta": k})
    return out


class Personas:
    """Resuelve un nombre (usuario Revit o de ACC) contra el listado oficial.
    Prioridad: alias conocido -> llave compacta exacta. Sin coincidencia: nombre original, SIN EQUIPO."""

    def __init__(self, equipos, alias=None):
        self.por_k = {e["compacta"]: e for e in equipos}
        self.alias = {persona_compacta(k): v for k, v in (alias or {}).items()}

    def resolver(self, nombre):
        k = persona_compacta(nombre)
        destino = self.alias.get(k)
        if destino:
            k = persona_compacta(destino)
        e = self.por_k.get(k)
        if e:
            return e["integrante"], e["equipo"]
        return (nombre or None), "SIN EQUIPO"
