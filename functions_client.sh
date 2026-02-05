#!/bin/sh

# functions_client.sh
#
# This script provides a set of common functions.

add_client() {
    header "[1] Add client"
    [ "$FREE" -gt 0 ] || { warning "No free slots."; continue; }
    ask NAME "Client name" ""
    NUM=$(next_free_client_number "$MAX_CLIENTS")
    IP="${BASE3}.$((1+NUM))"

    ask OFFICE "Office subnet (e.g. 192.168.1.0/24 or multiple, comma-separated)" "$SERVER_SUBNET"

    # Retrieve the Subnet from the server file ${WG_CONF_PATH}
    if [ -n "$SERVER_SUBNET_VPN" ]; then
        OFFICE="$SERVER_SUBNET_VPN,$OFFICE"
        info "Final authorized subnet: $OFFICE"
    fi

    # Retrieve the DNS from the server file ${WG_CONF_PATH}
    ask SERVER_DNS "DNS (${SERVER_DNS}, 1.1.1.1 or empty for none)" ""

    generate_client_keys "$NUM" "$NAME"
    make_client_config "$NUM" "$NAME" "$IP" "$SERVER_PUBKEY" "$SERVER_ENDPOINT" "$SERVER_PORT" "$SERVER_DNS" "$OFFICE"
    server_append_peer "client${NUM}_${NAME}" "$(cat "${CLIENTS_DIR}/client${NUM}_${NAME}_public.key")" "${IP}"
    reload_and_start_wg_interface "$INTERFACE"
    success "Created client${NUM}_${NAME}"
}

modify_client() {
    header "[2] Modify client"
    [ -n "$CLIENT_LIST" ] || { warning "No client to modify."; continue; }

    ask N "Enter client number to modify" ""
    [ -n "$N" ] || { warning "Number not entered."; continue; }

    CFG_FILE=$(ls "${CLIENTS_DIR}/client${N}_"*_config.conf 2>/dev/null | head -n1 || true)
    if [ -z "$CFG_FILE" ] || [ ! -f "$CFG_FILE" ]; then
        warning "No client with number ${N} found."
        info "Press ENTER to return to the menu..."
        read dummy || true
        continue
    fi

    NAME=$(basename "$CFG_FILE" | sed -E 's/^client[0-9]+_([^_]+)_config\.conf$/\1/')
    CFG="${CLIENTS_DIR}/client${N}_${NAME}_config.conf"
    SECRET="${CLIENTS_DIR}/client${N}_${NAME}_secret.key"
    PUB="${CLIENTS_DIR}/client${N}_${NAME}_public.key"

    [ -f "$CFG" ] || { warning "Config file not found for client${N}_${NAME}."; continue; }

    # Extract current values
    CUR_IP=$(grep -E "^Address" "$CFG" | head -n1 | cut -d'=' -f2 | tr -d ' ' | cut -d/ -f1)
    CUR_DNS=$(grep -E "^DNS" "$CFG" | head -n1 | cut -d'=' -f2 | tr -d ' ')
    CUR_ALLOWED=$(grep -E "^AllowedIPs" "$CFG" | head -n1 | cut -d'=' -f2- | xargs)
    CUR_PUBKEY=$(cat "$PUB" 2>/dev/null || echo "<key missing>")

    info ""
    info "=== Modify client${N}_${NAME} ==="
    info " Current IP        : $CUR_IP"
    info " Office subnet    : $CUR_ALLOWED"
    info " Current PublicKey : $CUR_PUBKEY"
    info " Current DNS       : $CUR_DNS"
    info ""

    # --- ask for new name ---
    ask NEW_NAME "New client name" "$NAME"
    [ -n "$NEW_NAME" ] || NEW_NAME="$NAME"

    # --- ask for new IP ---
    DEF_NEW_IP="$(calc_client_ip "$SERVER_SUBNET_VPN" "$N")"
    ask NEW_IP "New IP (format x.y.z.w in the VPN)" "$CUR_IP"
    [ -n "$NEW_IP" ] || NEW_IP="$CUR_IP"

    # --- ask for new office subnets ---
    info "  VPN Subnet: ${SERVER_SUBNET_VPN:-<none>}"
    info "  Office subnet: ${SERVER_SUBNET:-<none>}"
    ask NEW_OFFICE "Authorized subnet (e.g. 192.168.1.0/24 or multiple, comma-separated)" "$CUR_ALLOWED"
    [ -n "$NEW_OFFICE" ] || NEW_OFFICE="$CUR_ALLOWED"

    # --- ask for new DNS ---
    info "  Current DNS: ${CUR_DNS:-<none>}"
    info "  Expected DNS: ${SERVER_DNS:-<none>}"
    ask NEW_DNS "DNS (e.g. 1.1.1.1 or empty for none)" "$CUR_DNS"
    [ -n "$NEW_DNS" ] || NEW_DNS="$CUR_DNS"

    info ""
    # --- ask if keys should be regenerated ---
    ask REGEN "Do you want to regenerate the keys for this client? (y/N)" "N"
    REGEN="${REGEN:-n}"

    if [ "$REGEN" = "y" ] || [ "$REGEN" = "Y" ]; then
        info "Regenerating keys for client${N}_${NAME}..."
        generate_client_keys "$N" "$NAME"
        NEW_PUBKEY=$(cat "${CLIENTS_DIR}/client${N}_${NAME}_public.key")
        NEW_PRIVKEY=$(cat "${CLIENTS_DIR}/client${N}_${NAME}_secret.key")
    else
        info "Keeping existing keys."
        NEW_PUBKEY=$(cat "$PUB")
        NEW_PRIVKEY=$(cat "$SECRET")
    fi

    # --- Update server file (remove old block and add new one) ---
    info ""
    info "Updating ${WG_CONF}..."
    server_remove_peer_block "client${N}_${NAME}"
    server_append_peer "client${N}_${NEW_NAME}" "$NEW_PUBKEY" "$NEW_IP"

    # --- Rename files if necessary ---
    if [ "$NEW_NAME" != "$NAME" ]; then
        rename_client_files "$N" "$NAME" "$NEW_NAME"
        NAME="$NEW_NAME"
    fi

    # --- Regenerate updated client configuration ---
    info "Regenerating configuration file..."
    make_client_config "$N" "$NAME" "$NEW_IP" "$SERVER_PUBKEY" "$SERVER_ENDPOINT" "$SERVER_PORT" "$NEW_DNS" "$NEW_OFFICE"

    reload_and_start_wg_interface "$INTERFACE"
    info ""
    success "Client updated successfully:"
    info " Name      : client${N}_${NAME}"
    info " IP        : ${NEW_IP}"
    info " Subnet    : ${NEW_OFFICE}"
    info " Keys      : $( [ "$REGEN" = "y" ] || [ "$REGEN" = "Y" ] && echo "regenerated" || echo "unchanged" )"
}

