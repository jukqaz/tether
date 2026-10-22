#!/usr/bin/env python3
"""Real removal script, unprivileged temporary paths and mocked OS writes only."""
import fcntl, json, os, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
if os.geteuid() == 0: raise SystemExit('Run without root: removal is restricted to isolated mock paths')
configured_bin = os.environ.get('TETHER_TEST_BIN_DIRECTORY')
BIN = Path(configured_bin) if configured_bin else Path(subprocess.check_output(
    ['swift', 'build', '--disable-sandbox', '--show-bin-path'], cwd=ROOT, text=True).strip())
BOOT = subprocess.check_output(['/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid'], text=True).strip()
MOCK = '''#!/bin/sh
case "$(basename "$0")" in
  launchctl) if [ "$1" = print ]; then [ -f "$TETHER_UNINSTALL_TEST_ROOT/stuck" ]; else exit 0; fi ;;
  pmset) printf '%s\\n' "$*" >> "$TETHER_UNINSTALL_TEST_ROOT/commands"; [ ! -f "$TETHER_UNINSTALL_TEST_ROOT/write-fail" ] ;;
  ioreg) if [ -f "$TETHER_UNINSTALL_TEST_ROOT/no-effect" ]; then echo '"SleepDisabled" = Yes'; else echo '"SleepDisabled" = No'; fi ;;
  stat) if [ "$2" = %u ] && [ "$3" = "$TETHER_UNINSTALL_TEST_ROOT/Library/Application Support/Tether/helper-state.json" ] && [ -f "$TETHER_UNINSTALL_TEST_ROOT/foreign-owner" ]; then
      echo "$(( $(id -u) + 1 ))"
    else exec /usr/bin/stat "$@"; fi ;;
esac
'''

validation_failures = {
    'state-corrupt', 'state-array', 'state-wrong-type', 'state-invalid-value',
    'state-unreadable', 'state-unsafe-mode', 'state-link', 'state-hard-link', 'state-foreign-owner',
    'ownership-corrupt', 'ownership-wrong-type', 'ownership-missing-field', 'ownership-unsafe-mode',
}
cases = ['owned', 'unowned', 'previous-boot', 'restore-pending', 'write-fail', 'stuck',
    'foreign-link', 'lock-busy', 'unsafe-lock', 'no-effect',
    'state-corrupt', 'state-array', 'state-null', 'state-wrong-type', 'state-invalid-value',
    'state-high-power-pending', 'state-unreadable', 'state-unsafe-mode', 'state-link',
    'state-hard-link', 'state-foreign-owner', 'ownership-corrupt', 'ownership-wrong-type',
    'ownership-missing-field', 'ownership-unsafe-mode', 'legacy-readable-records', 'missing-records']
for case in cases:
    with tempfile.TemporaryDirectory(prefix='tether-uninstall-test-', dir='/tmp') as temp:
        root = Path(temp)
        support = root/'Library/Application Support/Tether'; support.mkdir(parents=True)
        lock = support.parent/'.tether-power-recovery.lock'; lock.touch(mode=0o600)
        inode = lock.stat().st_ino
        holder = lock.open('r+')
        if case == 'lock-busy': fcntl.flock(holder, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if case == 'unsafe-lock': lock.chmod(0o666)
        mock = root/'mock'; mock.mkdir()
        for name in ['launchctl', 'pmset', 'ioreg', 'stat']:
            path = mock/name; path.write_text(MOCK); path.chmod(0o755)
        ownership = support/'power-ownership.json'
        ownership.write_text(json.dumps({'owned': case != 'unowned', 'boot': 'old' if case == 'previous-boot' else BOOT}))
        state = support/'helper-state.json'
        state.write_text(json.dumps({'savedBatteryLowPower': 0} if case == 'restore-pending' else {}))
        ownership.chmod(0o600); state.chmod(0o600)
        if case == 'state-corrupt': state.write_text('{"savedBatteryLowPower":0')
        if case == 'state-array': state.write_text('[]')
        if case == 'state-null': state.write_text('{"savedBatteryLowPower":null,"savedACLowPower":null}')
        if case == 'state-wrong-type': state.write_text('{"savedBatteryLowPower":"0"}')
        if case == 'state-invalid-value': state.write_text('{"savedACLowPower":3}')
        if case == 'state-high-power-pending': state.write_text('{"savedACLowPower":2}')
        if case == 'state-unreadable': state.chmod(0)
        if case == 'state-unsafe-mode': state.chmod(0o666)
        if case == 'state-link':
            target = root/'external-state.json'; state.rename(target); state.symlink_to(target)
        if case == 'state-hard-link': os.link(state, root/'external-state.json')
        if case == 'state-foreign-owner': (root/'foreign-owner').touch()
        if case == 'ownership-corrupt': ownership.write_text('{"owned":true')
        if case == 'ownership-wrong-type': ownership.write_text(json.dumps({'owned':'true','boot':BOOT}))
        if case == 'ownership-missing-field': ownership.write_text(json.dumps({'boot':BOOT}))
        if case == 'ownership-unsafe-mode': ownership.chmod(0o666)
        if case == 'legacy-readable-records': ownership.chmod(0o644); state.chmod(0o644)
        if case == 'missing-records': ownership.unlink(); state.unlink()
        # Assert failed removal preserves the original evidence, including partial JSON.
        original_state = state.read_bytes() if case != 'state-unreadable' and state.exists() else None
        original_ownership = ownership.read_bytes() if ownership.exists() else None
        for name in ['PrivilegedHelperTools/local.tether.helper', 'LaunchDaemons/local.tether.helper.plist', 'Logs/Tether/helper.log']:
            path = root/'Library'/name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text('fixture')
        link = root/'usr/local/bin/tether'; link.parent.mkdir(parents=True)
        link.symlink_to('/Applications/Other.app/tool' if case == 'foreign-link' else '/Applications/Tether.app/Contents/Helpers/tether')
        if case in ['write-fail', 'stuck', 'no-effect']: (root/case).touch()
        result = subprocess.run(['sh', str(ROOT/'Resources/uninstall-helper.sh')], env=dict(os.environ,
            TETHER_UNINSTALL_TEST_ROOT=temp, TETHER_RECOVERY_EXECUTOR=str(BIN/'TetherRecoveryCLI')),
            capture_output=True, text=True, timeout=15)
        holder.close()
        retained = case in validation_failures or case in ['restore-pending', 'state-high-power-pending',
            'write-fail', 'stuck', 'lock-busy', 'unsafe-lock', 'no-effect']
        assert (result.returncode != 0) == retained, (case, result.stderr)
        assert support.exists() == retained, case
        assert (root/'Library/PrivilegedHelperTools/local.tether.helper').exists() == retained, case
        assert link.is_symlink() == (retained or case == 'foreign-link'), case
        wrote = (root/'commands').exists()
        assert wrote == (case not in validation_failures and case not in
            ['unowned', 'previous-boot', 'stuck', 'lock-busy', 'unsafe-lock', 'missing-records']), case
        assert lock.stat().st_ino == inode, (case, 'stable lock was replaced/deleted')
        if retained:
            if original_state is not None: assert state.read_bytes() == original_state, (case, 'state original lost')
            if original_ownership is not None: assert ownership.read_bytes() == original_ownership, (case, 'ownership original lost')
        if case == 'state-high-power-pending': assert 'restoration is incomplete' in result.stderr, result.stderr
        if case in validation_failures: assert 'record' in result.stderr or 'value is invalid' in result.stderr, result.stderr
        print('PASS', case, flush=True)
print('TOTAL', len(cases), 'uninstall scenarios passed')
