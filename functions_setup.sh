#!/bin/sh

# functions_setup.sh
#
# This script provides a set of common functions.

update_system() {
  header "[0] Update packages & repository"

  update_ok=0
  if [ -n "$PKG" ]; then
    info "Updating packages using $PKG ..."
    case "$PKG" in
      apk) sed -i 's/^[[:space:]]*#[[:space:]]*\(https\?:\/\/.*\)$/\1/' /etc/apk/repositories && apk update && apk upgrade -U --available && update_ok=1 ;;
      apt-get) export DEBIAN_FRONTEND=noninteractive; apt-get update -y && apt-get dist-upgrade -y && update_ok=1 ;;
      dnf) dnf -y upgrade && update_ok=1 ;;
      yum) yum -y update && update_ok=1 ;;
      zypper) zypper -n refresh && zypper -n update && update_ok=1 ;;
      pacman) pacman -Syu --noconfirm && update_ok=1 ;;
      opkg) opkg update && opkg upgrade && update_ok=1 ;;
    esac
  else
    warning "Package manager not detected."
  fi
  [ "$update_ok" -eq 1 ] && success "System updated." || warning "Update failed."

  if have_cmd git; then
    if [ -d "$WG_HELPERS_DIR/.git" ]; then
      info "Pulling latest changes..."
      git -C "$WG_HELPERS_DIR" pull --rebase || true
    else
      info "Cloning repo..."
      git clone --depth 1 https://github.com/baruffaldi/linux-wireguard-vpn-helpers "$WG_HELPERS_DIR"
    fi
    success "Repository ready."
    info "Closing setup to apply updates... please re-run setup-vpn after this."
    exit 0
  else
    warning "git not installed; skipping repo update."
  fi
}

change_root_password() {
  header "[1] Change root password"
  ask confirm "Change root password now? (yes/no)" "no"
  [ "$confirm" != "yes" ] && return
  ask_secret p1 "New password"
  ask_secret p2 "Repeat password"
  [ "$p1" != "$p2" ] && { warning "Mismatch."; return; }
  printf "root:%s\n" "$p1" | chpasswd && success "Password updated."
}

show_network_info() {
  header "[2] Network interfaces and routes"
  
  show_network_info_details
}

setup_networking() {
  header "[3] Run network setup"

  # --- Helper per controllare comandi ---
  have_cmd() { command -v "$1" >/dev/null 2>&1; }

  # --- Alpine Linux ---
  if have_cmd setup-interfaces; then
    info "Detected Alpine Linux (setup-interfaces present)."
    setup-interfaces && rc-service networking restart && success "setup-interfaces completed." && return 0
  fi

  # --- Debian/Ubuntu (ifupdown) ---
  if [ -f /etc/network/interfaces ] && have_cmd ifup; then
    info "Detected ifupdown (Debian-like)."
    ifdown -a >/dev/null 2>&1 || true
    ifup -a && success "ifup/ifdown cycle completed." && return 0
  fi

  # --- systemd-networkd ---
  if systemctl list-unit-files | grep -q '^systemd-networkd'; then
    info "Detected systemd-networkd."
    systemctl restart systemd-networkd && success "systemd-networkd restarted." && return 0
  fi

  # --- NetworkManager ---
  if have_cmd nmcli; then
    info "Detected NetworkManager."
    nmcli networking off >/dev/null 2>&1 || true
    sleep 1
    nmcli networking on && success "NetworkManager restarted." && return 0
  fi

  # --- netplan (Ubuntu 18+ / cloud-init) ---
  if have_cmd netplan; then
    info "Detected netplan (Ubuntu-like)."
    netplan apply && success "netplan applied." && return 0
  fi

  # --- Arch Linux (netctl) ---
  if have_cmd netctl; then
    info "Detected netctl (Arch-based)."
    netctl restart-all && success "netctl restarted." && return 0
  fi

  # --- fallback generico ---
  if have_cmd systemctl; then
    info "Trying generic network service restart via systemctl..."
    if systemctl list-units | grep -q 'network'; then
      systemctl restart network* && success "network services restarted." && return 0
    fi
  fi

  warning "Unable to detect a known network manager. Please reconfigure manually."
}

