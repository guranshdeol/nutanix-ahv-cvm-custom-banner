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
  if command -v python3 >/dev/null 2>&1; then
    command -v python3
    return
  fi
  if command -v python >/dev/null 2>&1; then
    command -v python
    return
  fi
  return 1
}

if ! PY="$(find_python)"; then
  echo "Python 3 is not installed. Install Python 3, then run this launcher again."
  echo "This launcher does not install the Python interpreter."
  exit 1
fi

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

if [[ -x "$VENV_PY" ]] && python_deps_ok "$VENV_PY"; then
  start_tui "$VENV_PY"
fi

if python_deps_ok "$PY"; then
  start_tui "$PY"
fi

echo "Python packages are missing (need: requests, urllib3, paramiko)."
echo
echo "DISCLAIMER"
echo "  If you continue, this launcher will create a local virtual environment"
echo "  at:"
echo "    $VENV"
echo "  and run: pip install -r requirements.txt"
echo "  System Python is not modified. The Python interpreter is not installed."
echo
read -r -p "Install project dependencies now? (y/N) " ans
case "$ans" in
  y|Y|yes|YES)
    "$PY" -m venv "$VENV"
    "$VENV_PY" -m pip install --upgrade pip
    "$VENV_PY" -m pip install -r "$ROOT/requirements.txt"
    start_tui "$VENV_PY"
    ;;
  *)
    echo "Stopped. Missing: a venv (or current Python) with requests and paramiko."
    echo "Re-run and answer y, or install them yourself, then start again."
    exit 1
    ;;
esac
