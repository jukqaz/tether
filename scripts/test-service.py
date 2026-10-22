#!/usr/bin/env python3
"""Actual helper/CLI, isolated mocked sensors and power writes; no administrator access."""
import concurrent.futures
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
BIN = (Path(os.environ['TETHER_TEST_HELPER']).parent if os.environ.get('TETHER_TEST_HELPER') else
       Path(subprocess.check_output(['swift','build','--show-bin-path'],cwd=ROOT,text=True).strip()))
COUNT = 0

def passed(label):
    global COUNT
    COUNT += 1
    print('PASS', label, flush=True)

from service_fixture import Fixture

# Keep all power/lid combinations and native coexistence on the actual service path.
for lid in ['open','closed']:
    with Fixture(lid=lid) as f:
        assert f.ok('snapshot')['status']['ownsOverride']
        r=f.step(power='battery');assert not r['status']['ownsOverride']
        assert ('IOPMSleepSystem' in f.logs()) == (lid=='closed')
        passed('AC to battery with lid '+lid)
    with Fixture(power='battery',lid='open') as f:
        f.step(lid=lid);assert not f.ok('snapshot')['status']['ownsOverride']
        r=f.step(power='ac');assert r['status']['ownsOverride']
        passed('lid/power ordering '+lid)
with Fixture() as f:
    f.ok('stop');f.step(power='battery');f.step(power='ac')
    assert not f.ok('snapshot')['control']['enabled'];assert not f.ok('snapshot')['status']['ownsOverride']
    f.stop();f.start();assert not f.ok('snapshot')['control']['enabled']
    passed('manual off survives power return and helper restart')
    f.ok('resume');f.step(lid='closed',external=True,displayTopology='externalUnverified',nativeDisplayVerified=True)
    assert not f.ok('snapshot')['status']['ownsOverride']
    mark=len(f.logs());f.ok('stop');f.ok('resume')
    assert 'IOPMSleepSystem' not in f.logs()[mark:] and 'displaysleepnow' not in f.logs()[mark:]
    passed('native external-display handoff and ordinary stop never force sleep')
    assert f.step(external=False,nativeDisplayVerified=False)['status']['ownsOverride']
    passed('display disconnect restores eligible headless hold')
    mark=len(f.logs());r=f.step(displayTopology='unknown')
    assert r['status']['ownsOverride'] and r['status']['displayTopology']=='unknown'
    assert 'disablesleep 0' not in f.logs()[mark:] and 'displaysleepnow' not in f.logs()[mark:]
    passed('unknown topology preserves owned work without switching off external screens')
with Fixture(fullWake=False) as f:
    assert not f.ok('snapshot')['status']['ownsOverride']
    assert 'displaysleepnow' not in f.logs()
    passed('Dark Wake never enables override or screen commands')
for mode in ['battery','any']:
    with Fixture(control={'powerCondition':mode,'automaticHoldMinutes':15}) as f:
        r=f.step(power='battery')
        assert r['control']['powerCondition']=='ac' and not r['status'].get('batteryHoldUntil'),r
        assert not r['status']['ownsOverride'] and not r['status']['manualSession']['active'],r
        r=f.step(fullWake=False);assert not r['status'].get('batteryHoldUntil'),r
        f.step(fullWake=True)
        f.step(power='ac',powerClock=101);r=f.step(power='battery',powerClock=102)
        assert not r['status'].get('batteryHoldUntil') and not r['status']['ownsOverride'],r
        passed(mode+' migration and brief AC return never arm a battery automatic timer')
        f.step(power='ac',powerClock=200);f.step(powerClock=231);r=f.step(power='battery')
        assert not r['status'].get('batteryHoldUntil') and not r['status']['ownsOverride'],r
        passed(mode+' confirmed AC return still cannot grant battery automatic work')
        f.stop();f.start();assert not f.config()['status'].get('batteryHoldUntil')
        passed(mode+' helper restart never replays a retired timer')
