#!/bin/sh
set -eu

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

# ================== LOAD CONFIG ==================
CONFIG_FILE="${SCRIPT_PATH}/wg_filter.conf"

if [ ! -f "$CONFIG_FILE" ]; then
  error "Configuration file not found: $CONFIG_FILE"
fi

# shellcheck disable=SC1090
. "$CONFIG_FILE"

# Verify that fundamental variables are defined
: "${WGPORT?Config WGPORT missing}"
: "${WAN_IF?Config WAN_IF missing}"
: "${HOSTS?Config HOSTS missing}"
: "${IPTABLES?Config IPTABLES missing}"
: "${CHAIN?Config CHAIN missing}"
: "${EXTRA_URL?Config EXTRA_URL missing}"

# ================================================

# --- Helper: validate IPv4/CIDR simply (not rigid, but sufficient) ---
is_ipv4_or_cidr() {
  echo "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}(/([0-9]|[12][0-9]|3[0-2]))?$'
}

# --- 1) Resolve A-records of your DDNS HOSTS ---
RESOLVED_IPS=""
for H in $HOSTS; do
  IPS="$(dig +short A "$H" 2>/dev/null | tr -d '\r' || true)"
  for ip in $IPS; do
    if is_ipv4_or_cidr "$ip"; then
      RESOLVED_IPS="$RESOLVED_IPS $ip"
    fi
  done
done

# --- 2) Download the extra list (one line = IP or CIDR) ---
EXTRA_IPS=""
if [ -n "$EXTRA_URL" ]; then
  CONTENT="$(curl -fsS --max-time 5 "$EXTRA_URL" 2>/dev/null || true)"
  if [ -n "$CONTENT" ]; then
    TMP="$(mktemp)"
    # Normalize CRLF -> LF
    printf '%s\n' "$CONTENT" | tr -d '\r' > "$TMP"

    # No pipeline: the while loop runs in the current shell
    while IFS= read -r line; do
      # Trim spaces
      L="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -z "$L" ] && continue

      # Skip comments without triggering set -e
      case "$L" in
        \#*) continue ;;
      esac

      if is_ipv4_or_cidr "$L"; then
        EXTRA_IPS="$EXTRA_IPS $L"
      fi
    done < "$TMP"
    rm -f "$TMP"
  fi
fi


# --- 3) Build the final allow-list ---
ALLOW_LIST="$(echo "$RESOLVED_IPS $EXTRA_IPS" | xargs -n1 | sort -u | xargs)"
if [ -z "$ALLOW_LIST" ]; then
  warning "No IP obtained (DDNS/EXTRA). Leaving rules unchanged."
  exit 0
fi

# --- Helper: normalize a space-separated list into sorted unique lines ---
normalize_list_lines() {
  # stdin or args -> one per line, sorted unique
  # usage: normalize_list_lines "$LIST"
  printf '%s\n' "$1" | xargs -n1 2>/dev/null | sed '/^$/d' | sort -u
}

# --- Helper: read current ACCEPT sources from a chain (one per line, sorted unique) ---
get_current_chain_sources() {
  # Extract only "-s X ... -j ACCEPT" rules from CHAIN; return X values
  # Output: one per line
  $IPTABLES -S "$CHAIN" 2>/dev/null \
    | awk '
        $1 == "-A" && $2 == "'"$CHAIN"'" {
          src=""
          j=""
          for (i=3; i<=NF; i++) {
            if ($i == "-s" && (i+1) <= NF) src=$(i+1)
            if ($i == "-j" && (i+1) <= NF) j=$(i+1)
          }
          if (j == "ACCEPT" && src != "") print src
        }
      ' \
    | sort -u
}

# --- 4) Prepare the dedicated chain and the hook from INPUT ---
if ! $IPTABLES -nL "$CHAIN" >/dev/null 2>&1; then
  $IPTABLES -N "$CHAIN"
fi

# Compute "desired" and "current" sets and compare BEFORE changing anything
DESIRED_SET="$(normalize_list_lines "$ALLOW_LIST")"
CURRENT_SET="$(get_current_chain_sources || true)"

if [ -n "$CURRENT_SET" ] && [ "$DESIRED_SET" = "$CURRENT_SET" ]; then
  success "No changes: $CHAIN already matches allow-list. Nothing to do."
  exit 0
fi

# --- 4) Prepare the dedicated chain and the hook from INPUT ---
if ! $IPTABLES -nL "$CHAIN" >/dev/null 2>&1; then
  $IPTABLES -N "$CHAIN"
fi

# Ensure the jump from INPUT to the dedicated chain for UDP/WG port on WAN_IF
if ! $IPTABLES -C INPUT -i "$WAN_IF" -p udp --dport "$WGPORT" -j "$CHAIN" 2>/dev/null; then
  # Insert at the top to evaluate before generic rules
  $IPTABLES -I INPUT -i "$WAN_IF" -p udp --dport "$WGPORT" -j "$CHAIN"
fi

# (Recommended) allow already established traffic globally if not present
if ! $IPTABLES -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
  $IPTABLES -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
fi

# --- 5) Rebuild the chain atomically: flush -> allow -> drop ---
$IPTABLES -F "$CHAIN"

for SRC in $ALLOW_LIST; do
  # iptables accepts both single IP and CIDR with -s
  $IPTABLES -A "$CHAIN" -s "$SRC" -j ACCEPT
done

# Everything else on the WG port -> DROP
$IPTABLES -A "$CHAIN" -j DROP

# --- 6) Save persistent configuration on Alpine ---
if [ -x /etc/init.d/iptables ]; then
  /etc/init.d/iptables save >/dev/null 2>&1 || true
fi

success "Updated $CHAIN with: $ALLOW_LIST"