from __future__ import annotations

import time
from typing import Any
import requests
import urllib3

from ntx.common import log

_CANDIDATES = ("v4.0", "v4.1", "v4.2", "v4.3")


class PrismApiError(Exception):
    def __init__(self, method: str, path: str, status: int, body: str):
        self.status = status
        super().__init__(f"{method} {path} -> HTTP {status}: {body[:800]}")


class PcSession:
    def __init__(
        self,
        host: str,
        user: str,
        secret: str | None = None,
        auth_mode: str = "basic",
        port: int = 9440,
        timeout: int = 120,
    ):
        pc_host = host
        if ":" in host and not host.startswith("["):
            left, maybe_port = host.rsplit(":", 1)
            if maybe_port.isdigit():
                pc_host, port = left, int(maybe_port)

        if auth_mode == "basic" and not secret:
            raise ValueError("Password is required for basic auth.")

        self.host = pc_host
        self.port = port
        self.base = f"https://{pc_host}:{port}/api"
        self.timeout = timeout
        self.version: str | None = None

        self.http = requests.Session()
        self.http.verify = False
        self.http.headers["Accept"] = "application/json"
        if auth_mode == "api_key":
            self.http.headers["X-ntnx-api-key"] = user
        else:
            self.http.auth = (user, secret or "")
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
        self._pin_clustermgmt()

    def _pin_clustermgmt(self) -> None:
        for v in _CANDIDATES:
            try:
                self.get(f"clustermgmt/{v}/config/clusters", params={"$limit": 1})
                self.version = v
                log(f"clustermgmt -> {v}")
                return
            except PrismApiError:
                continue
        raise PrismApiError("GET", "clustermgmt/*/config/clusters", 0, "no v4 minor answered")

    def path(self, suffix: str) -> str:
        if not self.version:
            raise RuntimeError("clustermgmt version is not pinned.")
        return f"clustermgmt/{self.version}/{suffix}"

    def get(self, path: str, params: dict | None = None) -> Any:
        url = f"{self.base}/{path.lstrip('/')}"
        last_err: Exception | None = None
        for attempt in range(5):
            resp = self.http.get(url, params=params, timeout=self.timeout)
            if resp.status_code in (429, 503):
                time.sleep(min(30, 2 ** (attempt + 1)))
                continue
            if not resp.ok:
                last_err = PrismApiError("GET", path, resp.status_code, resp.text)
                if resp.status_code >= 500 and attempt < 4:
                    time.sleep(1)
                    continue
                raise last_err
            if not resp.text:
                return None
            return resp.json().get("data")
        if last_err:
            raise last_err
        return None

    def list_all(self, path: str, orderby: str | None = None, limit: int = 100) -> list[Any]:
        out: list[Any] = []
        page = 0
        while True:
            params: dict[str, Any] = {"$page": page, "$limit": limit}
            if orderby:
                params["$orderby"] = orderby
            try:
                data = self.get(path, params=params)
            except PrismApiError:
                break
            if not data:
                break
            batch = data if isinstance(data, list) else [data]
            out.extend(batch)
            if len(batch) < limit:
                break
            page += 1
        return out
