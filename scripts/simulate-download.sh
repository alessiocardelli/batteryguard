#!/bin/sh
# Mette sul .dmg l'attributo di quarantena che Safari/Chrome aggiungono a un file scaricato,
# così l'apertura segue lo stesso percorso di un utente reale (Gatekeeper + "Apri comunque").
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/dist/ChargeLimit.dmg"
DEST="${1:-$HOME/Downloads/ChargeLimit.dmg}"

cp "$SRC" "$DEST"
# Formato: flag;timestamp esadecimale;agente;UUID. 0083 = scaricato, non ancora aperto
xattr -w com.apple.quarantine "0083;$(printf '%x' "$(date +%s)");Safari;$(uuidgen)" "$DEST"
xattr -p com.apple.quarantine "$DEST"
echo "pronto: $DEST"
