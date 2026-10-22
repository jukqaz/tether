#!/bin/sh
# Sourced by the watchdog and install/removal transactions. Uses the same BSD flock
# as RecoveryLock.swift. FD 9 stays open in the caller; the lock inode is never removed.
recovery_lock_path() {
  recovery_support=$1
  RECOVERY_WRITER="$recovery_support/power-writer.json"
  RECOVERY_EXECUTOR=${2:-/Library/PrivilegedHelperTools/local.tether.power-recovery}
  if [ "$(id -u)" -ne 0 ] && [ -n "${TETHER_RECOVERY_EXECUTOR:-}" ]; then
    RECOVERY_EXECUTOR=$TETHER_RECOVERY_EXECUTOR
  fi
  case "$recovery_support" in
    */Application\ Support/Tether) RECOVERY_LOCK_PATH="${recovery_support%/*}/.tether-power-recovery.lock" ;;
    *) RECOVERY_LOCK_PATH="$recovery_support/recovery.lock" ;;
  esac
}
recovery_executor_capable() {
  [ -f "$RECOVERY_EXECUTOR" ] && [ -x "$RECOVERY_EXECUTOR" ] && [ ! -L "$RECOVERY_EXECUTOR" ] &&
  [ "$(stat -f %l "$RECOVERY_EXECUTOR")" = 1 ] || return 1
  recovery_executor_mode=$(stat -f %Lp "$RECOVERY_EXECUTOR") || return 1
  case "$recovery_executor_mode" in ''|*[!0-7]*) return 1 ;; esac
  [ "$((0$recovery_executor_mode & 022))" -eq 0 ] || return 1
  if [ "$RECOVERY_EXECUTOR" = /Library/PrivilegedHelperTools/local.tether.power-recovery ]; then
    [ "$(stat -f %u "$RECOVERY_EXECUTOR")" = 0 ] || return 1
  fi
  if [ "$(id -u)" = 0 ]; then
    # Check the component before trying flags: a mistakenly supplied legacy
    # helper could otherwise ignore --capability and start its daemon.
    /usr/bin/codesign --verify --strict "$RECOVERY_EXECUTOR" 2>/dev/null || return 1
    recovery_identifier=$(/usr/bin/codesign -dv "$RECOVERY_EXECUTOR" 2>&1 | sed -n 's/^Identifier=//p')
    [ "$recovery_identifier" = local.tether.power-recovery ] || return 1
  fi
  [ "$("$RECOVERY_EXECUTOR" --capability 2>/dev/null)" = power-recovery-executor-v2 ] &&
  [ "$("$RECOVERY_EXECUTOR" --gate-capability 2>/dev/null)" = power-writer-gate-v3 ]
}
recovery_pmset() {
  case "$*" in
    '-a disablesleep 0') recovery_operation=release-sleep ;;
    sleepnow) recovery_operation=request-sleep ;;
    *) return 64 ;;
  esac
  if recovery_executor_capable; then
    "$RECOVERY_EXECUTOR" --write --support "$recovery_support" --operation "$recovery_operation" <&9
  elif [ -x "$RECOVERY_HELPER" ] && [ ! -L "$RECOVERY_HELPER" ] &&
       grep -aq -- '--validate-settings' "$RECOVERY_HELPER" &&
       [ "$("$RECOVERY_HELPER" --validate-settings --recovery-write-capability 2>/dev/null)" = power-recovery-executor-v2 ] &&
       [ "$("$RECOVERY_HELPER" --validate-settings --writer-gate-capability 2>/dev/null)" = power-writer-gate-v3 ]; then
    "$RECOVERY_HELPER" --recovery-write --support "$recovery_support" --operation "$recovery_operation" <&9
  else
    # Never fall back to an unjournaled writer when both native executors are unavailable.
    return 1
  fi
}
recovery_helper_capable() {
  [ -x "$RECOVERY_HELPER" ] && [ ! -L "$RECOVERY_HELPER" ] || return 1
  # Some much older binaries ignore unfamiliar arguments and start their service.
  # Inspect for the established validator before running even the harmless probe.
  grep -aq -- '--validate-settings' "$RECOVERY_HELPER" || return 1
  [ "$("$RECOVERY_HELPER" --validate-settings --control "$recovery_support/control.json" --writer-recovery-capability 2>/dev/null)" = power-writer-recovery-v1 ]
}
recovery_writer_ready() {
  [ ! -e "$RECOVERY_WRITER" ] && [ ! -L "$RECOVERY_WRITER" ] && return 0
  [ -f "$RECOVERY_WRITER" ] && [ ! -L "$RECOVERY_WRITER" ] &&
  [ "$(stat -f %l "$RECOVERY_WRITER")" = 1 ] &&
  [ "$(stat -f %u "$RECOVERY_WRITER")" = "$(id -u)" ] &&
  [ "$(stat -f %Lp "$RECOVERY_WRITER")" = 600 ] || return 1
  if recovery_executor_capable; then
    "$RECOVERY_EXECUTOR" --clear --support "$recovery_support" <&9
    return $?
  fi
  if recovery_helper_capable; then
    "$RECOVERY_HELPER" --power-writer-recovery --journal-file "$RECOVERY_WRITER" --recovery-lock-stdin <&9
    return $?
  fi
  # Independent watchdog fallback: acquisition of the very same flock proves that
  # a direct pmset writer no longer holds its inherited stdin. Never signal a PID
  # here without the native lifetime verifier. Unsupported records remain intact.
  [ "$(plutil -extract schema raw -o - "$RECOVERY_WRITER" 2>/dev/null)" = 1 ] &&
  [ "$(plutil -extract inheritsRecoveryLock raw -o - "$RECOVERY_WRITER" 2>/dev/null)" = true ] &&
  [ "$(plutil -extract executable raw -o - "$RECOVERY_WRITER" 2>/dev/null)" = /usr/bin/pmset ] &&
  [ "$(plutil -extract owner.uid raw -o - "$RECOVERY_WRITER" 2>/dev/null)" = "$(id -u)" ] || return 1
  case "$(plutil -extract phase raw -o - "$RECOVERY_WRITER" 2>/dev/null)" in
    prepared|running|writerUnresolved) ;;
    *) return 1 ;;
  esac
  rm -f "$RECOVERY_WRITER"
}
recovery_lock_safe() {
  [ -f "$RECOVERY_LOCK_PATH" ] && [ ! -L "$RECOVERY_LOCK_PATH" ] &&
  [ "$(stat -f %l "$RECOVERY_LOCK_PATH")" = 1 ] &&
  [ "$(stat -f %u "$RECOVERY_LOCK_PATH")" = "$(id -u)" ] &&
  [ "$(stat -f %Lp "$RECOVERY_LOCK_PATH")" = 600 ]
}
recovery_lock_acquire() {
  recovery_parent=${RECOVERY_LOCK_PATH%/*}
  [ -d "$recovery_parent" ] && [ ! -L "$recovery_parent" ] || return 1
  [ "$(stat -f %u "$recovery_parent")" = "$(id -u)" ] || return 1
  recovery_mode=$(stat -f %Lp "$recovery_parent") || return 1
  case "$recovery_mode" in ''|*[!0-7]*) return 1 ;; esac
  [ "$((0$recovery_mode & 022))" -eq 0 ] || return 1
  if [ ! -e "$RECOVERY_LOCK_PATH" ] && [ ! -L "$RECOVERY_LOCK_PATH" ]; then
    (umask 077; set -C; : > "$RECOVERY_LOCK_PATH") 2>/dev/null || :
  fi
  recovery_lock_safe || return 1
  recovery_inode=$(stat -f '%d:%i' "$RECOVERY_LOCK_PATH") || return 1
  exec 9<> "$RECOVERY_LOCK_PATH" || return 1
  RECOVERY_HELPER=${RECOVERY_HELPER:-/Library/PrivilegedHelperTools/local.tether.helper}
  if ! /usr/bin/lockf -s -t "${1:-0}" 9; then
    # The identified expired writer can outlive the helper that launched it.
    if [ -f "$RECOVERY_WRITER" ]; then
      if recovery_executor_capable; then
        "$RECOVERY_EXECUTOR" --resolve --support "$recovery_support" >/dev/null 2>&1 || :
      elif recovery_helper_capable; then
        "$RECOVERY_HELPER" --power-writer-recovery --journal-file "$RECOVERY_WRITER" >/dev/null 2>&1 || :
      fi
    fi
    if ! /usr/bin/lockf -s -t 0 9; then exec 9>&-; return 75; fi
  fi
  # macOS /dev/fd reports a synthetic device number; its inode identifies the
  # opened file. The ordinary path's device AND inode must remain unchanged.
  if ! recovery_lock_safe || [ "$(stat -L -f %i /dev/fd/9)" != "${recovery_inode#*:}" ] ||
     [ "$(stat -f '%d:%i' "$RECOVERY_LOCK_PATH")" != "$recovery_inode" ]; then
    exec 9>&-; return 1
  fi
  if ! recovery_writer_ready; then exec 9>&-; return 1; fi
}
recovery_lock_release() { exec 9>&-; }