with Fixture(control={'powerCondition':'battery'}) as f:
    f.step(powerClock=131);f.step(power='battery',fullWake=False);r=f.step(fullWake=True)
    assert r['status'].get('batteryHoldUntil') is None
    passed('Dark Wake consumes automatic power edge without deferred activation')
with Fixture(manualClock=100) as f:
    before=f.ok('snapshot');original=f.control.read_bytes()
    for _ in range(2):
        rejected=f.rpc('startHold',minutes=30)
        assert rejected['error']=='unsupportedVersion' and rejected['control']==before['control'],rejected
        assert f.control.read_bytes()==original and not rejected['status']['manualSession']['active'],rejected
    passed('retired reservation and repeated root Start are explicitly rejected without settings or work changes')
    f.step(power='battery',manualClock=101);f.ok('attachApp')
    r=f.ok('startManualSession',minutes=30);deadline=r['status']['manualSession']['until']
    assert 1799<deadline-r['status']['updatedAt']<=1801 and r['status']['manualSession']['holding'],r
    assert f.rpc('startManualSession',minutes=30)['error']=='holdAlreadyRunning'
    rejected=f.rpc('configure',control=r['control']|{'batteryHoldUntil':deadline+900},epoch=r['epoch'],revision=r['revision'])
    assert rejected['error']=='invalidRequest' and abs(rejected['status']['manualSession']['until']-deadline)<1,rejected
    passed('direct battery timer retains its deadline; duplicate start and retired root retiming cannot extend it')
    f.ok('endManualSession');f.step(power='ac',manualClock=102)
    assert f.rpc('startHold',minutes=30)['error']=='unsupportedVersion'
    r=f.step(power='battery',manualClock=103)
    assert not r['status']['manualSession']['active'] and not r['status'].get('batteryHoldUntil'),r
    passed('rejected reservation cannot activate on unplug')
    f.ok('startManualSession',minutes=15);f.stop();f.start();f.ok('attachApp')
    assert not f.ok('snapshot')['status']['manualSession']['active']
    passed('helper restart discards a temporary direct battery request')
    f.step(power='ac',manualClock=104)
    assert f.rpc('startHold',minutes=30)['error']=='unsupportedVersion'
    r=f.step(power='battery',fullWake=False,manualClock=105)
    assert not r['control'].get('pendingHoldMinutes') and not r['status']['manualSession']['active'],r
    r=f.step(fullWake=True,manualClock=106)
    assert not r['status'].get('batteryHoldUntil') and not r['status']['manualSession']['active'],r
    passed('Dark Wake never defers a rejected reservation into a later activation')
    f.ok('startManualSession',minutes=1);r=f.step(manualClock=166)
    assert not r['status']['manualSession']['active'] and r['protection'].get('blockReason') is None,r
    assert f.ok('startManualSession',minutes=15)['status']['manualSession']['holding']
    passed('normal direct battery expiry permits a new explicit bounded request')
for field,value,reason in [('thermal',2,'thermal'),('thermal',3,'thermal'),('battery',30,'battery'),('battery',None,'sensor')]:
    with Fixture(power='battery',lid='closed') as f:
        f.ok('attachApp');f.ok('startManualSession',minutes=15);r=f.step(**{field:value})
        assert r['protection']['blockReason']==reason,r
        assert not r['status']['ownsOverride'];assert f.rpc('resume')['error']=='safetyBlocked'
        f.step(temperature=30,thermal=0,battery=80);f.stop();f.start()
        assert f.ok('snapshot')['protection']['blockReason']==reason
        f.ok('resume');passed(reason+' latch survives cooling/restart and requires explicit resume')
