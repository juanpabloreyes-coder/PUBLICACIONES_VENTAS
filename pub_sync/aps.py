"""Cliente minimo de APS (Data Management) para leer las versiones de los .rvt en Forma/ACC.

Misma autenticacion que PLANOS_VENTAS: 2-legged, credenciales en las variables de entorno
APS_CLIENT_ID / APS_CLIENT_SECRET, y la app registrada como Custom Integration en ACC.
Solo necesita el scope data:read.
"""
import logging
import time
from urllib.parse import quote

import requests

BASE = "https://developer.api.autodesk.com"
log = logging.getLogger("pub_sync.aps")


class APSError(RuntimeError):
    pass


class APS:
    def __init__(self, client_id, client_secret, scope="data:read"):
        self.cid, self.secret, self.scope = client_id, client_secret, scope
        self._tok, self._exp = None, 0
        self.s = requests.Session()

    # -- auth / http -------------------------------------------------
    def token(self):
        if self._tok and time.time() < self._exp - 60:
            return self._tok
        r = requests.post(f"{BASE}/authentication/v2/token", auth=(self.cid, self.secret),
                          data={"grant_type": "client_credentials", "scope": self.scope}, timeout=60)
        if r.status_code != 200:
            raise APSError(f"Autenticacion APS fallo ({r.status_code}): {r.text[:300]}")
        j = r.json()
        self._tok, self._exp = j["access_token"], time.time() + int(j.get("expires_in", 3000))
        return self._tok

    def get(self, url, retries=5):
        if url.startswith("/"):
            url = BASE + url
        for i in range(retries):
            r = self.s.get(url, headers={"Authorization": f"Bearer {self.token()}"}, timeout=120)
            if r.status_code == 200:
                return r.json()
            if r.status_code in (429, 500, 502, 503, 504):
                time.sleep(min(2 ** i * 2, 60))
                continue
            raise APSError(f"GET {url} -> {r.status_code}: {r.text[:300]}")
        raise APSError(f"GET {url}: demasiados reintentos")

    def _paginas(self, url):
        while url:
            j = self.get(url)
            yield j
            url = (j.get("links", {}).get("next") or {}).get("href")

    # -- Data Management ---------------------------------------------
    @staticmethod
    def con_b(guid):
        return guid if guid.startswith("b.") else "b." + guid

    def top_folders(self, hub, pid):
        j = self.get(f"/project/v1/hubs/{quote(hub, safe='')}/projects/{quote(pid, safe='')}/topFolders")
        return [{"id": d["id"], "name": _nombre(d)} for d in j.get("data", [])]

    def contenido(self, pid, folder_id):
        """-> (subcarpetas, items) directos de una carpeta.
        items: {item_id, name, tip_version}"""
        carpetas, items = [], []
        url = f"/data/v1/projects/{pid}/folders/{quote(folder_id, safe='')}/contents?page[limit]=200"
        for j in self._paginas(url):
            inc = {i["id"]: i for i in j.get("included", [])}
            for d in j.get("data", []):
                if d["type"] == "folders":
                    carpetas.append({"id": d["id"], "name": _nombre(d)})
                elif d["type"] == "items":
                    tip_id = ((d.get("relationships", {}).get("tip") or {}).get("data") or {}).get("id")
                    tip = inc.get(tip_id, {}).get("attributes", {}) if tip_id else {}
                    items.append({"item_id": d["id"], "name": _nombre(d),
                                  "tip_version": tip.get("versionNumber")})
        return carpetas, items

    def versiones(self, pid, item_id):
        """Todas las versiones de un item -> [{version_id, numero, creado, creado_por}]
        Cada 'Publish' de un modelo colaborativo en la nube crea una version nueva."""
        out = []
        url = f"/data/v1/projects/{pid}/items/{quote(item_id, safe='')}/versions?page[limit]=50"
        for j in self._paginas(url):
            for d in j.get("data", []):
                a = d.get("attributes", {})
                out.append({"version_id": d["id"],
                            "numero": a.get("versionNumber"),
                            "creado": a.get("createTime"),
                            "creado_por": a.get("createUserName") or a.get("lastModifiedUserName")})
        return out


def _nombre(d):
    """Para CARPETAS se usa 'name': cuando una carpeta se renombra en Forma, 'displayName' puede
    quedarse con el nombre anterior (paso con HOWA, que la API seguia reportando como
    'Z_PLANTILLA - copia'). Para archivos se mantiene displayName (nombre visible del archivo)."""
    a = d.get("attributes", {})
    if d.get("type") == "folders":
        nombre, visible = a.get("name") or "", a.get("displayName") or ""
        if nombre and visible and nombre != visible:
            log.debug("Carpeta con dos nombres en la API: name=%r displayName=%r (se usa name)", nombre, visible)
        return nombre or visible
    return a.get("displayName") or a.get("name", "")
