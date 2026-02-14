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

header "WireGuard Filter Configurator"

WG_DIR="/etc/wireguard"
WG_FILTER_CONF="wg_filter.conf"
WG_FILTER_CONF_PATH="${SCRIPT_PATH}/${WG_FILTER_CONF}"
WG_FILTER_PATH="${SCRIPT_PATH}/wg_filter.sh"
WG_EXAMPLE_FILTER_CONF_PATH="${SCRIPT_PATH}/wg_filter.conf.example"
CRON_DEFAULT="/etc/crontabs/root"

# --- Determine the absolute path of the script ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRON_LINE="*       *       *       *       *       ${SCRIPT_DIR}/wg_filter.sh >/dev/null 2>&1"

info ""
info "Configuration file: $WG_FILTER_CONF_PATH"

# ----- SERVER READING -----
need_root
ensure_dirs
[ -f "$WG_FILTER_CONF_PATH" ] || die "Server file not found: $WG_FILTER_CONF_PATH"


# ------------------------------------------------------------------------------
# STEP FUNCTIONS
# ------------------------------------------------------------------------------

if [ -f "${SCRIPT_PATH}/functions_filter.sh" ]; then
  . $SCRIPT_PATH/functions_filter.sh
else
  error "Missing file: ${SCRIPT_PATH}/functions_filter.sh" >&2
  exit 1
fi

while true; do

  info "Firewall status:"
  if crontab -l 2>/dev/null | grep -q "wg_filter.sh"; then
      info "\e[32m *\e[0m status: started"
  else
      info "\e[32m *\e[0m status: stopped"
  fi

  if [ ! -n "$AUTO_CHOICE" ]; then
    info ""
    info "===================== MENU ====================="
    info " [1] View firewall configuration file (wg_filter.conf)"
    info " [2] Configure firewall and DynDNS"
    info " [3] Enable/Disable firewall"
    info " [Q] Quit"
    info "==============================================="
  fi

  if [ -n "$AUTO_CHOICE" ]; then
    choice="$AUTO_CHOICE"
  else
    ask choice "Select an option" ""
  fi
  case "$choice" in
    1) view_firewall_config ;;
    2) firewall_configure ;;
    3) enable_disable_firewall ;;
    q|Q) success "Exiting."; break ;;
    *) warning "Invalid choice." ;;
  esac
  
  if [ -n "$AUTO_CHOICE" ]; then
    break
  fi
done