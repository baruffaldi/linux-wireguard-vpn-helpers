#!/bin/sh
set -eu

apk update
apk upgrade

if grep -qEi '(hypervisor|virtual)' /proc/cpuinfo 2>/dev/null; then
    IS_VM="yes"
elif [ -f /sys/class/dmi/id/product_name ] && grep -qEi '(vmware|kvm|qemu|virtualbox|hyper-v|xen|bochs)' /sys/class/dmi/id/product_name 2>/dev/null; then
    IS_VM="yes"
elif [ -f /sys/class/dmi/id/sys_vendor ] && grep -qEi '(vmware|kvm|qemu|virtualbox|hyper-v|xen|bochs)' /sys/class/dmi/id/sys_vendor 2>/dev/null; then
    IS_VM="yes"
else
    IS_VM="no"
fi


if [ "$IS_VM" = "yes" ]; then
    apk add open-vm-tools open-vm-tools-guestinfo open-vm-tools-deploypkg
fi
apk add wireguard-tools iptables openrc darkhttpd iptables-openrc

rc-update add iptables default
rc-update add networking default
