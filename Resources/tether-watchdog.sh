#!/bin/sh
# Tether's watchdog, run by launchd as root every minute. If the helper has gone silent (no status
# for 3 minutes) while sleep is disabled and the Mac runs on battery, a closed Mac in a bag would
# never sleep: turn sleep back on, then request sleep if the lid is still closed in a full wake.
# Plain shell on purpose, so it works even if the helper binary cannot run.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
# The paths can be overridden only to test this script.
STATUS="${TETHER_STATUS:-/Library/Application Support/Tether/status.json}"
LOG="${TETHER_LOG:-/Library/Logs/Tether/helper.log}"

on_battery() { pmset -g batt | head -n 1 | grep -q "Battery Power"; }
helper_fresh() {
  age="?"
  modified=$(stat -f %m "$STATUS" 2>/dev/null) || return 1
  case "$modified" in ''|*[!0-9]*) return 1 ;; esac
  age=$(( $(date +%s) - modified ))
  [ "$age" -ge 0 ] && [ "$age" -lt 180 ]
}
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') watchdog: $*" >> "$LOG"; }

on_battery || exit 0
ioreg -r -c IOPMrootDomain -d 1 | grep -q '"SleepDisabled" = Yes' || exit 0
helper_fresh && exit 0
on_battery || exit 0
if ! pmset -a disablesleep 0; then
  log "helper silent for $age s on battery: could not restore sleep"
  exit 1
fi
log "helper silent for $age s on battery: sleep turned back on"

# Releasing disablesleep alone does not replay an already-closed lid event. Re-read all the
# conditions before requesting sleep: the charger, lid or helper may have changed meanwhile.
on_battery || exit 0
helper_fresh && exit 0
root=$(ioreg -r -c IOPMrootDomain -d 1)
printf '%s\n' "$root" | grep -q '"SleepDisabled" = No' || exit 0
printf '%s\n' "$root" | grep -q '"AppleClamshellState" = Yes' || exit 0
capabilities=$(printf '%s\n' "$root" | awk '/"System Capabilities" =/ {print $NF; exit}')
case "$capabilities" in ''|*[!0-9]*) exit 0 ;; esac
[ "$((capabilities & 2))" -ne 0 ] || exit 0  # Do not interfere with Dark Wake.
if pmset sleepnow; then
  log "closed lid on battery in full wake: sleep requested (actual sleep must be confirmed in power logs)"
else
  log "closed lid on battery in full wake: sleep request failed"
  exit 1
fi