delete_client() {
    header "[3] Delete client"
    ask N "Enter client number to delete" ""
    [ -n "$N" ] || { warning "Number not entered."; continue; }

    CFG_FILE=$(ls "${CLIENTS_DIR}/client${N}_"*_config.conf 2>/dev/null | head -n1 || true)
    if [ -z "$CFG_FILE" ] || [ ! -f "$CFG_FILE" ]; then
        warning "No client with number ${N} found."
        info "Press ENTER to return to the menu..."
        read dummy || true
        continue
    fi

    NAME=$(basename "$CFG_FILE" | sed -E 's/^client[0-9]+_([^_]+)_config\.conf$/\1/')

    ask answer "Confirm deletion of client${N}_${NAME}? (y/N)" ""
    if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
        info "Removing client files..."
        rm -f "${CLIENTS_DIR}/client${N}_${NAME}"_* 2>/dev/null || true

        info "Removing block from ${WG_CONF} file..."
        sed -i "/# client${N}_${NAME}/,/^$/d" "$WG_CONF_PATH" 2>/dev/null || true
        reload_and_start_wg_interface "$INTERFACE"

        success "Client client${N}_${NAME} removed successfully."
    else
        info "Cancelled."
        info ""
        continue;
    fi
}

start_microserver() {
    header "[4] Start microserver"
    info "Available IP addresses:"
    list_local_ips | while IFS= read -r line; do
        [ -n "$line" ] && info "$line"
    done

    SERVER_IP=""

    if [ -n "${SERVER_SUBNET:-}" ]; then
        SERVER_IP=$(
        list_local_ips | while IFS= read -r line; do
            # estrai il primo IPv4 dalla riga (funziona sia con "1.2.3.4/24" che con "1.2.3.4")
            addr=$(printf '%s\n' "$line" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
            [ -z "$addr" ] && continue

            base=${SERVER_SUBNET%/*}
            maskbits=${SERVER_SUBNET#*/}

            if ip_in_subnet "$addr" "$base" "$maskbits"; then
            echo "$addr"
            exit 0  # ferma il while nella subshell e restituisce l'IP al command substitution
            fi
        done
        )
    fi

    ask BINDIP "On which IP do you want to expose the microserver? (0.0.0.0 to bind on all interfaces)" "${SERVER_IP:-0.0.0.0}"

    PORT="$(get_free_port)"
    STOP_PORT=$((PORT + 1))   # separate control port for /stop
    SRC="$CLIENTS_DIR"
    SHARE="/tmp/wgshare"      # isolated folder: ONLY .conf
    TMP="/tmp/microserver"; STOP="$TMP/STOP"
    mkdir -p "$TMP" "$SHARE"
    rm -f "$STOP"

    # Copy only .conf and generate index.html
    rm -f "$SHARE"/* 2>/dev/null || true
    for f in "$SRC"/*.conf; do [ -f "$f" ] && cp -f "$f" "$SHARE/"; done
    for f in "$SRC"/*.csv; do [ -f "$f" ] && cp -f "$f" "$SHARE/"; done

    INDEX="$SHARE/index.html"
    {
        echo "<html><head><meta charset=utf-8><title>WireGuard Clients</title></head><body>"
        echo "<h1>.conf Files</h1><ul>"
        for f in "$SHARE"/*.conf; do
        [ -f "$f" ] && bn=$(basename "$f") && echo "<li><a href=\"$bn\">$bn</a></li>"
        done
        echo "</ul><hr>"
        echo "<p><a href=\"http://${SERVER_IP:-BINDIP}:${STOP_PORT}/stop\">Stop web server</a></p>"
        echo "<p>Auto-stop in 5 minutes for security.</p>"
        echo "</body></html>"
    } > "$INDEX"

    info "==> Microserver on http://${BINDIP}:${PORT}"
    info "==> Stop link:   http://${BINDIP}:${STOP_PORT}/stop"
    info "==> Directory:   $SHARE (ONLY .conf)"

    # Start server with fallback: python3 -> darkhttpd -> busybox-httpd/httpd
    PID=""
    if have_cmd python3; then
        info "Starting microserver with python3 -m http.server"
        (cd "$SHARE" && python3 -m http.server "$PORT" --bind "$BINDIP") &
        PID=$!
        SERVER_KIND="python3"
    elif have_cmd darkhttpd; then
        info "Starting microserver with darkhttpd"
        darkhttpd "$SHARE" --port "$PORT" --addr "$BINDIP" &
        PID=$!
        SERVER_KIND="darkhttpd"
    elif have_cmd busybox-httpd; then
        info "Starting microserver with busybox-httpd"
        busybox-httpd -f -p "${BINDIP}:${PORT}" -h "$SHARE" &
        PID=$!
        SERVER_KIND="busybox-httpd"
    elif have_cmd httpd; then
        info "Starting microserver with httpd"
        httpd -f -p "${BINDIP}:${PORT}" -h "$SHARE" &
        PID=$!
        SERVER_KIND="httpd"
    else
        warning " No web server available (python3 / darkhttpd / busybox-httpd)."
        warning "Suggestions: apk add python3   or   apk add darkhttpd"
        continue
    fi

    # Auto-stop after 5 minutes
    ( sleep 300; touch "$STOP" ) &

    # Control port /stop (uses nc BusyBox). No -q option used.
    if have_cmd nc; then
        (
        while true; do
            REQ="$(nc -l -p "$STOP_PORT" -s "$BINDIP" -w 2 < /dev/null 2>/dev/null | head -n1 || true)"
            case "$REQ" in
            *"GET /stop"*)
                {
                echo "HTTP/1.1 200 OK"
                echo "Content-Type: text/html"
                echo
                echo "<html><body><h2>Server stopped.</h2></body></html>"
                } | nc -l -p "$STOP_PORT" -s "$BINDIP" -w 1 >/dev/null 2>&1 &
                touch "$STOP"
                break
                ;;
            esac
            [ -f "$STOP" ] && break
            sleep 1
        done
        ) &
        CTRL_PID=$!
    else
        warning "  'nc' not present: only 5-minute auto-stop is available."
        CTRL_PID=""
    fi

    # Wait for stop request or timeout, then cleanup
    while true; do
        [ -f "$STOP" ] && break
        sleep 1
    done

    info "==> Stopping microserver ($SERVER_KIND)..."
    [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
    [ -n "${CTRL_PID:-}" ] && kill "$CTRL_PID" 2>/dev/null || true
    rm -f "$STOP"
}

regenerate_config() {
    header "[5] Regenerate client configurations"
    ask N "Enter client number to regenerate" ""
    NAME=$(ls "${CLIENTS_DIR}/client${N}_"*_config.conf | head -n1 | sed 's/.*client[0-9]\+_\([^_]\+\)_config\.conf/\1/')
    [ -n "$NAME" ] || { warning "Client not found."; continue; }
    CFG="${CLIENTS_DIR}/client${N}_${NAME}_config.conf"
    IP=$(awk '/Address/{print $3}' "$CFG" | cut -d/ -f1)
    ask OFFICE "Office subnet (e.g. 192.168.10.0/24 or multiple, comma-separated)" ""
    make_client_config "$N" "$NAME" "$IP" "$SERVER_PUBKEY" "$SERVER_ENDPOINT" "$SERVER_PORT" "$SERVER_DNS" "$OFFICE"
    reload_and_start_wg_interface "$INTERFACE"
    success "Regenerated configuration file for client${N}_${NAME}"
}

test_vpn_configuration() {
    header "[6] Test VPN configuration"
    info "This function tests the VPN connection using wg-quick."

    ask N "Enter client number to test" ""
    NAME=$(ls "${CLIENTS_DIR}/client${N}_"*_config.conf 2>/dev/null | head -n1 | sed 's/.*client[0-9]\+_\([^_]\+\)_config\.conf/\1/')
    [ -n "$NAME" ] || { warning "Client not found."; return; }
    CFG="${CLIENTS_DIR}/client${N}_${NAME}_config.conf"

    #info "Bringing up the VPN interface using wg-quick..."
    #if ! wg-quick up "$CFG" >/dev/null 2>&1; then
    #    warning "Failed to bring up VPN interface. Check configuration."
    #    return
    #fi

    #info "VPN interface is up. Performing connectivity checks..."
    #sleep 2

    # --- 1️⃣ Gateway ping test ---
    GATEWAY=$(ip route | awk '/default/ {print $3; exit}')
    if [ -n "$GATEWAY" ]; then
        if ping -c1 -W2 "$GATEWAY" >/dev/null 2>&1; then
            success "Gateway reachable: $GATEWAY"
        else
            warning "Gateway not reachable: $GATEWAY"
        fi
    else
        warning "No default gateway detected."
    fi

    # --- 2️⃣ DNS test ---
    if nslookup google.com 8.8.8.8 >/dev/null 2>&1 || dig +short google.com >/dev/null 2>&1; then
        success "DNS resolution working"
    else
        warning "DNS resolution failed"
    fi

    # --- 3️⃣ Internet connectivity test ---
    if curl -fsSL https://ifconfig.me >/dev/null 2>&1 || wget -qO- https://ifconfig.me >/dev/null 2>&1; then
        success "Internet connectivity OK"
    else
        warning "Internet not reachable"
    fi

    # --- 4️⃣ Endpoint verification ---
    PUBLIC_IP="unknown"
    if command -v curl >/dev/null 2>&1; then
        PUBLIC_IP=$(curl -fsSL https://ifconfig.me 2>/dev/null || echo "unknown")
    elif command -v wget >/dev/null 2>&1; then
        PUBLIC_IP=$(wget -qO- https://ifconfig.me 2>/dev/null || echo "unknown")
    fi

    ENDPOINT=$(grep -E '^Endpoint *= *' "$CFG" | awk '{print $3}' | cut -d: -f1)
    if [ -n "$ENDPOINT" ] && [ "$ENDPOINT" = "$PUBLIC_IP" ]; then
        success "Endpoint matches public IP ($PUBLIC_IP)"
    else
        warning "Endpoint mismatch: config=$ENDPOINT, detected=$PUBLIC_IP"
    fi

    #ask dummy "Press ENTER to bring down the VPN interface..." ""
    #wg-quick down "$CFG" >/dev/null 2>&1
    #success "VPN interface brought down."
}
