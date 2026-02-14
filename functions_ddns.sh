#!/bin/sh

# functions_filter.sh
#
# This script provides a set of common functions.

resolve_realpath() {
  f="$1"
  while [ -L "$f" ]; do f="$(readlink "$f")"; done
  cd "$(dirname "$f")" || exit 1
  pwd -P
}
SCRIPT_PATH="$(resolve_realpath "$0")"

# Source the common functions
if [ -f "${SCRIPT_PATH}/common.sh" ]; then
  . $SCRIPT_PATH/common.sh
else
  printf "\033[31m[ERROR]\033[0m Missing file: %s/common.sh\n" "$SCRIPT_PATH" >&2
  exit 1
fi

view_ddns_config() {
    header "WireGuard DDNS Configuration File"
    info ""
    if [ -f "$WG_DDNS_CONF_PATH" ]; then
    cat "$WG_DDNS_CONF_PATH"
    else
    warning "Configuration file not found: $WG_CONF_PATH"
    fi
}

ddclient_configure() {
    header "DDClient Configuration"

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
    DDCLIENT_CONF_PATH="$(conf_get DDCLIENT_CONF_PATH "$WG_DDNS_CONF_PATH")"
    DYNSERVER_PREV="$(conf_get DYNSERVER "$DDCLIENT_CONF_PATH")"
    DYNDOMAIN_PREV="$(conf_get DYNDOMAIN "$DDCLIENT_CONF_PATH")"
    DYNUSER_PREV="$(conf_get DYNUSER "$DDCLIENT_CONF_PATH")"
    DYNPASS_PREV="$(conf_get DYNPASS "$DDCLIENT_CONF_PATH")" 
    ask DYNSERVER "DynDNS provider (server)" "dynv6.com" "$DYNSERVER_PREV"
    ask DYNDOMAIN "DynDNS hostname (e.g. example.dynv6.com)" "" "$DYNDOMAIN_PREV"
    ask DYNUSER "DynDNS username" "none" "$DYNUSER_PREV"
    ask_secret DYNPASS "DynDNS password" "$DYNPASS_PREV"

    # --- Write file ---
    info ""
    info "Writing configuration to $DDCLIENT_CONF_PATH ..."
    cat >> "$DDCLIENT_CONF_PATH" <<EOF
protocol=dyndns2
server=$DYNSERVER
login=$DYNUSER
password='$DYNPASS'
ssl=yes
use=web, web=ifconfig.me/ip
$DYNDOMAIN
EOF

    #chmod 600 "$DDCLIENT_CONF_PATH"
    success "ddclient configuration written to $DDCLIENT_CONF_PATH"
  else
    warning "ddclient not installed. Skipping configuration."
    return 1
  fi

  # --- Ensure ddclient runs and starts at boot ---
  info "Ensuring ddclient service is enabled and running..."
  enable_ddclient

  success "DDClient setup complete."
}

ovhclient_configure() {
    header "OVH Client Configuration"

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
  if ! have_cmd curl; then
    info "Installing curl..."
    case "$PKG" in
      apk) apk add --no-cache curl ;;
      apt-get) apt-get update -qq && apt-get install -y curl ;;
      dnf|yum) "$PKG" install -y curl ;;
      zypper) zypper -n install curl ;;
      pacman) pacman -Sy --noconfirm curl ;;
      *) warning "No supported package manager detected. Install curl manually."; return 1 ;;
    esac
  fi

  if have_cmd curl; then
    DDCLIENT_CONF_PATH="$(conf_get DDCLIENT_CONF_PATH "$WG_DDNS_CONF_PATH")"
    OVH_HOSTNAME_PATH="$(conf_get OVH_HOSTNAME "$WG_DDNS_CONF_PATH")"
    OVH_USERNAME_PATH="$(conf_get OVH_USERNAME "$WG_DDNS_CONF_PATH")"
    OVH_PASSWORD_PATH="$(conf_get OVH_PASSWORD "$WG_DDNS_CONF_PATH")"

    ask OVH_HOSTNAME "OVH hostname (server)" "this-server.example.com"
    ask OVH_USERNAME "OVH username" "exampleuser"
    ask OVH_PASSWORD "OVH password" "examplepassword"

    # --- Write file ---
    info ""
    info "Writing configuration to $WG_DDNS_CONF_PATH ..."
    cat > "$WG_DDNS_CONF_PATH" <<EOF
