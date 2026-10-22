#!/bin/sh
# Tether's watchdog, run by launchd as root every 30 seconds. If the helper has gone silent (no status
# for 90 seconds) while sleep is disabled, restore our setting on either power source.
# A silent/crashed helper is not a new approved power-disconnection incident.
# Plain shell on purpose, so it works even if the helper binary cannot run.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
# The paths can be overridden only to test this script.
STATUS="${TETHER_STATUS:-/Library/Application Support/Tether/status.json}"
LOG="${TETHER_LOG:-/Library/Logs/Tether/helper.log}"

# A completion receipt is independent of the helper heartbeat. A scheduled shell job is
# normally not running; this lets the UI distinguish installed from recently checked.
HEALTH="${TETHER_WATCHDOG_STATUS:-/Library/Application Support/Tether/watchdog-status.json}"
write_receipt() (
  receipt_code="$1"
  receipt_dir="${HEALTH%/*}"
  [ -d "$receipt_dir" ] && [ ! -L "$receipt_dir" ] || exit 1
  [ "$(stat -f %u "$receipt_dir")" = "$(id -u)" ] || exit 1
  receipt_mode=$(stat -f %Lp "$receipt_dir") || exit 1
  case "$receipt_mode" in ''|*[!0-7]*) exit 1 ;; esac
  [ "$((0$receipt_mode & 022))" -eq 0 ] || exit 1
  [ ! -L "$HEALTH" ] || exit 1
  if [ -e "$HEALTH" ]; then
    [ -f "$HEALTH" ] && [ "$(stat -f %l "$HEALTH")" = 1 ] || exit 1
    [ "$(stat -f %u "$HEALTH")" = "$(id -u)" ] || exit 1
  fi
  receipt_boot=$(sysctl -n kern.bootsessionuuid) || exit 1
  case "$receipt_boot" in ''|*[!0-9a-fA-F-]*) exit 1 ;; esac
  receipt_time=$(date +%s) || exit 1
  receipt_file=$(mktemp "$receipt_dir/.watchdog-check.XXXXXX") || exit 1
  if printf '{"checkedAt":%s,"boot":"%s","exitStatus":%s}\n' "$receipt_time" "$receipt_boot" "$receipt_code" > "$receipt_file" &&
      chmod 644 "$receipt_file" && mv -f "$receipt_file" "$HEALTH"; then
    exit 0
  fi
  rm -f "$receipt_file"
  exit 1
)
# A recording failure must never prevent recovery or change its exit result.
trap 'watchdog_result=$?; write_receipt "$watchdog_result" || :; exit "$watchdog_result"' 0

helper_fresh() {
  age="?"
  modified=$(stat -f %m "$STATUS" 2>/dev/null) || return 1
  case "$modified" in ''|*[!0-9]*) return 1 ;; esac
  age=$(( $(date +%s) - modified ))
  [ "$age" -ge 0 ] && [ "$age" -lt 90 ]
}
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') watchdog: $*" >> "$LOG"; }

helper_fresh && exit 0
OWNERSHIP="${TETHER_OWNERSHIP:-/Library/Application Support/Tether/power-ownership.json}"
RECOVERY_LIBRARY=/Library/PrivilegedHelperTools/local.tether.recovery-lock
if [ "$(id -u)" -ne 0 ] && [ -n "${TETHER_RECOVERY_LOCK_LIBRARY:-}" ]; then
  RECOVERY_LIBRARY=$TETHER_RECOVERY_LOCK_LIBRARY
fi
[ -f "$RECOVERY_LIBRARY" ] && [ ! -L "$RECOVERY_LIBRARY" ] || exit 1
. "$RECOVERY_LIBRARY"
recovery_lock_path "${OWNERSHIP%/*}"
recovery_lock_acquire 0
recovery_result=$?
[ "$recovery_result" = 75 ] && exit 0 # A live transaction gets the next scheduled check.
[ "$recovery_result" = 0 ] || exit 1
# Freshness and the journal must be read again after acquiring the common lock.
helper_fresh && exit 0
[ -f "$OWNERSHIP" ] && [ ! -L "$OWNERSHIP" ] || exit 0
[ "$(plutil -extract owned raw -o - "$OWNERSHIP" 2>/dev/null)" = true ] || exit 0
[ "$(plutil -extract boot raw -o - "$OWNERSHIP" 2>/dev/null)" = "$(sysctl -n kern.bootsessionuuid)" ] || exit 0
# A restarting helper journals before its OS write and first status publication. Give that
# new lease the same heartbeat budget, rather than racing it with crash recovery.
ownership_modified=$(stat -f %m "$OWNERSHIP" 2>/dev/null) || exit 0
case "$ownership_modified" in ''|*[!0-9]*) exit 0 ;; esac
ownership_age=$(( $(date +%s) - ownership_modified ))
[ "$ownership_age" -ge 0 ] && [ "$ownership_age" -lt 90 ] && exit 0
ownership_generation=$(cksum "$OWNERSHIP") || exit 0
same_ownership() { [ ! -L "$OWNERSHIP" ] && [ "$(cksum "$OWNERSHIP" 2>/dev/null)" = "$ownership_generation" ]; }
root=$(ioreg -r -c IOPMrootDomain -d 1) || exit 0
if printf '%s\n' "$root" | grep -q '"SleepDisabled" = No'; then
  # Otherwise a later, unrelated app's override could be cleared using this old lease.
  root=$(ioreg -r -c IOPMrootDomain -d 1) || exit 1
  if printf '%s\n' "$root" | grep -q '"SleepDisabled" = No' && same_ownership; then rm -f "$OWNERSHIP"; fi
  exit 0
fi
printf '%s\n' "$root" | grep -q '"SleepDisabled" = Yes' || exit 0
same_ownership && ! helper_fresh || exit 0
if ! recovery_pmset -a disablesleep 0; then
  log "helper silent for $age s: could not restore sleep"
  exit 1
fi
root=$(ioreg -r -c IOPMrootDomain -d 1) || exit 1
if ! printf '%s\n' "$root" | grep -q '"SleepDisabled" = No'; then
  log "sleep restoration was not confirmed; ownership retained"
  exit 1
fi
# A later foreign override must not be cleared using this already-consumed journal.
if ! same_ownership; then
  log "ownership changed during recovery; preserving the new session and skipping sleep"
  exit 0
fi
root=$(ioreg -r -c IOPMrootDomain -d 1) || exit 1
printf '%s\n' "$root" | grep -q '"SleepDisabled" = No' || exit 1
same_ownership || exit 0
rm -f "$OWNERSHIP"
log "helper silent for $age s: sleep turned back on"
log "crash recovery only: no new Sleep incident or request"
