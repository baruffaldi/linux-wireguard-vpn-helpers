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

WG_CONF_PATH=""
WG_DDNS_CONF="wg_ddns.conf"
WG_DDNS_CONF_PATH="${SCRIPT_PATH}/${WG_DDNS_CONF}"

OVH_HOSTNAME="$(conf_get OVH_HOSTNAME "$WG_DDNS_CONF_PATH")"
OVH_USERNAME="$(conf_get OVH_USERNAME "$WG_DDNS_CONF_PATH")"
OVH_PASSWORD="$(conf_get OVH_PASSWORD "$WG_DDNS_CONF_PATH")"

OVH_HOSTNAME=$(printf '%s' "$OVH_HOSTNAME" | sed 's/^"//;s/"$//')
OVH_USERNAME=$(printf '%s' "$OVH_USERNAME" | sed 's/^"//;s/"$//')
OVH_PASSWORD=$(printf '%s' "$OVH_PASSWORD" | sed 's/^"//;s/"$//')

# ==============================
# FUNZIONI
# ==============================

get_public_ip() {
    curl -4 -s https://ifconfig.me/ip 2>/dev/null
}

update_dynhost() {
    local ip="$1"
    local url="https://www.ovh.com/nic/update"

    response=$(curl -s -u "$OVH_USERNAME:$OVH_PASSWORD" \
        "$url?system=dyndns&hostname=$OVH_HOSTNAME&myip=$ip")

    echo "$response"

    if [[ "$response" == *"good"* || "$response" == *"nochg"* ]]; then
        echo "[$OVH_HOSTNAME] IP aggiornato correttamente a $ip"
    else
        echo "[$OVH_HOSTNAME] Errore: $response"
    fi
}

# ==============================
# MAIN
# ==============================

ip=$(get_public_ip)

if [[ -z "$ip" ]]; then
    echo "Errore: impossibile recuperare IP pubblico"
    exit 1
fi

echo "IP pubblico attuale: $ip"
update_dynhost "$ip"
