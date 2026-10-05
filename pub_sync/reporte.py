"""Arma el JSON del dashboard y lo inserta en la plantilla HTML.

Es una traduccion 1:1 de Build-ReportData y del bloque final de Export-PUBLICACIONES_VENTAS.ps1,
asi que Publicaciones-Modelos-Report.template.html se usa sin cambios.
"""
import json
import logging
import re
from datetime import datetime
from pathlib import Path

log = logging.getLogger("pub_sync.reporte")
MARCADOR = '<script id="publicaciones-data" type="application/json"></script>'


def _periodo(fecha_txt):
    return str(fecha_txt)[:7] if fecha_txt and re.match(r"^\d{4}-\d{2}", str(fecha_txt)) else None


def _distinct_joined(valores):
    vistos = {}
    for v in valores:
        if v is None or not str(v).strip():
            continue
        s = str(v).strip()
        vistos.setdefault(s.lower(), s)  # unico sin distinguir mayusculas (Sort-Object -Unique)
    return " | ".join(sorted(vistos.values(), key=str.lower))


def _num_version(txt):
    m = re.findall(r"\d+", str(txt or ""))
    return int(m[-1]) if m else None


def _agrupar(filas, llave):
    g = {}
    for f in filas:
        g.setdefault(llave(f), []).append(f)
    return g.values()


def build_report_data(activity_rows, history_rows):
    activity = []
    for r in activity_rows:
        p = _periodo(r["Fecha"])
        if not p:
            continue
        activity.append({
            "Periodo": p, "Proyecto": r["ProyectoConcurso"] or "", "Modelo": r["Modelo"] or "",
            "Disciplina": r["Disciplina"] or "", "Responsable": r["Responsable Modificacion"] or "",
            "Equipo": r["Equipo"] or "", "IdModelo": r["IdModelo"] or "", "Fecha": r["Fecha"],
            "Modificado": int(r["Modificado"]), "Publicado": int(r["Publicado"]),
            "EstadoDia": r["EstadoDia"], "MetaPublicacion": int(r["MetaPublicacion"]),
            "PublicacionCumplida": int(r["PublicacionCumplida"]), "LlaveCruce": r["LlaveCruce"],
        })

    models = []
    for rows in _agrupar(activity, lambda a: (a["Periodo"], a["Proyecto"], a["Modelo"])):
        f = rows[0]
        meta = sum(r["MetaPublicacion"] for r in rows)
        cump = sum(r["PublicacionCumplida"] for r in rows)
        models.append({
            "Periodo": f["Periodo"], "Proyecto": f["Proyecto"], "Modelo": f["Modelo"], "IdModelo": f["IdModelo"],
            "Disciplina": _distinct_joined(r["Disciplina"] for r in rows),
            "Responsable": _distinct_joined(r["Responsable"] for r in rows),
            "Equipo": _distinct_joined(r["Equipo"] for r in rows),
            "Publicaciones": cump, "Meta": meta, "Incumplimientos": max(0, meta - cump),
            "Cumplimiento": (cump / meta) if meta else 0,
        })

    projects = []
    for rows in _agrupar(models, lambda m: (m["Periodo"], m["Proyecto"])):
        f = rows[0]
        meta = sum(r["Meta"] for r in rows)
        pub = sum(r["Publicaciones"] for r in rows)
        projects.append({
            "Periodo": f["Periodo"], "Proyecto": f["Proyecto"], "Modelos": len({r["Modelo"] for r in rows}),
            "Publicaciones": pub, "Meta": meta, "Cumplimiento": (pub / meta) if meta else 0,
            "Brecha": max(0, meta - pub),
        })

    portfolio = []
    for rows in _agrupar(projects, lambda p: p["Periodo"]):
        per = rows[0]["Periodo"]
        meta = sum(r["Meta"] for r in rows)
        pub = sum(r["Publicaciones"] for r in rows)
        portfolio.append({
            "Periodo": per, "Proyectos": len({r["Proyecto"] for r in rows}),
            "Modelos": sum(1 for m in models if m["Periodo"] == per),
            "Publicaciones": pub, "Meta": meta, "Cumplimiento": (pub / meta) if meta else 0,
            "Brecha": max(0, meta - pub),
        })

    history = []
    for r in history_rows:
        p = r.get("AnoMes") or _periodo(r.get("Fecha"))
        if not p:
            continue
        history.append({
            "Periodo": p, "Proyecto": r["ProyectoConcurso"], "Modelo": r["Modelo"], "IdModelo": r["IdModelo"],
            "VersionRaw": r["Version"], "VersionNumber": _num_version(r["Version"]),
            "FechaHora": r["FechaHoraPublicacion"] or r["Fecha"],
        })

    versions = []
    for rows in _agrupar(history, lambda h: (h["Periodo"], h["Proyecto"], h["Modelo"])):
        rows = sorted(rows, key=lambda h: h["FechaHora"] or "")
        a, b = rows[0], rows[-1]
        vi, vf = a["VersionNumber"], b["VersionNumber"]
        versions.append({
            "Periodo": a["Periodo"], "Proyecto": a["Proyecto"], "Modelo": a["Modelo"], "IdModelo": a["IdModelo"],
            "VersionInicial": vi, "VersionActual": vf,
            "VersionInicialTexto": a["VersionRaw"], "VersionActualTexto": b["VersionRaw"],
            "AvanceVersion": (vf - vi) if vi is not None and vf is not None else 0,
            "PublicacionesMesTotal": len(rows),
        })

    detail = [{
        "Periodo": m["Periodo"], "Proyecto": m["Proyecto"], "Modelo": m["Modelo"], "IdModelo": m["IdModelo"],
        "Disciplina": m["Disciplina"], "Responsable": m["Responsable"], "Equipo": m["Equipo"],
        "Meta": m["Meta"], "PublicacionesCumplidas": m["Publicaciones"],
        "Incumplimientos": m["Incumplimientos"], "Cumplimiento": m["Cumplimiento"],
    } for m in models]

    activity.sort(key=lambda a: (a["Periodo"], a["Proyecto"], a["Modelo"], a["Fecha"]))
    return {"portfolio": portfolio, "projects": projects, "models": models,
            "versions": versions, "detail": detail, "activity": activity}


