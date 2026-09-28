"""PUBLICACIONES_VENTAS sin Power BI.

Uso (desde la carpeta PUBLICACIONES_VENTAS):
  python -m pub_sync run          # lee Forma + RevitSyncLog + Excel y genera Data\\*.json y Dashboard\\*.html
  python -m pub_sync diagnostico  # igual, pero NO escribe nada: imprime conteos y avisos

Credenciales: las mismas de PLANOS_VENTAS (variables de entorno APS_CLIENT_ID / APS_CLIENT_SECRET).
"""
import argparse
import json
import logging
import os
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

from .aps import APS
from .fuentes import Personas, leer_equipos, leer_forma, leer_revit
from .actividad import actividad_diaria, historial, resolver_modificaciones
from .reporte import escribir

RAIZ = Path(__file__).resolve().parent.parent
FUENTE = "APS (Forma) + RevitSyncLog"


def _ruta(v):
    p = Path(v)
    return p if p.is_absolute() else RAIZ / p


def _log_automation(msg):
    try:
        with open(RAIZ / "Automation" / "automation.log", "a", encoding="utf-8") as f:
            f.write(f"{datetime.now():%Y-%m-%d %H:%M:%S}  PUBSYNC  {msg}\n")
    except Exception:
        pass


def procesar(cfg, escribir_salida=True):
    tz = timezone(timedelta(hours=cfg.get("zona_horaria_utc", -6)))
    avisos = []

    cid, sec = os.environ.get("APS_CLIENT_ID"), os.environ.get("APS_CLIENT_SECRET")
    if not cid or not sec:
        raise SystemExit("Falta APS_CLIENT_ID / APS_CLIENT_SECRET (las mismas variables que usa PLANOS_VENTAS).")
    modelos, pubs, av = leer_forma(APS(cid, sec), cfg, tz, _ruta(cfg.get("cache", "cache/versiones_forma.json")))
    avisos += av

    mods = leer_revit(_ruta(cfg.get("revit_sync_log", "RevitSyncLog")), tz)
    mods, av = resolver_modificaciones(mods, modelos)
    avisos += av

    xlsx = _ruta(cfg["equipos_xlsx"])
    if xlsx.exists():
        personas = Personas(leer_equipos(xlsx, cfg.get("equipos_hoja", "Integrantes")), cfg.get("alias_personas"))
    else:
        avisos.append(f"No se encontro el Excel de equipos: {xlsx}. Todos quedan SIN EQUIPO.")
        personas = Personas([], cfg.get("alias_personas"))

    hist = historial(pubs, personas)
    act = actividad_diaria(mods, pubs, personas, set(cfg.get("equipos_incluidos") or []))

    estados = Counter(a["EstadoDia"] for a in act)
    print(f"Forma: {len(modelos)} modelos .rvt, {len(pubs)} publicaciones")
    print(f"Revit: {len(mods)} sincronizaciones exitosas")
    print(f"Actividad diaria: {len(act)} filas  {dict(estados)}")
    for a in avisos:
        print("AVISO:", a)

    if not escribir_salida:
        return "DIAGNOSTICO: no se escribio ningun archivo."
    return escribir(act, hist, avisos,
                    _ruta(cfg.get("json", "Data/PUBLICACIONES_VENTAS.json")),
                    _ruta(cfg.get("plantilla", "Dashboard/Publicaciones-Modelos-Report.template.html")),
                    _ruta(cfg.get("html", "Dashboard/Publicaciones-Modelos-Report.html")),
                    FUENTE)


def main():
    ap = argparse.ArgumentParser(prog="pub_sync")
    ap.add_argument("cmd", choices=["run", "diagnostico"])
    ap.add_argument("--config", default=str(RAIZ / "config.json"))
    a = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    cfg = json.loads(Path(a.config).read_text(encoding="utf-8"))
    try:
        estado = procesar(cfg, escribir_salida=(a.cmd == "run"))
    except SystemExit:
        raise
    except Exception as e:
        _log_automation(f"ERROR: {e}. Se conservan el JSON y el HTML anteriores.")
        print(f"\nERROR: {e}\nSe conservan el JSON y el HTML anteriores.", file=sys.stderr)
        sys.exit(2)
    print("\n" + estado)
    if a.cmd == "run":
        _log_automation(estado)


if __name__ == "__main__":
    main()
