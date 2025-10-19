#!/bin/sh
set -eu

# ================== CONFIG ==================
CONFIG_FILE="./wg_filter.conf"
EXAMPLE_FILE="./wg_filter.conf.example"
CRON_DEFAULT="/etc/crontabs/root"
# ============================================

# --- determina percorso assoluto dello script ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRON_LINE="*       *       *       *       *       ${SCRIPT_DIR}/wg_filter.sh >/dev/null 2>&1"

# --- helper: estrai SOLO il valore tra doppi apici, ignorando commenti/spazi ---
# Funziona anche su BusyBox awk.
get_conf_value_from_file() {
  key="$1"
  file="$2"
  if [ -f "$file" ]; then
    awk -v k="$key" '
      BEGIN { IGNORECASE=0 }
      # righe del tipo:    KEY="valore"   # commento
      $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
        # trova la PRIMA stringa tra doppi apici
        if (match($0, /"[^"]*"/)) {
          v = substr($0, RSTART+1, RLENGTH-2);
          print v;
          exit;
        }
      }
    ' "$file"
  fi
}

# --- wrapper: cerca prima nel conf, poi nell'example ---
get_conf_value() {
  key="$1"
  if [ -f "$CONFIG_FILE" ]; then
    get_conf_value_from_file "$key" "$CONFIG_FILE"
  elif [ -f "$EXAMPLE_FILE" ]; then
    get_conf_value_from_file "$key" "$EXAMPLE_FILE"
  else
    echo ""
  fi
}

# --- messaggio iniziale ---
echo "=============================="
echo " WireGuard Filter Configurator"
echo "=============================="
echo

if [ -f "$CONFIG_FILE" ]; then
  echo "Trovato file di configurazione esistente: $CONFIG_FILE"
  echo "I valori correnti saranno mostrati tra parentesi quadre []."
  echo
  echo "Vuoi cancellarlo prima di procedere? (y/N): "
  read answer
  if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
    rm -f "$CONFIG_FILE"
    echo "File di configurazione cancellato."
    echo
  else
    echo "Procedo con il file di configurazione esistente."
    echo
  fi
elif [ -f "$EXAMPLE_FILE" ]; then
  echo "Nessun file di configurazione trovato."
  echo "Userò i valori predefiniti da: $EXAMPLE_FILE"
  echo
else
  echo "ERRORE: nessun file di configurazione o di esempio trovato!"
  echo "Crea almeno $EXAMPLE_FILE per continuare."
  exit 1
fi

# --- trova default IPTABLES con which (richiesto) ---
IPTABLES_DEFAULT="$(which iptables 2>/dev/null || command -v iptables 2>/dev/null || echo /usr/sbin/iptables)"
IPTABLES_PREV="$(get_conf_value IPTABLES)"

# --- funzione per chiedere input con default e (opz.) "precedente" ---
ask() {
  varname="$1"
  question="$2"
  default_val="$3"          # default da proporre (es. IPTABLES_DEFAULT)
  prev_val="${4:-}"         # valore precedente (da file), opzionale

  if [ -n "$prev_val" ] && [ "$varname" != "IPTABLES" ]; then
    # Per tutte le variabili tranne IPTABLES usiamo come default quello precedente
    default_show="$prev_val"
  else
    default_show="$default_val"
  fi

  if [ "$varname" = "IPTABLES" ] && [ -n "$IPTABLES_PREV" ] && [ "$IPTABLES_PREV" != "$IPTABLES_DEFAULT" ]; then
    printf "%s [%s] (precedente: %s): " "$question" "$default_show" "$IPTABLES_PREV"
  else
    printf "%s [%s]: " "$question" "$default_show"
  fi

  # shellcheck disable=SC2162
  read input || true

  if [ -n "${input:-}" ]; then
    eval "$varname=\"\$input\""
  else
    eval "$varname=\"\$default_show\""
  fi
}

# --- prepara i default/precedenti ---
WGPORT_PREV="$(get_conf_value WGPORT)"
WAN_IF_PREV="$(get_conf_value WAN_IF)"
HOSTS_PREV="$(get_conf_value HOSTS)"
EXTRA_URL_PREV="$(get_conf_value EXTRA_URL)"
CHAIN_PREV="$(get_conf_value CHAIN)"

# --- domande all'utente ---
ask WGPORT   "Inserisci la porta UDP WireGuard"                "${WGPORT_PREV:-51234}"          "$WGPORT_PREV"
ask WAN_IF   "Inserisci l'interfaccia WAN (es. eth0)"          "${WAN_IF_PREV:-eth0}"           "$WAN_IF_PREV"
ask HOSTS    "Inserisci uno o più hostname DDNS (spazio-sep.)" "${HOSTS_PREV:-ddns.example.com}" "$HOSTS_PREV"
ask EXTRA_URL "Inserisci URL lista IP/CIDR extra"              "${EXTRA_URL_PREV:-https://example.com/acl.txt}" "$EXTRA_URL_PREV"
# Per IPTABLES: default = which iptables (non dal file), ma mostriamo il precedente come nota
ask IPTABLES "Percorso binario iptables"                       "$IPTABLES_DEFAULT"              "$IPTABLES_PREV"
ask CHAIN    "Nome catena dedicata per WireGuard"              "${CHAIN_PREV:-WG_FILTER}"       "$CHAIN_PREV"

# --- scrittura file ---
echo
echo "Scrittura configurazione in $CONFIG_FILE ..."
cat > "$CONFIG_FILE" <<EOF
# ================== WireGuard Filter Config ==================
WGPORT="$WGPORT"
WAN_IF="$WAN_IF"
HOSTS="$HOSTS"
EXTRA_URL="$EXTRA_URL"
IPTABLES="$IPTABLES"
CHAIN="$CHAIN"
EOF

echo "Configurazione salvata con successo!"
echo
echo "Contenuto generato:"
echo "-----------------------------------"
cat "$CONFIG_FILE"
echo "-----------------------------------"

# ================== CRONTAB MANAGEMENT ==================
echo
echo "Controllo presenza riga cron per wg_filter.sh ..."

if command -v crontab >/dev/null 2>&1; then
  CURRENT_CRON="$(crontab -l 2>/dev/null || true)"
  echo "$CURRENT_CRON" | grep -F "$CRON_LINE" >/dev/null 2>&1 || {
    echo "Aggiungo riga a crontab utente root..."
    (echo "$CURRENT_CRON"; echo "$CRON_LINE") | crontab -
    echo "Riga aggiunta con successo a crontab (usando crontab -l / -)."
  }
else
  echo "Comando 'crontab' non disponibile (probabile Alpine/BusyBox)."
  printf "Percorso file cron root [%s]: " "$CRON_DEFAULT"
  read CRON_FILE || true
  [ -z "${CRON_FILE:-}" ] && CRON_FILE="$CRON_DEFAULT"

  if [ ! -f "$CRON_FILE" ]; then
    echo "File cron non trovato, verrà creato: $CRON_FILE"
    : > "$CRON_FILE"
  fi

  if grep -F "$CRON_LINE" "$CRON_FILE" >/dev/null 2>&1; then
    echo "Riga già presente in $CRON_FILE."
  else
    echo "$CRON_LINE" >> "$CRON_FILE"
    echo "Riga aggiunta con successo a $CRON_FILE"
    # Nota: su Alpine potrebbe servire:  rc-service crond reload  (a mano)
  fi
fi

echo
echo "Setup completato"