with Fixture(power='battery') as f:
    f.ok('attachApp');f.ok('startManualSession',minutes=15);f.stop()
    p=f.folder/'protection-state.json';d=json.loads(p.read_text())
    d.update(blockReason='budget',batteryBudgetStart=0,budgetBoot='dry-run');p.write_text(json.dumps(d))
    f.start();f.ok('attachApp')
    assert f.rpc('startManualSession',minutes=15)['error']=='safetyBlocked'
    assert f.rpc('resume')['error']=='powerUnconfirmed'
    f.step(power='ac',powerClock=200);assert f.rpc('resume')['error']=='powerUnconfirmed'
    f.step(powerClock=231);r=f.ok('resume')
    assert not r['status']['manualSession']['active'] and not r['status'].get('batteryHoldUntil'),r
    passed('retained legacy budget protection needs confirmed AC and explicit resume without restoring an old request')
with Fixture(lid='closed',external=True,nativeDisplayVerified=True) as f:
    r=f.step(thermal=3);assert r['protection'].get('blockReason') is None
    assert 'IOPMSleepSystem' not in f.logs();passed('native AC thermal management is left to macOS')
with Fixture(control={'powerCondition':'battery'},lid='closed',external=True,nativeDisplayVerified=True) as f:
    r=f.step(thermal=3,temperature=None);assert r['protection'].get('blockReason') is None
    assert 'IOPMSleepSystem' not in f.logs();passed('battery-only condition excludes native AC heat/sensor intervention')
# New ownership and screen coordination regressions.
with Fixture(control={'enabled':False},sleepDisabled=True) as f:
    f.config();assert 'disablesleep 0' not in f.logs();assert 'IOPMSleepSystem' not in f.logs()
    assert f.rpc('resume')['error']=='powerConflict';passed('disabled Tether never clears foreign global override')
with Fixture(sleepDisabled=True) as f:
    assert f.ok('snapshot')['protection']['blockReason']=='powerConflict'
    assert 'disablesleep' not in f.logs();f.step(sleepDisabled=False);f.ok('resume')
    assert f.ok('snapshot')['status']['ownsOverride'];passed('pre-existing override suspends until resolved and explicitly resumed')
with Fixture() as f:
    mark=len(f.logs());r=f.step(externalOverride=False)
    assert r['protection']['blockReason']=='powerConflict';f.config();f.config()
    assert 'disablesleep 1' not in f.logs()[mark:];passed('external change never causes a power setting fight')
with Fixture(lid='closed',displaySleeping=True,displayClock=0) as f:
    mark=len(f.logs());r=f.step(displaySleeping=False,displayClock=1)
    assert not r['protection'].get('blockReason') and r['status']['ownsOverride']
    # Confirm the transient wake before the 10-second retry becomes due.
    f.step(displayClock=10);r=f.step(displaySleeping=True,displayClock=10.5)
    assert not r['protection'].get('blockReason') and r['status']['ownsOverride']
    assert f.logs()[mark:].count('pmset displaysleepnow')==1 and 'IOPMSleepSystem' not in f.logs()[mark:]
    passed('transient remote-style screen wake recovers without ending the hold')
with Fixture(lid='closed',displaySleeping=False) as f:
    f.config();assert f.logs().count('pmset displaysleepnow')==1
    f.step(displaySleeping=True);assert f.ok('snapshot')['protection'].get('blockReason') is None
    passed('single screen request accepts a later sleep observation')
with Fixture(lid='closed',displaySleeping=False,displayClock=0) as f:
    # Readiness is not a display write; begin this timeline explicitly at zero.
    f.config();assert f.logs().count('pmset displaysleepnow')==1
    for clock in [10,20,30]:r=f.step(displayClock=clock)
    assert r['protection'].get('blockReason') is None and r['status']['ownsOverride']
    assert r['status']['displayRecovery']['phase']=='stopped'
    assert f.logs().count('pmset displaysleepnow')==3
    mark=len(f.logs());f.config();f.config()
    assert 'displaysleepnow' not in f.logs()[mark:]
    passed('persistent screen wake stops bounded display retries while preserving work')
