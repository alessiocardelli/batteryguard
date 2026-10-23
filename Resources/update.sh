#!/bin/sh
# Sostituisce BatteryGuard.app con la versione nuova già scaricata e verificata dall'app.
# Lanciato staccato dall'app, gira come l'utente (niente sudo). Le righe di log vanno nel log di sistema
# con il tag BatteryGuard-update.
# Uso: update.sh <pid dell'app> <bundle in uso> <bundle nuovo> <cartella temporanea>
set -u

PID="$1"
DEST="$2"
NEW="$3"
WORK="$4"
OLD="$WORK/old.app"

say() { /usr/bin/logger -t BatteryGuard-update "$*"; }

# Aspetta che l'app sia uscita (al massimo 20 secondi)
i=0
while kill -0 "$PID" 2>/dev/null; do
  i=$((i + 1))
  if [ "$i" -gt 100 ]; then
    say "l'app non si è chiusa, aggiornamento annullato"
    rm -rf "$WORK"
    exit 1
  fi
  sleep 0.2
done

if mv "$DEST" "$OLD"; then
  if mv "$NEW" "$DEST"; then
    say "aggiornata: $DEST"
    # -n: un'altra copia con lo stesso identificativo già aperta altrove non deve prendere il posto di questa
    open -n "$DEST"
    rm -rf "$WORK"
    exit 0
  fi
  say "bundle nuovo non spostato, ripristino della versione precedente"
  mv "$OLD" "$DEST"
else
  say "bundle in uso non spostato: $DEST"
fi
open -n "$DEST"
rm -rf "$WORK"
exit 1
