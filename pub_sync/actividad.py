"""KPI de publicacion diaria (replica ACTIVIDAD_DIARIA_MODELOS y HISTORIAL_PUBLICACIONES_MODELOS).

Regla por Modelo + Dia:
    Modificado = hubo al menos una sincronizacion exitosa en Revit ese dia
    Publicado  = hubo al menos una version nueva en Forma ese dia
    CUMPLE (1,1) | INCUMPLE (1,0) | PUBLICACION ADICIONAL (0,1)
    Meta = Modificado ; Cumplida = Modificado y Publicado

Diferencia con Power BI: el cruce se hace por el URN del modelo (identificador unico en ACC),
no por Proyecto + Nombre. El proyecto sale de la carpeta en Forma. Solo los CSV historicos
(capturados a mano, sin URN) se resuelven por Proyecto + Nombre dentro de ese proyecto.
"""
import json
import logging
from collections import defaultdict
from datetime import date
from pathlib import Path

from .fuentes import disciplina, modelo_key

log = logging.getLogger("pub_sync.actividad")


def _fecha_txt(d):
    return d.strftime("%Y-%m-%dT00:00:00.0000000")


def _dt_txt(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + f"{dt.microsecond:06d}0"


def resolver_modificaciones(mods, modelos):
    """Asigna a cada sincronizacion su modelo de Forma (urn, proyecto, modelo).
    -> (resueltas, avisos)"""
    por_nombre = defaultdict(list)
    for urn, m in modelos.items():
        por_nombre[(m["proyecto"].upper(), modelo_key(m["modelo"]))].append(urn)

    out, sin_forma, ambiguos = [], defaultdict(int), defaultdict(int)
    for r in mods:
        urn = r["urn"]
        if urn and urn in modelos:
            m = modelos[urn]
            out.append({**r, "urn": urn, "proyecto": m["proyecto"], "modelo": m["modelo"]})
            continue
        # Sin URN (historicos) o URN que ya no esta en 011_WIP: por Proyecto + Nombre
        cands = por_nombre.get((r["proyecto_csv"].upper(), modelo_key(r["modelo"])), [])
        if len(cands) == 1:
            m = modelos[cands[0]]
            out.append({**r, "urn": cands[0], "proyecto": m["proyecto"], "modelo": m["modelo"]})
        else:
            if len(cands) > 1:
                ambiguos[(r["proyecto_csv"], r["modelo"])] += 1
            else:
                sin_forma[(r["proyecto_csv"], r["modelo"])] += 1
            # Se conserva como modificacion sin publicacion posible (cuenta como INCUMPLE)
            out.append({**r, "urn": urn, "proyecto": r["proyecto_csv"], "modelo": r["modelo"]})

    avisos = [f"Modelo de Revit sin .rvt equivalente en Forma: {p} / {m} ({n} sincronizaciones)."
              for (p, m), n in sorted(sin_forma.items())]
    avisos += [f"Modelo ambiguo (mismo nombre dos veces en el proyecto): {p} / {m} ({n} sincronizaciones)."
               for (p, m), n in sorted(ambiguos.items())]
    return out, avisos


def filtrar_modelos_addin(modelos, pubs, mods, base_path):
    """Solo cuentan los modelos que han pasado por Revit con el add-in (tienen al menos una
    sincronizacion en RevitSyncLog). Un .rvt cargado directo a Forma (del cliente, de un externo,
    o nuestro subido por fuera) se ignora: no aparece en el reporte ni cuenta en los datos.

    Transicion: los modelos que ya estaban en Forma la primera vez que corre este filtro quedan
    registrados en base_path y siguen contando como hasta ahora, aunque su responsable aun no
    tenga el add-in. Solo los modelos NUEVOS necesitan una sincronizacion con el add-in.
    -> (publicaciones filtradas, avisos)"""
    base_path = Path(base_path)
    try:
        base = set(json.loads(base_path.read_text(encoding="utf-8"))["modelos"])
    except Exception:
        base = set(modelos)
        base_path.parent.mkdir(parents=True, exist_ok=True)
        base_path.write_text(json.dumps({
            "nota": "Modelos que ya existian en Forma al activar 'solo_modelos_con_addin'. "
                    "Siguen contando aunque no tengan sincronizaciones del add-in.",
            "creado": date.today().isoformat(),
            "modelos": sorted(base)}, ensure_ascii=False, indent=1), encoding="utf-8")
        log.info("Se registraron %d modelos existentes en %s (siguen contando como hasta ahora)",
                 len(base), base_path)

    con_addin = {r["urn"] for r in mods if r.get("urn")}
    ignorados = {u: m for u, m in modelos.items() if u not in con_addin and u not in base}
    if not ignorados:
        return pubs, []
    lista = "; ".join(sorted(f"{m['proyecto']} / {m['modelo']}" for m in ignorados.values()))
    log.warning("Modelos que nunca pasaron por el add-in (no se incluyen): %s", lista)
    return ([p for p in pubs if p["urn"] not in ignorados],
            [f"{len(ignorados)} modelos nunca sincronizados con el add-in no se incluyeron: {lista}"])


def _id(urn, proyecto, modelo):
    """Identidad del modelo: URN cuando existe; si no, Proyecto|Modelo."""
    return urn or f"{proyecto.upper()}|{modelo_key(modelo)}"


def historial(pubs, personas):
    """Filas equivalentes a HISTORIAL_PUBLICACIONES_MODELOS."""
    filas = []
    for p in sorted(pubs, key=lambda x: x["fecha_hora"], reverse=True):
        _, equipo = personas.resolver(p["publicado_por"])
        d = p["fecha_hora"].date()
        filas.append({
            "Modelo": p["modelo"],
            "Version": "" if p["version"] is None else str(p["version"]),
            "FechaHoraPublicacion": _dt_txt(p["fecha_hora"]),
            "Fecha": _fecha_txt(d),
            "AnoMes": d.strftime("%Y-%m"),
            "IdPublicacion": p["version_id"],
            "IdModelo": p["urn"],
            "ProyectoConcurso": p["proyecto"],
            "Disciplina": disciplina(p["modelo"]),
            "PublicadoPor": p["publicado_por"] or "Usuario no encontrado",
            "Equipo": equipo,
        })
    return filas


def actividad_diaria(mods, pubs, personas, equipos_incluidos):
    """Filas equivalentes a ACTIVIDAD_DIARIA_MODELOS."""
    dias = {}  # (id, fecha) -> info

    def celda(urn, proyecto, modelo, fecha):
        k = (_id(urn, proyecto, modelo), fecha)
        if k not in dias:
            dias[k] = {"urn": urn or "", "proyecto": proyecto, "modelo": modelo, "fecha": fecha,
                       "mod": 0, "pub": 0, "ultima_sync": None, "usuario": None}
        return dias[k]

    for p in pubs:
        celda(p["urn"], p["proyecto"], p["modelo"], p["fecha_hora"].date())["pub"] = 1

    listado = {}  # usuario -> esta en el Excel (cache)

    def en_listado(u):
        if u not in listado:
            listado[u] = bool(u) and personas.resolver(u)[1] != "SIN EQUIPO"
        return listado[u]

    for r in mods:
        c = celda(r["urn"], r["proyecto"], r["modelo"], r["fecha_hora"].date())
        c["mod"] = 1
        # Responsable = ultima sincronizacion del dia DE UN INTEGRANTE DEL EXCEL. Las de personas
        # fuera del listado no cuentan: si alguien de fuera sincroniza despues, no borra el dia
        # del integrante que si trabajo el modelo.
        if not en_listado(r["usuario"]):
            continue
        if c["ultima_sync"] is None or r["fecha_hora"] > c["ultima_sync"]:
            c["ultima_sync"], c["usuario"] = r["fecha_hora"], r["usuario"]

    filas = []
    for c in dias.values():
        mod, pub = c["mod"], c["pub"]
        estado = ("CUMPLE" if mod and pub else "INCUMPLE" if mod else
                  "PUBLICACION ADICIONAL" if pub else "INACTIVO")
        # Responsable = ultimo integrante del Excel que sincronizo ese dia (ver arriba)
        responsable, equipo = personas.resolver(c["usuario"]) if c["usuario"] else (None, "SIN EQUIPO")
        # Cuentan TODOS los integrantes del listado (todos sus equipos). Solo se excluye a quien no
        # esta en el Excel (SIN EQUIPO). 'equipos_incluidos' en config.json es un filtro opcional.
        if equipo == "SIN EQUIPO":
            continue
        if equipos_incluidos and equipo not in equipos_incluidos:
            continue
        filas.append({
            "ProyectoConcurso": c["proyecto"],
            "Modelo": c["modelo"],
            "Disciplina": disciplina(c["modelo"]),
            "Responsable Modificacion": responsable,
            "Equipo": equipo,
            "IdModelo": c["urn"],
            "Fecha": _fecha_txt(c["fecha"]),
            "Modificado": mod,
            "Publicado": pub,
            "EstadoDia": estado,
            "MetaPublicacion": 1 if mod else 0,
            "PublicacionCumplida": 1 if mod and pub else 0,
            "LlaveCruce": f"{c['proyecto'].upper()}|{modelo_key(c['modelo'])}|{c['fecha'].isoformat()}",
        })
    filas.sort(key=lambda f: (f["ProyectoConcurso"], f["Modelo"]))
    filas.sort(key=lambda f: f["Fecha"], reverse=True)
    log.info("Actividad diaria: %d filas (%d modelo-dia antes del filtro de equipos)", len(filas), len(dias))
    return filas
