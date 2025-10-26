#!/bin/sh
set -eu

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

# --- Helper: extract ONLY the value between double quotes, ignoring comments/spaces ---
# Works on BusyBox awk as well.
get_conf_value_from_file() {
  key="$1"
  file="$2"
  if [ -f "$file" ]; then
    awk -v k="$key" '
      BEGIN { IGNORECASE=0 }
      # Lines like:    KEY="value"   # comment
      $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
        # Find the FIRST string in double quotes
        if (match($0, /"[^"]*"/)) {
          v = substr($0, RSTART+1, RLENGTH-2);
          print v;
          exit;
        }
      }
    ' "$file"
  fi
}

# --- Wrapper: search first in the conf, then in the example ---
get_conf_value() {
  key="$1"
  if [ -f "$CONFIG_FILE" ]; then
    get_conf_value_from_file "$key" "$CONFIG_FILE"
  elif [ -f "$EXAMPLE_FILE" ]; then
    get_conf_value_from_file "$key" "$EXAMPLE_FILE"
  else
    echo ""
  fi
}

# ================== CONFIG ==================
CONFIG_FILE="${SCRIPT_PATH}/wg_filter.conf"
EXAMPLE_FILE="${SCRIPT_PATH}/wg_filter.conf.example"
CRON_DEFAULT="/etc/crontabs/root"
# ============================================

# --- Determine the absolute path of the script ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRON_LINE="*       *       *       *       *       ${SCRIPT_DIR}/wg_filter.sh >/dev/null 2>&1"

# --- Initial message ---
header "WireGuard Filter Configurator"

# TODO: Enable report logging
# REPORT_DIR="${SCRIPT_PATH}/reports"
# REPORT_PATH="${REPORT_DIR}/wg_filter_report_$(date +%Y%m%d-%H%M%S).csv"
# mkdir -p "$REPORT_DIR"
# echo "Step,Status,Details,Timestamp" > "$REPORT_PATH"

if [ -f "$CONFIG_FILE" ]; then
  info "Found existing configuration file: $CONFIG_FILE"
  info "Current values will be shown in square brackets []."
  echo
  ask answer "Do you want to delete it before proceeding? (y/N): " "n"
  if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
    rm -f "$CONFIG_FILE"
    success "Configuration file deleted."
    echo
  else
    info "Proceeding with the existing configuration file."
    echo
  fi
elif [ -f "$EXAMPLE_FILE" ]; then
  info "No configuration file found."
  info "Default values will be used from: $EXAMPLE_FILE"
  echo
else
  error "ERROR: no configuration or example file found!"
  error "Create at least $EXAMPLE_FILE to continue."
  exit 1
fi

# --- Find default IPTABLES with which (required) ---
IPTABLES_DEFAULT="$(which iptables 2>/dev/null || command -v iptables 2>/dev/null || echo /usr/sbin/iptables)"
IPTABLES_PREV="$(get_conf_value IPTABLES)"

# --- Function to ask for input with default and (opt.) "previous" ---
ask_config() {
  varname="$1"
  question="$2"
  default_val="$3"          # Default to propose (e.g., IPTABLES_DEFAULT)
  prev_val="${4:-}"         # Previous value (from file), optional

  if [ -n "$prev_val" ] && [ "$varname" != "IPTABLES" ]; then
    # For all variables except IPTABLES, we use the previous one as default
    default_show="$prev_val"
  else
    default_show="$default_val"
  fi

  if [ "$varname" = "IPTABLES" ] && [ -n "$IPTABLES_PREV" ] && [ "$IPTABLES_PREV" != "$IPTABLES_DEFAULT" ]; then
    printf "%s [%s] (previous: %s): " "$question" "$default_show" "$IPTABLES_PREV"
  else
    printf "%s [%s]: " "$question" "$default_show"
  fi

  # shellcheck disable=SC2162
  read input || true

  if [ -n "${input:-}" ]; then
    eval "$varname=\"\$input\""
  else
    eval "$varname=\"\$default_show\""
  fi
}

# --- Prepare defaults/previous ---
WGPORT_PREV="$(get_conf_value WGPORT)"
WAN_IF_PREV="$(get_conf_value WAN_IF)"
HOSTS_PREV="$(get_conf_value HOSTS)"
EXTRA_URL_PREV="$(get_conf_value EXTRA_URL)"
CHAIN_PREV="$(get_conf_value CHAIN)"

# --- Questions to the user ---
ask_config WGPORT   "Enter the WireGuard UDP port"                "${WGPORT_PREV:-51234}"          "$WGPORT_PREV"
ask_config WAN_IF   "Enter the WAN interface (e.g., eth0)"          "${WAN_IF_PREV:-eth0}"           "$WAN_IF_PREV"
ask_config HOSTS    "Enter one or more DDNS hostnames (space-separated)" "${HOSTS_PREV:-ddns.example.com}" "$HOSTS_PREV"
ask_config EXTRA_URL "Enter URL of the extra IP/CIDR list"              "${EXTRA_URL_PREV:-https://example.com/acl.txt}" "$EXTRA_URL_PREV"
# For IPTABLES: default = which iptables (not from the file), but we show the previous as a note
ask_config IPTABLES "Path to iptables binary"                       "$IPTABLES_DEFAULT"              "$IPTABLES_PREV"
ask_config CHAIN    "Name of the dedicated chain for WireGuard"      "${CHAIN_PREV:-WG_FILTER}"       "$CHAIN_PREV"

# --- Write file ---
echo
info "Writing configuration to $CONFIG_FILE ..."
cat > "$CONFIG_FILE" <<EOF
# ================== WireGuard Filter Config ==================
WGPORT="$WGPORT"
WAN_IF="$WAN_IF"
HOSTS="$HOSTS"
EXTRA_URL="$EXTRA_URL"
IPTABLES="$IPTABLES"
CHAIN="$CHAIN"
EOF

success "Configuration saved successfully!"
echo
info "Generated content:"
echo "-----------------------------------"
cat "$CONFIG_FILE"
echo "-----------------------------------"

# ================== CRONTAB MANAGEMENT ==================
echo
info "Checking for cron job for wg_filter.sh ..."

if command -v crontab >/dev/null 2>&1; then
  CURRENT_CRON="$(crontab -l 2>/dev/null || true)"
  echo "$CURRENT_CRON" | grep -F "$CRON_LINE" >/dev/null 2>&1 || {
    info "Adding line to root's crontab..."
    (echo "$CURRENT_CRON"; echo "$CRON_LINE") | crontab -
    success "Line added successfully to crontab (using crontab -l / -)."
  }
else
  warning "Command 'crontab' not available (likely Alpine/BusyBox)."
  printf "Path to root cron file [%s]: " "$CRON_DEFAULT"
  read CRON_FILE || true
  [ -z "${CRON_FILE:-}" ] && CRON_FILE="$CRON_DEFAULT"

  if [ ! -f "$CRON_FILE" ]; then
    warning "Cron file not found, will be created: $CRON_FILE"
    : > "$CRON_FILE"
  fi

  if grep -F "$CRON_LINE" "$CRON_FILE" >/dev/null 2>&1; then
    success "Line already present in $CRON_FILE."
  else
    echo "$CRON_LINE" >> "$CRON_FILE"
    success "Line added successfully to $CRON_FILE"
    # Note: on Alpine, you might need to run: rc-service crond reload (manually)
  fi
fi

echo
success "Setup completed"