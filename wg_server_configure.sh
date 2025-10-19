#!/bin/sh
set -eu

echo "=============================="
echo " WireGuard Server Configurator"
echo "=============================="
echo

# --- helper per prompt interattivo ---
ask() {
  varname="$1"
  question="$2"
  default="$3"

  if [ -n "${default:-}" ]; then
    printf "%s [%s]: " "$question" "$default"
  else
    printf "%s: " "$question"
  fi
  read input || true
  if [ -n "${input:-}" ]; then
    eval "$varname=\"\$input\""
  else
    eval "$varname=\"\$default\""
  fi
}

ask INTERFACE "Inserisci l'interfaccia WireGuard" "wg0"

WG_DIR="/etc/wireguard"
WG_CONF="${INTERFACE}.conf"
WG_CONF_PATH="${WG_DIR}/${WG_CONF}"
PRIVATE_KEY="${WG_DIR}/server_private.key"
PUBLIC_KEY="${WG_DIR}/server_public.key"

echo "Interfaccia WireGuard selezionata: $INTERFACE"

if [ ! -e "/etc/init.d/wg-quick.${INTERFACE}" ]; then
    ln -s /etc/init.d/wg-quick "/etc/init.d/wg-quick.${INTERFACE}"
    echo
    echo "Creato link simbolico: /etc/init.d/wg-quick.${INTERFACE}"
fi

echo

[ -d "$WG_DIR" ] || mkdir -p "$WG_DIR"

# --- funzione per leggere un valore esistente da wg0.conf ---
get_conf_value() {
  key="$1"
  if [ -f "$WG_CONF_PATH" ]; then
    awk -v k="$key" '
      $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
        val=$0
        sub("^[[:space:]]*"k"[[:space:]]*=[[:space:]]*","",val)
        gsub(/[[:space:]]+$/, "", val)
        print val
        exit
      }' "$WG_CONF_PATH"
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

# --- calcola maschera adatta al numero di client ---
calc_netmask() {
  clients="$1"
  if [ "$clients" -le 2 ]; then echo "30"
  elif [ "$clients" -le 6 ]; then echo "29"
  elif [ "$clients" -le 14 ]; then echo "28"
  elif [ "$clients" -le 30 ]; then echo "27"
  elif [ "$clients" -le 62 ]; then echo "26"
  elif [ "$clients" -le 126 ]; then echo "25"
  else echo "24"
  fi
}

# --- calcola range IP da indirizzo e netmask ---
calc_range() {
  ip="$1"
  maskbits="$2"

  IFS=. read -r i1 i2 i3 i4 <<EOF
$ip
EOF
  mask=$((0xFFFFFFFF << (32 - maskbits) & 0xFFFFFFFF))
  ipnum=$(( (i1 << 24) + (i2 << 16) + (i3 << 8) + i4 ))
  net=$(( ipnum & mask ))
  bcast=$(( net + ( (1 << (32 - maskbits)) - 1 ) ))
  start=$(( net + 1 ))
  end=$(( bcast - 1 ))

  ip_to_str() { printf "%d.%d.%d.%d" $(( ($1>>24)&255 )) $(( ($1>>16)&255 )) $(( ($1>>8)&255 )) $(( $1&255 )); }

  net_str=$(ip_to_str "$net")
  start_str=$(ip_to_str "$start")
  end_str=$(ip_to_str "$end")
  bcast_str=$(ip_to_str "$bcast")

  echo "$net_str - $bcast_str|$start_str - $end_str"
}

# --- lettura vecchi valori se presenti ---
OLD_ADDR="$(get_conf_value Address | awk -F'/' '{print $1}')"
OLD_PORT="$(get_conf_value ListenPort)"
OLD_ENDPOINT="$(conf_comment_get "Endpoint Host")"
OLD_DNS="$(conf_comment_get "DNS")"

# --- trovo la subnet da condividere in VPN ---
echo "Interfacce di rete disponibili:"
IFACES=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v lo || ifconfig -a | grep '^[^ ]' | awk '{print $1}' | grep -v lo)

n=1
for i in $IFACES; do
  echo "  $n) $i"
  n=$((n+1))
