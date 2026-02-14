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

view_filter_config() {
    header "WireGuard Filter Configuration File"
    info ""
    if [ -f "$WG_FILTER_CONF_PATH" ]; then
    info "Current configuration file content:"
    info "------------------------------------------------------------------------------"
    cat "$WG_FILTER_CONF_PATH"
    info "------------------------------------------------------------------------------"
    else
    warning "Configuration file not found: $WG_FILTER_CONF_PATH"
    fi
}

filter_configure() {
    header "WireGuard Filter Configuration"

    # TODO: Enable report logging
    # REPORT_DIR="${SCRIPT_PATH}/reports"
    # REPORT_PATH="${REPORT_DIR}/wg_filter_report_$(date +%Y%m%d-%H%M%S).csv"
    # mkdir -p "$REPORT_DIR"
    # echo "Step,Status,Details,Timestamp" > "$REPORT_PATH"

    if [ -f "$WG_FILTER_CONF_PATH" ]; then
    info "Found existing configuration file: $WG_FILTER_CONF_PATH"
    info "Current values will be shown in square brackets []."
    info ""
    ask answer "Do you want to delete it before proceeding? (y/N): " "n"
    if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
        rm -f "$WG_FILTER_CONF_PATH"
        success "Configuration file deleted."
        info ""
    else
        info "Proceeding with the existing configuration file."
        info ""
    fi
    elif [ -f "$WG_EXAMPLE_FILTER_CONF_PATH" ]; then
    info "No configuration file found."
    info "Default values will be used from: $WG_EXAMPLE_FILTER_CONF_PATH"
    info ""
    else
    error "ERROR: no configuration or example file found!"
    error "Create at least $WG_EXAMPLE_FILTER_CONF_PATH to continue."
    exit 1
    fi

    # --- Find default IPTABLES with which (required) ---
    IPTABLES_DEFAULT="$(which iptables 2>/dev/null || command -v iptables 2>/dev/null || echo /usr/sbin/iptables)"
    IPTABLES_PREV="$(conf_get IPTABLES "$WG_FILTER_CONF_PATH")"

    # --- Prepare defaults/previous ---
    WGPORT_PREV="$(conf_get WGPORT "$WG_FILTER_CONF_PATH")"
    WAN_IF_PREV="$(conf_get WAN_IF "$WG_FILTER_CONF_PATH")"
    HOSTS_PREV="$(conf_get HOSTS "$WG_FILTER_CONF_PATH")"
    EXTRA_URL_PREV="$(conf_get EXTRA_URL "$WG_FILTER_CONF_PATH")"
    CHAIN_PREV="$(conf_get CHAIN "$WG_FILTER_CONF_PATH")"

    # --- Questions to the user ---
    ask WGPORT   "Enter the WireGuard UDP port"                "${WGPORT_PREV:-51234}"          "$WGPORT_PREV"
    ask WAN_IF   "Enter the WAN interface (e.g., eth0)"          "${WAN_IF_PREV:-eth0}"           "$WAN_IF_PREV"
    ask HOSTS    "Enter one or more IP/hostnames (space-separated)" "${HOSTS_PREV:-ddns.example.com}" "$HOSTS_PREV"
    ask EXTRA_URL "Enter URL of the extra IP/CIDR list"              "${EXTRA_URL_PREV:-https://example.com/acl.txt}" "$EXTRA_URL_PREV"
    # For IPTABLES: default = which iptables (not from the file), but we show the previous as a note
    ask IPTABLES "Path to iptables binary"                       "$IPTABLES_DEFAULT"              "$IPTABLES_PREV"
    ask CHAIN    "Name of the dedicated chain for WireGuard"      "${CHAIN_PREV:-WG_FILTER}"       "$CHAIN_PREV"

    if [ "$EXTRA_URL" = "https://example.com/acl.txt" ]; then
    EXTRA_URL=""
    fi

    # --- Write file ---
    info ""
    info "Writing configuration to $WG_FILTER_CONF_PATH ..."
    cat > "$WG_FILTER_CONF_PATH" <<EOF
# ================== WireGuard Filter Config ==================
WGPORT="$WGPORT"
WAN_IF="$WAN_IF"
HOSTS="$HOSTS"
EXTRA_URL="$EXTRA_URL"
IPTABLES="$IPTABLES"
CHAIN="$CHAIN"
EOF

    success "Configuration saved successfully!"
    info ""
    info "Generated content:"
    info "-----------------------------------"
    cat "$WG_FILTER_CONF_PATH"
    info "-----------------------------------"

    # ================== CRONTAB MANAGEMENT ==================
    info ""
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

    info ""
    success "Setup completed"
    #info "Restarting the interface..."
    #info ""
    #reload_and_start_wg_interface "$INTERFACE"
}


enable_disable_filter() {
    header "Firewall Enable/Disable"

    # Controlla se è presente nel crontab
    if crontab -l 2>/dev/null | grep -qE '(^|[[:space:]])wg_filter\.sh([[:space:]]|$)'; then
        
        info "Firewall attualmente ATTIVO"

        # Rimuove wg_filter.sh dal crontab
        crontab -l 2>/dev/null | grep -v "wg_filter.sh" | crontab -

        # Flush completo iptables
        iptables -F
        #iptables -X
        #iptables -t nat -F
        #iptables -t nat -X
        #iptables -t mangle -F
        #iptables -t mangle -X

        success -e "\e[32m *\e[0m Firewall disabilitato (regole rimosse e cron disattivato)"

    else
        
        info "Firewall attualmente DISATTIVO"

        # Aggiunge wg_filter.sh al crontab (ogni 5 minuti esempio)
        (crontab -l 2>/dev/null; echo "*/5 * * * * $WG_FILTER_PATH") | crontab -

        # Esegue subito lo script
        "$WG_FILTER_PATH"

        success -e "\e[32m *\e[0m Firewall abilitato (cron attivo e regole caricate)"
    fi
}
