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

header "WireGuard Server Configurator"

ask INTERFACE "Enter the WireGuard interface" "wg0"

WG_DIR="/etc/wireguard"
WG_CONF="${INTERFACE}.conf"
WG_CONF_PATH="${WG_DIR}/${WG_CONF}"
CLIENTS_DIR="${WG_DIR}/clients"

success "Selected interface: $INTERFACE"

if [ ! -e "/etc/init.d/wg-quick.${INTERFACE}" ]; then
    ln -s /etc/init.d/wg-quick "/etc/init.d/wg-quick.${INTERFACE}"
    info ""
    success "Created symlink: /etc/init.d/wg-quick.${INTERFACE}"
    rc-update add wg-quick."${INTERFACE}"
fi

[ -d "$WG_DIR" ] || mkdir -p "$WG_DIR"

info ""
info "Configuration file: $WG_CONF_PATH"
info "Client directory:      $CLIENTS_DIR"

# ----- SERVER READING -----
need_root
have_cmd wg || install_wg
ensure_dirs
[ -f "$WG_CONF_PATH" ] || die "Server file not found: $WG_CONF_PATH"


# ------------------------------------------------------------------------------
# STEP FUNCTIONS
# ------------------------------------------------------------------------------

if [ -f "${SCRIPT_PATH}/functions_server.sh" ]; then
  . $SCRIPT_PATH/functions_server.sh
else
  error "Missing file: ${SCRIPT_PATH}/functions_server.sh" >&2
  exit 1
fi

while true; do

  # --- Read old values if present ---
  OLD_ADDR="$(get_conf_value Address | awk -F'/' '{print $1}')"
  OLD_PORT="$(get_conf_value ListenPort)"
  OLD_ENDPOINT="$(conf_comment_get "Endpoint Host")"
  OLD_DNS="$(conf_comment_get "DNS")"
  OLD_MAXCLIENTS="$(conf_comment_get "Max Clients")"
  OLD_CLIENTS_ISOLATION="$(conf_comment_get "Clients Isolation")"

  SERVER_SUBNET="$(conf_comment_get "Subnet")"
  SERVER_SUBNET_VPN="$(conf_comment_get "Subnet VPN")"
  SERVER_PUBKEY="$(conf_comment_get "PublicKey")"
  SERVER_PORT="$(conf_get ListenPort)"
  SERVER_ENDPOINT="$(conf_comment_get "Endpoint Host")"
  SERVER_DNS="$(conf_comment_get "DNS")"
  MAX_CLIENTS="$(conf_comment_get "Max Clients" || echo 254)"
  CLIENTS_ISOLATION="$(conf_comment_get "Clients Isolation" || echo 0)"
  CLIENTS_SUBNET_VPN="$(conf_comment_get "Clients Authorized Subnet" || echo "$SERVER_SUBNET_VPN")"
  BASE3="$(first_three "$SERVER_SUBNET_VPN")"

  CLIENTS=$(ls "$CLIENTS_DIR"/*_config.conf 2>/dev/null | wc -l || echo 0)
  FREE=$((MAX_CLIENTS - CLIENTS))
  [ "$FREE" -lt 0 ] && FREE=0

  if [ ! -n "$AUTO_CHOICE" ]; then
    info ""
    info "===================== MENU ====================="
    info " [1] View server configuration file (.conf)"
    info " [2] Modify server configuration"
    info " [3] Test VPN configuration"
    info " [Q] Quit"
    info "==============================================="
  fi

  if [ -n "$AUTO_CHOICE" ]; then
    choice="$AUTO_CHOICE"
  else
    ask choice "Select an option" ""
  fi
  case "$choice" in
    1) view_server_config ;;
    2) server_configure ;;
    3) test_vpn_configuration ;;
    q|Q) success "Exiting."; break ;;
    *) warning "Invalid choice." ;;
  esac
  
  if [ -n "$AUTO_CHOICE" ]; then
    break
  fi
done
