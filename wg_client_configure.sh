#!/bin/sh
set -eu

echo "=============================="
echo " WireGuard Client Configurator"
echo "=============================="
echo

ask() {
  var="$1"; prompt="$2"; def="${3:-}"
  if [ -n "$def" ]; then printf "%s [%s]: " "$prompt" "$def"; else printf "%s: " "$prompt"; fi
  printf ">> "
  read ans || true
  if [ -n "${ans:-}" ]; then eval "$var=\$ans"; else eval "$var=\$def"; fi
}

ask INTERFACE "Inserisci l'interfaccia WireGuard" "wg0"

WG_DIR="/etc/wireguard"
WG_CONF="${INTERFACE}.conf"
WG_CONF_PATH="${WG_DIR}/${WG_CONF}"
CLIENTS_DIR="${WG_DIR}/clients"

echo "Interfaccia selezionata: $INTERFACE"
echo "File di configurazione: $WG_CONF_PATH"
echo "Directory client:      $CLIENTS_DIR"
echo

die() { echo "ERRORE: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "Esegui come root."; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

install_wg() {
  echo "WireGuard (wg) non trovato."
  echo "Hai eseguito il comando come root?"
  echo "Prima di eseguire questo comando, hai eseguito sys_prepare_alpinelinux.sh?"
  printf "Quale package manager usi? [apk/apt/yum/dnf/zypper/pacman/opkg]: "
  read PM || true
  PM="${PM:-apk}"
  case "$PM" in
    apk)   apk add --no-cache --no-progress wireguard-tools || die "Installazione fallita";;
    apt)   DEBIAN_FRONTEND=noninteractive apt-get update -y && apt-get install -y wireguard-tools || die "Installazione fallita";;
    yum)   yum install -y epel-release || true; yum install -y wireguard-tools || die "Installazione fallita";;
    dnf)   dnf install -y wireguard-tools || die "Installazione fallita";;
    zypper) zypper --non-interactive install wireguard-tools || die "Installazione fallita";;
    pacman) pacman -Sy --noconfirm wireguard-tools || die "Installazione fallita";;
    opkg)  opkg update && opkg install wireguard-tools || die "Installazione fallita";;
    *) die "Package manager non supportato: $PM";;
  esac
}

conf_get() {
  key="$1"
  if [ -f "$WG_CONF_PATH" ]; then
    # usa grep + cut, più portabile
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$WG_CONF_PATH" 2>/dev/null \
      | head -n1 \
      | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//" \
      | tr -d '\r' \
      | sed 's/[[:space:]]*$//'
  fi
}

conf_comment_get() {
  key="$1"
  if [ -f "$WG_CONF_PATH" ]; then
    grep -E "^# *${key}:" "$WG_CONF_PATH" 2>/dev/null \
      | head -n1 \
      | sed -E "s/^# *${key}:[[:space:]]*//" \
      | tr -d '\r' \
      | sed 's/[[:space:]]*$//'
  fi
}

first_three() { echo "$1" | awk -F'[./]' '{print $1"."$2"."$3}'; }
last_octet()  { echo "$1" | awk -F'[./]' '{print $4}'; }

ensure_dirs() { [ -d "$CLIENTS_DIR" ] || mkdir -p "$CLIENTS_DIR"; }

calc_client_ip() {
  subnet="$1"; num="$2"
  base3=$(first_three "$subnet")
  base_last=$(last_octet "$subnet")
  host=$((base_last + 1 + num))
  echo "${base3}.${host}"
}

next_free_client_number() {
  max="$1"; n=1
  while [ "$n" -le "$max" ]; do
    if ! ls "${CLIENTS_DIR}/client${n}_"*  >/dev/null 2>&1; then
      echo "$n"; return
    fi
    n=$((n+1))
  done
  echo 0
}

list_clients() {
  for f in "${CLIENTS_DIR}"/client*_*_config.conf; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    num=$(echo "$b" | sed -E 's/^client([0-9]+)_.*/\1/')
    name=$(echo "$b" | sed -E 's/^client[0-9]+_([^_]+)_config\.conf/\1/')
    [ -n "$num" ] && [ -n "$name" ] && echo "$num $name"
  done | sort -n -k1
}

