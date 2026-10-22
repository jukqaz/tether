#!/bin/sh
# Transactional helper upgrade. The app requests administrator authorization once.
set -eu
RES=$(cd "$(dirname "$0")" && pwd)
LABEL=local.tether.helper
WATCHDOG=local.tether.watchdog
LOCK_LIBRARY=local.tether.recovery-lock
RECOVERY_TOOL=local.tether.power-recovery
PREFIX=
if [ "$(id -u)" -ne 0 ]; then
  case "${TETHER_INSTALL_TEST_ROOT:-}" in
    /tmp/tether-install-test-*) PREFIX=$TETHER_INSTALL_TEST_ROOT ;;
    *) echo 'Administrator authorization is required.' >&2; exit 1 ;;
  esac
  # Only an unprivileged test can substitute system commands.
  PATH="$PREFIX/mock:/usr/bin:/bin:/usr/sbin:/sbin"
else
  PATH=/usr/bin:/bin:/usr/sbin:/sbin
fi
export PATH
RECOVERY_HELPER="$RES/tether-helper"
. "$RES/tether-recovery-lock.sh"
# Recheck hardware and lid after administrator authorization, before stopping the
# current helper. A desktop uses user-session assertions and needs no root helper.
# Unknown/old probe output must not be interpreted as a portable or desktop Mac.
require_install_target() {
  target=$("$RECOVERY_HELPER" --validate-settings --helper-install-target --control "$PREFIX/Library/Application Support/Tether/control.json" 2>/dev/null) || {
    echo 'The helper installation target could not be verified. Nothing was replaced.' >&2; exit 1;
  }
  case "$target" in
    'helper-install-target-v1 portable') ;;
    'helper-install-target-v1 desktop') echo 'This Mac uses user-session assertions; an administrator helper is not required. Nothing was replaced.' >&2; exit 1 ;;
    'helper-install-target-v1 unsupported') echo 'Tether requires an Apple Silicon Mac running macOS 26 or later. Nothing was replaced.' >&2; exit 1 ;;
    *) echo 'The internal battery and lid could not be verified. Nothing was replaced.' >&2; exit 1 ;;
  esac
  lid=$(ioreg -r -k AppleClamshellState -d 4 | awk '/"AppleClamshellState" =/ { print $NF; exit }')
  [ "$lid" = No ] || { echo 'Open the MacBook before installing the helper. Lid state is closed or unavailable.' >&2; exit 1; }
}
require_install_target
SUPPORT="$PREFIX/Library/Application Support/Tether"
recovery_lock_path "$SUPPORT" "$RES/tether-power-recovery"
recovery_executor_capable || { echo 'Recovery executor is missing or invalid. Nothing was replaced.' >&2; exit 1; }
lockHeld=false
TOOLS="$PREFIX/Library/PrivilegedHelperTools"
DAEMONS="$PREFIX/Library/LaunchDaemons"
# Validate all existing log paths before stopping a service or installing the
# rollback trap. Descriptor-based permission repair preserves active stdout and
# rejects links, foreign owners and unsafe directories without modifying logs.
"$RECOVERY_EXECUTOR" --prepare-logs --support "$SUPPORT" || {
  echo 'Unsafe helper log paths. Nothing was replaced.' >&2; exit 1;
}
[ ! -L "$SUPPORT" ] || { echo 'Unsafe support directory.' >&2; exit 1; }
mkdir -p "$SUPPORT"
if [ -z "$PREFIX" ]; then chown root:wheel "$SUPPORT"; fi
chmod 755 "$SUPPORT"
FILES='control.json control.json.backup status.json usage.json helper-state.json suite-state.json protection-state.json migration-report.json power-ownership.json watchdog-status.json'
# Writer journal is checked by the recovery guard and must never be copied back as
# a rollback setting after its process has stopped. It belongs to a transaction.
if [ -e "$SUPPORT/power-writer.json" ] || [ -L "$SUPPORT/power-writer.json" ]; then
  [ -f "$SUPPORT/power-writer.json" ] && [ ! -L "$SUPPORT/power-writer.json" ] || exit 1