def escribir(activity_rows, history_rows, avisos, json_path, template_path, html_path, fuente):
    """Genera JSON + HTML. Devuelve un texto de estado. Nunca deja archivos a medias:
    si algo falla o no hay datos, se conservan el ultimo JSON y HTML validos."""
    if not activity_rows:
        return "SIN ACTUALIZACION: la actividad diaria salio vacia. Se conservan el JSON y el HTML anteriores."
    if not history_rows:
        return "SIN ACTUALIZACION: no se encontraron publicaciones en Forma. Se conservan el JSON y el HTML anteriores."

    data = build_report_data(activity_rows, history_rows)
    if not data["models"]:
        return "SIN ACTUALIZACION: el procesamiento genero 0 modelos. Se conservan el JSON y el HTML anteriores."

    comparable = {"activityRowCount": len(activity_rows), "historyRowCount": len(history_rows), **data}
    json_path, html_path = Path(json_path), Path(html_path)
    try:
        prev = json.loads(json_path.read_text(encoding="utf-8-sig"))
        prev_cmp = {k: prev.get(k) for k in comparable}
        if json.dumps(prev_cmp, sort_keys=True, default=str) == json.dumps(comparable, sort_keys=True, default=str) \
                and prev.get("source") == fuente and html_path.exists() \
                and html_path.stat().st_mtime >= Path(template_path).stat().st_mtime:
            return (f"SIN CAMBIOS: Activity={len(activity_rows)}, History={len(history_rows)}, "
                    f"Models={len(data['models'])}. Se conservan el JSON y el HTML existentes.")
    except Exception:
        pass

    template = Path(template_path).read_text(encoding="utf-8")
    snapshot = {"generatedAt": datetime.now().astimezone().isoformat(), "source": fuente,
                "avisos": avisos, **comparable}
    txt = json.dumps(snapshot, ensure_ascii=False, indent=2)
    seguro = txt.replace("</script>", "<\\/script>")
    bloque = f'<script id="publicaciones-data" type="application/json">{seguro}</script>'
    if MARCADOR in template:
        html = template.replace(MARCADOR, bloque)
    elif "__PUBLICACIONES_DATA_JSON__" in template:
        html = template.replace("__PUBLICACIONES_DATA_JSON__", seguro)
    elif "</body>" in template:
        html = template.replace("</body>", bloque + "</body>")
    else:
        raise ValueError("La plantilla HTML no tiene un punto para insertar los datos.")
    html = html.replace("Datos de Power BI", "Datos de ACC y Revit")

    json_path.parent.mkdir(parents=True, exist_ok=True)
    html_path.parent.mkdir(parents=True, exist_ok=True)
    for destino, contenido in ((json_path, txt), (html_path, html)):
        tmp = destino.with_suffix(destino.suffix + ".tmp")
        tmp.write_text(contenido, encoding="utf-8")
        tmp.replace(destino)
    return (f"EXPORTACION COMPLETADA: Activity={len(activity_rows)}, History={len(history_rows)}, "
            f"Models={len(data['models'])}, Versions={len(data['versions'])}.")
