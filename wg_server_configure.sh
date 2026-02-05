#!/bin/sh
set -eu

GENERATED_PUBKEY=0
GENERATED_PRIVKEY=0

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

header "WireGuard Server Configurator"

# TODO: Enable report logging
# REPORT_DIR="${SCRIPT_PATH}/reports"
# REPORT_PATH="${REPORT_DIR}/wg_server_report_$(date +%Y%m%d-%H%M%S).csv"
# mkdir -p "$REPORT_DIR"
# echo "Step,Status,Details,Timestamp" > "$REPORT_PATH"

ask INTERFACE "Enter the WireGuard interface name" "wg0"

WG_DIR="/etc/wireguard"
WG_CONF="${INTERFACE}.conf"
WG_CONF_PATH="${WG_DIR}/${WG_CONF}"
PRIVATE_KEY="${WG_DIR}/server_private.key"
PUBLIC_KEY="${WG_DIR}/server_public.key"

success "Selected WireGuard interface: $INTERFACE"

if [ ! -e "/etc/init.d/wg-quick.${INTERFACE}" ]; then
    ln -s /etc/init.d/wg-quick "/etc/init.d/wg-quick.${INTERFACE}"
    info ""
    success "Created symlink: /etc/init.d/wg-quick.${INTERFACE}"
    rc-update add wg-quick.wg0
fi

[ -d "$WG_DIR" ] || mkdir -p "$WG_DIR"

# --- Read old values if present ---
OLD_ADDR="$(get_conf_value Address | awk -F'/' '{print $1}')"
OLD_PORT="$(get_conf_value ListenPort)"
OLD_ENDPOINT="$(conf_comment_get "Endpoint Host")"
OLD_DNS="$(conf_comment_get "DNS")"
OLD_MAXCLIENTS="$(conf_comment_get "Max Clients")"
OLD_CLIENTS_ISOLATION="$(conf_comment_get "Clients Isolation")"

# --- Find the subnet to share in the VPN ---
info ""
info "Available network interfaces:"
IFACES=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v lo || ifconfig -a | grep '^[^ ]' | awk '{print $1}' | grep -v lo)

n=1
for i in $IFACES; do
  info "  $n) $i"
  n=$((n+1))
done

# --- Step 2: Ask the user which interface to use ---
ask sel "Select an interface to share in the VPN [1-$((n-1))]" "1"

sel_if=$(echo "$IFACES" | sed -n "${sel}p" || true)

if [ -z "$sel_if" ]; then
  error "Invalid selection."
fi

success "Selected interface: $sel_if"
info ""

# --- Step 3: Detect the interface subnet ---
# Try with ip, then fallback to ifconfig
OFFICE_SUBNET=""

if command -v ip >/dev/null 2>&1; then
  # Example output: inet 192.168.1.10/24 brd ...
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

# --- Prompt ---
ask SERVER_IP "Enter the VPN server IP" "${OLD_ADDR:-100.64.1.1}"
ask NUM_CLIENTS "How many clients will connect to this server?" "${OLD_MAXCLIENTS:-1}"
ask CLIENTS_ISOLATION "Do you want client isolation? (1/0)" "${OLD_CLIENTS_ISOLATION:-0}"
ask PORT "Enter the WireGuard UDP port" "${OLD_PORT:-51234}"
ask ENDPOINT "Enter the public endpoint (hostname or public IP)" "${OLD_ENDPOINT:-$(public_ip_lookup)}"
ask DNS "Set a DNS for clients ($OLD_DNS, 1.1.1.1 or empty for none)" ""
ask SUBNET "Office subnet to share in VPN" "$OFFICE_SUBNET"

NETMASK="$(calc_netmask "$NUM_CLIENTS")"

# Calculate network base from IP
IFS=. read -r a b c d <<EOF
$SERVER_IP
EOF

# Calculate the correct subnet base aligned to the CIDR block
block_size=$(( 2 ** (32 - NETMASK) ))
last_octet_base=$(( (d / block_size) * block_size ))
BASE_SUBNET_VPN="${a}.${b}.${c}.${last_octet_base}"
SUBNET_VPN="${BASE_SUBNET_VPN}/${NETMASK}"
ADDRESS="${SERVER_IP}/${NETMASK}"

RANGE_INFO="$(calc_range "$SERVER_IP" "$NETMASK")"
VPN_RANGE_NET="$(echo "$RANGE_INFO" | cut -d'|' -f1)"
VPN_RANGE_CLIENTS="$(echo "$RANGE_INFO" | cut -d'|' -f2)"

if [ "$CLIENTS_ISOLATION" -eq 1 ]; then
  CLIENTS_SUBNET_VPN="${SERVER_IP}/32"
