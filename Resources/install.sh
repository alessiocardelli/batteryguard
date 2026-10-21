#!/bin/sh
# Installa il demone root. Eseguito dall'app via osascript "with administrator privileges".
# Uso: install.sh <percorso helper nel bundle> <soglia>
set -eu

SRC="$1"
LIMIT="$2"
LABEL="com.alessiocardelli.chargelimit.helper"
DEST="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
CONF_DIR="/Library/Application Support/ChargeLimit"
LOG_DIR="/Library/Logs/ChargeLimit"

case "$LIMIT" in
  ''|*[!0-9]*) echo "soglia non valida: $LIMIT" >&2; exit 1 ;;
esac

# Reinstallazione: fermiamo l'eventuale istanza precedente prima di sovrascrivere il binario
launchctl bootout "system/$LABEL" 2>/dev/null || true

install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
install -o root -g wheel -m 755 "$SRC" "$DEST"
# Il binario arriva da un'app scaricata: senza questo launchd potrebbe rifiutarlo
xattr -c "$DEST"

install -d -o root -g wheel -m 755 "$CONF_DIR" "$LOG_DIR"
printf 'limit=%s\n' "$LIMIT" > "$CONF_DIR/config"
chmod 644 "$CONF_DIR/config"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$DEST</string>
    <string>daemon</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/helper.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/helper.log</string>
</dict>
</plist>
EOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

launchctl bootstrap system "$PLIST"
echo "installato: $DEST (soglia $LIMIT%)"