fi
for name in $FILES; do
  file="$SUPPORT/$name"
  [ ! -e "$file" ] && [ ! -L "$file" ] && continue
  [ -f "$file" ] && [ ! -L "$file" ] && [ "$(stat -f %l "$file")" = 1 ] || {
    echo "Unsafe existing file: $name. Nothing was replaced." >&2; exit 1;
  }
done
if [ -f "$SUPPORT/control.json" ]; then
  "$RES/tether-helper" --validate-settings --control "$SUPPORT/control.json"
fi
# Keep both binaries and settings until the new service reports the expected version/schema.
[ ! -L "$SUPPORT/upgrades" ] || exit 1
mkdir -p "$SUPPORT/upgrades"
if [ -z "$PREFIX" ]; then chown root:wheel "$SUPPORT/upgrades"; fi
chmod 700 "$SUPPORT/upgrades"
BACKUP=$(mktemp -d "$SUPPORT/upgrades/helper-XXXXXXXX")
mkdir "$BACKUP/tools" "$BACKUP/daemons" "$BACKUP/settings"
for name in "$LABEL" "$WATCHDOG" "$LOCK_LIBRARY" "$RECOVERY_TOOL"; do
  [ ! -f "$TOOLS/$name" ] || cp -p "$TOOLS/$name" "$BACKUP/tools/$name"
done
for name in "$LABEL" "$WATCHDOG"; do
  [ ! -f "$DAEMONS/$name.plist" ] || cp -p "$DAEMONS/$name.plist" "$BACKUP/daemons/$name.plist"
done
settingsReady=false
committed=false
rollback() {
  echo 'Helper upgrade failed; restoring previous helper and settings.' >&2
  if [ "$lockHeld" = true ]; then recovery_lock_release; lockHeld=false; fi
  launchctl bootout "system/$WATCHDOG" 2>/dev/null || true
  launchctl bootout "system/$LABEL" 2>/dev/null || true
  i=0
  while { launchctl print "system/$LABEL" >/dev/null 2>&1 || launchctl print "system/$WATCHDOG" >/dev/null 2>&1; } && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  if launchctl print "system/$LABEL" >/dev/null 2>&1 || launchctl print "system/$WATCHDOG" >/dev/null 2>&1 || ! recovery_lock_acquire 2; then
    echo "Recovery deferred: a service/transaction is still active. Backup retained: $BACKUP" >&2
    return
  fi
  lockHeld=true
  for name in "$LABEL" "$WATCHDOG" "$LOCK_LIBRARY" "$RECOVERY_TOOL"; do
    if [ -f "$BACKUP/tools/$name" ]; then cp -p "$BACKUP/tools/$name" "$TOOLS/$name"; else rm -f "$TOOLS/$name"; fi
  done
  for name in "$LABEL" "$WATCHDOG"; do
    if [ -f "$BACKUP/daemons/$name.plist" ]; then cp -p "$BACKUP/daemons/$name.plist" "$DAEMONS/$name.plist"; else rm -f "$DAEMONS/$name.plist"; fi
  done
  if [ "$settingsReady" = true ]; then
    for name in $FILES; do
      # Ownership is a consumed runtime lease, not a setting. Replaying the backup
      # could clear a later foreign override with an already-used Tether journal.
      [ "$name" != power-ownership.json ] || continue
      if [ -f "$BACKUP/settings/$name" ]; then cp -p "$BACKUP/settings/$name" "$SUPPORT/$name"; else rm -f "$SUPPORT/$name"; fi
    done
  fi
  recovery_lock_release; lockHeld=false
  for name in "$LABEL" "$WATCHDOG"; do
    [ ! -f "$DAEMONS/$name.plist" ] || launchctl bootstrap system "$DAEMONS/$name.plist" || true
  done
  echo "Recovery backup: $BACKUP" >&2
}
require_install_target
trap 'status=$?; trap - 0; if [ "$committed" != true ]; then rollback; fi; exit "$status"' 0
trap 'exit 1' HUP INT TERM
# Let the old helper release its own settings when it stops. A missing helper's
# override may only be recovered from a valid current-boot ownership journal.
launchctl bootout "system/$WATCHDOG" 2>/dev/null || true
launchctl bootout "system/$LABEL" 2>/dev/null || true
i=0
while { launchctl print "system/$LABEL" >/dev/null 2>&1 || launchctl print "system/$WATCHDOG" >/dev/null 2>&1; } && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
if launchctl print "system/$LABEL" >/dev/null 2>&1 || launchctl print "system/$WATCHDOG" >/dev/null 2>&1; then echo 'Old power service did not stop.' >&2; exit 1; fi
recovery_lock_acquire 2 || { echo 'Power recovery transaction is busy or unsafe; upgrade deferred.' >&2; exit 1; }
lockHeld=true
for name in $FILES; do
  [ ! -f "$SUPPORT/$name" ] || cp -p "$SUPPORT/$name" "$BACKUP/settings/$name"