else
  CLIENTS_SUBNET_VPN="${SUBNET_VPN}"
fi

info ""
success "Using Address      = ${ADDRESS}"
success "Office subnet      = ${SUBNET}"
success "Client range       = ${VPN_RANGE_CLIENTS}"
if [ "${CLIENTS_ISOLATION}" -eq 1 ]; then
  success "Client isolation   = enabled"
else
  success "Client isolation   = disabled"
fi
success "VPN subnet will be = ${SUBNET_VPN}"
success "VPN IP range       = ${VPN_RANGE_NET}"
success "Max clients       = ${NUM_CLIENTS}"
success "Listening on port  = ${PORT}"
success "Endpoint           = ${ENDPOINT}"
if [ -n "$DNS" ]; then
  success "DNS for clients    = ${DNS}"
else
  success "DNS for clients    = (none)"
fi
success "Client isolation         = ${CLIENTS_ISOLATION}"
success "Client authorized VPN subnet = ${CLIENTS_SUBNET_VPN}"
info ""

# --- Generate keys if missing ---
if ! command -v wg >/dev/null 2>&1; then
  warning "The 'wg' command is not installed. Please install it first (e.g., 'apk add wireguard-tools' or 'apt install wireguard')."
  exit 1
fi

if [ ! -f "$PRIVATE_KEY" ]; then
  info "Generating new server private key..."
  umask 077
  wg genkey > "$PRIVATE_KEY"
  GENERATED_PRIVKEY=1
fi

if [ ! -f "$PUBLIC_KEY" ]; then
  info "Generating new server public key..."
  wg pubkey < "$PRIVATE_KEY" > "$PUBLIC_KEY"
  GENERATED_PUBKEY=1
fi

# --- Stop interface ---
info "Stopping the interface if active..."
if wg show "$INTERFACE" >/dev/null 2>&1; then
  wg-quick down "$INTERFACE" >/dev/null 2>&1 || true
fi

# --- Write wg0.conf ---
info "Writing configuration to $WG_CONF..."

# If a configuration already exists, extract the [Peer] blocks
PEERS_TMP=""
if [ -f "$WG_CONF_PATH" ]; then
  info "Existing configuration detected, saving [Peer] blocks..."
  PEERS_TMP="$(awk '/^\[Peer\]/{flag=1} flag{print}' "$WG_CONF_PATH" || true)"

  cp "$WG_CONF_PATH" "${WG_CONF_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
  success "Backup created at ${WG_CONF_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
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
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT

# --- Endpoint Info ---
# Endpoint: ${ENDPOINT}:${PORT}
# Endpoint Host: ${ENDPOINT}
# Endpoint Port: ${PORT}
# PublicKey: $(cat "$PUBLIC_KEY")
# Subnet: ${SUBNET}
# Subnet VPN: ${SUBNET_VPN}
# Max Clients: ${NUM_CLIENTS}
# Clients Isolation: ${CLIENTS_ISOLATION}
# Clients Authorized Subnet: ${CLIENTS_SUBNET_VPN}
EOF
if [ -n "$DNS" ]; then
  echo "# DNS: $DNS" >> "$WG_CONF_PATH"
fi

info ""

# If peers were present, add them back at the end
if [ -n "$PEERS_TMP" ]; then
  echo >> "$WG_CONF_PATH"
  echo "$PEERS_TMP" >> "$WG_CONF_PATH"
  success "Configuration updated with $(echo "$PEERS_TMP" | grep -c '^\[Peer\]' || echo 0) peers maintained."
fi

chmod 600 "$WG_CONF_PATH"

# --- Summary ---
success "Configuration complete!"
info ""
info "Generated files:"
info " - $WG_CONF_PATH"
if [ $GENERATED_PRIVKEY -eq 1 ]; then
  info " - $PRIVATE_KEY"
fi
if [ $GENERATED_PUBKEY -eq 1 ]; then
  info " - $PUBLIC_KEY"
fi
info ""
info "Main details:"
info " Address     : $ADDRESS"
info " Subnet      : $SUBNET"
info " Subnet VPN  : $SUBNET_VPN"
info " VPN Range   : $VPN_RANGE_NET"
info " Client range: $VPN_RANGE_CLIENTS"
info " Port        : $PORT"
info " Endpoint    : $ENDPOINT"
info " Max clients : $NUM_CLIENTS"
info " Client DNS  : ${DNS:-(none)}"
info ""
info " Client isolation: $CLIENTS_ISOLATION"
info " Client authorized VPN subnet: $CLIENTS_SUBNET_VPN"
info ""

# --- Start the interface ---
info "Starting the interface..."
success "Everything is ok!"
info ""
reload_and_start_wg_interface "$INTERFACE"
