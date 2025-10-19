#!/bin/sh
set -eu

# ================== LOAD CONFIG ==================
CONFIG_FILE="./wg_filter.conf"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERRORE: file di configurazione non trovato: $CONFIG_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
. "$CONFIG_FILE"

# Verifica che le variabili fondamentali siano definite
: "${WGPORT:?Config WGPORT mancante}"
: "${WAN_IF:?Config WAN_IF mancante}"
: "${HOSTS:?Config HOSTS mancante}"
: "${IPTABLES:?Config IPTABLES mancante}"
: "${CHAIN:?Config CHAIN mancante}"

# ================================================

# --- helper: valida IPv4/CIDR in modo semplice (non rigidissimo, ma sufficiente) ---
is_ipv4_or_cidr() {
  echo "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}(/([0-9]|[12][0-9]|3[0-2]))?$'
}

# --- 1) Risolvi gli A-record dei tuoi HOSTS DDNS ---
RESOLVED_IPS=""
for H in $HOSTS; do
  IPS="$(dig +short A "$H" 2>/dev/null | tr -d '\r' || true)"
  for ip in $IPS; do
    if is_ipv4_or_cidr "$ip"; then
      RESOLVED_IPS="$RESOLVED_IPS $ip"
    fi
  done
done

# --- 2) Scarica la lista extra (una riga = IP o CIDR) ---
EXTRA_IPS=""
if [ -n "$EXTRA_URL" ]; then
  CONTENT="$(curl -fsS --max-time 5 "$EXTRA_URL" 2>/dev/null || true)"
  if [ -n "$CONTENT" ]; then
    TMP="$(mktemp)"
    # normalizza CRLF -> LF
    printf '%s\n' "$CONTENT" | tr -d '\r' > "$TMP"

    # Niente pipeline: il while gira nella shell corrente
    while IFS= read -r line; do
      # trim spazi
      L="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -z "$L" ] && continue

      # salta commenti senza usare '&&' (per non far scattare set -e)
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


# --- 3) Costruisci la allow-list finale ---
ALLOW_LIST="$(echo "$RESOLVED_IPS $EXTRA_IPS" | xargs -n1 | sort -u | xargs)"
if [ -z "$ALLOW_LIST" ]; then
  echo "Nessun IP ottenuto (DDNS/EXTRA). Lascio regole invariate." >&2
  exit 0
fi

# --- 4) Prepara la catena dedicata e l'hook da INPUT ---
if ! $IPTABLES -nL "$CHAIN" >/dev/null 2>&1; then
  $IPTABLES -N "$CHAIN"
fi

# Assicura il salto da INPUT alla catena dedicata per UDP/porta WG su WAN_IF
if ! $IPTABLES -C INPUT -i "$WAN_IF" -p udp --dport "$WGPORT" -j "$CHAIN" 2>/dev/null; then
  # Inserisci in cima per valutare prima di regole generiche
  $IPTABLES -I INPUT -i "$WAN_IF" -p udp --dport "$WGPORT" -j "$CHAIN"
fi

# (Consigliato) consenti traffico già stabilito a livello globale se non presente
if ! $IPTABLES -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
  $IPTABLES -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
fi

# --- 5) Ricostruisci la catena in modo atomico: flush → allow → drop ---
$IPTABLES -F "$CHAIN"

for SRC in $ALLOW_LIST; do
  # iptables accetta sia IP singolo che CIDR con -s
  $IPTABLES -A "$CHAIN" -s "$SRC" -j ACCEPT
done

# Tutto il resto sulla porta WG → DROP
$IPTABLES -A "$CHAIN" -j DROP

# --- 6) Salva configurazione persistente su Alpine ---
if [ -x /etc/init.d/iptables ]; then
  /etc/init.d/iptables save >/dev/null 2>&1 || true
fi

echo "Aggiornato $CHAIN con: $ALLOW_LIST"
