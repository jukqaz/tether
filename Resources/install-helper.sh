#!/bin/sh
# Installs the Tether helper as a root LaunchDaemon. Runs as root; the app asks for the password.
set -eu
RES=$(cd "$(dirname "$0")" && pwd)
LABEL=local.tether.helper
SUPPORT="/Library/Application Support/Tether"

launchctl bootout "system/$LABEL" 2>/dev/null || true
# bootout returns before the old instance has exited, and bootstrap fails (EIO) until it has.
i=0
while launchctl print "system/$LABEL" >/dev/null 2>&1 && [ "$i" -lt 50 ]; do
  sleep 0.1
  i=$((i + 1))
done

install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
install -o root -g wheel -m 755 "$RES/tether-helper" "/Library/PrivilegedHelperTools/$LABEL"
install -o root -g wheel -m 644 "$RES/$LABEL.plist" "/Library/LaunchDaemons/$LABEL.plist"

# Admins may write the control file, so the app can change settings without a password.
install -d -o root -g admin -m 775 "$SUPPORT"
if [ ! -f "$SUPPORT/control.json" ]; then
  printf '{\n  "enabled" : true\n}\n' > "$SUPPORT/control.json"
  chown root:admin "$SUPPORT/control.json"
  chmod 664 "$SUPPORT/control.json"
fi
install -d -o root -g wheel -m 755 /Library/Logs/Tether

launchctl enable "system/$LABEL" 2>/dev/null || true
launchctl bootstrap system "/Library/LaunchDaemons/$LABEL.plist" ||
  { sleep 1; launchctl bootstrap system "/Library/LaunchDaemons/$LABEL.plist"; }
