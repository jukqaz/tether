#!/bin/sh
# Tether's watchdog, run by launchd as root every minute. If the helper has gone silent (no status
# for 3 minutes) while sleep is disabled and the Mac runs on battery, a closed Mac in a bag would
# never sleep: turn sleep back on. Plain shell on purpose, so it works even if the helper binary
# cannot run.
# The paths can be overridden only to test this script.
STATUS="${TETHER_STATUS:-/Library/Application Support/Tether/status.json}"
LOG="${TETHER_LOG:-/Library/Logs/Tether/helper.log}"

pmset -g batt | head -n 1 | grep -q "Battery Power" || exit 0
ioreg -r -c IOPMrootDomain -d 1 | grep -q '"SleepDisabled" = Yes' || exit 0
age="?"
if [ -f "$STATUS" ]; then
  age=$(( $(date +%s) - $(stat -f %m "$STATUS") ))
  [ "$age" -lt 180 ] && exit 0
fi
pmset -a disablesleep 0
echo "$(date '+%Y-%m-%d %H:%M:%S') watchdog: helper silent for $age s with sleep disabled on battery: sleep turned back on" >> "$LOG"
