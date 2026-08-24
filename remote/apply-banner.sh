#!/bin/bash
# Runs ON a CVM (or PC VM). Kind and mode are arguments.
#   $1 = whatif | apply
#   $2 = PE | PC
# Non-login SSH has a bare PATH; load the CVM tool locations first.
if [ -f /etc/profile ]; then
  set +u
  # shellcheck disable=SC1091
  . /etc/profile
fi
export PATH="/home/nutanix/prism/cli:/usr/local/nutanix/cluster/bin:/usr/local/nutanix/bin:${PATH:-/usr/bin:/bin}"
set -u
MODE="${1:-apply}"
KIND="${2:-PE}"
BANNER_SRC="$HOME/tmp/DODbanner"
CVM_DST="/srv/salt/security/CVM/sshd/DODbanner"
CVM_BAK="/srv/salt/security/CVM/sshd/DODbannerbak"
AHV_DST="/etc/puppet/modules/kvm/files/issue.DoD"
AHV_BAK="/etc/puppet/modules/kvm/files/issue.DoD.bak"
# Nested ssh/scp otherwise print the AHV pre-auth banner on stderr.
SSH_Q="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

cvm_md5() {
  # Salt file is root:root; nutanix md5sum looks like "missing".
  sudo md5sum "$CVM_DST" 2>/dev/null || echo "CVM file missing"
}

cvm_ip_list() {
  if command -v svmips >/dev/null 2>&1; then
    svmips
  fi
}

cvm_count() {
  # shellcheck disable=SC2046
  set -- $(cvm_ip_list)
  echo "$#"
}

# Single-node PE: allssh/svmips only see this CVM. Copy locally.
# Multi-CVM: allssh if present, otherwise ssh/scp to each svmips address.
cvm_backup_cmd() {
  if command -v allssh >/dev/null 2>&1; then
    allssh "sudo test -f $CVM_BAK || sudo cp -a $CVM_DST $CVM_BAK"
    return
  fi
  if [ "$(cvm_count)" -gt 1 ]; then
    for i in $(cvm_ip_list); do
      # shellcheck disable=SC2086
      ssh $SSH_Q "$i" \
        "sudo test -f $CVM_BAK || sudo cp -a $CVM_DST $CVM_BAK"
    done
    return
  fi
  sudo test -f "$CVM_BAK" || sudo cp -a "$CVM_DST" "$CVM_BAK"
}

cvm_stage_cmd() {
  if [ "$(cvm_count)" -gt 1 ]; then
    for i in $(cvm_ip_list); do
      # shellcheck disable=SC2086
      scp $SSH_Q "$BANNER_SRC" "$i:$HOME/tmp/DODbanner"
      # shellcheck disable=SC2086
      ssh $SSH_Q "$i" "sudo cp \$HOME/tmp/DODbanner $CVM_DST; sudo chown root:root $CVM_DST"
    done
    return
  fi
  sudo cp "$BANNER_SRC" "$CVM_DST"
  sudo chown root:root "$CVM_DST"
}

do_ahv_backup() {
  if [ "$KIND" != "PE" ]; then return 0; fi
  hostssh "sudo test -f $AHV_BAK || sudo cp -a $AHV_DST $AHV_BAK"
}

do_ahv_stage() {
  if [ "$KIND" != "PE" ]; then return 0; fi
  # scp as nutanix can write /tmp. sudo over plain ssh needs a TTY/password
  # on this AHV; hostssh (same path as backup) does not.
  for i in $(hostips); do
    # shellcheck disable=SC2086
    scp $SSH_Q "$BANNER_SRC" "$i:/tmp/DODbanner"
  done
  hostssh "sudo cp /tmp/DODbanner $AHV_DST && sudo chown root:root $AHV_DST"
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
    # shellcheck disable=SC2086
    echo "AHV $i $(ssh $SSH_Q "$i" "sudo md5sum $AHV_DST 2>/dev/null || echo missing")"
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
cvm_md5
verify_ahv

if [ "$MODE" = "whatif" ]; then
  echo "=== WHATIF planned ==="
  echo "ncli cluster edit-cvm-security-params enable-banner=false"
  if [ "$KIND" = "PE" ]; then
    echo "ncli cluster edit-hypervisor-security-params enable-banner=false"
    echo "backup CVM DODbanner (allssh, or this CVM on a single-node)"
    echo "hostssh backup AHV issue.DoD"
    echo "stage CVM Salt + AHV Puppet (this CVM / this AHV on a single-node)"
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
cvm_md5
if [ "$(cvm_count)" -gt 1 ]; then
  for i in $(cvm_ip_list); do
    # shellcheck disable=SC2086
    echo "CVM $i $(ssh $SSH_Q "$i" "sudo md5sum $CVM_DST 2>/dev/null || echo missing")"
  done
else
  echo "CVM this-node $(cvm_md5)"
fi
verify_ahv
echo "=== DONE ==="
