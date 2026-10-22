#!/bin/sh
# Removes the Tether helper, its watchdog, their files and a system-wide `tether` link, and
# releases only Tether-owned overrides. Runs as root.
set -eu
RES=$(cd "$(dirname "$0")" && pwd)
LABEL=local.tether.helper
WATCHDOG=local.tether.watchdog
PREFIX=
if [ "$(id -u)" -ne 0 ]; then
  case "${TETHER_UNINSTALL_TEST_ROOT:-}" in
    /tmp/tether-uninstall-test-*) PREFIX=$TETHER_UNINSTALL_TEST_ROOT ;;
    *) echo 'Administrator authorization is required.' >&2; exit 1 ;;
  esac
  PATH="$PREFIX/mock:/usr/bin:/bin:/usr/sbin:/sbin"
else
  PATH=/usr/bin:/bin:/usr/sbin:/sbin
fi
export PATH
[ ! -x "$RES/tether-helper" ] || RECOVERY_HELPER="$RES/tether-helper"
. "$RES/tether-recovery-lock.sh"
SUPPORT="$PREFIX/Library/Application Support/Tether"
if [ -x "$RES/tether-power-recovery" ]; then
  recovery_lock_path "$SUPPORT" "$RES/tether-power-recovery"
else
  recovery_lock_path "$SUPPORT"
fi
[ ! -L "$SUPPORT" ] || { echo 'Unsafe support directory.' >&2; exit 1; }

# Stopping the helper also restores Low Power Mode if a heat guard or battery hold had it on.
launchctl bootout "system/$WATCHDOG" 2>/dev/null || true
launchctl bootout "system/$LABEL" 2>/dev/null || true
i=0
while { launchctl print "system/$LABEL" >/dev/null 2>&1 || launchctl print "system/$WATCHDOG" >/dev/null 2>&1; } && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
if launchctl print "system/$LABEL" >/dev/null 2>&1 || launchctl print "system/$WATCHDOG" >/dev/null 2>&1; then echo 'Power service did not stop; files retained.' >&2; exit 1; fi
recovery_lock_acquire 2 || { echo 'Power recovery transaction is busy or unsafe; files retained.' >&2; exit 1; }

# A parse failure is not evidence that no owned change remains. Current journals
# are private; older installations may have used 644, which remains read-only to
# other users. Test fixtures use the invoking UID inside their isolated prefix.
validate_recovery_record() {
  recovery_record=$1
  recovery_json=
  [ ! -e "$recovery_record" ] && [ ! -L "$recovery_record" ] && return 0
  [ -f "$recovery_record" ] && [ ! -L "$recovery_record" ] &&
    [ "$(stat -f %l "$recovery_record")" = 1 ] &&
    [ "$(stat -f %u "$recovery_record")" = "$(id -u)" ] || return 1
  case "$(stat -f %Lp "$recovery_record")" in 600|644) ;; *) return 1 ;; esac
  recovery_size=$(stat -f %z "$recovery_record") || return 1
  case "$recovery_size" in ''|*[!0-9]*) return 1 ;; esac
  [ "$recovery_size" -le 4194304 ] || return 1
  recovery_json=$(plutil -convert json -o - "$recovery_record" 2>/dev/null) || return 1
  case "$recovery_json" in \{*\}) ;; *) return 1 ;; esac
}
recovery_value() { printf '%s\n' "$recovery_json" | plutil "$@" - 2>/dev/null; }

OWNERSHIP="$SUPPORT/power-ownership.json"
STATE="$SUPPORT/helper-state.json"
validate_recovery_record "$OWNERSHIP" || { echo 'Power recovery record is unreadable or unsafe; helper files retained.' >&2; exit 1; }
ownership_json=$recovery_json
validate_recovery_record "$STATE" || { echo 'Power recovery record is unreadable or unsafe; helper files retained.' >&2; exit 1; }
state_json=$recovery_json
if [ -n "$ownership_json" ]; then
  recovery_json=$ownership_json
  owned=$(recovery_value -extract owned raw -expect bool -o -) &&
    ownership_boot=$(recovery_value -extract boot raw -expect string -o -) &&
    [ -n "$ownership_boot" ] || { echo 'Power ownership record is invalid; helper files retained.' >&2; exit 1; }
fi
# Decode legacy restoration fields before any OS write or file removal. Missing
# and explicit null fields both mean no saved value, as HelperState's decoder does.
restore_pending=false
if [ -n "$state_json" ]; then
  recovery_json=$state_json
  for key in savedBatteryLowPower savedACLowPower; do
    saved_type=$(recovery_value -type "$key") || continue
    case "$saved_type" in
      '(any)') continue ;; # plutil's type for JSON null, decoded as nil by Swift
      integer) ;;
      *) echo 'Power mode recovery record is invalid; helper files retained.' >&2; exit 1 ;;
    esac
    saved=$(recovery_value -extract "$key" raw -o -) || { echo 'Power mode recovery value is unreadable; helper files retained.' >&2; exit 1; }
    case "$saved" in 0|1|2) restore_pending=true ;; *) echo 'Power mode recovery value is invalid; helper files retained.' >&2; exit 1 ;; esac
  done
fi
if [ -n "$ownership_json" ] && [ "$owned" = true ] &&
   [ "$ownership_boot" = "$(sysctl -n kern.bootsessionuuid)" ]; then
  recovery_pmset -a disablesleep 0 || exit 1
  restored=$(ioreg -r -c IOPMrootDomain -d 1) || exit 1
  printf '%s\n' "$restored" | grep -q '"SleepDisabled" = No' || { echo 'Sleep restoration not confirmed; helper files retained.' >&2; exit 1; }
fi
# Preserve a failed Low Power Mode restoration record instead of deleting it.
if [ "$restore_pending" = true ]; then
  echo 'Power mode restoration is incomplete; helper files retained.' >&2; exit 1
fi
rm -f "$PREFIX/Library/PrivilegedHelperTools/$LABEL" "$PREFIX/Library/LaunchDaemons/$LABEL.plist"
rm -f "$PREFIX/Library/PrivilegedHelperTools/$WATCHDOG" "$PREFIX/Library/LaunchDaemons/$WATCHDOG.plist"
rm -f "$PREFIX/Library/PrivilegedHelperTools/local.tether.recovery-lock"
rm -f "$PREFIX/Library/PrivilegedHelperTools/local.tether.power-recovery"
# The empty lock lives outside SUPPORT. Preserve its inode even after removal so
# an outstanding writer cannot share its path with a newly created, unlocked inode.
rm -rf "$SUPPORT" "$PREFIX/Library/Logs/Tether"
case "$(readlink "$PREFIX/usr/local/bin/tether" 2>/dev/null || true)" in
  *Tether.app/Contents/Helpers/tether) rm -f "$PREFIX/usr/local/bin/tether" ;;
esac