done

# --- Step 2: chiedi all'utente quale interfaccia usare ---
echo
printf "Seleziona un'interfaccia da condividere in VPN [1-%d]: " $((n-1))
read sel

sel_if=$(echo "$IFACES" | sed -n "${sel}p" || true)

if [ -z "$sel_if" ]; then
  echo "Selezione non valida." >&2
  exit 1
fi

echo "Interfaccia selezionata: $sel_if"
echo

# --- Step 3: rileva la subnet dell'interfaccia ---
# Tenta con ip, poi fallback su ifconfig
OFFICE_SUBNET=""

if command -v ip >/dev/null 2>&1; then
  # Esempio output: inet 192.168.1.10/24 brd ...
  CIDR=$(ip -o -4 addr show "$sel_if" | awk '{print $4}' | head -n1)
  if [ -n "$CIDR" ]; then
    BASE=$(echo "$CIDR" | cut -d'/' -f1 | awk -F. '{printf "%d.%d.%d.0", $1,$2,$3}')
    MASK=$(echo "$CIDR" | cut -d'/' -f2)
    OFFICE_SUBNET="${BASE}/${MASK}"
  fi
elif command -v ifconfig >/dev/null 2>&1; then
  IP=$(ifconfig "$sel_if" | awk '/inet /{print $2;exit}')
  MASK=$(ifconfig "$sel_if" | awk '/netmask/{print $4;exit}')
  if [ -n "$IP" ] && [ -n "$MASK" ]; then
    # Convert netmask to CIDR bits
    MASKBITS=$(printf "%d.%d.%d.%d" $(echo "$MASK" | tr '.' ' ') |
      awk -F. '{for(i=1;i<=4;i++){n=0;v=$i;while(v){n+=v%2;v=int(v/2)};c+=n}print c}')
    BASE=$(echo "$IP" | awk -F. '{printf "%d.%d.%d.0",$1,$2,$3}')
    OFFICE_SUBNET="${BASE}/${MASKBITS}"
  fi
fi


# --- prompt ---
ask SERVER_IP "Inserisci l'IP del server VPN" "${OLD_ADDR:-100.64.1.1}"
ask NUM_CLIENTS "Quanti client si collegheranno a questo server?" "1"
ask PORT "Inserisci la porta UDP WireGuard" "${OLD_PORT:-51234}"
ask ENDPOINT "Inserisci l'endpoint pubblico (hostname o IP pubblico)" "$OLD_ENDPOINT"
ask DNS "Vuoi impostare un DNS per i client (es. 1.1.1.1 o vuoto per nessuno)" "$OLD_DNS"
ask SUBNET "Subnet ufficio da condividere in VPN" "$OFFICE_SUBNET"

NETMASK="$(calc_netmask "$NUM_CLIENTS")"

# Calcolo network base da IP
IFS=. read -r a b c d <<EOF
$SERVER_IP
EOF

# Calcola la base subnet corretta allineata al blocco CIDR
block_size=$(( 2 ** (32 - NETMASK) ))
last_octet_base=$(( (d / block_size) * block_size ))
BASE_SUBNET_VPN="${a}.${b}.${c}.${last_octet_base}"
SUBNET_VPN="${BASE_SUBNET_VPN}/${NETMASK}"
ADDRESS="${SERVER_IP}/${NETMASK}"

RANGE_INFO="$(calc_range "$SERVER_IP" "$NETMASK")"
VPN_RANGE_NET="$(echo "$RANGE_INFO" | cut -d'|' -f1)"
VPN_RANGE_CLIENTS="$(echo "$RANGE_INFO" | cut -d'|' -f2)"

echo
echo "→ Verrà usato Address = ${ADDRESS}"
echo "→ La subnet VPN sarà  = ${SUBNET_VPN}"
echo "→ Subnet ufficio      = ${SUBNET}"
echo "→ Range IP VPN        = ${VPN_RANGE_NET}"
echo "→ Range client        = ${VPN_RANGE_CLIENTS}"
echo

