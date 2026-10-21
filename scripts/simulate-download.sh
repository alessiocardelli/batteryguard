#!/bin/sh
# Mette sul file l'attributo di quarantena che Safari/Chrome aggiungono a un download,
# così l'apertura segue lo stesso percorso di un utente reale (Gatekeeper + "Apri comunque").
# Uso: simulate-download.sh [zip|dmg]   (default zip)
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FORMAT="${1:-zip}"
case "$FORMAT" in
  zip|dmg) ;;
  *) echo "formato non valido: $FORMAT (zip o dmg)" >&2; exit 1 ;;
esac
SRC="$ROOT/dist/ChargeLimit.$FORMAT"
DEST="$HOME/Downloads/ChargeLimit.$FORMAT"

cp "$SRC" "$DEST"
# Formato: flag;timestamp esadecimale;agente;UUID. 0083 = scaricato, non ancora aperto
xattr -w com.apple.quarantine "0083;$(printf '%x' "$(date +%s)");Safari;$(uuidgen)" "$DEST"
xattr -p com.apple.quarantine "$DEST"
echo "pronto: $DEST"