server_remove_peer_block() {
  # remove [Peer] block that has comment "# clientN_NAME"
  label="$1"
  tmp="${WG_CONF_PATH}.tmp.$$"
  awk -v L="$label" '
    BEGIN{skip=0}
    /^\[Peer\]/ {    # start peer block
      if (getline nextline) {
        # we will print [Peer] and the line we read later if not skipping
        # Save them
        b1=$0; b2=nextline
        # Scan ahead to collect lines until next [Peer] or EOF
        block=b1 "\n" b2 "\n"
        while (getline l) {
          if (l ~ /^\[Peer\]/) { nextPeer=l; hasNext=1; break }
          block=block l "\n"
        }
        # Decide if this block has our label
        if (b2 ~ "#[[:space:]]*" L) {
          # skip this block
          if (hasNext) { print nextPeer; } # start next peer immediately considered by next cycles
          next
        } else {
          # print previous accumulated block
          printf "%s", block;
          if (hasNext) { print nextPeer; }
        }
        next
      }
    }
    { print }
  ' "$WG_CONF_PATH" > "$tmp" && mv "$tmp" "$WG_CONF_PATH"
}

server_append_peer() {
  # args: label(public comment), pubkey, ip
  label="$1"; pubkey="$2"; ip="$3"
  umask 077
  cat >> "$WG_CONF_PATH" <<EOF
[Peer]
# $label
PublicKey = $pubkey
AllowedIPs = ${ip}/32
EOF
}

generate_client_keys() {
  n="$1"; name="$2"
  base="${CLIENTS_DIR}/client${n}_${name}"
  umask 077
  wg genkey > "${base}_secret.key"
  wg pubkey < "${base}_secret.key" > "${base}_public.key"
  chmod 600 "${base}_secret.key" "${base}_public.key"
}

make_client_config() {
  n="$1"; name="$2"; ip="$3"; server_pub="$4"; endpoint="$5"; port="$6"; dns="$7"; office="$8"
  base="${CLIENTS_DIR}/client${n}_${name}"
  umask 077
  cat > "${base}_config.conf" <<EOF
[Interface]
Address = ${ip}/32
PrivateKey = $(cat "${base}_secret.key")
EOF
    if [ -n "$dns" ]; then
        echo "DNS = $dns" >> "${base}_config.conf"
    fi
  cat >> "${base}_config.conf" <<EOF

[Peer]
PublicKey = ${server_pub}
Endpoint = ${endpoint}:${port}
AllowedIPs = ${office}
PersistentKeepalive = 25
EOF
  chmod 600 "${base}_config.conf"
    echo "Riavvio l'interfaccia ..."
    wg-quick down $INTERFACE && wg-quick up $INTERFACE >/dev/null 2>&1
}

rename_client_files() {
  n="$1"; old="$2"; new="$3"
  oldb="${CLIENTS_DIR}/client${n}_${old}"
  newb="${CLIENTS_DIR}/client${n}_${new}"
  for t in secret.key public.key config.conf; do
    if [ -f "${oldb}_$t" ]; then mv "${oldb}_$t" "${newb}_$t"; fi
  done
}

# ----- LETTURA SERVER -----
need_root
have_cmd wg || install_wg
ensure_dirs
[ -f "$WG_CONF_PATH" ] || die "File server non trovato: $WG_CONF_PATH"