with Fixture(control={'enabled':False},commandFailure=True) as f:
    r=f.rpc('resume');assert r['error']=='pmsetFailed'
    r=f.ok('snapshot');assert not r['status']['sleepDisabled'] and not r['status']['ownsOverride']
    f.step(commandFailure=False);assert f.ok('snapshot')['status']['ownsOverride']
    passed('failed command stays visible and cannot claim ownership or applied state')
# Authenticated app lifecycle, without running or stopping any real GUI app.
with Fixture() as f:
    r=f.ok('attachApp',authenticatedPID=1);assert r['status']['appPID']==os.getpid()
    f.ok('startManualSession',minutes=30);r=f.ok('detachApp')
    assert r['control']['enabled'] and r['status']['appConnected'] is False
    assert not r['status']['ownsOverride'] and not r['control'].get('pendingHoldMinutes')
    f.config();f.stop();f.start();assert not f.ok('snapshot')['status']['ownsOverride']
    f.ok('attachApp');assert f.ok('snapshot')['status']['ownsOverride']
    passed('normal app detach preserves preference, clears work, survives restart, reconnect resumes')
    assert f.ok('snapshot')['status']['appPID']==os.getpid();passed('server peer PID overrides forged client identity')
with Fixture() as f:
    client='''import socket,json,uuid,sys,time
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.connect(sys.argv[1]);s.sendall((json.dumps(dict(version=2,id=str(uuid.uuid4()),action='attachApp'))+'\\n').encode());print(s.recv(65536).decode(),flush=True);time.sleep(60)
'''
    child=subprocess.Popen(['python3','-c',client,f.sock],stdout=subprocess.PIPE,text=True)
    try:
        assert json.loads(child.stdout.readline())['ok']
        assert f.rpc('attachApp')['error']=='notOwner'
        passed('second live controller cannot steal the app session')
        child.terminate();child.wait(timeout=5)
        for _ in range(60):
            r=f.ok('snapshot')
            if r['status'].get('appConnected') is False:break
            time.sleep(.1)
        assert r['status']['appConnected'] is False and not r['status']['ownsOverride']
        passed('controller process exit autonomously releases override')
    finally:
        if child.poll() is None:child.terminate();child.wait(timeout=5)
# Detach must release the runtime even when a settings backup cannot be written,
# and must return that persistence failure instead of masking it during evaluation.
with Fixture() as f:
    f.ok('attachApp')
    f.ok('attachApp');f.ok('startManualSession',minutes=15)
    backup=f.folder/'control.json.backup';backup.unlink(missing_ok=True);backup.mkdir()
    reply=f.rpc('detachApp')
    assert not reply['ok'] and reply['error']=='writeFailed',reply
    assert not reply['status']['ownsOverride'] and not reply['status']['appConnected']
    assert reply['control']['enabled'] and reply['protection']['blockReason']=='stateWriteFailed'
    backup.rmdir();f.ok('attachApp');f.ok('resume')
    passed('detach write failure is reported while owned power is released')

# Remote display classification must not add keep-awake/display-off commands or
# accidentally remove the existing opted-in AC heat protection.
with Fixture(external=True,displayTopology='virtualOnly',lid='closed') as f:
    r=f.ok('snapshot')
    assert r['status']['displayTopology']=='virtualOnly' and r['status']['ownsOverride']
    assert 'displaysleepnow' not in f.logs()
    passed('virtual-only AC setup preserves selected work without forcing screens')
    r=f.step(thermal=2)
    assert r['status']['heatGuard'] is False and not r['status']['ownsOverride'],r
    assert r['protection']['blockReason']=='thermal',r
    passed('virtual-only AC setup retains thermal protection without changing energy mode')
    r=f.step(thermal=3)
    assert r['protection'].get('blockReason')=='thermal' and not r['status']['ownsOverride']
    passed('virtual output cannot clear an existing thermal protection block')
with Fixture(external=True,displayTopology='externalWithVirtual',lid='closed') as f:
    assert f.ok('snapshot')['status']['ownsOverride']
    assert 'displaysleepnow' not in f.logs()
    passed('mixed external and virtual display setup avoids all-display sleep')