install_vpn_prereq() {
  header "[5] Run VPN installer"
  INSTALLER=""
  [ -x "$WG_HELPERS_DIR/sys_prepare_${OS_ID}.sh" ] && INSTALLER="$WG_HELPERS_DIR/sys_prepare_${OS_ID}.sh"
  [ -z "$INSTALLER" ] && [ -x "$WG_HELPERS_DIR/sys_prepare_common.sh" ] && INSTALLER="$WG_HELPERS_DIR/sys_prepare_common.sh"

  if [ -n "$INSTALLER" ] && [ -x "$INSTALLER" ]; then
    info "Executing $INSTALLER..."
    sh "$INSTALLER"
  else
    warning "Installer script not found."
  fi
}

ddns_configure() {
  header "[6] Configure Dynamic DNS"
  if [ -x "$WG_HELPERS_DIR/wg_ddns_configure.sh" ]; then
    sh "$WG_HELPERS_DIR/wg_ddns_configure.sh"
  else
    warning "DDNS configurator not found."
  fi
}

server_configure() {
  header "[6] Configure VPN server"
  if [ -x "$WG_HELPERS_DIR/wg_server_configure.sh" ]; then
    sh "$WG_HELPERS_DIR/wg_server_configure.sh"
  else
    warning "Server configurator not found."
  fi
}

client_configure() {
  header "[7] Configure VPN client"
  if [ -x "$WG_HELPERS_DIR/wg_client_configure.sh" ]; then
    sh "$WG_HELPERS_DIR/wg_client_configure.sh"
  else
    warning "Client configurator not found."
  fi
}

filter_configure() {
  header "[8] Configure VPN filter"
  if [ -x "$WG_HELPERS_DIR/wg_filter_configure.sh" ]; then
    sh "$WG_HELPERS_DIR/wg_filter_configure.sh"
  else
    warning "Filter configurator not found."
  fi
}

generate_report() {
  header "[9] Generate report"
  echo "Step,Status,Details,Timestamp" > "$REPORT_PATH"

  PUBLIC_IP=""
  if have_cmd curl; then
    PUBLIC_IP=$(curl -s https://ifconfig.me || true)
  elif have_cmd wget; then
    PUBLIC_IP=$(wget -qO- https://ifconfig.me || true)
  fi
  [ -z "$PUBLIC_IP" ] && PUBLIC_IP="(unavailable)"

  DYNDNS=""
  if [ -f /etc/ddclient.conf ]; then
    DYNDNS=$(grep -E '^[^#[:space:]]' /etc/ddclient.conf | grep -v '=' | head -n1 | tr -d '\r' | xargs || true)
  fi
  [ -z "$DYNDNS" ] && DYNDNS="(none)"

  for WGCONF in /etc/wireguard/wg*.conf; do
    # se il glob non matcha nulla
    [ -e "$WGCONF" ] || continue

    IFACE="$(basename "$WGCONF" .conf)"

    VPN_PORT=$(grep -E '^[[:space:]]*ListenPort[[:space:]]*=' "$WGCONF" \
              | head -n1 \
              | sed -E 's/^[^=]+=[[:space:]]*//' \
              | tr -d '\r' \
              | xargs || true)

    [ -z "$VPN_PORT" ] && VPN_PORT="(unknown)"

    echo "\"Public IP\",\"$PUBLIC_IP\",\"\",\"$(date '+%Y-%m-%d %H:%M:%S')\"" >> "$REPORT_PATH"
    echo "\"DynDNS Host\",\"$DYNDNS\",\"\",\"$(date '+%Y-%m-%d %H:%M:%S')\"" >> "$REPORT_PATH"
    echo "\"VPN Port\",\"$VPN_PORT\",\"\",\"$(date '+%Y-%m-%d %H:%M:%S')\"" >> "$REPORT_PATH"
    echo "" >> "$REPORT_PATH"
  done

  success "Report generated and saved to: $REPORT_PATH"
  info ""
  info "Public IP   : $PUBLIC_IP"
  info "DynDNS Host : $DYNDNS"
  info "VPN Port    : $VPN_PORT"
  info ""
  info "Full report content:"
  tail -n +1 "$REPORT_PATH"
}
