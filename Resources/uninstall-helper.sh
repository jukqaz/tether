#!/bin/sh
# Removes the Tether helper, its files and a system-wide `tether` link, and restores normal
# lid-close sleep. Runs as root.
set -eu
LABEL=local.tether.helper

# Stopping the helper also restores Low Power Mode if a heat guard or battery hold had it on.
launchctl bootout "system/$LABEL" 2>/dev/null || true
rm -f "/Library/PrivilegedHelperTools/$LABEL" "/Library/LaunchDaemons/$LABEL.plist"
rm -rf "/Library/Application Support/Tether" /Library/Logs/Tether
case "$(readlink /usr/local/bin/tether 2>/dev/null || true)" in
  *Tether.app/Contents/Helpers/tether) rm -f /usr/local/bin/tether ;;
esac
pmset -a disablesleep 0
