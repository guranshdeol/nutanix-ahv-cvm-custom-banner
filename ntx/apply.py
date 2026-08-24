from __future__ import annotations

import csv
import shlex
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import paramiko

from ntx.common import log
from ntx.discover import BannerTarget

_REMOTE_SCRIPT_NAME = "apply-banner.sh"


@dataclass
class ApplyResult:
    cluster: str
    kind: str
    aos_version: str
    ssh_host: str
    status: str
    detail: str


def _connect(host: str, user: str, password: str, timeout: int = 30) -> paramiko.SSHClient:
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(
        hostname=host,
        username=user,
        password=password,
        timeout=timeout,
        allow_agent=False,
        look_for_keys=False,
    )
    return client


def _run(client: paramiko.SSHClient, command: str, timeout: int = 300) -> tuple[int, str]:
    last: Exception | None = None
    for attempt in range(4):
        try:
            stdin, stdout, stderr = client.exec_command(command, timeout=timeout)
            try:
                out = stdout.read().decode("utf-8", errors="replace")
                err = stderr.read().decode("utf-8", errors="replace")
                code = stdout.channel.recv_exit_status()
                text = out.strip()
                if code != 0 and err.strip():
                    text = (text + "\n" + err.strip()).strip()
                return code, text
            finally:
                stdin.close()
                stdout.close()
                stderr.close()
        except paramiko.ssh_exception.ChannelException as exc:
            last = exc
            time.sleep(0.6 * (attempt + 1))
    raise last or RuntimeError("SSH exec failed")


def _put_file(client: paramiko.SSHClient, local: Path, remote: str) -> None:
    """Write a local file onto the CVM over the exec channel.

    These CVMs accept SSH exec but reject the SFTP subsystem
    (ChannelException: Connect failed). Do not open SFTP first — a failed
    subsystem open also burns the tight MaxSessions limit.
    """
    data = local.read_bytes()
    quoted = remote.replace("'", "'\\''")
    last: Exception | None = None
    for attempt in range(4):
        try:
            stdin, stdout, stderr = client.exec_command(f"cat > '{quoted}'")
            try:
                stdin.channel.sendall(data)
                stdin.channel.shutdown_write()
                code = stdout.channel.recv_exit_status()
                if code != 0:
                    err = (stdout.read() + stderr.read()).decode("utf-8", errors="replace")
                    raise RuntimeError(f"upload {remote} failed: {err.strip()}")
                return
            finally:
                stdin.close()
                stdout.close()
                stderr.close()
        except paramiko.ssh_exception.ChannelException as exc:
            last = exc
            time.sleep(0.6 * (attempt + 1))
    raise last or RuntimeError(f"upload {remote} failed")


def apply_banner(
    target: BannerTarget,
    ssh_user: str,
    ssh_password: str,
    banner_file: Path,
    remote_script: Path,
    what_if: bool,
) -> ApplyResult:
    result = ApplyResult(
        cluster=target.name,
        kind=target.kind,
        aos_version=target.aos_version,
        ssh_host=target.ssh_host or "",
        status="failed",
        detail="",
    )
    if not target.allowed:
        result.status = "skipped"
        result.detail = target.reason
        return result
    if not target.ssh_host:
        result.detail = "No CVM / PC VM IP to SSH to."
        return result

    mode = "whatif" if what_if else "apply"
    log(f"{'WhatIf' if what_if else 'Apply'} {target.name} ({target.kind}) via {target.ssh_host}")

    client = None
    try:
        client = _connect(target.ssh_host, ssh_user, ssh_password)
        code, out = _run(client, 'mkdir -p "$HOME/tmp" && printf %s "$HOME"')
        if code != 0:
            result.detail = f"SSH failed: {out}"
            return result
        home = out.strip() or "/home/nutanix"
        remote_tmp = f"{home}/tmp"
        _put_file(client, banner_file, f"{remote_tmp}/DODbanner")
        _put_file(client, remote_script, f"{remote_tmp}/{_REMOTE_SCRIPT_NAME}")
        remote_script_path = f"{remote_tmp}/{_REMOTE_SCRIPT_NAME}"
        inner = (
            f"chmod +x {shlex.quote(remote_script_path)} && "
            f"bash {shlex.quote(remote_script_path)} {mode} {target.kind}"
        )
        code, out = _run(client, f"bash -lc {shlex.quote(inner)}", timeout=300)
        result.detail = out
        result.status = ("whatif" if what_if else "changed") if code == 0 else "failed"
        return result
    except Exception as exc:
        result.detail = str(exc)
        return result
    finally:
        if client:
            client.close()


def export_report(rows: list[ApplyResult], output_dir: Path) -> Path:
    output_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d_%H-%M-%S")
    path = output_dir / f"banner-report_{stamp}.csv"
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(["Cluster", "Kind", "AosVersion", "SshHost", "Status", "Detail"])
        for r in rows:
            writer.writerow([r.cluster, r.kind, r.aos_version, r.ssh_host, r.status, r.detail])
    return path
