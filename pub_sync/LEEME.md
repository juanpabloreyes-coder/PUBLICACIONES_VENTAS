# pub_sync: PUBLICACIONES_VENTAS sin Power BI

Genera el mismo `Data\PUBLICACIONES_VENTAS.json` y el mismo `Dashboard\Publicaciones-Modelos-Report.html`
que `Export-PUBLICACIONES_VENTAS.ps1`, pero leyendo las fuentes directamente:

```
Forma (APS Data Management) -> versiones de cada .rvt en 011_WIP   = PUBLICACIONES
RevitSyncLog\*.csv           -> sincronizaciones exitosas             = MODIFICACIONES
Equipos e integrantes - VENTAS.xlsx -> responsable y equipo
```

## Requisitos
- Python y las librerias de PLANOS_VENTAS (`requests`, `openpyxl`).
- Variables de entorno `APS_CLIENT_ID` / `APS_CLIENT_SECRET` (las mismas de PLANOS_VENTAS).

## Uso (desde la carpeta PUBLICACIONES_VENTAS)
```
python -m pub_sync diagnostico   # no escribe nada: muestra conteos y avisos
python -m pub_sync run           # genera JSON + HTML  (o doble clic en Generar-Reporte-PUBLICACIONES.cmd)
```

## Reglas (iguales a las consultas de Power BI)
- Modelo-dia: Modificado (sync exitosa) / Publicado (version nueva en Forma).
  CUMPLE, INCUMPLE, PUBLICACION ADICIONAL. Meta = Modificado; Cumplida = Modificado y Publicado.
- Responsable = usuario de la ultima sync del dia, cruzado con el Excel (alias en `config.json`).
- Solo se reportan los equipos de `equipos_incluidos` (Diseño A, B y D).
- Disciplina por palabras en el nombre del archivo (ARQ, EST, ELE, ESP, MEC, PLO).

## Diferencias con Power BI
- El cruce Revit <-> Forma es por URN del modelo, no por nombre. El proyecto sale de la carpeta de Forma,
  asi que ya no hace falta la tabla fija de URNs ni `_modelos_duplicados.json`.
  Los CSV historicos (sin URN) se resuelven por Proyecto + Nombre.
- El nombre del modelo va siempre sin `.rvt` (antes se mezclaba y un mismo modelo salia dos veces).
- Las versiones ya descargadas se guardan en `cache\versiones_forma.json`; solo se vuelven a pedir
  si el .rvt tiene una version nueva.
- Si algo falla o no hay datos, se conservan el JSON y el HTML anteriores.
