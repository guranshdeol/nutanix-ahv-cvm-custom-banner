from __future__ import annotations

import getpass
from pathlib import Path

from ntx.apply import ApplyResult, apply_banner, export_report
from ntx.common import log
from ntx.discover import BannerTarget, discover_targets
from ntx.rest import PcSession, PrismApiError


def _banner(title: str) -> None:
    print()
    print("=" * 62)
    print(f"  {title}")
    print("=" * 62)


def _required(prompt: str) -> str:
    while True:
        value = input(f"{prompt}: ").strip()
        if value:
            return value
        print("Value cannot be empty.")


def _line(prompt: str, default: str = "") -> str:
    suffix = f" [{default}]" if default else ""
    value = input(f"{prompt}{suffix}: ").strip()
    return value or default


def _yes_no(prompt: str, default: bool = True) -> bool:
    hint = "Y/n" if default else "y/N"
    while True:
        value = input(f"{prompt} ({hint}): ").strip().lower()
        if not value:
            return default
        if value in ("y", "yes"):
            return True
        if value in ("n", "no"):
            return False


def _secret(prompt: str) -> str:
    while True:
        value = getpass.getpass(f"{prompt}: ")
        if value:
            return value
        print("Value cannot be empty.")


def read_pc() -> dict:
    _banner("Prism Central login")
    pc = _required("Prism Central IP or FQDN")
    print("  Auth: 1 = Basic   2 = API key")
    mode = ""
    while mode not in ("1", "2"):
        mode = input("  Select (1/2): ").strip()
    if mode == "2":
        return {"host": pc, "auth_mode": "api_key", "user": _required("  API key"), "secret": None}
    return {
        "host": pc,
        "auth_mode": "basic",
        "user": _required("  Username"),
        "secret": _secret("  Password"),
    }


def read_banner_file() -> Path:
    _banner("Banner file (SSH pre-auth text)")
    print("This file is not stored in the tool. Point at the banner you already have.")
    while True:
        path = Path(_required("Path to banner file")).expanduser()
        if path.is_file():
            return path.resolve()
        print(f"File not found: {path}")


def show_table(targets: list[BannerTarget]) -> None:
    print()
    print(f"{'#':<4} {'Type':<8} {'Name':<24} {'AOS':<14} File banner")
    print("-" * 72)
    for i, t in enumerate(targets, start=1):
        gate = "ok" if t.allowed else "REFUSE 7.6+"
        print(f"{i:<4} {t.kind:<8} {t.name:<24} {t.aos_version:<14} {gate}")


def select_clusters(targets: list[BannerTarget]) -> list[BannerTarget]:
    _banner("Discovered clusters")
    show_table(targets)
    print()
    print("Enter numbers (e.g. 1,3), ALL. 7.6+ rows are marked REFUSE.")
    while True:
        raw = _required("Clusters")
        if raw.upper() == "ALL":
            return list(targets)
        picked: list[BannerTarget] = []
        ok = True
        for part in raw.split(","):
            try:
                n = int(part.strip())
            except ValueError:
                print(f"Bad selection: {part.strip()}")
                ok = False
                break
            if n < 1 or n > len(targets):
                print(f"Bad selection: {n}")
                ok = False
                break
            picked.append(targets[n - 1])
        if ok and picked:
            return picked


def read_ssh_creds(targets: list[BannerTarget]) -> dict[str, tuple[str, str]]:
    _banner("CVM / PC VM SSH (nutanix)")
    print("Passwords stay in memory only. Nothing is written to disk.")
    creds: dict[str, tuple[str, str]] = {}
    reuse: tuple[str, str] | None = None
    for i, t in enumerate(targets):
        print()
        print(f"[{i + 1}/{len(targets)}] {t.name} ({t.kind})  ssh {t.ssh_host}")
        if reuse and _yes_no("  Use the same SSH user/password as the last cluster?", True):
            creds[t.name] = reuse
            continue
        user = _line("  SSH username", "nutanix")
        password = _secret("  SSH password")
        creds[t.name] = (user, password)
        reuse = (user, password)
        if i < len(targets) - 1 and _yes_no("  Use these CVM creds for all remaining clusters?", False):
            for rest in targets[i + 1 :]:
                creds[rest.name] = (user, password)
            break
    return creds


def read_what_if() -> bool:
    _banner("Run mode")
    print("  1 = WhatIf (read + show plan, no ncli edits, no file writes)")
    print("  2 = Apply  (disable banner, backup, stage, re-enable)")
    choice = ""
    while choice not in ("1", "2"):
        choice = input("Select (1/2): ").strip()
    return choice == "1"


def show_report(rows: list[ApplyResult]) -> None:
    _banner("Result")
    print(f"{'Cluster':<24} {'Type':<6} {'Status':<10} Note")
    print("-" * 72)
    for r in rows:
        note = r.detail.replace("\n", " ")
        if len(note) > 80:
            note = note[:77] + "..."
        print(f"{r.cluster:<24} {r.kind:<6} {r.status:<10} {note}")


def run_tui(root: Path) -> int:
    remote_script = root / "remote" / "apply-umicore-banner.sh"
    output_dir = root / "output"

    _banner("Nutanix SSH consent banner")
    print("  PE: CVM Salt DODbanner + AHV Puppet issue.DoD (AOS before 7.6)")
    print("  PC: CVM ncli + CVM Salt file only (no AHV)")
    print("  Jump host SSHs to one CVM; that CVM fans out with allssh/hostssh/svmips/hostips.")

    pc = read_pc()
    banner_file = read_banner_file()

    log(f"Connecting to {pc['host']} ...")
    try:
        session = PcSession(
            host=pc["host"],
            user=pc["user"],
            secret=pc["secret"],
            auth_mode=pc["auth_mode"],
        )
    except (PrismApiError, ValueError, OSError) as exc:
        log(str(exc), "ERROR")
        return 1

    targets = discover_targets(session)
    selected = select_clusters(targets)
    work = []
    for t in selected:
        if not t.allowed:
            log(f"{t.name}: {t.reason}", "WARN")
        else:
            work.append(t)
    if not work:
        log("Nothing left to do after the AOS 7.6+ gate.", "WARN")
        return 0

    creds = read_ssh_creds(work)
    what_if = read_what_if()
    if not _yes_no("Start WhatIf now?" if what_if else "Apply the banner to the selected clusters now?", True):
        log("Cancelled.")
        return 0

    rows: list[ApplyResult] = []
    for i, t in enumerate(work, start=1):
        log(f"[{i}/{len(work)}] {t.name}")
        user, password = creds[t.name]
        row = apply_banner(t, user, password, banner_file, remote_script, what_if)
        rows.append(row)
        log(f"  {row.status}")
        if row.detail:
            for line in row.detail.splitlines():
                print(f"    {line}")

    show_report(rows)
    report = export_report(rows, output_dir)
    log(f"Report: {report}")
    return 1 if any(r.status == "failed" for r in rows) else 0
