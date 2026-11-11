#!/usr/bin/env python3
"""Real independent recovery executor, native mock writer and parent death. No OS writes."""
import fcntl
import json
import os
import shutil
import signal
import subprocess
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIN = (Path(os.environ['TETHER_TEST_BIN']) if os.environ.get('TETHER_TEST_BIN') else
       Path(subprocess.check_output(['swift', 'build', '--disable-sandbox', '--show-bin-path'], cwd=ROOT, text=True).strip()))
EXECUTOR = BIN/'TetherRecoveryCLI'
HELPER = BIN/'TetherHelper'
DRIVER = BIN/'TetherWriterFixture'
LIBRARY = ROOT/'Resources/tether-recovery-lock.sh'

def wait_for(test, timeout=5):
    until = time.monotonic()+timeout
    while time.monotonic()<until:
        if test(): return
        time.sleep(.01)
    raise AssertionError('Native recovery fixture did not reach expected state')

def busy(path):
    with path.open('r+') as file:
        try: fcntl.flock(file, fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError: return True
    return False

@contextmanager
def fixture(behavior='success'):
    with tempfile.TemporaryDirectory(prefix='tether-recovery-test-', dir='/private/tmp') as temp:
        folder=Path(temp); folder.chmod(0o700)
        (folder/'mock').mkdir()
        shutil.copy2(DRIVER, folder/'mock/pmset'); (folder/'mock/pmset').chmod(0o700)
        env=dict(os.environ,TETHER_RECOVERY_TEST_ROOT=str(folder),TETHER_RECOVERY_FIXTURE=behavior,
                 TETHER_RECOVERY_EXECUTOR=str(EXECUTOR))
        observation=folder/'recovery-sleep.json'
        observation.write_text(json.dumps(dict(power='battery',lidClosed=True,sleepDisabled=False,
            fullWake=True,foreignKeepAwake=False)))
        observation.chmod(0o600)
        lock=folder/'recovery.lock'; lock.touch(mode=0o600)
        yield folder,env,lock

def native(mode, folder, env, *, operation=None, handle=None):
    arguments=[str(EXECUTOR),mode,'--support',str(folder)]
    if operation: arguments += ['--operation',operation]
    return subprocess.run(arguments,stdin=handle or subprocess.DEVNULL,env=env,
        capture_output=True,text=True,timeout=5)

def normal_case(operation, behavior='success'):
    with fixture(behavior) as (folder,env,lock):
        with lock.open('r+') as handle:
            fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
            result=native('--write',folder,env,operation=operation,handle=handle)
        assert (result.returncode==0)==(behavior=='success'),result.stderr
        assert not (folder/'power-writer.json').exists()
        if behavior=='success':
            expected='-a disablesleep 0' if operation=='release-sleep' else 'sleepnow'
            assert (folder/'effect').read_text()==expected
        else: assert not (folder/'effect').exists()
        assert not busy(lock)
        print('PASS native recovery',operation,behavior,flush=True)

def deferred_sleep_case(foreign):
    with fixture() as (folder,env,lock):
        observation=folder/'recovery-sleep.json'
        observation.write_text(json.dumps(dict(power='battery',lidClosed=True,sleepDisabled=False,
            fullWake=True,foreignKeepAwake=foreign)))
        with lock.open('r+') as handle:
            fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
            result=native('--write',folder,env,operation='request-sleep',handle=handle)
        assert result.returncode==77,(result.stdout,result.stderr)
        assert not (folder/'effect').exists() and not (folder/'power-writer.json').exists()
        assert not busy(lock)
        print('PASS recovery preserves foreign work or unavailable request observation',foreign,flush=True)

def deadline_case():
    with fixture('delay') as (folder,env,lock):
        start=time.monotonic()
        with lock.open('r+') as handle:
            fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
            result=native('--write',folder,env,operation='release-sleep',handle=handle)
        elapsed=time.monotonic()-start
        assert result.returncode!=0 and elapsed<3.5,(result.stderr,elapsed)
        assert not (folder/'power-writer.json').exists() and not busy(lock)
        time.sleep(.1)
        assert not (folder/'effect').exists()
        print('PASS native recovery deadline confirms TERM-ignoring writer exit',flush=True)

def parent_crash_case():
    with fixture('delay') as (folder,env,lock):
        with lock.open('r+') as handle:
            fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
            parent=subprocess.Popen([str(EXECUTOR),'--write','--support',str(folder),'--operation','release-sleep'],
                stdin=handle,env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        # Close rather than unlock the parent's duplicate; the inherited open-file
        # description must continue to hold the same flock in the native coordinator.
        writer=None; owner=None
        try:
            journal=folder/'power-writer.json'
            def registered():
                try: return json.loads(journal.read_text()).get('writerPID') and (folder/'child.pid').exists()
                except (OSError,ValueError): return False
            wait_for(registered)
            record=json.loads(journal.read_text()); owner=record['owner']['pid']; writer=record['writerPID']
            assert record['phase']=='running' and record['intentEpoch']=='recovery'
            assert writer==int((folder/'child.pid').read_text())
            assert record['executable']==str(folder/'mock/pmset') or Path(record['executable']).resolve()==(folder/'mock/pmset').resolve()
            assert owner==parent.pid and record['owner']['uid']==os.geteuid()
            parent.kill(); parent.wait(timeout=2)
            assert parent.returncode!=0 and busy(lock)
            saved=journal.read_bytes()
            assert native('--resolve',folder,env).returncode==75
            assert journal.read_bytes()==saved
            time.sleep(2.1)
            assert native('--resolve',folder,env).returncode==0
            wait_for(lambda: not busy(lock))
            with lock.open('r+') as handle:
                fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
                assert native('--clear',folder,env,handle=handle).returncode==0
            assert not journal.exists() and not (folder/'effect').exists()
            print('PASS independent recovery parent SIGKILL retains lock and resolves identified expired writer',flush=True)
        finally:
            if parent.poll() is None: parent.kill(); parent.wait(timeout=2)
            if busy(lock):
                # Let the native resolver revalidate lifetime instead of signalling a
                # journal PID from Python after it might already have been reused.
                time.sleep(2.1)
                native('--resolve',folder,env)

def rejected_case():
    with fixture() as (folder,env,lock):
        assert native('--write',folder,env,operation='release-sleep').returncode!=0
        assert not (folder/'effect').exists() and not (folder/'power-writer.json').exists()
        with lock.open('r+') as handle:
            fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
            assert native('--write',folder,env,operation='enable-sleep-override',handle=handle).returncode!=0
        assert not (folder/'effect').exists() and not (folder/'power-writer.json').exists()
        print('PASS missing common stdin lock and unsupported operation are rejected before writes',flush=True)

def fallback_case(healthy):
    with fixture() as (folder,env,lock):
        env['TETHER_RECOVERY_EXECUTOR']=str(folder/'missing-executor')
        helper=HELPER if healthy else folder/'missing-helper'
        shell='. "$1"; recovery_lock_path "$2"; RECOVERY_HELPER="$3"; recovery_lock_acquire 0; recovery_pmset -a disablesleep 0'
        result=subprocess.run(['/bin/sh','-ec',shell,'test',str(LIBRARY),str(folder),str(helper)],env=env,
            capture_output=True,text=True,timeout=5)
        assert (result.returncode==0)==healthy,(result.stdout,result.stderr)
        assert (folder/'effect').exists()==healthy and not (folder/'power-writer.json').exists()
        print('PASS recovery helper fallback', 'healthy' if healthy else 'both unavailable refuse unjournaled writes',flush=True)

def legacy_gate_case(healthy_fallback, gate_version=1):
    with fixture() as (folder,env,lock):
        # Earlier executors cannot claim the exec-boundary GUI/coexistence
        # contract. These temporary stand-ins would leave a marker if run.
        executor=folder/'old-executor'
        executor.write_text('#!/bin/sh\ncase "$1" in\n--capability) echo power-recovery-executor-v1;;\n'
            f'--gate-capability) echo power-writer-gate-v{gate_version};;\n*) touch "$TETHER_RECOVERY_TEST_ROOT/legacy-write"; exit 0;;\nesac\n')
        executor.chmod(0o755)
        old_helper=folder/'old-helper'
        old_helper.write_text('#!/bin/sh\n# --validate-settings\ncase "$2" in\n'
            '--recovery-write-capability) echo power-recovery-executor-v1;;\n'
            f'--writer-gate-capability) echo power-writer-gate-v{gate_version};;\n'
            '*) touch "$TETHER_RECOVERY_TEST_ROOT/legacy-write"; exit 0;;\nesac\n')
        old_helper.chmod(0o755)
        env['TETHER_RECOVERY_EXECUTOR']=str(executor)
        helper=HELPER if healthy_fallback else old_helper
        shell='. "$1"; recovery_lock_path "$2"; RECOVERY_HELPER="$3"; recovery_lock_acquire 0; recovery_pmset -a disablesleep 0'
        result=subprocess.run(['/bin/sh','-ec',shell,'test',str(LIBRARY),str(folder),str(helper)],env=env,
            capture_output=True,text=True,timeout=5)
        assert (result.returncode==0)==healthy_fallback,(result.stdout,result.stderr)
        assert not (folder/'legacy-write').exists(), f'Stale v{gate_version} gate was executed'
        assert (folder/'effect').exists()==healthy_fallback and not (folder/'power-writer.json').exists()
        print('PASS legacy gate capability',gate_version,'new helper fallback' if healthy_fallback else 'old components refuse writes',flush=True)

if os.geteuid()==0: raise SystemExit('Run without root: only isolated fixture processes may be used')
normal_case('release-sleep')
normal_case('request-sleep')
deferred_sleep_case(True)
deferred_sleep_case(None)
normal_case('release-sleep','fail')
deadline_case()
parent_crash_case()
rejected_case()
fallback_case(True)
fallback_case(False)
legacy_gate_case(True)
legacy_gate_case(False)
legacy_gate_case(True, gate_version=2)
legacy_gate_case(False, gate_version=2)
print('TOTAL 14 independent recovery executor scenarios passed',flush=True)
