from __future__ import annotations

from dataclasses import dataclass, field

from ntx.common import aos_file_banner_supported, get_prop, get_prop_text, ip_value
from ntx.rest import PcSession


@dataclass
class BannerTarget:
    name: str
    ext_id: str | None
    kind: str
    aos_version: str
    allowed: bool
    reason: str
    vip: str | None
    cvm_ips: list[str] = field(default_factory=list)
    ahv_ips: list[str] = field(default_factory=list)
    ssh_host: str | None = None


def discover_targets(session: PcSession) -> list[BannerTarget]:
    clusters = session.list_all(session.path("config/clusters"))
    if not clusters:
        raise RuntimeError("No clusters returned from Prism Central.")

    targets: list[BannerTarget] = []
    for c in clusters:
        name = get_prop_text(c, "name")
        ext_id = get_prop(c, "extId")
        version = get_prop_text(c, "config.buildInfo.version")
        functions = get_prop(c, "config.clusterFunction") or []
        if not isinstance(functions, list):
            functions = [functions]
        is_pc = any(str(x) == "PRISM_CENTRAL" for x in functions)
        kind = "PC" if is_pc else "PE"
        allowed, reason = aos_file_banner_supported(version)

        vip = ip_value(get_prop(c, "network.externalAddress"))
        cvm_ips: list[str] = []
        ahv_ips: list[str] = []

        if ext_id:
            hosts = session.list_all(session.path(f"config/clusters/{ext_id}/hosts"))
            for h in hosts:
                cvm = ip_value(get_prop(h, "controllerVm.externalAddress"))
                ahv = ip_value(get_prop(h, "hypervisor.externalAddress"))
                if cvm:
                    cvm_ips.append(cvm)
                if ahv and not is_pc:
                    ahv_ips.append(ahv)

        if vip and vip not in cvm_ips:
            cvm_ips.insert(0, vip)
        if is_pc and not cvm_ips:
            cvm_ips.append(session.host)

        ssh_host = cvm_ips[0] if cvm_ips else vip
        targets.append(
            BannerTarget(
                name=name,
                ext_id=str(ext_id) if ext_id else None,
                kind=kind,
                aos_version=version,
                allowed=allowed,
                reason=reason,
                vip=vip,
                cvm_ips=cvm_ips,
                ahv_ips=ahv_ips,
                ssh_host=ssh_host,
            )
        )
    return targets
