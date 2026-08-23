#!/bin/bash
# Runs ON a CVM (or PC VM). Kind and mode are arguments.
#   $1 = whatif | apply
#   $2 = PE | PC
set -u
MODE="${1:-apply}"
KIND="${2:-PE}"
BANNER_SRC="$HOME/tmp/DODbanner"
CVM_DST="/srv/salt/security/CVM/sshd/DODbanner"
CVM_BAK="/srv/salt/security/CVM/sshd/DODbannerbak"
AHV_DST="/etc/puppet/modules/kvm/files/issue.DoD"
AHV_BAK="/etc/puppet/modules/kvm/files/issue.DoD.bak"

cvm_backup_cmd() {
  if command -v allssh >/dev/null 2>&1; then
    allssh "sudo test -f $CVM_BAK || sudo cp -a $CVM_DST $CVM_BAK"
  else
    sudo test -f "$CVM_BAK" || sudo cp -a "$CVM_DST" "$CVM_BAK"
  fi
}

cvm_stage_cmd() {
  if command -v svmips >/dev/null 2>&1; then
    for i in $(svmips); do
      scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$BANNER_SRC" "$i:$HOME/tmp/DODbanner"
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$i" "sudo cp \$HOME/tmp/DODbanner $CVM_DST; sudo chown root:root $CVM_DST"
    done
  else
    sudo cp "$BANNER_SRC" "$CVM_DST"
    sudo chown root:root "$CVM_DST"
  fi
}

do_ahv_backup() {
  if [ "$KIND" != "PE" ]; then return 0; fi
  hostssh "sudo test -f $AHV_BAK || sudo cp -a $AHV_DST $AHV_BAK"
}

do_ahv_stage() {
  if [ "$KIND" != "PE" ]; then return 0; fi
  for i in $(hostips); do
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$BANNER_SRC" "$i:/tmp/DODbanner"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$i" "sudo cp /tmp/DODbanner $AHV_DST; sudo chown root:root $AHV_DST"
  done
}

read_ahv_ncli() {
  if [ "$KIND" != "PE" ]; then return 0; fi
  ncli cluster get-hypervisor-security-config 2>/dev/null || true
}

set_ahv_banner() {
  if [ "$KIND" != "PE" ]; then return 0; fi
  ncli cluster edit-hypervisor-security-params enable-banner="$1"
}

verify_ahv() {
  if [ "$KIND" != "PE" ]; then return 0; fi
  for i in $(hostips); do
    echo "AHV $i $(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$i" "md5sum $AHV_DST 2>/dev/null || echo missing")"
  done
}

mkdir -p "$HOME/tmp"
if [ ! -f "$BANNER_SRC" ]; then
  echo "MISSING_BANNER $BANNER_SRC"
  exit 2
fi
sudo chown nutanix:nutanix "$BANNER_SRC" 2>/dev/null || true

echo "=== KIND=$KIND MODE=$MODE ==="
echo "=== CVM ncli (before) ==="
ncli cluster get-cvm-security-config 2>/dev/null || echo "CVM_NCLI_UNAVAILABLE"
echo "=== AHV ncli (before) ==="
read_ahv_ncli
echo "=== checksums (before) ==="
md5sum "$CVM_DST" 2>/dev/null || echo "CVM file missing"
verify_ahv

if [ "$MODE" = "whatif" ]; then
  echo "=== WHATIF planned ==="
  echo "ncli cluster edit-cvm-security-params enable-banner=false"
  if [ "$KIND" = "PE" ]; then
    echo "ncli cluster edit-hypervisor-security-params enable-banner=false"
    echo "allssh backup CVM DODbanner"
    echo "hostssh backup AHV issue.DoD"
    echo "stage CVM Salt + AHV Puppet"
    echo "ncli enable-banner=true (CVM + AHV)"
  else
    echo "backup CVM DODbanner"
    echo "stage CVM Salt only"
    echo "ncli enable-banner=true (CVM only)"
  fi
  exit 0
fi

set -e
echo "=== disable CVM banner ==="
ncli cluster edit-cvm-security-params enable-banner=false
echo "=== disable AHV banner ==="
set_ahv_banner false

echo "=== backup ==="
cvm_backup_cmd
do_ahv_backup

echo "=== stage files ==="
cvm_stage_cmd
do_ahv_stage

echo "=== enable CVM banner ==="
ncli cluster edit-cvm-security-params enable-banner=true
echo "=== enable AHV banner ==="
set_ahv_banner true

echo "=== CVM ncli (after) ==="
ncli cluster get-cvm-security-config 2>/dev/null || true
echo "=== AHV ncli (after) ==="
read_ahv_ncli
echo "=== checksums (after) ==="
md5sum "$CVM_DST" 2>/dev/null || echo "CVM file missing"
if command -v svmips >/dev/null 2>&1; then
  for i in $(svmips); do
    echo "CVM $i $(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$i" "md5sum $CVM_DST 2>/dev/null || echo missing")"
  done
fi
verify_ahv
echo "=== DONE ==="
