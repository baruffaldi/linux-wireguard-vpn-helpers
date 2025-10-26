#!/bin/sh
set -eu

resolve_realpath() {
  f="$1"
  while [ -L "$f" ]; do f="$(readlink "$f")"; done
  cd "$(dirname "$f")" || exit 1
  pwd -P
}
SCRIPT_PATH="$(resolve_realpath "$0")"

# Load your existing shared functions
if [ -f "${SCRIPT_PATH}/common.sh" ]; then
  . $SCRIPT_PATH/common.sh
else
  printf "\033[31m[ERROR]\033[0m Missing file: %s/common.sh\n" "$SCRIPT_PATH" >&2
  exit 1
fi

header "Alpine Linux System Preparation"

info "Updating and upgrading packages..."
apk update
apk upgrade

# --- Detect if running in a VM ---
IS_VM="no"
if grep -qEi '(hypervisor|virtual)' /proc/cpuinfo 2>/dev/null; then
    IS_VM="yes"
elif [ -f /sys/class/dmi/id/product_name ] && grep -qEi '(vmware|kvm|qemu|virtualbox|hyper-v|xen|bochs)' /sys/class/dmi/id/product_name 2>/dev/null; then
    IS_VM="yes"
elif [ -f /sys/class/dmi/id/sys_vendor ] && grep -qEi '(vmware|kvm|qemu|virtualbox|hyper-v|xen|bochs)' /sys/class/dmi/id/sys_vendor 2>/dev/null; then
    IS_VM="yes"
fi

# --- Install packages ---
info "Installing required packages..."
PACKAGES="wireguard-tools iptables openrc darkhttpd iptables-openrc"

if [ "$IS_VM" = "yes" ]; then
    info "VM detected, adding open-vm-tools..."
    PACKAGES="$PACKAGES open-vm-tools open-vm-tools-guestinfo open-vm-tools-deploypkg"
fi

apk add $PACKAGES

# --- Configure services ---
info "Configuring services to start on boot..."
rc-update add iptables default
rc-update add networking default

success "System preparation complete!"