# ================== WireGuard DDNS Config ==================
DDCLIENT_CONF_PATH="$DDCLIENT_CONF_PATH"
OVH_HOSTNAME_PATH="$OVH_HOSTNAME_PATH"
OVH_USERNAME_PATH="$OVH_USERNAME_PATH"
OVH_PASSWORD_PATH="$OVH_PASSWORD_PATH"
EOF

    success "DDNS configuration written to $WG_DDNS_CONF_PATH"
  else
    warning "curl not installed. Skipping configuration."
    return 1
  fi

  # --- Ensure ovhclient runs and starts at boot ---
  #info "Ensuring ovhclient service is enabled and running..."
  # enable_ovhclient

  success "OVHClient setup complete."
}

enable_disable_ddclient() {
    header "DDClient Enable/Disable"

    SERVICE="ddclient"

    if ! systemctl list-unit-files | grep -q "^${SERVICE}.service"; then
        warning "Servizio $SERVICE non trovato."
        return 1
    fi

    if systemctl is-active --quiet "$SERVICE"; then
      disable_ddclient
    else
      enable_ddclient
    fi
}

enable_ddclient() {
  if systemctl is-active --quiet "$SERVICE"; then
    info "ddclient è attualmente ATTIVO."
    return
  fi

  info "ddclient è attualmente FERMO."
  info "Abilitazione ed avvio del servizio..."
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

  success "ddclient avviato e abilitato."
}

disable_ddclient() {
  if ! systemctl is-active --quiet "$SERVICE"; then
    info "ddclient è attualmente FERMO."
    return
  fi

  info "Disabilitazione ed arresto del servizio..."

  if have_cmd rc-service; then
    # Alpine OpenRC
    rc-service ddclient stop >/dev/null 2>&1 || true
    rc-update del ddclient default >/dev/null 2>&1 || true
    success "ddclient stopped/disabled (OpenRC)."

  elif have_cmd systemctl; then
    # systemd-based systems
    systemctl stop ddclient >/dev/null 2>&1 || true
    systemctl disable ddclient >/dev/null 2>&1 || true
    success "ddclient stopped/disabled (systemd)."

  elif have_cmd service; then
    # sysvinit fallback
    service ddclient stop >/dev/null 2>&1 || true
    if have_cmd update-rc.d; then
      update-rc.d ddclient disable >/dev/null 2>&1 || true
    elif have_cmd chkconfig; then
      chkconfig ddclient off >/dev/null 2>&1 || true
    fi
    success "ddclient stopped/disabled (SysVinit)."

  else
    # No service manager detected
    warning "No service manager detected. Trying to stop ddclient process..."
    pkill -f '[d]dclient' >/dev/null 2>&1 || true
    success "ddclient process stopped (best-effort)."
  fi

  success "ddclient fermato e disabilitato."
}

enable_disable_ovhclient() {
    header "OVHClient Enable/Disable"
    
    if crontab -l 2>/dev/null | grep -q "${WG_DDNS_PATH}"; then
        disable_ovhclient
    else
        enable_ovhclient
    fi
}

enable_ovhclient() {
    if crontab -l 2>/dev/null | grep -q "${WG_DDNS_PATH}"; then
      info "OVHClient è attualmente ATTIVO."
      return
    fi
    info "OVHClient è attualmente FERMO."
    info "Abilitazione del client OVH (aggiunta al crontab)..."
    (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
    success "OVHClient abilitato (cron attivo)."
}

disable_ovhclient() {
    if crontab -l 2>/dev/null | grep -q "${WG_DDNS_PATH}"; then
        info "OVHClient è attualmente ATTIVO."
        info "Disabilitazione del client OVH (rimozione dal crontab)..."

        crontab -l 2>/dev/null | grep -v "${WG_DDNS_PATH}" | crontab -

        success "OVHClient disabilitato (cron rimosso)."
    else
        info "OVHClient è attualmente FERMO."
    fi
}
