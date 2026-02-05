#!/bin/sh

# common.sh
#
# This script provides a set of common functions.

die() { error "$*"; }
need_root() { [ "$(id -u)" -eq 0 ] || die "Please run as root."; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

install_wg() {
  warning "WireGuard (wg) not found."
  warning "Did you run the command as root?"
  warning "Before running this command, did you run sys_prepare_alpinelinux.sh?"
  ask PM "Which package manager do you use? [apk/apt/yum/dnf/zypper/pacman/opkg]: " ""
  case "$PM" in
    apk)   apk add --no-cache --no-progress wireguard-tools || die "Installation failed";;
    apt)   DEBIAN_FRONTEND=noninteractive apt-get update -y && apt-get install -y wireguard-tools || die "Installation failed";;
    yum)   yum install -y epel-release || true; yum install -y wireguard-tools || die "Installation failed";;
    dnf)   dnf install -y wireguard-tools || die "Installation failed";;
    zypper) zypper --non-interactive install wireguard-tools || die "Installation failed";;
    pacman) pacman -Sy --noconfirm wireguard-tools || die "Installation failed";;
    opkg)  opkg update && opkg install wireguard-tools || die "Installation failed";;
    *) die "Unsupported package manager: $PM";;
  esac
}

reload_and_start_wg_interface() {
  local INTERFACE="$1"
  [ -z "$INTERFACE" ] && INTERFACE="wg0"
  info "Restarting WireGuard interface $INTERFACE..."
  wg show "$INTERFACE" >/dev/null 2>&1 && { tmp="$(mktemp)"; \
  wg-quick strip "$INTERFACE" >"$tmp" 2>/dev/null && wg syncconf \
  "$INTERFACE" "$tmp" >/dev/null 2>&1 || true; rm -f "$tmp"; } || true
  rc-service wg-quick.$INTERFACE stop >/dev/null 2>&1 || true
  rc-service wg-quick.$INTERFACE zap >/dev/null 2>&1 || true
  wg-quick up /etc/wireguard/$INTERFACE.conf >/dev/null 2>&1 || true
  rc-service wg-quick.$INTERFACE start >/dev/null 2>&1 || true
}

# --- Function to read an existing value from wg0.conf ---
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

conf_get() {
  key="$1"
  if [ -f "$WG_CONF_PATH" ]; then
    # use grep + cut for better portability
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
    info ""
    info "Restarting interface..."
    reload_and_start_wg_interface "$INTERFACE"
}

rename_client_files() {
  n="$1"; old="$2"; new="$3"
  oldb="${CLIENTS_DIR}/client${n}_${old}"
  newb="${CLIENTS_DIR}/client${n}_${new}"
  for t in secret.key public.key config.conf; do
    if [ -f "${oldb}_$t" ]; then mv "${oldb}_$t" "${newb}_$t"; fi
  done
}

timestamp() { date +"%Y-%m-%d %H:%M:%S"; }

# --- Calculate netmask based on number of clients ---
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

# --- helper: lista IP in formato "iface: ip[/mask]" (ip) o "iface: ip ..." (ifconfig) ---
list_local_ips() {
  if have_cmd ip; then
    ip -o -4 addr show 2>/dev/null | awk '{print $2": "$4}'
  elif have_cmd ifconfig; then
    # BusyBox/Nettools compat: righe con "inet "
    ifconfig 2>/dev/null | awk '
      /^[a-zA-Z0-9]/ {iface=$1}
      /inet / {print iface": "$2" "$0}
    '
  fi
}

show_network_info_details() {
  run_if_exists() {
    if command -v "$1" >/dev/null 2>&1; then
      shift
      "$@"
    else
      return 1
    fi
  }

  info "Interfaces:"

  if command -v ip >/dev/null 2>&1; then
    ip -br addr show 2>/dev/null || ip addr show 2>/dev/null || true
  elif command -v ifconfig >/dev/null 2>&1; then
    ifconfig -a 2>/dev/null || true
  elif command -v busybox >/dev/null 2>&1 && busybox ip >/dev/null 2>&1; then
    busybox ip addr show 2>/dev/null || true
  elif command -v busybox >/dev/null 2>&1 && busybox ifconfig >/dev/null 2>&1; then
    busybox ifconfig -a 2>/dev/null || true
  elif [ -d /sys/class/net ]; then
    echo ""
    for i in /sys/class/net/*; do
      iface=$(basename "$i")
      state=$(cat "$i/operstate" 2>/dev/null || echo "unknown")
      mac=$(cat "$i/address" 2>/dev/null || echo "no-mac")
      echo "  $iface ($state) - $mac"
    done
  else
    echo "  Nessuna interfaccia trovata (nessun comando o /sys/class/net)"
  fi

  info ""
  info "Routes:"
  if command -v ip >/dev/null 2>&1; then
    ip route show 2>/dev/null || true
  elif command -v route >/dev/null 2>&1; then
    route -n 2>/dev/null || true
  elif command -v busybox >/dev/null 2>&1 && busybox route >/dev/null 2>&1; then
    busybox route -n 2>/dev/null || true
  else
    echo "  Nessuna route trovata (ip/route mancanti)"
  fi

  info ""
  info "DNS resolvers:"
  if [ -f /etc/resolv.conf ]; then
    grep -E '^nameserver' /etc/resolv.conf 2>/dev/null || echo "  Nessun DNS configurato"
  else
    echo "  File /etc/resolv.conf mancante"
  fi
}

get_free_port() {
    local port
    while true; do
        port=$((RANDOM % 40000 + 20000))
        # controlla se la porta è libera (usa netcat o ss o lsof o fallback su /proc)
        if command -v nc >/dev/null 2>&1; then
            nc -z 127.0.0.1 "$port" >/dev/null 2>&1 || break
        elif command -v ss >/dev/null 2>&1; then
            ss -ltn "( sport = :$port )" 2>/dev/null | grep -q "$port" || break
        elif command -v lsof >/dev/null 2>&1; then
            lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 || break
        elif [ -d /proc/net ]; then
            grep -q ":$(printf '%04X' "$port")" /proc/net/tcp* 2>/dev/null || break
        elif command -v netstat >/dev/null 2>&1; then
            netstat -ltn | awk '{print $4}' | grep -q ":$port$" || break
        else
            break  # nessun metodo disponibile, prendila comunque
        fi
    done
    echo "$port"
}

public_ip_lookup() {
  PUBLIC_IP=$(curl -fsSL https://ifconfig.me 2>/dev/null || wget -qO- https://ifconfig.me 2>/dev/null || echo "unknown")
  echo "$PUBLIC_IP"
}

# --- helper: check if IP is inside CIDR ---
ip_in_subnet() {
  ip="$1"; net="$2"; maskbits="$3"

  ip2int() {
    IFS=. read -r a b c d <<EOF
$1
EOF
    echo $(( (a<<24) + (b<<16) + (c<<8) + d ))
  }

  ip_int=$(ip2int "$ip") || return 1
  net_int=$(ip2int "$net") || return 1
  [ -n "$maskbits" ] || return 1
  mask=$(( (0xFFFFFFFF << (32-maskbits)) & 0xFFFFFFFF ))

  [ $((ip_int & mask)) -eq $((net_int & mask)) ]
}

# --- Calculate IP range from address and netmask ---
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