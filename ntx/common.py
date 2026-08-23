from __future__ import annotations

import re
from typing import Any


def log(message: str, level: str = "INFO") -> None:
    print(f"[{level}] {message}")


def get_prop(obj: Any, path: str, default: Any = None) -> Any:
    current = obj
    for segment in path.split("."):
        if current is None:
            return default
        if isinstance(current, dict):
            if segment not in current:
                return default
            current = current[segment]
            continue
        current = getattr(current, segment, None)
        if current is None:
            return default
    return default if current is None else current


def get_prop_text(obj: Any, path: str, default: str = "NA") -> str:
    value = get_prop(obj, path, None)
    if value is None:
        return default
    if isinstance(value, (list, tuple)):
        joined = ", ".join(str(x) for x in value)
        return joined if joined.strip() else default
    text = str(value).strip()
    return text if text else default


def ip_value(obj: Any) -> str | None:
    if obj is None:
        return None
    if isinstance(obj, str):
        return obj or None
    for path in ("value", "ipv4.value", "ipv6.value"):
        v = get_prop(obj, path, None)
        if v:
            return str(v)
    return None


def aos_file_banner_supported(version: str) -> tuple[bool, str]:
    """Allow AOS before 7.6. Refuse 7.6 and newer."""
    if not version or version == "NA":
        return True, ""
    m = re.match(r"(\d+)\.(\d+)", version)
    if not m:
        return True, ""
    major, minor = int(m.group(1)), int(m.group(2))
    if major > 7 or (major == 7 and minor >= 6):
        return False, (
            f"AOS {version} is 7.6 or newer; file banner edits are deprecated. "
            "Use the Prism Central v4 Security Configs API (out of scope here)."
        )
    return True, ""