# --- genera chiavi se mancanti ---
if ! command -v wg >/dev/null 2>&1; then
  echo "⚠️  Il comando 'wg' non è installato. Installalo prima (es. 'apk add wireguard-tools' o 'apt install wireguard')."
  exit 1
fi

if [ ! -f "$PRIVATE_KEY" ]; then
  echo "Generazione nuova chiave privata server..."
  umask 077
  wg genkey > "$PRIVATE_KEY"
fi

if [ ! -f "$PUBLIC_KEY" ]; then
  echo "Generazione nuova chiave pubblica server..."
  wg pubkey < "$PRIVATE_KEY" > "$PUBLIC_KEY"
fi

# --- stop interface ---
echo
echo "Stoppo l'interfaccia se attiva ..."
if wg show "$INTERFACE" >/dev/null 2>&1; then
  wg-quick down "$INTERFACE" >/dev/null 2>&1 || true
fi

# --- scrittura wg0.conf ---
echo
echo "Scrittura configurazione in $WG_CONF ..."

if [ -f "$WG_CONF_PATH" ]; then
  cp "$WG_CONF_PATH" "${WG_CONF_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
  echo "→ Backup eseguito in ${WG_CONF_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
fi

# Se esiste già una configurazione, estrai i blocchi [Peer]
PEERS_TMP=""
if [ -f "$WG_CONF_PATH" ]; then
  echo "→ Rilevata configurazione esistente, salvo i blocchi [Peer]..."
  PEERS_TMP="$(awk '/^\[Peer\]/{flag=1} flag{print}' "$WG_CONF_PATH" || true)"
fi

umask 077
cat > "$WG_CONF_PATH" <<EOF
# ======================== WireGuard Server Configuration ========================

[Interface]
Address = $ADDRESS
ListenPort = $PORT
PrivateKey = $(cat "$PRIVATE_KEY")

# --- Routing & Firewall Rules ---
PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = iptables -t nat -A POSTROUTING -s ${SUBNET_VPN} -j MASQUERADE
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -j ACCEPT

PostDown = sysctl -w net.ipv4.ip_forward=0
PostDown = iptables -t nat -D POSTROUTING -s ${SUBNET_VPN} -j MASQUERADE
PostDown = iptables -A FORWARD -i wg0 -j ACCEPT
PostDown = iptables -A FORWARD -o wg0 -j ACCEPT

# --- Endpoint Info ---
# Endpoint: ${ENDPOINT}:${PORT}
# Endpoint Host: ${ENDPOINT}
# Endpoint Port: ${PORT}
# PublicKey: $(cat "$PUBLIC_KEY")
# Subnet: ${SUBNET}
# Subnet VPN: ${SUBNET_VPN}
# Max Clients: ${NUM_CLIENTS}
EOF
if [ -n "$DNS" ]; then
  echo "# DNS: $DNS" >> "$WG_CONF_PATH"
fi


# Se erano presenti peer, li riaggiungo in fondo
if [ -n "$PEERS_TMP" ]; then
  echo >> "$WG_CONF_PATH"
  echo "$PEERS_TMP" >> "$WG_CONF_PATH"
fi

chmod 600 "$WG_CONF_PATH"

echo "→ Configurazione aggiornata con $(echo "$PEERS_TMP" | grep -c '^\[Peer\]' || echo 0) peer mantenuti."

# --- riepilogo ---
echo
echo "Configurazione completata!"
echo
echo "File generati:"
echo " - $WG_CONF_PATH"
echo " - $PRIVATE_KEY"
echo " - $PUBLIC_KEY"
echo
echo "Dettagli principali:"
echo " Address     : $ADDRESS"
echo " Subnet      : $SUBNET"
echo " Subnet VPN  : $SUBNET_VPN"
echo " Range VPN   : $VPN_RANGE_NET"
echo " Range client: $VPN_RANGE_CLIENTS"
echo " Porta       : $PORT"
echo " Endpoint    : $ENDPOINT"
echo " Client max  : $NUM_CLIENTS"
echo

# --- avvio l'interfaccia interface ---
echo
echo "Avvio l'interfaccia ..."
wg-quick up $INTERFACE >/dev/null 2>&1