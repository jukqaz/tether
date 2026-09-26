#!/bin/sh
# Installs the Tether helper and its watchdog as root LaunchDaemons. Runs as root; the app asks
# for the password.
set -eu
RES=$(cd "$(dirname "$0")" && pwd)
LABEL=local.tether.helper
WATCHDOG=local.tether.watchdog
SUPPORT="/Library/Application Support/Tether"

launchctl bootout "system/$WATCHDOG" 2>/dev/null || true
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
install -o root -g wheel -m 755 "$RES/tether-watchdog.sh" "/Library/PrivilegedHelperTools/$WATCHDOG"
install -o root -g wheel -m 644 "$RES/$WATCHDOG.plist" "/Library/LaunchDaemons/$WATCHDOG.plist"

# The support folder is root's alone: only root may add, remove or replace files in it, so nothing
# there can be swapped for a link. Admins may rewrite control.json, so the app changes settings
# without a password. 2.0.0 made the folder admin-writable, so it is taken back first, then
# anything that isn't a known plain file with a single name is removed before control.json is
# touched.
mkdir -p "$SUPPORT"
chown root:wheel "$SUPPORT"
chmod 755 "$SUPPORT"
find "$SUPPORT" -mindepth 1 -maxdepth 1 \( ! -type f -o -links +1 \) -exec rm -rf {} +
find "$SUPPORT" -mindepth 1 -maxdepth 1 -type f ! \( -name control.json -o -name status.json \
  -o -name usage.json -o -name helper-state.json \) -exec rm -f {} +
if [ ! -f "$SUPPORT/control.json" ]; then
  printf '{\n  "enabled" : true\n}\n' > "$SUPPORT/control.json"
fi
chown root:admin "$SUPPORT/control.json"
chmod 664 "$SUPPORT/control.json"
install -d -o root -g wheel -m 755 /Library/Logs/Tether

launchctl enable "system/$LABEL" 2>/dev/null || true
launchctl bootstrap system "/Library/LaunchDaemons/$LABEL.plist" ||
  { sleep 1; launchctl bootstrap system "/Library/LaunchDaemons/$LABEL.plist"; }
launchctl enable "system/$WATCHDOG" 2>/dev/null || true
launchctl bootstrap system "/Library/LaunchDaemons/$WATCHDOG.plist" || true
