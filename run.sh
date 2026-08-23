#!/usr/bin/env bash
# Linux / macOS launcher — Python engine only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "=============================================================="
echo "  Nutanix SSH consent banner"
echo "=============================================================="
echo "  This host is not Windows — PowerShell is not offered."
echo "  Engine: Python"
echo

find_python() {
  local c
  for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1; then
      if "$c" -c 'import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)' 2>/dev/null; then
        command -v "$c"
        return 0
      fi
    fi
  done
  return 1
}

pkg_install() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "Need root or sudo to install packages: $*"
    return 1
  fi
}

install_python() {
  local os
  os="$(uname -s)"
  echo "Installing Python 3 ..."
  if [[ "$os" == Darwin ]]; then
    if command -v brew >/dev/null 2>&1; then
      brew install python3
      return 0
    fi
    echo "Homebrew is not installed. Install Python 3 from https://www.python.org or install Homebrew, then re-run."
    return 1
  fi

  if command -v apt-get >/dev/null 2>&1; then
    pkg_install apt-get update
    pkg_install env DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv python3-pip
    return 0
  fi
  if command -v dnf >/dev/null 2>&1; then
    pkg_install dnf install -y python3 python3-pip
    return 0
  fi
  if command -v yum >/dev/null 2>&1; then
    pkg_install yum install -y python3 python3-pip
    return 0
  fi
  if command -v zypper >/dev/null 2>&1; then
    pkg_install zypper --non-interactive install python3 python3-pip python3-venv
    return 0
  fi

  echo "No supported package manager found (apt, dnf, yum, zypper, or brew)."
  echo "Install Python 3 yourself, then re-run this launcher."
  return 1
}

VENV="$ROOT/.venv"
if [[ "$(uname -s)" == "MINGW"* || "$(uname -s)" == "CYGWIN"* || "$(uname -s)" == "MSYS"* ]]; then
  VENV_PY="$VENV/Scripts/python.exe"
else
  VENV_PY="$VENV/bin/python"
fi

python_deps_ok() {
  local exe="$1"
  "$exe" -c "import requests, paramiko" >/dev/null 2>&1
}

start_tui() {
  local exe="$1"
  exec "$exe" "$ROOT/banner.py"
}

PY=""
NEED_PY=0
if PY="$(find_python)"; then
  :
else
  PY=""
  NEED_PY=1
fi

if [[ -x "$VENV_PY" ]] && python_deps_ok "$VENV_PY"; then
  start_tui "$VENV_PY"
fi

if [[ -n "$PY" ]] && python_deps_ok "$PY"; then
  start_tui "$PY"
fi

echo "Python runtime or packages are missing (need: Python 3, requests, urllib3, paramiko)."
echo
echo "DISCLAIMER"
echo "  If you continue, this launcher will:"
if [[ "$NEED_PY" -eq 1 ]]; then
  echo "    - Install Python 3 via apt, dnf, yum, zypper, or Homebrew (needs sudo on Linux)"
fi
echo "    - Create a local virtual environment at:"
echo "        $VENV"
echo "    - Run: pip install -r requirements.txt"
echo "  That downloads software from the internet / OS package repos."
echo
read -r -p "Install missing Python / packages now? (y/N) " ans
case "$ans" in
  y|Y|yes|YES)
    if [[ "$NEED_PY" -eq 1 ]]; then
      install_python
      hash -r
      if ! PY="$(find_python)"; then
        echo "Python 3 is still not on PATH after the install. Open a new shell and re-run."
        exit 1
      fi
      echo "  Using $PY"
    fi
    "$PY" -m venv "$VENV"
    "$VENV_PY" -m pip install --upgrade pip
    "$VENV_PY" -m pip install -r "$ROOT/requirements.txt"
    if ! python_deps_ok "$VENV_PY"; then
      echo "Install finished but imports still fail. Check pip output above."
      exit 1
    fi
    start_tui "$VENV_PY"
    ;;
  *)
    echo "Stopped. Missing: Python 3 and/or a venv with requests and paramiko."
    echo "Re-run and answer y, or install them yourself, then start again."
    exit 1
    ;;
esac