while true; do
    SERVER_SUBNET="$(conf_comment_get "Subnet")"
    SERVER_SUBNET_VPN="$(conf_comment_get "Subnet VPN")"
    SERVER_PUBKEY="$(conf_comment_get "PublicKey")"
    SERVER_PORT="$(conf_get ListenPort)"
    SERVER_ENDPOINT="$(conf_comment_get "Endpoint Host")"
    SERVER_DNS="$(conf_comment_get "DNS")"
    MAX_CLIENTS="$(conf_comment_get "Max Clients" || echo 254)"
    BASE3="$(first_three "$SERVER_SUBNET_VPN")"

    CLIENTS=$(ls "$CLIENTS_DIR"/*_config.conf 2>/dev/null | wc -l || echo 0)
    FREE=$((MAX_CLIENTS - CLIENTS))
    [ "$FREE" -lt 0 ] && FREE=0

    echo "=============================="
    echo " WireGuard Client Manager"
    echo "=============================="
    echo
    echo "Client supportati : $MAX_CLIENTS"
    echo "Client configurati: $CLIENTS"
    echo "Client liberi     : $FREE"
    echo
    echo "Elenco client configurati:"
    CLIENT_LIST=$(list_clients)
    [ -n "$CLIENT_LIST" ] && echo "$CLIENT_LIST" | awk '{printf " %2d) client%s_%s\n",$1,$1,$2}' || echo " (nessuno)"
    echo

    # ----- MENU -----
    echo "Scegli azione:"
    echo " [1] Aggiungi client"
    echo " [2] Modifica client"
    echo " [3] Cancella client"
    echo " [4] Avvia microserver (solo .conf)"
    echo " [5] Rigenera file di configurazione (.conf) per un client"
    echo " [6] Esci"
    printf "> "
    read ACTION || true

    case "$ACTION" in
    1)
        [ "$FREE" -gt 0 ] || { echo "Nessuno slot libero."; continue; }
        ask NAME "Nome client" ""
        NUM=$(next_free_client_number "$MAX_CLIENTS")
        IP="${BASE3}.$((1+NUM))"

        ask OFFICE "Subnet ufficio (es. 192.168.1.0/24 o multiple, virgola)" "$SERVER_SUBNET"

        # Recupera la Subnet dal file server ${WG_CONF_PATH}
        if [ -n "$SERVER_SUBNET_VPN" ]; then
            OFFICE="$SERVER_SUBNET_VPN,$OFFICE"
            echo "→ Subnet finale autorizzata: $OFFICE"
        fi

        # Recupera il DNS dal file server ${WG_CONF_PATH}
        ask SERVER_DNS "DNS (es. 1.1.1.1 o vuoto per nessuno)" "$SERVER_DNS"

        generate_client_keys "$NUM" "$NAME"
        make_client_config "$NUM" "$NAME" "$IP" "$SERVER_PUBKEY" "$SERVER_ENDPOINT" "$SERVER_PORT" "$SERVER_DNS" "$OFFICE"
        server_append_peer "client${NUM}_${NAME}" "$(cat "${CLIENTS_DIR}/client${NUM}_${NAME}_public.key")" "${IP}"
        echo "Creato client${NUM}_${NAME}"
        ;;

    2)
        [ -n "$CLIENT_LIST" ] || { echo "Nessun client da modificare."; continue; }
        echo "Inserisci numero client da modificare:"
        printf ">> "
        read N || true
        [ -n "$N" ] || { echo "Numero non inserito."; continue; }

        CFG_FILE=$(ls "${CLIENTS_DIR}/client${N}_"*_config.conf 2>/dev/null | head -n1 || true)
        if [ -z "$CFG_FILE" ] || [ ! -f "$CFG_FILE" ]; then
            echo "Nessun client con numero ${N} trovato."
            echo "Premi INVIO per tornare al menu..."
            read dummy || true
            continue
        fi

        NAME=$(basename "$CFG_FILE" | sed -E 's/^client[0-9]+_([^_]+)_config\.conf$/\1/')
        CFG="${CLIENTS_DIR}/client${N}_${NAME}_config.conf"
        SECRET="${CLIENTS_DIR}/client${N}_${NAME}_secret.key"
        PUB="${CLIENTS_DIR}/client${N}_${NAME}_public.key"

        [ -f "$CFG" ] || { echo "File config non trovato per client${N}_${NAME}."; continue; }

        # Estrai valori correnti
        CUR_IP=$(grep -E "^Address" "$CFG" | head -n1 | cut -d'=' -f2 | tr -d ' ' | cut -d/ -f1)
        CUR_DNS=$(grep -E "^DNS" "$CFG" | head -n1 | cut -d'=' -f2 | tr -d ' ')
        CUR_ALLOWED=$(grep -E "^AllowedIPs" "$CFG" | head -n1 | cut -d'=' -f2- | xargs)
        CUR_PUBKEY=$(cat "$PUB" 2>/dev/null || echo "<chiave mancante>")

        echo
        echo "=== Modifica client${N}_${NAME} ==="
        echo " IP attuale        : $CUR_IP"
        echo " Subnet ufficio    : $CUR_ALLOWED"
        echo " PublicKey attuale : $CUR_PUBKEY"
        echo " DNS attuale       : $CUR_DNS"
        echo

        # --- chiedi nuovo nome ---
        ask NEW_NAME "Nuovo nome client" "$NAME"
        [ -n "$NEW_NAME" ] || NEW_NAME="$NAME"

        # --- chiedi nuovo IP ---
        DEF_NEW_IP="$(calc_client_ip "$SERVER_SUBNET_VPN" "$N")"
        ask NEW_IP "Nuovo IP (formato x.y.z.w nella VPN)" "$CUR_IP"
        [ -n "$NEW_IP" ] || NEW_IP="$CUR_IP"

        # --- chiedi nuove subnet ufficio ---
        echo "  Subnet VPN: ${SERVER_SUBNET_VPN:-<nessuno>}"
        echo "  Subnet ufficio: ${SERVER_SUBNET:-<nessuno>}"
        ask NEW_OFFICE "Subnet ufficio (es. 192.168.1.0/24 o multiple, virgola)" "$CUR_ALLOWED"
        [ -n "$NEW_OFFICE" ] || NEW_OFFICE="$CUR_ALLOWED"

        # --- chiedi nuovo DNS ---
        echo "  DNS attuale: ${CUR_DNS:-<nessuno>}"
        echo "  DNS previsto: ${SERVER_DNS:-<nessuno>}"
        ask NEW_DNS "DNS (es. 1.1.1.1 o vuoto per nessuno)" "$CUR_DNS"
        [ -n "$NEW_DNS" ] || NEW_DNS="$CUR_DNS"

        # --- chiedi se rigenerare chiavi ---
        echo "Vuoi rigenerare le chiavi per questo client? (y/N)"
        printf ">> "
        read REGEN || true
        REGEN="${REGEN:-n}"

        if [ "$REGEN" = "y" ] || [ "$REGEN" = "Y" ]; then
            echo "→ Rigenerazione chiavi per client${N}_${NAME}..."
            generate_client_keys "$N" "$NAME"
            NEW_PUBKEY=$(cat "${CLIENTS_DIR}/client${N}_${NAME}_public.key")
            NEW_PRIVKEY=$(cat "${CLIENTS_DIR}/client${N}_${NAME}_secret.key")
        else
            echo "→ Mantengo le chiavi esistenti."
            NEW_PUBKEY=$(cat "$PUB")
            NEW_PRIVKEY=$(cat "$SECRET")
        fi

        # --- Aggiorna file server (rimuovi blocco vecchio e aggiungi nuovo) ---
        echo "→ Aggiornamento ${WG_CONF}..."
        server_remove_peer_block "client${N}_${NAME}"
        server_append_peer "client${N}_${NEW_NAME}" "$NEW_PUBKEY" "$NEW_IP"

        # --- Rinominazione file se necessario ---
        if [ "$NEW_NAME" != "$NAME" ]; then
            rename_client_files "$N" "$NAME" "$NEW_NAME"
            NAME="$NEW_NAME"
        fi

        # --- Rigenera configurazione client aggiornata ---
        echo "→ Rigenerazione file di configurazione..."
        make_client_config "$N" "$NAME" "$NEW_IP" "$SERVER_PUBKEY" "$SERVER_ENDPOINT" "$SERVER_PORT" "$NEW_DNS" "$NEW_OFFICE"

        echo
        echo "Client aggiornato correttamente:"
        echo " Nome      : client${N}_${NAME}"
        echo " IP        : ${NEW_IP}"
        echo " Subnet    : ${NEW_OFFICE}"
        echo " Chiavi    : $( [ "$REGEN" = "y" ] || [ "$REGEN" = "Y" ] && echo "rigenerate" || echo "invariate" )"
        ;;

    3)
        echo "Inserisci numero client da cancellare:"
        printf ">> "
        read N || true
        [ -n "$N" ] || { echo "Numero non inserito."; continue; }

        CFG_FILE=$(ls "${CLIENTS_DIR}/client${N}_"*_config.conf 2>/dev/null | head -n1 || true)
        if [ -z "$CFG_FILE" ] || [ ! -f "$CFG_FILE" ]; then
            echo "Nessun client con numero ${N} trovato."
            echo "Premi INVIO per tornare al menu..."
            read dummy || true
            continue
        fi

        NAME=$(basename "$CFG_FILE" | sed -E 's/^client[0-9]+_([^_]+)_config\.conf$/\1/')

        echo "Confermi eliminazione di client${N}_${NAME}? (y/N)"
        printf ">> "
        read answer || true
        if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
            echo "→ Rimozione file del client..."
            rm -f "${CLIENTS_DIR}/client${N}_${NAME}"_* 2>/dev/null || true

            echo "→ Rimozione blocco dal file ${WG_CONF}..."
            sed -i "/# client${N}_${NAME}/,/^$/d" "$WG_CONF_PATH" 2>/dev/null || true

            echo "Client client${N}_${NAME} rimosso correttamente."
        else
            echo "Annullato."
            echo
            continue;
        fi
        ;;
    4)
        # Elenco IP locali
        echo "Indirizzi IP disponibili:"
        if have_cmd ip; then
          ip -o -4 addr show | awk '{print $2": "$4}'
        else
          ifconfig | grep "inet "
        fi
        ask BINDIP "Su quale IP vuoi esporre il microserver?" "0.0.0.0"

        PORT=8080
        STOP_PORT=$((PORT + 1))   # porta di controllo separata per /stop
        SRC="$CLIENTS_DIR"
        SHARE="/tmp/wgshare"      # cartella isolata: SOLO .conf
        TMP="/tmp/microserver"; STOP="$TMP/STOP"
        mkdir -p "$TMP" "$SHARE"
        rm -f "$STOP"

        # Copia solo i .conf e genera index.html
        rm -f "$SHARE"/* 2>/dev/null || true
        for f in "$SRC"/*.conf; do [ -f "$f" ] && cp -f "$f" "$SHARE/"; done

        INDEX="$SHARE/index.html"
        {
          echo "<html><head><meta charset=utf-8><title>WireGuard Clients</title></head><body>"
          echo "<h1>Files .conf</h1><ul>"
          for f in "$SHARE"/*.conf; do
            [ -f "$f" ] && bn=$(basename "$f") && echo "<li><a href=\"$bn\">$bn</a></li>"
          done
          echo "</ul><hr>"
          echo "<p><a href=\"http://${BINDIP}:${STOP_PORT}/stop\">Termina server web</a></p>"
          echo "<p>Auto-stop in 5 minuti per sicurezza.</p>"
          echo "</body></html>"
        } > "$INDEX"

        echo "==> Microserver su http://${BINDIP}:${PORT}"
        echo "==> Link stop:   http://${BINDIP}:${STOP_PORT}/stop"
        echo "==> Directory:   $SHARE (SOLO .conf)"

        # Avvio server con fallback: python3 -> darkhttpd -> busybox-httpd/httpd
        PID=""
        if have_cmd python3; then
          echo "→ Avvio microserver con python3 -m http.server"
          (cd "$SHARE" && python3 -m http.server "$PORT" --bind "$BINDIP") &
          PID=$!
          SERVER_KIND="python3"
        elif have_cmd darkhttpd; then
          echo "→ Avvio microserver con darkhttpd"
          darkhttpd "$SHARE" --port "$PORT" --addr "$BINDIP" &
          PID=$!
          SERVER_KIND="darkhttpd"
        elif have_cmd busybox-httpd; then
          echo "→ Avvio microserver con busybox-httpd"
          busybox-httpd -f -p "${BINDIP}:${PORT}" -h "$SHARE" &
          PID=$!
          SERVER_KIND="busybox-httpd"
        elif have_cmd httpd; then
          echo "→ Avvio microserver con httpd"
          httpd -f -p "${BINDIP}:${PORT}" -h "$SHARE" &
          PID=$!
          SERVER_KIND="httpd"
        else
          echo " Nessun server web disponibile (python3 / darkhttpd / busybox-httpd)."
          echo "Suggerimenti: apk add python3   oppure   apk add darkhttpd"
          continue
        fi

        # Auto-stop dopo 5 minuti
        ( sleep 300; touch "$STOP" ) &

        # Porta di controllo /stop (usa nc BusyBox). Nessuna opzione -q usata.
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
                    echo "<html><body><h2>Server terminato.</h2></body></html>"
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
          echo "  'nc' non presente: disponibile solo l'auto-stop a 5 minuti."
          CTRL_PID=""
        fi

        # Attendi richiesta stop o timeout, poi cleanup
        while true; do
          [ -f "$STOP" ] && break
          sleep 1
        done

        echo "==> Arresto microserver ($SERVER_KIND)..."
        [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
        [ -n "${CTRL_PID:-}" ] && kill "$CTRL_PID" 2>/dev/null || true
        rm -f "$STOP"
        ;;

    5)
        echo "Inserisci numero client da rigenerare:"
        printf ">> "
        read N || true
        NAME=$(ls "${CLIENTS_DIR}/client${N}_"*_config.conf | head -n1 | sed 's/.*client[0-9]\+_\([^_]\+\)_config\.conf/\1/')
        [ -n "$NAME" ] || { echo "Client non trovato."; continue; }
        CFG="${CLIENTS_DIR}/client${N}_${NAME}_config.conf"
        IP=$(awk '/Address/{print $3}' "$CFG" | cut -d/ -f1)
        ask OFFICE "Subnet ufficio (es. 192.168.10.0/24 o multiple, virgola)" ""
        make_client_config "$N" "$NAME" "$IP" "$SERVER_PUBKEY" "$SERVER_ENDPOINT" "$SERVER_PORT" "$SERVER_DNS" "$OFFICE"
        echo "Rigenerato file di configurazione per client${N}_${NAME}"
        ;;
    6) echo "Uscita."; exit 0;;
    *) echo "Scelta non valida."; exit 1;;
    esac

    echo "Operazione completata."
    echo
    echo "Premi INVIO per tornare al menu..."
    read dummy || true
done