# IPC, persistence, removed commands and migration guarantees retained.
with Fixture() as f:
    mtime=f.status.stat().st_mtime_ns;rev=f.ok('snapshot')['revision'];started=time.monotonic()
    for _ in range(100):assert f.ok('snapshot')['revision']==rev
    assert f.status.stat().st_mtime_ns==mtime
    passed('100 snapshot queries are read-only (%.3fs)'%(time.monotonic()-started))
    for value in [0,-1,241]:assert f.rpc('startHold',minutes=value)['error']=='unsupportedVersion'
    f.ok('attachApp')
    for value in [0,-1]:
        rejected=f.rpc('startManualSession',minutes=value)
        assert rejected['error']=='invalidRequest',rejected
    passed('retired timer entry remains unsupported; invalid current manual bounds are rejected')
    before=f.ok('snapshot')
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        replies=list(pool.map(lambda v:f.rpc('configure',control=before['control']|v,epoch=before['epoch'],revision=before['revision']),[{'debugLog':True},{'automaticHoldMinutes':30}]))
    assert sorted(r['ok'] for r in replies)==[False,True]
    assert next(r for r in replies if not r['ok'])['error']=='staleRevision'
    assert f.ok('snapshot')['control']['limits']['batteryFloor']==30
    passed('concurrent settings CAS preserves user limits')
    assert f.rpc('snapshot',version=1)['error']=='unsupportedVersion';passed('unsupported protocol rejected')
    identity=str(uuid.uuid4());first=f.ok('stop',id=identity)
    saved_mtime=f.control.stat().st_mtime_ns
    repeated=f.ok('stop',id=identity)
    assert repeated['id']==first['id'] and repeated['revision']==first['revision'],repeated
    assert repeated['control']==first['control'] and f.control.stat().st_mtime_ns==saved_mtime,repeated
    assert f.rpc('resume',id=identity)['error']=='requestIDConflict'
    passed('idempotent retry and reused request ID protection')
    saved=f.control.read_bytes();backup=f.folder/'control.json.backup';backup.unlink(missing_ok=True);backup.mkdir();before=f.ok('snapshot')
    assert f.rpc('configure',control=before['control']|{'enabled':True},epoch=before['epoch'],revision=before['revision'])['error']=='writeFailed'
    assert f.control.read_bytes()==saved;backup.rmdir();passed('backup failure preserves original settings')
    env=dict(os.environ,TETHER_SERVICE_SOCKET=f.sock)
    result=subprocess.run([str(BIN/'TetherCLI'),'status','--json'],env=env,capture_output=True,text=True,timeout=10)
    assert result.returncode==0 and json.loads(result.stdout)['protection']['dryRun'];passed('CLI real service status')
    for command in ['session','rules','agent','mcp','profile','events']:
        result=subprocess.run([str(BIN/'TetherCLI'),command],env=env,capture_output=True,text=True,timeout=10);assert result.returncode==2
    result=subprocess.run([str(BIN/'TetherCLI'),'run'],env=env,capture_output=True,text=True,timeout=10)
    assert result.returncode==2
    passed('removed command families remain removed; current run requires explicit arguments')
    f.stop();(f.folder/'protection-state.json').write_text('corrupt');f.start()
    assert f.ok('snapshot')['protection']['blockReason']=='stateUnreadable';passed('corrupt protection file starts blocked')
with Fixture() as f:
    f.stop();(f.folder/'protection-state.json').unlink()
    (f.folder/'suite-state.json').write_text(json.dumps({'blockReason':'heat','sessions':[{'obsolete':True}]}))
    f.control.write_text(json.dumps({'schemaVersion':1,'enabled':True,'profile':'tasks','batteryHoldUntil':time.time()+3600}))
    f.start();r=f.ok('snapshot')
    assert not r['control']['enabled'] and r['protection']['blockReason']=='heat'
    assert r['status'].get('batteryHoldUntil') is None
    passed('legacy migration preserves protection and removes obsolete jobs')
