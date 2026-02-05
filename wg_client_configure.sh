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

header "WireGuard Client Configurator"

# TODO: Enable report logging
# REPORT_DIR="${SCRIPT_PATH}/reports"
# REPORT_PATH="${REPORT_DIR}/wg_client_report_$(date +%Y%m%d-%H%M%S).csv"
# mkdir -p "$REPORT_DIR"
# echo "Step,Status,Details,Timestamp" > "$REPORT_PATH"

ask INTERFACE "Enter the WireGuard interface" "wg0"

WG_DIR="/etc/wireguard"
WG_CONF="${INTERFACE}.conf"
WG_CONF_PATH="${WG_DIR}/${WG_CONF}"
CLIENTS_DIR="${WG_DIR}/clients"

success "Selected interface: $INTERFACE"
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

if [ -f "${SCRIPT_PATH}/functions_client.sh" ]; then
  . $SCRIPT_PATH/functions_client.sh
else
  error "Missing file: ${SCRIPT_PATH}/functions_client.sh" >&2
  exit 1
fi

while true; do
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

  info ""
  info "Supported clients : $MAX_CLIENTS"
  info "Configured clients: $CLIENTS"
  info "Free slots clients: $FREE"
  info ""
  info "List of configured clients:"
  CLIENT_LIST=$(list_clients)
  [ -n "$CLIENT_LIST" ] && \
    echo "$CLIENT_LIST" | awk '{printf " %2d) client%s_%s\n", $1, $1, $2}' | while IFS= read -r line; do
      info "$line"
    done || warning " (none)"

  if [ ! -n "$AUTO_CHOICE" ]; then
    info ""
    info "===================== MENU ====================="
    info " [1] Add client"
    info " [2] Modify client"
    info " [3] Delete client"
    info " [4] Start microserver (only .conf)"
    info " [5] View client configuration file (.conf)"
    info " [6] Regenerate configuration file (.conf) for a client"
    info " [7] Test VPN configuration"
    info " [Q] Quit"
    info "==============================================="
  fi

  if [ -n "$AUTO_CHOICE" ]; then
    choice="$AUTO_CHOICE"
  else
    ask choice "Select an option" ""
  fi
  case "$choice" in
    1) add_client ;;
    2) modify_client ;;
    3) delete_client ;;
    4) start_microserver ;;
    5) view_config ;;
    6) regenerate_config ;;
    7) test_vpn_configuration ;;
    q|Q) success "Exiting."; break ;;
    *) warning "Invalid choice." ;;
  esac
  
  if [ -n "$AUTO_CHOICE" ]; then
    break
  fi
done