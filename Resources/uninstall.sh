#!/bin/sh
# Disinstalla il demone e lascia la ricarica sempre abilitata.
set -u

LABEL="com.alessiocardelli.chargelimit.helper"
DEST="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

# bootout manda SIGTERM: il demone riabilita la ricarica da solo prima di uscire
launchctl bootout "system/$LABEL" 2>/dev/null || true

# Doppia sicurezza nel caso il demone fosse già morto con la ricarica bloccata
if [ -x "$DEST" ]; then
  "$DEST" enable-charging || echo "attenzione: riabilitazione ricarica fallita" >&2
fi

rm -f "$PLIST" "$DEST"
rm -rf "/Library/Application Support/ChargeLimit" "/Library/Logs/ChargeLimit"
echo "disinstallato"
