#!/bin/sh
set -eu

# Source the common functions
. ./common.sh

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