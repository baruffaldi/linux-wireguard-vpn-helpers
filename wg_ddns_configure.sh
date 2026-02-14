#!/bin/sh
set -eu

if [ -n "${1:-}" ]; then
  AUTO_CHOICE="$1"
else
  AUTO_CHOICE=""
fi

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
if [ -f "${SCRIPT_PATH}/functions.sh" ]; then
  . $SCRIPT_PATH/functions.sh
else
  printf "\033[31m[ERROR]\033[0m Missing file: %s/functions.sh\n" "$SCRIPT_PATH" >&2
  exit 1
fi

header "WireGuard DDNS Configurator"

WG_DIR="/etc/wireguard"
WG_DDNS="wg_ddns.sh"
WG_DDNS_CONF="wg_ddns.conf"
WG_DDNS_PATH="${SCRIPT_PATH}/${WG_DDNS}"
WG_DDNS_CONF_PATH="${SCRIPT_PATH}/${WG_DDNS_CONF}"
WG_EXAMPLE_DDNS_CONF_PATH="${SCRIPT_PATH}/wg_ddns.conf.example"
CRON_DEFAULT="/etc/crontabs/root"

# --- Determine the absolute path of the script ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRON_LINE="*/5       *       *       *       *       ${WG_DDNS_PATH} >/dev/null 2>&1"

info ""
info "Configuration file: $WG_DDNS_CONF_PATH"

# ----- SERVER READING -----
need_root
[ -f "$WG_DDNS_CONF_PATH" ] || warning "Server file not found: $WG_DDNS_CONF_PATH"

# ------------------------------------------------------------------------------
# STEP FUNCTIONS
# ------------------------------------------------------------------------------

if [ -f "${SCRIPT_PATH}/functions_ddns.sh" ]; then
  . $SCRIPT_PATH/functions_ddns.sh
else
  error "Missing file: ${SCRIPT_PATH}/functions_ddns.sh" >&2
  exit 1
fi

while true; do

  info "DDClient status:"
  service ddclient status

  info ""

  info "OVHClient status:"
  if crontab -l 2>/dev/null | grep -q "${WG_DDNS_PATH}"; then
      info "${C_GREEN} *${C_RESET} status: started"
  else
      info "${C_GREEN} *${C_RESET} status: stopped"
  fi

  if [ ! -n "$AUTO_CHOICE" ]; then
    info ""
    info "===================== MENU ====================="
    info " [1] View DynDNS configuration file (wg_ddns.conf)"
    info " [2] Configure ddclient"
    info " [3] Configure ovhclient"
    info " [4] Enable/Disable ddclient"
    info " [5] Enable/Disable ovhclient"
    info " [Q] Quit"
    info "==============================================="
  fi

  if [ -n "$AUTO_CHOICE" ]; then
    choice="$AUTO_CHOICE"
  else
    ask choice "Select an option" ""
  fi
  case "$choice" in
    1) view_ddns_config ;;
    2) ddclient_configure ;;
    3) ovhclient_configure ;;
    4) enable_disable_ddclient ;;
    5) enable_disable_ovhclient ;;
    q|Q) success "Exiting."; break ;;
    *) warning "Invalid choice." ;;
  esac
  
  if [ -n "$AUTO_CHOICE" ]; then
    break
  fi
done