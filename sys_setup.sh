#!/bin/sh
# wg_full_setup_menu.sh
# Interactive orchestrator for linux-wireguard-vpn-helpers
# POSIX /bin/sh compatible

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
if [ -f "${SCRIPT_PATH}/functions.sh" ]; then
  . $SCRIPT_PATH/functions.sh
else
  printf "\033[31m[ERROR]\033[0m Missing file: %s/functions.sh\n" "$SCRIPT_PATH" >&2
  exit 1
fi

# ------------------------------------------------------------------------------
# INITIALIZATION
# ------------------------------------------------------------------------------
need_root
header "WireGuard Full Setup"

REPORT_DIR="${SCRIPT_PATH}/reports"
REPORT_PATH="${REPORT_DIR}/wg_setup_report_$(date +%Y%m%d-%H%M%S).csv"
mkdir -p "$REPORT_DIR"

log_report() {
  step="$1"; status="$2"; detail="$3"
  printf "\"%s\",\"%s\",\"%s\",\"%s\"\n" "$step" "$status" "$detail" "$(date '+%Y-%m-%d %H:%M:%S')" >> "$REPORT_PATH"
}

WG_HELPERS_DIR="${SCRIPT_PATH}/"
WG_SCRIPTS_OK=1

# Detect OS
if [ -r /etc/os-release ]; then
  . /etc/os-release
  OS_ID="${ID:-}"
else
  OS_ID="$(uname -s | tr '[:upper:]' '[:lower:]')"
fi

# Detect package manager
PKG=""
for c in apk apt-get dnf yum zypper pacman opkg; do
  if have_cmd "$c"; then PKG="$c"; break; fi
done

# ------------------------------------------------------------------------------
# STEP FUNCTIONS
# ------------------------------------------------------------------------------

if [ -f "${SCRIPT_PATH}/functions_setup.sh" ]; then
  . $SCRIPT_PATH/functions_setup.sh
else
  error "Missing file: ${SCRIPT_PATH}/functions_setup.sh" >&2
  exit 1
fi

# ------------------------------------------------------------------------------
# MENU LOOP
# ------------------------------------------------------------------------------

while true; do
  info ""
  info "===================== MENU ====================="
  info " [0] Update system and helpers"
  info " [1] Change root password"
  info " [2] Show network interfaces and routes"
  info " [3] Run setup-networking"
  info " [4] Configure Dynamic DNS (ddclient)"
  info " [5] Install VPN prerequisites"
  info " [6] Configure VPN server"
  info " [7] Configure VPN client"
  info " [8] Configure VPN filter"
  info " [9] Generate and show setup report"
  info " [Q] Quit"
  info "==============================================="
  ask choice "Select an option" ""
  case "$choice" in
    0) step0_update_system ;;
    1) step1_change_root_password ;;
    2) step2_show_network_info ;;
    3) step3_setup_networking ;;
    4) step4_ddclient_configure ;;
    5) step5_install_vpn_prereq ;;
    6) step6_server_configure ;;
    7) step7_client_configure ;;
    8) step8_filter_configure ;;
    9) step9_generate_report ;;
    q|Q) success "Exiting."; break ;;
    *) warning "Invalid choice." ;;
  esac
done

exit 0