# Diagnostics must preserve power preferences and newer recording choices.
with Fixture(control={'enabled':False}) as f:
    before=f.ok('snapshot');identity=str(uuid.uuid4())
    first=f.ok('markDiagnostic',id=identity)
    repeated=f.ok('markDiagnostic',id=identity)
    assert repeated['id']==first['id'] and repeated['revision']==first['revision'],repeated
    assert f.logs().count('diagnostic marker '+identity.upper())==1
    assert f.ok('snapshot')['control']==before['control']
    assert 'pmset ' not in f.logs()
    passed('diagnostic marker is idempotent and leaves disabled power policy unchanged')
    deadline=time.time()+.3
    f.config(debugLog=True,debugLogUntil=deadline)
    assert 'detailed logging on' in f.logs()
    time.sleep(.35);f.config()
    assert 'detailed logging off' in f.logs()
    assert not f.ok('snapshot')['control']['enabled']
    f.stop();f.start();assert 'detailed logging on' not in f.logs().split('detailed logging off')[-1]
    passed('detailed recording expires and stays expired after helper restart')
    r=f.config(debugLog=True,debugLogUntil=time.time()+999999)
    assert 14395<r['control']['debugLogUntil']-time.time()<=14401
    passed('service clamps new detailed recording deadlines to four hours')
    f.config(debugLog=True,debugLogUntil=None);f.stop();f.start()
    assert '(legacy manual stop)' in f.logs()
    passed('legacy explicit continuous recording survives restart')
    env=dict(os.environ,TETHER_SERVICE_SOCKET=f.sock)
    report=f.folder/'diagnostic.md'
    result=subprocess.run([str(BIN/'TetherCLI'),'diagnose','--hours','6','--out',str(report)],env=env,capture_output=True,text=True,timeout=10)
    assert result.returncode==0,result.stderr
    content=report.read_text()
    assert 'SIMULATED dry-run' in content and identity.upper() in content
    assert 'Not collected in dry-run.' in content and '(last 6 h)' in content
    passed('CLI report contains actual fixture markers and explicitly isolates simulated evidence')
    for option,value in [('--hours','nan'),('--hours','inf'),('--hours','-1'),('--hours','73'),('--record-minutes','0'),('--record-minutes','241')]:
        result=subprocess.run([str(BIN/'TetherCLI'),'diagnose',option,value],env=env,capture_output=True,text=True,timeout=10)
        assert result.returncode==2,(option,value,result)
    passed('CLI rejects nonfinite or out-of-range diagnostic durations')
    f.config(debugLog=False,debugLogUntil=None)
    cli=subprocess.Popen([str(BIN/'TetherCLI'),'diagnose','--record-minutes','1','--out',str(report)],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    try:
        for _ in range(100):
            if f.ok('snapshot')['control'].get('debugLogUntil'):break
            time.sleep(.03)
        assert f.ok('snapshot')['control']['debugLogUntil']>time.time()
        stdout,stderr=cli.communicate('\n',timeout=10)
        assert cli.returncode==0,(stdout,stderr)
        r=f.ok('snapshot')['control'];assert r.get('debugLog') is False and r.get('debugLogUntil') is None
        passed('CLI recording restores its previous detailed logging choice after export')
    finally:
        if cli.poll() is None:cli.terminate();cli.wait(timeout=5)
    cli=subprocess.Popen([str(BIN/'TetherCLI'),'diagnose','--record-minutes','1','--out',str(report)],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    try:
        for _ in range(100):
            if f.ok('snapshot')['control'].get('debugLogUntil'):break
            time.sleep(.03)
        newer=time.time()+3600;f.config(debugLog=True,debugLogUntil=newer)
        stdout,stderr=cli.communicate('\n',timeout=10)
        assert cli.returncode==0,(stdout,stderr)
        assert f.ok('snapshot')['control']['debugLogUntil']==newer
        passed('CLI export preserves a newer recording choice made by another client')
    finally:
        if cli.poll() is None:cli.terminate();cli.wait(timeout=5)
with Fixture(control={'enabled':False}) as f:
    f.stop()
    old=f.logs();inode=f.log.stat().st_ino
    f.log.write_text('padding\n'*260000+old)
    f.start()
    assert f.log.stat().st_ino==inode and f.log.stat().st_size<2_000_000
    assert (f.folder/'helper.log.1').exists()
    identity=str(uuid.uuid4());f.ok('markDiagnostic',id=identity)
    assert identity.upper() in f.logs()
    assert 'observed: power=' in (f.folder/'helper.log.1').read_text()
    passed('helper startup archives old logs and keeps writing through the same active inode')
# Legacy duration metadata stays readable; current requests use explicit manual policy.
with Fixture(control={'limits':{'maxHoldHours':1.5}},manualClock=100) as f:
    before=f.ok('snapshot');original=f.control.read_bytes()
    rejected=f.rpc('startHold',minutes=45)
    assert rejected['error']=='unsupportedVersion' and f.control.read_bytes()==original,rejected
    assert not rejected['control'].get('pendingHoldMinutes'),rejected
    f.ok('attachApp');r=f.ok('startManualSession',minutes=45)
    assert 2699<r['status']['manualSession']['until']-r['status']['updatedAt']<=2701,r
    f.ok('endManualSession')
    assert 'manual session started: 45m' in f.logs() and 'manual session ended by user' in f.logs()
    passed('legacy reservation is rejected; an explicit 45-minute AC request and cancellation remain logged')
    f.step(power='battery',manualClock=101)
    assert f.rpc('startManualSession',minutes=240)['error']=='safetyBlocked'
    r=f.ok('startManualSession',minutes=120)
    assert r['status']['manualSession']['batteryRemaining']==7200,r
    assert 7199<r['status']['manualSession']['until']-r['status']['updatedAt']<=7201,r
    passed('direct battery work rejects over-cap requests instead of clipping them and permits the explicit 120-minute ceiling')
    f.ok('endManualSession');r=f.ok('startManualSession',minutes=45)
    assert 2699<r['status']['manualSession']['until']-r['status']['updatedAt']<=2701,r
    passed('a new explicit 45-minute battery request has its own bounded deadline')
    for minutes in [0,-1,241]:
        assert f.rpc('startHold',minutes=minutes)['error']=='unsupportedVersion'
    f.ok('endManualSession')
    for minutes in [0,-1]:
        assert f.rpc('startManualSession',minutes=minutes)['error']=='invalidRequest'
    assert f.rpc('startManualSession',minutes=241)['error']=='safetyBlocked'
    passed('retired service timer is unsupported while current manual validates bounds and the battery ceiling')
    f.config(automaticHoldMinutes=45)
    f.stop();f.start()
    assert f.ok('snapshot')['control']['automaticHoldMinutes']==45
    assert not f.ok('snapshot')['status'].get('batteryHoldUntil')
    passed('saved legacy duration metadata survives restart without restoring an automatic battery timer')
    env=dict(os.environ,TETHER_SERVICE_SOCKET=f.sock)
    report=f.folder/'connection.md'
    result=subprocess.run([str(BIN/'TetherCLI'),'diagnose','--out',str(report)],env=env,capture_output=True,text=True,timeout=10)
    assert result.returncode==0 and 'authenticated service reply' in report.read_text()
    f.stop()
    assert f.status.exists()
    result=subprocess.run([str(BIN/'TetherCLI'),'diagnose','--out',str(report)],env=env,capture_output=True,text=True,timeout=10)
    assert result.returncode==0
    assert 'saved file only; live connection unverified' in report.read_text()
    assert '| helper installed / responding | no / no |' in report.read_text()
    passed('fresh saved status after helper exit does not masquerade as a live report connection')
print('TOTAL',COUNT,'scenarios passed',flush=True)
