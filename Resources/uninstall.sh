#!/bin/sh
# Disinstalla il demone e lascia la ricarica sempre abilitata.
set -u

LABEL="com.alessiocardelli.batteryguard.helper"
DEST="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

# bootout manda SIGTERM: il demone riabilita la ricarica (e riattacca l'alimentatore) da solo prima di uscire
launchctl bootout "system/$LABEL" 2>/dev/null || true

# Doppia sicurezza nel caso il demone fosse già morto con la ricarica bloccata o l'alimentatore staccato
if [ -x "$DEST" ]; then
  "$DEST" enable-charging || echo "attenzione: riabilitazione ricarica fallita" >&2
fi

rm -f "$PLIST" "$DEST"
# Con la cartella va via anche il battito del servizio (status)
rm -rf "/Library/Application Support/BatteryGuard" "/Library/Logs/BatteryGuard"

# Migrazione dalla versione di prova (nome ChargeLimit): si tolgono anche eventuali residui.
# bootout manda SIGTERM e il vecchio demone riabilita la ricarica; il comando esplicito copre il caso in cui fosse già morto.
OLD_LABEL="com.alessiocardelli.chargelimit.helper"
OLD_DEST="/Library/PrivilegedHelperTools/$OLD_LABEL"
launchctl bootout "system/$OLD_LABEL" 2>/dev/null || true
if [ -x "$OLD_DEST" ]; then
  "$OLD_DEST" enable-charging || echo "attenzione: riabilitazione ricarica (vecchio servizio) fallita" >&2
fi
rm -f "/Library/LaunchDaemons/$OLD_LABEL.plist" "$OLD_DEST"
rm -rf "/Library/Application Support/ChargeLimit" "/Library/Logs/ChargeLimit"
echo "disinstallato"
