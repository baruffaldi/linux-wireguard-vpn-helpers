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

ddclient_configure() {
  header "[4] Configure Dynamic DNS (ddclient)"

  # --- Detect package manager (global fallback if PKG unset) ---
  if [ -z "${PKG:-}" ]; then
    if have_cmd apk; then PKG="apk"
    elif have_cmd apt-get; then PKG="apt-get"
    elif have_cmd dnf; then PKG="dnf"
    elif have_cmd yum; then PKG="yum"
    elif have_cmd zypper; then PKG="zypper"
    elif have_cmd pacman; then PKG="pacman"
    else PKG=""
    fi
  fi

  # --- Install ddclient if missing ---
  if ! have_cmd ddclient; then
    info "Installing ddclient..."
    case "$PKG" in
      apk) apk add --no-cache ddclient ;;
      apt-get) apt-get update -qq && apt-get install -y ddclient ;;
      dnf|yum) "$PKG" install -y ddclient ;;
      zypper) zypper -n install ddclient ;;
      pacman) pacman -Sy --noconfirm ddclient ;;
      *) warning "No supported package manager detected. Install ddclient manually."; return 1 ;;
    esac
  fi

  # --- Configure ddclient ---
  if have_cmd ddclient; then
    # use=web, web=checkip.dyndns.com/, web-skip='IP Address'
    # ssl=yes
    ask DYNSERVER "DynDNS provider (server)" "dynv6.com"
    ask DYNDOMAIN "DynDNS hostname (e.g. example.dynv6.com)" ""
    ask DYNUSER "DynDNS username" "none"
    ask_secret DYNPASS "DynDNS password"

    cat >> /etc/ddclient/ddclient.conf <<EOF
protocol=dyndns2
server=$DYNSERVER
login=$DYNUSER
password='$DYNPASS'
ssl=yes
use=web, web=ifconfig.me/ip
$DYNDOMAIN
EOF

    #chmod 600 /etc/ddclient/ddclient.conf
    success "ddclient configuration written to /etc/ddclient/ddclient.conf"
  else
    warning "ddclient not installed. Skipping configuration."
    return 1
  fi

  # --- Ensure ddclient runs and starts at boot ---
  info "Ensuring ddclient service is enabled and running..."

  if have_cmd rc-service; then
    # Alpine OpenRC
    rc-update add ddclient default >/dev/null 2>&1 || true
    rc-service ddclient restart >/dev/null 2>&1 && success "ddclient restarted (OpenRC)."
  elif have_cmd systemctl; then
    # systemd-based systems
    systemctl enable ddclient >/dev/null 2>&1 || true
    if systemctl is-active --quiet ddclient; then
      systemctl restart ddclient && success "ddclient restarted (systemd)."
    else
      systemctl start ddclient && success "ddclient started (systemd)."
    fi
  elif have_cmd service; then
    # sysvinit fallback
    service ddclient restart >/dev/null 2>&1 || service ddclient start >/dev/null 2>&1
    success "ddclient started (SysVinit)."
  else
    warning "No service manager detected. Running ddclient in background..."
    nohup ddclient -daemon=300 >/dev/null 2>&1 &
  fi

  success "Dynamic DNS setup complete."
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

  VPN_PORT=""
  if [ -f /etc/wireguard/wg0.conf ]; then
    VPN_PORT=$(grep -E '^[[:space:]]*ListenPort[[:space:]]*=' /etc/wireguard/wg0.conf \
               | head -n1 \
               | sed -E 's/^[^=]+=[[:space:]]*//' \
               | tr -d '\r' \
               | xargs || true)
  fi
  [ -z "$VPN_PORT" ] && VPN_PORT="(unknown)"

  echo "\"Public IP\",\"$PUBLIC_IP\",\"\",\"$(date '+%Y-%m-%d %H:%M:%S')\"" >> "$REPORT_PATH"
  echo "\"DynDNS Host\",\"$DYNDNS\",\"\",\"$(date '+%Y-%m-%d %H:%M:%S')\"" >> "$REPORT_PATH"
  echo "\"VPN Port\",\"$VPN_PORT\",\"\",\"$(date '+%Y-%m-%d %H:%M:%S')\"" >> "$REPORT_PATH"

  success "Report generated and saved to: $REPORT_PATH"
  info ""
  info "Public IP   : $PUBLIC_IP"
  info "DynDNS Host : $DYNDNS"
  info "VPN Port    : $VPN_PORT"
  info ""
  info "Full report content:"
  tail -n +1 "$REPORT_PATH"
}