done
settingsReady=true
OWNERSHIP="$SUPPORT/power-ownership.json"
if [ -f "$OWNERSHIP" ] && [ "$(plutil -extract owned raw -o - "$OWNERSHIP" 2>/dev/null || true)" = true ] &&
   [ "$(plutil -extract boot raw -o - "$OWNERSHIP" 2>/dev/null || true)" = "$(sysctl -n kern.bootsessionuuid)" ]; then
  recovery_pmset -a disablesleep 0
  restored=$(ioreg -r -c IOPMrootDomain -d 1) || exit 1
  printf '%s\n' "$restored" | grep -q '"SleepDisabled" = No' || { echo 'Sleep restoration not confirmed; recovery journal retained.' >&2; exit 1; }
  rm -f "$OWNERSHIP"
fi
mkdir -p "$TOOLS" "$DAEMONS"
for pair in "tether-helper:$LABEL" "tether-watchdog.sh:$WATCHDOG"; do
  source=${pair%%:*}; target=${pair#*:}
  install -m 755 "$RES/$source" "$TOOLS/$target"
  install -m 644 "$RES/$target.plist" "$DAEMONS/$target.plist"
done
install -m 755 "$RES/tether-recovery-lock.sh" "$TOOLS/$LOCK_LIBRARY"
install -m 755 "$RES/tether-power-recovery" "$TOOLS/$RECOVERY_TOOL"
if [ ! -f "$SUPPORT/control.json" ]; then printf '{"enabled":true}\n' > "$SUPPORT/control.json"; fi
if [ -z "$PREFIX" ]; then
  chown root:wheel "$TOOLS/$LABEL" "$TOOLS/$WATCHDOG" "$TOOLS/$LOCK_LIBRARY" "$TOOLS/$RECOVERY_TOOL" "$DAEMONS/$LABEL.plist" "$DAEMONS/$WATCHDOG.plist" "$SUPPORT/control.json"
fi
chmod 644 "$SUPPORT/control.json"
# A restarting helper must be able to acquire the same lock. Never hold it while
# stopping/starting a service or waiting for that service's readiness.
recovery_lock_release; lockHeld=false
for name in "$LABEL" "$WATCHDOG"; do
  launchctl enable "system/$name" 2>/dev/null || true
  launchctl bootstrap system "$DAEMONS/$name.plist"
done
i=0
while ! "$RES/tether-helper" --check-service --socket "$SUPPORT/service.sock"; do
  i=$((i + 1)); [ "$i" -lt 30 ] || { echo 'New helper did not become ready.' >&2; exit 1; }
  sleep 0.2
done
committed=true
printf 'Helper update verified. Recovery backup: %s\n' "$BACKUP"
