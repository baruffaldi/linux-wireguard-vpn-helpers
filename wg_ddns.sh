#!/bin/bash

# ==============================
# CONFIGURAZIONE HOSTNAMES
# ==============================

declare -A HOSTNAMES
HOSTNAMES["dc0.sbn.ovh"]="sbn.ovh-dc0:24234234523"

# ==============================
# FUNZIONI
# ==============================

get_public_ip() {
    curl -s https://ifconfig.me/all.json | jq -r '.ip_addr'
}

update_dynhost() {
    local ip="$1"
    local url="https://www.ovh.com/nic/update"

    for fqdn in "${!HOSTNAMES[@]}"; do
        credentials="${HOSTNAMES[$fqdn]}"
        username="${credentials%%:*}"
        password="${credentials##*:}"

        response=$(curl -s -u "$username:$password" \
            "$url?system=dyndns&hostname=$fqdn&myip=$ip")

        echo "$response"

        if [[ "$response" == *"good"* || "$response" == *"nochg"* ]]; then
            echo "✔ [$fqdn] IP aggiornato correttamente a $ip"
        else
            echo "⚠ [$fqdn] Errore: $response"
        fi
    done
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
