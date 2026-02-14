#!/bin/sh
# sys_setup.sh
# Interactive orchestrator for linux-wireguard-vpn-helpers
# POSIX /bin/sh compatible

set +e

umask 077

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
  if [ ! -n "$AUTO_CHOICE" ]; then
    info ""
    info "===================== MENU ====================="
    info " [0] Update system and helpers"
    info " [1] Install VPN prerequisites"
    info " [2] Change root password"
    info " [3] Show network interfaces and routes"
    info " [4] Run setup-networking"
    info " [5] Configure Dynamic DNS"
    info " [6] Configure VPN server"
    info " [7] Configure VPN client"
    info " [8] Configure VPN filter"
    info " [9] Generate and show setup report"
    info " [10] Reboot system"
    info " [11] Halt system"
    info " [Q] Quit"
    info "==============================================="
  fi

  if [ -n "$AUTO_CHOICE" ]; then
    choice="$AUTO_CHOICE"
  else
    ask choice "Select an option" ""
  fi
  case "$choice" in
    0) update_system ;;
    1) install_vpn_prereq ;;
    2) change_root_password ;;
    3) show_network_info ;;
    4) setup_networking ;;
    5) ddns_configure ;;
    6) server_configure ;;
    7) client_configure ;;
    8) filter_configure ;;
    9) generate_report ;;
    10) reboot ;;
    11) halt ;;
    q|Q) success "Exiting."; break ;;
    *) warning "Invalid choice." ;;
  esac

  if [ -n "$AUTO_CHOICE" ]; then
    break
  fi
done

exit 0
