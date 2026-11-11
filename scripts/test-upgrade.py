#!/usr/bin/env python3
"""Exercise the real installer transaction with an unprivileged, isolated launchctl/pmset.
The actual new helper runs --dry-run; no /Library file or live power setting is changed.
"""
import fcntl, hashlib, json, plistlib, os, shutil, signal, socket, stat, subprocess, tempfile, threading, time, uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
BIN=None
if not (os.environ.get('TETHER_TEST_HELPER') and os.environ.get('TETHER_TEST_RECOVERY')):
 BIN=Path(subprocess.check_output(['swift','build','--disable-sandbox','--show-bin-path'],cwd=ROOT,text=True).strip())
HELPER=Path(os.environ['TETHER_TEST_HELPER']) if os.environ.get('TETHER_TEST_HELPER') else BIN/'TetherHelper'
RECOVERY=Path(os.environ['TETHER_TEST_RECOVERY']) if os.environ.get('TETHER_TEST_RECOVERY') else BIN/'TetherRecoveryCLI'
PREVIOUS=Path(os.environ['TETHER_TEST_PREVIOUS_HELPER']) if os.environ.get('TETHER_TEST_PREVIOUS_HELPER') else None
PREVIOUS_BUILD=int(os.environ.get('TETHER_TEST_PREVIOUS_BUILD','49'))
CURRENT_COORDINATOR=10
CURRENT_SCHEMA=4
PREVIOUS_MANUAL_CLOCK=100
PREVIOUS_MANUAL_SECONDS=600
COORDINATOR_10_LEASE_SECONDS=15
COORDINATOR_10_BATTERY_SECONDS=3600
LOG_NAMES=['helper.log','helper.log.1','helper.log.2','helper.log.3']
LOG_SUCCESS_CASES=['logs-private-upgrade','logs-new-umask077']
LOG_UNSAFE_CASES=['logs-active-symlink','logs-active-hardlink','logs-active-fifo','logs-active-directory',
                  'logs-rotated-symlink','logs-rotated-acl','logs-directory-symlink','logs-directory-file',
                  'logs-directory-unsafe','logs-parent-unsafe']
LOG_CASES=LOG_SUCCESS_CASES+['logs-watchdog-rollback']+LOG_UNSAFE_CASES
UPGRADE_SUCCESS_CASES=['legacy-support-mode','upgrade-private-mode']
UPGRADE_UNSAFE_CASES=['upgrade-support-acl','upgrade-directory-acl','upgrade-inherited-acl',
                      'upgrade-directory-symlink','upgrade-directory-file','upgrade-directory-unsafe',
                      'upgrade-parent-symlink']
MOCK=r'''#!/usr/bin/env python3
import os,sys,hashlib,json,subprocess,signal,time
from pathlib import Path
root=Path(os.environ['TETHER_INSTALL_TEST_ROOT'])
support=root/'Library/Application Support/Tether'
tools=root/'Library/PrivilegedHelperTools'
pidfile=root/'helper.pid'
a=sys.argv[1:]
def record(event,**values):
 with (root/'process-events.jsonl').open('a') as f:f.write(json.dumps(dict(event=event,time=time.time(),**values))+'\n')
def alive(pid):
 try:os.kill(pid,0)
 except ProcessLookupError:return False
 result=subprocess.run(['/bin/ps','-o','stat=','-p',str(pid)],text=True,capture_output=True)
 return result.returncode==0 and bool(result.stdout.strip()) and not result.stdout.strip().startswith('Z')
def identity(pid):
 return subprocess.check_output(['/bin/ps','-ww','-o','lstart=','-o','command=','-p',str(pid)],text=True).strip()
def stop():
 (root/'legacy-helper.loaded').unlink(missing_ok=True)
 if pidfile.exists():
  pid=int(pidfile.read_text())
  if alive(pid) and identity(pid)!=(root/'helper.identity').read_text():
   record('stale-pid',pid=pid);pidfile.unlink();return True
  try:
   os.kill(pid,signal.SIGTERM)
   for _ in range(50):
    if not alive(pid):break
    time.sleep(.02)
  except ProcessLookupError:pass
  stopped=not alive(pid)
  record('stop' if stopped else 'stop-deferred',pid=pid,controlSHA=hashlib.sha256((support/'control.json').read_bytes()).hexdigest())
  if stopped:pidfile.unlink(missing_ok=True)
  return stopped
 return True
if Path(sys.argv[0]).name=='ioreg':
 if 'IOPMrootDomain' in a:
  print('    "SleepDisabled" = '+'Yes' if (root/'no-effect').exists() else '    "SleepDisabled" = No')
  sys.exit(0)
 case=os.environ.get('TETHER_TEST_LID','open')
 if (root/'change-target-after-lid').exists():
  (root/'install-target-facts.json').write_text(json.dumps(dict(supportedPlatform=True,internalBattery=False,lid=False)))
 if case=='closes-after-validation':
  counter=root/'lid-reads'
  n=int(counter.read_text()) if counter.exists() else 0
  counter.write_text(str(n+1));case='open' if n==0 else 'closed'
 if case=='open': print('    "AppleClamshellState" = No')
 if case=='closed': print('    "AppleClamshellState" = Yes')
 sys.exit(0)
if Path(sys.argv[0]).name=='pmset':
 with (root/'commands.log').open('a') as f:f.write('pmset '+' '.join(a)+'\n')
 sys.exit(0)
with (root/'launchctl.log').open('a') as f:f.write(' '.join(a)+'\n')
label='helper' if any('local.tether.helper' in x for x in a) else 'watchdog'
if a[0]=='bootout':
 if label=='helper':stop()
 else:(root/'watchdog.loaded').unlink(missing_ok=True)
 sys.exit(0)
if a[0]=='print':
 if label=='watchdog':sys.exit(0 if (root/'watchdog.loaded').exists() else 1)
 if (root/'legacy-helper.loaded').exists():sys.exit(0)
 if not pidfile.exists():sys.exit(1)
 if alive(int(pidfile.read_text())):sys.exit(0)
 pidfile.unlink();sys.exit(1)
if a[0]=='enable':sys.exit(0)
if a[0]=='bootstrap':
 if not Path(a[2]).is_file():
  record('bootstrap-missing-registration',service=label);sys.exit(1)
 binary=tools/'local.tether.helper'
 if binary.read_bytes().startswith(b'legacy-'):
  (root/('legacy-helper.loaded' if label=='helper' else 'watchdog.loaded')).touch()
  sys.exit(0)
 # Inject failures only into the candidate. The real previous helper must be
 # allowed to bootstrap during rollback, rather than silently failing too.
 if (root/'failure').exists() and (root/'failure').read_text()==label and binary.read_bytes()==(root/'resources/tether-helper').read_bytes():
  if (root/'lock-on-failure').exists():
   (root/'rollback-lock-requested').touch()
   until=time.monotonic()+3
   while not (root/'rollback-lock-held').exists() and time.monotonic()<until:time.sleep(.01)
   if not (root/'rollback-lock-held').exists():sys.exit(2)
   (root/'failure').unlink()
  record('bootstrap-failed',service=label);sys.exit(1)
 if label=='helper':
  if not stop():sys.exit(1)
  log=(root/'helper.log').open('a')
  p=subprocess.Popen([str(binary),'--dry-run','--control',str(support/'control.json'),'--status',str(support/'status.json'),'--fake',str(root/'fake.json')],stdout=log,stderr=log,start_new_session=True)
  pidfile.write_text(str(p.pid))
  process_identity=identity(p.pid);(root/'helper.identity').write_text(process_identity)
  record('spawn',pid=p.pid,identity=process_identity,binarySHA=hashlib.sha256(binary.read_bytes()).hexdigest())
 else:(root/'watchdog.loaded').touch()
 sys.exit(0)
sys.exit(2)
'''

def process_alive(pid):
 try:os.kill(pid,0)
 except ProcessLookupError:return False
 result=subprocess.run(['/bin/ps','-o','stat=','-p',str(pid)],text=True,capture_output=True)
 return result.returncode==0 and bool(result.stdout.strip()) and not result.stdout.strip().startswith('Z')

def process_identity(pid):
 return subprocess.check_output(['/bin/ps','-ww','-o','lstart=','-o','command=','-p',str(pid)],text=True).strip()

def run_metadata_case(case):
 info=plistlib.loads((ROOT/'Resources/Info.plist').read_bytes())
 arguments=['--version'] + (['--dry-run'] if case=='metadata-version-flags' else [])
 result=subprocess.run([str(HELPER),*arguments],text=True,capture_output=True,timeout=3)
 expected=64 if case=='metadata-version-flags' else 0
 assert result.returncode==expected,(case,result.returncode,result.stdout,result.stderr)
 if expected==0:
  assert result.stdout.strip()==f"TetherHelper {info['CFBundleShortVersionString']} build={info['CFBundleVersion']} coordinator={CURRENT_COORDINATOR}"
 else:assert not result.stdout and not result.stderr,(case,'metadata query started work',result.stdout,result.stderr)
 print('PASS helper',case,flush=True)

def run_readiness_case(case):
 # Exercise the installed helper's real readiness entry point against a private
 # peer. A matching marketing/build version alone cannot approve an old contract.
 info=plistlib.loads((ROOT/'Resources/Info.plist').read_bytes())
 errors=[]
 with tempfile.TemporaryDirectory(prefix='tether-ready-test-',dir='/tmp') as temp:
  path=str(Path(temp)/'service.sock')
  with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as listener:
   listener.bind(path);listener.listen(1);listener.settimeout(4)
   def respond():
    try:
     with listener.accept()[0] as peer:
      peer.settimeout(4);data=b''
      while not data.endswith(b'\n'):
       part=peer.recv(8192);assert part,'missing readiness request';data+=part
      request=json.loads(data);assert request['action']=='snapshot'
      status=dict(updatedAt=time.time(),version=info['CFBundleShortVersionString'],build=int(info['CFBundleVersion']),
                  enabled=False,power='ac',lidClosed=False,sleepDisabled=False,workSessionCoordinatorVersion=CURRENT_COORDINATOR)
      protection=dict(protocolVersion=2,dryRun=True)
      control=dict(schemaVersion=CURRENT_SCHEMA,enabled=False)
      if case=='readiness-old-contract':status['workSessionCoordinatorVersion']=3
      if case=='readiness-previous-contract':status['workSessionCoordinatorVersion']=5
      if case=='readiness-before-p0-contract':status['workSessionCoordinatorVersion']=8
      if case=='readiness-before-display-contract':status['workSessionCoordinatorVersion']=9
      if case=='readiness-legacy-contract':status['workSessionCoordinatorVersion']=2
      if case=='readiness-missing-contract':status.pop('workSessionCoordinatorVersion')
      if case=='readiness-future-contract':status['workSessionCoordinatorVersion']=CURRENT_COORDINATOR+1
      if case=='readiness-future-state':status['updatedAt']+=60
      if case=='readiness-stale-state':status['updatedAt']-=30
      if case=='readiness-wrong-build':status['build']-=1
      if case=='readiness-migration-failed':protection['blockReason']='migrationFailed'
      if case=='readiness-future-schema':control['schemaVersion']=99
      if case=='readiness-previous-schema':control['schemaVersion']=CURRENT_SCHEMA-1
      if case=='readiness-sleep-events-unavailable':status['systemPowerObservationAvailable']=False
      reply=dict(version=2,id=request['id'],ok=True,epoch='ready-fixture',revision=1,
                 control=control,status=status,protection=protection)
      peer.sendall(json.dumps(reply).encode()+b'\n')
    except Exception as error:errors.append(error)
   worker=threading.Thread(target=respond);worker.start()
   try:result=subprocess.run([str(HELPER),'--check-service','--socket',path],text=True,capture_output=True,timeout=8)
   finally:
    worker.join(timeout=5)
    assert not worker.is_alive(),'readiness fixture did not stop'
   assert not errors,errors
   expected=case=='readiness-current'
   assert (result.returncode==0)==expected,(case,'incorrect helper readiness',result.returncode,result.stdout,result.stderr)
   assert ('helper-ready ' in result.stdout)==expected,(case,'incorrect readiness announcement',result.stdout)
  print('PASS installer',case,flush=True)

def rpc(support,action,**values):
 request=dict(version=2,id=str(uuid.uuid4()),action=action,**values)
 with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as connection:
  connection.settimeout(2);connection.connect(str(support/'service.sock'))
  connection.sendall(json.dumps(request).encode()+b'\n');data=b''
  while not data.endswith(b'\n'):
   part=connection.recv(8192);assert part,'helper closed the response';data+=part
 reply=json.loads(data);assert reply['id'].lower()==request['id'].lower() and reply['ok'],reply
 return reply

def wait_snapshot(support,build,old_epoch=None):
 for _ in range(100):
  try:
   reply=rpc(support,'snapshot')
   if reply.get('status',{}).get('build')==build and reply['epoch']!=old_epoch:return reply
  except (OSError,AssertionError):pass
  time.sleep(.03)
 raise AssertionError(f'fresh build {build} IPC readiness timeout')

def attach_previous_v3(support,old,holding):
 # Build 51+ is lease-only. Saved enabled settings cannot authorize legacy
 # attachApp/startHold; prepare and attach the same finite v3 decision as its GUI.
 clock=PREVIOUS_MANUAL_CLOCK
 control=old['control']
 lease=dict(version=1,executionVersion=3,sessionID=str(uuid.uuid4()),sequence=1,power=old['status']['power'],
  reasons=[],configuration=dict(enabled=control['enabled'],automaticEnabled=True,
   condition=control['powerCondition'],automaticMinutes=control['automaticHoldMinutes'],limits=control['limits']))
 prepared=rpc(support,'prepareWorkSession',workSession=lease,epoch=old['epoch'],revision=old['revision'])
 if holding:
  assert control['enabled'] and lease['power']=='battery',old
  request_id=str(uuid.uuid4())
  lease.update(expiry=clock+90,reasons=['manual'],manualDeadline=clock+PREVIOUS_MANUAL_SECONDS,
   manualStartedOnBattery=True,lidPermit=dict(powerScopes=['ac','battery'],batteryPermitID=request_id,
    batteryDuration=PREVIOUS_MANUAL_SECONDS,batteryDeadline=clock+PREVIOUS_MANUAL_SECONDS,
    disconnectAction='followOS',protectiveAction='sleepIfClosed'))
  if old['status'].get('workSessionCoordinatorVersion')==10:
   # Coordinator 10 has a 15-second renewable lease and tracks the request's
   # own timer separately from its first, finite battery allowance.
   expiry=prepared['workSessionPreparation']['expiresAt']
   assert expiry==clock+COORDINATOR_10_LEASE_SECONDS,prepared
   battery_cap=clock+COORDINATOR_10_BATTERY_SECONDS
   lease['configuration'].update(disconnectPolicy='endAll',batteryTimeLimit='oneHour',manualPowerCondition='any')
   lease.update(expiry=expiry,manualRequestID=request_id,manualBatteryMaximumDeadline=battery_cap,
    manualBatteryTimeLimit='oneHour',manualPowerCondition='any')
   lease['lidPermit'].update(powerScopes=['battery'],batteryDuration=COORDINATOR_10_BATTERY_SECONDS,
    batteryDeadline=battery_cap,batteryMaximumDeadline=battery_cap,batteryTimeLimit='oneHour')
 return rpc(support,'attachWorkSession',workSession=lease,epoch=prepared['epoch'],revision=prepared['revision'])

def cleanup_processes(root,owned_pids):
 events=root/'process-events.jsonl'
 if events.exists():owned_pids.update({e['pid']:e['identity'] for e in map(json.loads,events.read_text().splitlines()) if e['event']=='spawn'})
 for pid,identity in owned_pids.items():
  if not process_alive(pid):continue
  assert process_identity(pid)==identity and str(root/'Library/PrivilegedHelperTools/local.tether.helper') in identity,'fixture PID identity changed; no signal sent'
  # A stopped fixture must resume so its actual SIGTERM handler can finish.
  os.kill(pid,signal.SIGCONT);os.kill(pid,signal.SIGTERM)
  deadline=time.monotonic()+5
  while process_alive(pid) and time.monotonic()<deadline:time.sleep(.03)
  if process_alive(pid):os.kill(pid,signal.SIGKILL)
  deadline=time.monotonic()+2
  while process_alive(pid) and time.monotonic()<deadline:time.sleep(.03)
  assert not process_alive(pid),f'fixture process {pid} did not exit'

def log_path_state(path):
 try:entry=path.lstat()
 except (FileNotFoundError,NotADirectoryError):return None
 state=dict(device=entry.st_dev,inode=entry.st_ino,owner=entry.st_uid,group=entry.st_gid,
            mode=stat.S_IMODE(entry.st_mode),kind=stat.S_IFMT(entry.st_mode),links=entry.st_nlink)
 state['acl']=subprocess.check_output(['/bin/ls','-lde',str(path)],text=True).splitlines()[1:]
 if stat.S_ISREG(entry.st_mode):state['bytes']=path.read_bytes()
 elif stat.S_ISLNK(entry.st_mode):state['target']=os.readlink(path)
 return state

def prepare_log_fixture(root,case):
 parent=root/'Library/Logs'
 logs=parent/'Tether'
 if case=='logs-new-umask077':return logs,{},None
 parent.mkdir(mode=0o755);parent.chmod(0o755)
 # The unprivileged fixture uses its own UID in place of the production root
 # owner. Restrictive legacy modes match the installed root-owned log layout.
 logs.mkdir(mode=0o700);logs.chmod(0o700)
 for index,name in enumerate(LOG_NAMES):
  path=logs/name;path.write_bytes(b'old helper log\x00'+str(index).encode()+b'\n');path.chmod(0o600)
 paths=[parent,logs,*[logs/name for name in LOG_NAMES]]
 if case in ['logs-active-symlink','logs-rotated-symlink']:
  victim=root/'log-target';victim.write_bytes(b'do not change this target\n');victim.chmod(0o600);paths.append(victim)
  target=logs/('helper.log.3' if case=='logs-rotated-symlink' else 'helper.log')
  target.unlink();target.symlink_to(victim)
 elif case=='logs-active-hardlink':
  alias=root/'log-alias';os.link(logs/'helper.log',alias);paths.append(alias)
 elif case=='logs-active-fifo':
  (logs/'helper.log').unlink();os.mkfifo(logs/'helper.log',0o600)
 elif case=='logs-active-directory':
  (logs/'helper.log').unlink();(logs/'helper.log').mkdir(mode=0o700)
 elif case=='logs-rotated-acl':
  subprocess.run(['/bin/chmod','+a','everyone allow write',str(logs/'helper.log.3')],check=True)
  assert log_path_state(logs/'helper.log.3')['acl'],'missing unsafe ACL fixture'
 elif case in ['logs-directory-symlink','logs-directory-file']:
  original=root/'logs-original';logs.rename(original)
  paths += [original,*[original/name for name in LOG_NAMES]]
  if case=='logs-directory-symlink':logs.symlink_to(original,target_is_directory=True)
  else:logs.write_bytes(b'not a log directory\n');logs.chmod(0o600)
 elif case=='logs-directory-unsafe':logs.chmod(0o777)
 elif case=='logs-parent-unsafe':parent.chmod(0o777)
 before={path:log_path_state(path) for path in paths}
 active=(logs/'helper.log').open('rb') if case in ['logs-private-upgrade','logs-watchdog-rollback'] else None
 return logs,before,active

def verify_log_fixture(case,root,logs,before,active,result):
 if case in LOG_UNSAFE_CASES:
  assert result.returncode!=0 and 'Unsafe helper log paths. Nothing was replaced.' in result.stderr,(case,result.stdout,result.stderr)
  assert {path:log_path_state(path) for path in before}==before,(case,'unsafe log paths were changed')
  assert not (root/'launchctl.log').exists(),(case,'touched a service before log validation')
  assert not (root/'process-events.jsonl').exists(),(case,'stopped or launched a helper before log validation')
  assert not (root/'commands.log').exists(),(case,'issued a power command')
  assert not (root/'Library/Application Support/Tether/upgrades').exists(),(case,'created an upgrade before log validation')
  return
 assert stat.S_IMODE(logs.stat().st_mode)==0o755 and logs.stat().st_uid==os.geteuid(),(case,'unreadable log directory')
 assert stat.S_IMODE(logs.parent.stat().st_mode)==0o755 and logs.parent.stat().st_uid==os.geteuid(),(case,'unsafe log parent')
 names=['helper.log'] if case=='logs-new-umask077' else LOG_NAMES
 for name in names:
  path=logs/name;after=log_path_state(path)
  assert after['kind']==stat.S_IFREG and after['mode']==0o644 and after['owner']==os.geteuid() and after['links']==1,(case,name,after)
  if before:
   previous=before[path]
   assert after['bytes']==previous['bytes'] and after['inode']==previous['inode'] and after['device']==previous['device'],(case,name,'log bytes or inode were replaced')
 if active is not None:
  assert active.fileno()>=0 and os.fstat(active.fileno()).st_ino==(logs/'helper.log').stat().st_ino,(case,'open active log no longer points at installed path')
  assert active.read()==before[logs/'helper.log']['bytes'],(case,'open active log bytes were changed')
 if case=='logs-new-umask077':
  assert (logs/'helper.log').read_bytes()==b'',(case,'new log was not empty')
  assert not any((logs/name).exists() for name in LOG_NAMES[1:]),(case,'created unused rotated logs')
 if case=='logs-watchdog-rollback':
  assert 'Helper upgrade failed; restoring previous helper and settings.' in result.stderr
  assert 'Recovery backup:' in result.stderr

def verify_previous(case,root,support,tools,daemons,result,old,old_pid,started):
 assert PREVIOUS is not None
 previous_sha=hashlib.sha256(PREVIOUS.read_bytes()).hexdigest()
 events=list(map(json.loads,(root/'process-events.jsonl').read_text().splitlines()))
 backups=list((support/'upgrades').glob('helper-*'));assert len(backups)==1
 backup=backups[0]
 if case=='actual-previous-paused-stop':
  assert result.returncode!=0,(case,'installer replaced a still-running previous helper',result.stdout,result.stderr)
  assert process_alive(old_pid) and (tools/'local.tether.helper').read_bytes()==PREVIOUS.read_bytes()
  assert not list((backup/'settings').iterdir()),'settings backed up before actual old helper exit'
  assert 'Old power service did not stop.' in result.stderr and 'Recovery deferred:' in result.stderr
  assert not any(e['event']=='spawn' and e['pid']!=old_pid for e in events),'replacement launched while old process was live'
  return
 assert not process_alive(old_pid),'old helper is still running'
 stopped=next(e for e in events if e['event']=='stop' and e['pid']==old_pid)
 assert hashlib.sha256((backup/'settings/control.json').read_bytes()).hexdigest()==stopped['controlSHA'],'settings backup was not the final stopped helper state'
 failed=case.endswith('watchdog-failure') or case.endswith('bootstrap-failure')
 assert (result.returncode!=0)==failed,(case,result.stdout,result.stderr)
 missing_daemon=case.startswith('actual-previous-missing-daemon-')
 if missing_daemon:
  assert not (backup/'daemons/local.tether.helper.plist').exists(),'missing registration was invented in the backup'
  assert (backup/'settings/control.json').exists() and not process_alive(old_pid)
  assert 'disablesleep 0' in (root/'helper.log').read_text(),'active old helper never issued its own dry-run release'
  if failed:
   assert not (support/'power-ownership.json').exists() or json.loads((support/'power-ownership.json').read_text())['owned'] is False,('own power lease was replayed', (support/'helper-state.json').read_text(), (root/'helper.log').read_text())
   assert not (daemons/'local.tether.helper.plist').exists(),'rollback invented an old startup registration'
   assert (tools/'local.tether.helper').read_bytes()==PREVIOUS.read_bytes()
   for name in ['local.tether.watchdog','local.tether.recovery-lock','local.tether.power-recovery']:
    assert (tools/name).read_bytes()==(backup/'tools'/name).read_bytes(),('rollback changed original component',name)
   assert (daemons/'local.tether.watchdog.plist').read_bytes()==(backup/'daemons/local.tether.watchdog.plist').read_bytes()
   assert (root/'watchdog.loaded').exists(),'original watchdog was not restored'
   assert not (root/'helper.pid').exists() and not (support/'service.sock').exists(),'incomplete rollback still advertises live helper service'
   assert (support/'control.json').read_bytes()==(backup/'settings/control.json').read_bytes()
   # A preserved old peer/deadline in a stopped journal is not live authority.
   # Rollback must retain the original record, without copying candidate grants
   # back or inventing the missing registration to execute the stale record.
   assert (support/'helper-state.json').read_bytes()==(backup/'settings/helper-state.json').read_bytes(),'rollback copied candidate runtime authority into the old journal'
   restored_state=json.loads((support/'helper-state.json').read_text())
   if PREVIOUS_BUILD>=51:
    # SIGTERM restores the owned flag but retains the old enforcement record.
    # With no registration/process/socket this is recovery evidence; a future
    # v3 startup clears it before accepting any freshly prepared work.
    assert restored_state.get('lidExecutionVersion')==3
    assert restored_state.get('workSessionLease')==old['status'].get('workSession'),'rollback changed the original stopped v3 record'
   else:assert not restored_state.get('workSessionLease'),'rollback manufactured a work-session grant'
   restored_control=json.loads((support/'control.json').read_text())
   assert not restored_control.get('pendingHoldMinutes')
   assert restored_control.get('batteryHoldUntil')==old['control'].get('batteryHoldUntil'),'rollback changed the original stopped timer record'
   spawns=[e for e in events if e['event']=='spawn' and e['pid']!=old_pid]
   assert all(e['binarySHA']==hashlib.sha256(HELPER.read_bytes()).hexdigest() and not process_alive(e['pid']) for e in spawns),'rollback revived old helper or retained candidate work'
   assert bool(spawns)==case.endswith('watchdog-failure'),'unexpected candidate process phase'
   try:rpc(support,'snapshot')
   except OSError:pass
   else:raise AssertionError('saved old status was reported as a live rollback connection')
   assert 'Helper update verified.' not in result.stdout and 'helper-ready ' not in result.stdout,'incomplete registration was reported as ready'
   assert 'Helper upgrade failed;' in result.stderr and 'Recovery backup:' in result.stderr
   print(f'  verified actual build {PREVIOUS_BUILD} repair rollback; original files retained, helper registration still missing, no live helper/grant, candidate stopped',flush=True)
   return
  assert (daemons/'local.tether.helper.plist').read_bytes()==(ROOT/'Resources/local.tether.helper.plist').read_bytes(),'successful repair did not install startup registration'
 expected_build=PREVIOUS_BUILD if failed else int(plistlib.loads((ROOT/'Resources/Info.plist').read_bytes())['CFBundleVersion'])
 after=wait_snapshot(support,expected_build,old['epoch'])
 assert after['status']['updatedAt']>=started and after['protection']['dryRun'] is True
 expected_coordinator=old['status'].get('workSessionCoordinatorVersion') if failed else CURRENT_COORDINATOR
 assert after['status'].get('workSessionCoordinatorVersion')==expected_coordinator,'helper coordinator contract was not installed/restored'
 assert after['control']['enabled']==old['control']['enabled'] and after['control']['limits']==old['control']['limits']
 assert after['control']['powerCondition']==old['control']['powerCondition'] and after['control']['debugLog'] is True
 assert after['control']['automaticHoldMinutes']==old['control']['automaticHoldMinutes']
 if missing_daemon:
  # GUI50 persists a kernel-authenticated owner; GUI49 only saves an app PID.
  # A PID alone must not become authority after the repair. Both preserve the
  # saved AC choice. GUI50 retains its legacy hold with a live authenticated
  # owner, while v3 restarts require a fresh grant even with the same owner.
  previous_owner=json.loads((backup/'settings/helper-state.json').read_text()).get('guiOwner')
  previous_v3=PREVIOUS_BUILD>=51
  if previous_owner is not None:
   assert old['status'].get('guiSessionAuthority')=='confirmed',('unconfirmed previous owner',old['status'])
   assert after['status']['guiSessionAuthority']=='confirmed' and after['status'].get('appPID')==os.getpid(),(case,'GUI continuity',old['status'],after['status'])
   assert after['status']['appConnected']
   if previous_v3:
    assert not after['status']['ownsOverride'] and not after['status']['sleepDisabled'],(case,'v3 restart replayed a grant',after)
   else:assert after['status']['ownsOverride'] and after['status']['sleepDisabled']
  else:
   assert old['status'].get('guiSessionAuthority') is None,('previous authenticated owner was not persisted',old['status'])
   assert after['status']['guiSessionAuthority']=='unavailable' and not after['status']['appConnected'],(case,'PID adopted as GUI authority',after)
   assert not after['status']['ownsOverride'] and not after['status']['sleepDisabled'],(case,'unverified PID acquired power',after)
  assert after['workSessionBridge']['coordinated']==previous_v3
  assert not after['status'].get('batteryHoldUntil') and not after['control'].get('pendingHoldMinutes')
  assert not after['status'].get('manualSession',{}).get('active')
  if previous_v3:
   assert not json.loads((support/'helper-state.json').read_text()).get('workSessionLease'),'v3 restart retained live work'
  else:assert json.loads((support/'helper-state.json').read_text())['consumedHold']==after['control']['batteryHoldUntil']
  empty=dict(version=1,executionVersion=3,sessionID=str(uuid.uuid4()),sequence=1,power='ac',reasons=[],
             configuration=dict(enabled=after['control']['enabled'],automaticEnabled=True,
              condition=after['control']['powerCondition'],automaticMinutes=after['control']['automaticHoldMinutes'],limits=after['control']['limits']))
  prepared=rpc(support,'prepareWorkSession',workSession=empty,epoch=after['epoch'],revision=after['revision'])
  after=rpc(support,'attachWorkSession',workSession=empty,epoch=prepared['epoch'],revision=prepared['revision'])
  assert after['workSessionBridge']['coordinated'] and after['control']['enabled']==old['control']['enabled']
  saved=json.loads((support/'helper-state.json').read_text())
  assert saved['lidExecutionVersion']==3 and saved['workSessionLease']['reasons']==[] and not saved['workSessionLease'].get('lidPermit')
  continuity=('v3 restart retained authenticated owner without replaying work' if previous_v3 else 'authenticated live owner retained AC selection') if previous_owner is not None else 'PID-only previous state released power until fresh authentication'
  print(f'  verified build {PREVIOUS_BUILD} {continuity}; explicit authenticated empty v3 prepare/attach has no own override or lid permit',flush=True)
 assert not after['status']['ownsOverride'] and not after['status']['sleepDisabled'],(case,'restart acquired power without a new app grant',after,(root/'helper.log').read_text())
 assert not after['status'].get('workSession',{}).get('reasons'),'restart replayed temporary work'
 assert not after['status'].get('batteryHoldUntil') and not after['control'].get('pendingHoldMinutes')
 if after['control'].get('batteryHoldUntil'):
  assert json.loads((support/'helper-state.json').read_text())['consumedHold']==after['control']['batteryHoldUntil'],'retained timer value was not marked consumed'
 assert not after['status'].get('manualSession',{}).get('active')
 ownership=support/'power-ownership.json'
 assert not ownership.exists() or json.loads(ownership.read_text())['owned'] is False,'an ended ownership lease was replayed'
 spawns=[e for e in events if e['event']=='spawn' and e['pid']!=old_pid]
 assert spawns and spawns[-1]['binarySHA']==(previous_sha if failed else hashlib.sha256(HELPER.read_bytes()).hexdigest())
 assert int((root/'helper.pid').read_text())==spawns[-1]['pid'] and process_alive(spawns[-1]['pid'])
 assert all(not process_alive(e['pid']) for e in spawns[:-1]),'failed candidate is still running after rollback'
 assert (root/'watchdog.loaded').exists(),'watchdog registration was not restored'
 assert stopped['time']<=spawns[0]['time'],'replacement started before previous helper stopped'
 if failed:
  assert (tools/'local.tether.helper').read_bytes()==PREVIOUS.read_bytes()
  assert (tools/'local.tether.watchdog').read_text()=='legacy-local.tether.watchdog'
  for name in ['local.tether.helper','local.tether.watchdog']:
   assert (daemons/(name+'.plist')).read_text()=='legacy-plist-'+name
  assert 'Recovery backup:' in result.stderr
 else:assert (tools/'local.tether.helper').read_bytes()==HELPER.read_bytes()
 print(f'  verified actual build {PREVIOUS_BUILD} -> {expected_build}; coordinator {expected_coordinator}; old PID exited; new epoch; timer not replayed',flush=True)

def run_case(case):
 previous_case=case.startswith('actual-previous-')
 missing_daemon=case.startswith('actual-previous-missing-daemon-')
 owned_pids={}
 with tempfile.TemporaryDirectory(prefix='tether-install-test-',dir='/tmp') as temp:
  root=Path(temp);support=root/'Library/Application Support/Tether';support.mkdir(parents=True)
  lock=support.parent/'.tether-power-recovery.lock';lock.touch(mode=0o600);lock_inode=lock.stat().st_ino
  holder=lock.open('r+')
  if case in ['lock-busy','lock-busy-loaded-services']:fcntl.flock(holder,fcntl.LOCK_EX|fcntl.LOCK_NB)
  if case=='lock-busy-loaded-services':
   (root/'legacy-helper.loaded').touch();(root/'watchdog.loaded').touch()
  if case=='unsafe-lock':lock.chmod(0o666)
  if case in ['owned-recovery','no-effect','owned-watchdog-failure','lock-busy-loaded-services']:
   boot=subprocess.check_output(['/usr/sbin/sysctl','-n','kern.bootsessionuuid'],text=True).strip()
   (support/'power-ownership.json').write_text(json.dumps({'owned':True,'boot':boot}))
  ownership_before=(support/'power-ownership.json').read_bytes() if case=='lock-busy-loaded-services' else None
  if case=='no-effect':(root/'no-effect').touch()
  tools=root/'Library/PrivilegedHelperTools';tools.mkdir(parents=True)
  daemons=root/'Library/LaunchDaemons';daemons.mkdir(parents=True)
  logs=None;log_before={};active_log=None
  if case in LOG_CASES:logs,log_before,active_log=prepare_log_fixture(root,case)
  for name in ['local.tether.helper','local.tether.watchdog']:
   (tools/name).write_text('legacy-'+name);(daemons/(name+'.plist')).write_text('legacy-plist-'+name)
  if previous_case:
   assert PREVIOUS and PREVIOUS.is_file(),'TETHER_TEST_PREVIOUS_HELPER is required'
   shutil.copy2(PREVIOUS,tools/'local.tether.helper')
  if missing_daemon:
   for source,target in [('tether-watchdog.sh','local.tether.watchdog'),('tether-recovery-lock.sh','local.tether.recovery-lock')]:
    shutil.copy2(ROOT/'Resources'/source,tools/target);(tools/target).chmod(0o755)
   shutil.copy2(RECOVERY,tools/'local.tether.power-recovery')
   shutil.copy2(ROOT/'Resources/local.tether.watchdog.plist',daemons/'local.tether.watchdog.plist')
  raw=b'{ "enabled": false, "limits": {"batteryFloor": 40,"maxHoldHours":1}, "holdLowPower": false, "debugLog":true, "batteryHoldUntil":9999999999 }\n'
  if case.startswith('schema-'):
   schema=int(case.removeprefix('schema-'))
   raw=json.dumps(dict(schemaVersion=schema,enabled=schema<CURRENT_SCHEMA,
    powerCondition='battery' if schema<CURRENT_SCHEMA else 'ac',automaticHoldMinutes=30,
    limits=dict(batteryFloor=40,maxHoldHours=1),debugLog=True),ensure_ascii=False).encode()
  if previous_case:
   raw=json.dumps(dict(schemaVersion=3,enabled=missing_daemon or case in ['actual-previous-active-success','actual-previous-detach-success','actual-previous-active-watchdog-failure'],
    powerCondition='ac',automaticHoldMinutes=30,limits=dict(batteryFloor=40,maxHoldHours=1),debugLog=True)).encode()
  (support/'control.json').write_bytes(raw)
  (support/'custom-old-settings.json').write_text('retain me')
  (support/'usage.json').write_text('{}')
  resources=root/'resources';resources.mkdir()
  for name in ['install-helper.sh','tether-watchdog.sh','tether-recovery-lock.sh','local.tether.helper.plist','local.tether.watchdog.plist']:
   shutil.copy2(ROOT/'Resources'/name,resources/name)
  shutil.copy2(HELPER,resources/'tether-helper')
  shutil.copy2(RECOVERY,resources/'tether-power-recovery')
  if case=='recovery-executor-missing':(resources/'tether-power-recovery').unlink()
  if case=='recovery-executor-unsafe':(resources/'tether-power-recovery').chmod(0o777)
  mock=root/'mock';mock.mkdir()
  for name in ['pmset','launchctl','ioreg']:(mock/name).write_text(MOCK);(mock/name).chmod(0o755)
  (root/'fake.json').write_text(json.dumps(dict(power='ac',lid='open',sleepDisabled=False,fullWake=True,external=False,temperature=30,thermal=0,battery=80)))
  if previous_case:
   previous_fake=dict(power='battery',lid='open',sleepDisabled=False,fullWake=True,external=False,temperature=30,thermal=0,battery=80,displaySleeping=True)
   if PREVIOUS_BUILD>=51:previous_fake.update(manualClock=PREVIOUS_MANUAL_CLOCK,lowPowerWarning=False)
   (root/'fake.json').write_text(json.dumps(previous_fake))
  if missing_daemon:
   fake=json.loads((root/'fake.json').read_text());fake.update(guiAuthority=True,guiConsoleUID=os.geteuid())
   (root/'fake.json').write_text(json.dumps(fake))
  if case in ['watchdog-failure','owned-watchdog-failure','logs-watchdog-rollback','rollback-lock-busy']:(root/'failure').write_text('watchdog')
  if case=='rollback-lock-busy':(root/'lock-on-failure').touch()
  if case=='migration-failure':(support/'migrations').write_text('occupied')
  if case=='future-schema':(support/'control.json').write_text('{"enabled":true,"schemaVersion":99}');raw=(support/'control.json').read_bytes()
  if case=='corrupt-settings':(support/'control.json').write_text('{');raw=(support/'control.json').read_bytes()
  if case.startswith('writer-'):
   current_boot=subprocess.check_output(['/usr/sbin/sysctl','-n','kern.bootsessionuuid'],text=True).strip()
   record=dict(schema=99 if case=='writer-future' else 1,transaction='08F7A1B7-7993-45E2-BB8E-C28FD6BD49E8',phase='writerUnresolved',
    boot='previous-boot' if case=='writer-old-boot' else current_boot,
    owner=dict(pid=os.getpid(),uid=os.geteuid(),started=1,executable='/usr/bin/python3'),
    executable='/usr/bin/pmset',arguments=['-a','disablesleep','1'],deadline=1,inheritsRecoveryLock=True)
   (support/'power-writer.json').write_text('{' if case=='writer-corrupt' else json.dumps(record))
   (support/'power-writer.json').chmod(0o600)
  env=dict(os.environ,TETHER_INSTALL_TEST_ROOT=str(root),TETHER_TEST_LID=case.removeprefix("lid-") if case.startswith("lid-") else "open")
  facts=dict(supportedPlatform=True,internalBattery=True,lid=True)
  if case in ['target-desktop','target-ups']:facts.update(internalBattery=False,lid=False)
  if case=='target-unknown':facts.update(internalBattery=None,lid=None)
  if case=='target-missing-lid':facts['lid']=None
  if case=='target-missing-battery':facts['internalBattery']=None
  if case=='target-unsupported':facts['supportedPlatform']=False
  facts_path=root/'install-target-facts.json';facts_path.write_text(json.dumps(facts));facts_path.chmod(0o600)
  if case=='target-corrupt':facts_path.write_text('{')
  if case=='target-unsafe':facts_path.chmod(0o666)
  if case=='target-symlink':
   facts_path.rename(root/'facts-original.json');facts_path.symlink_to(root/'facts-original.json')
  if case=='target-hardlink':os.link(facts_path,root/'facts-alias.json')
  if case=='target-legacy-probe':
   (resources/'tether-helper').write_text('#!/bin/sh\nprintf "settings-valid\\n"\n');(resources/'tether-helper').chmod(0o755)
  if case=='target-changes-after-validation':(root/'change-target-after-lid').touch()
  # A desktop has no clamshell key. Refusal must happen at the hardware probe,
  # instead of turning a missing key into an instruction to open a MacBook.
  if case in ['target-desktop','target-ups']:env['TETHER_TEST_LID']='unknown'
  upgrade_before={}
  if case in UPGRADE_SUCCESS_CASES+UPGRADE_UNSAFE_CASES:
   upgrades=support/'upgrades'
   paths=[support,upgrades]
   if case=='legacy-support-mode':
    # /tmp inherits wheel on macOS; model the executor's allowed legacy group.
    os.chown(support,-1,os.getegid());support.chmod(0o775)
   elif case=='upgrade-private-mode':upgrades.mkdir(mode=0o755)
   elif case=='upgrade-support-acl':
    subprocess.run(['/bin/chmod','+a','everyone allow write',str(support)],check=True)
   elif case=='upgrade-directory-file':upgrades.write_bytes(b'not a directory')
   elif case=='upgrade-directory-symlink':
    victim=root/'outside-upgrades';victim.mkdir();sentinel=victim/'sentinel';sentinel.write_bytes(b'keep')
    upgrades.symlink_to(victim,target_is_directory=True);paths += [victim,sentinel]
   elif case=='upgrade-parent-symlink':
    parent=support.parent;original=root/'original-support-parent';parent.rename(original)
    parent.symlink_to(original,target_is_directory=True);paths += [parent,original]
   else:
    upgrades.mkdir(mode=0o700)
    if case=='upgrade-directory-unsafe':upgrades.chmod(0o777)
    else:
     acl='everyone allow write' if case=='upgrade-directory-acl' else 'everyone allow add_file,add_subdirectory,delete_child,file_inherit,directory_inherit'
     subprocess.run(['/bin/chmod','+a',acl,str(upgrades)],check=True)
     if case=='upgrade-inherited-acl':
      # Reproduce the old mode-only assumption without root or a live service:
      # chmod 0700 does not remove ACLs, and new backup directories inherit them.
      upgrades.chmod(0o700)
      probe=upgrades/'inheritance-probe';probe.mkdir(mode=0o700)
      assert log_path_state(probe)['acl'],'ACL inheritance reproduction did not execute'
      probe.rmdir()
   upgrade_before={path:log_path_state(path) for path in paths}
  try:
   if previous_case:
    subprocess.run([str(mock/'launchctl'),'bootstrap','system',str(daemons/'local.tether.helper.plist')],env=env,check=True)
    subprocess.run([str(mock/'launchctl'),'bootstrap','system',str(daemons/'local.tether.watchdog.plist')],env=env,check=True)
    old_pid=int((root/'helper.pid').read_text());owned_pids[old_pid]=process_identity(old_pid)
    old=wait_snapshot(support,PREVIOUS_BUILD)
    assert old['protection']['dryRun'] is True and old['status']['power']=='battery'
    active_previous=missing_daemon or case in ['actual-previous-active-success','actual-previous-detach-success','actual-previous-active-watchdog-failure']
    if PREVIOUS_BUILD>=51:
     old=attach_previous_v3(support,old,active_previous)
     assert old['workSessionBridge']['coordinated'] and old['status']['ownsOverride']==active_previous,old
     if active_previous:
      lease=old['status']['workSession'];receipt=old['workSessionBridge']['batteryPermitReceipt']
      assert lease['executionVersion']==3 and lease['manualDeadline']==PREVIOUS_MANUAL_CLOCK+PREVIOUS_MANUAL_SECONDS,old
      if old['status'].get('workSessionCoordinatorVersion')==10:
       assert lease['expiry']==PREVIOUS_MANUAL_CLOCK+COORDINATOR_10_LEASE_SECONDS,old
       assert receipt['permitID']==lease['manualRequestID']==lease['lidPermit']['batteryPermitID'],old
       assert receipt['deadline']==lease['manualBatteryMaximumDeadline']==PREVIOUS_MANUAL_CLOCK+COORDINATOR_10_BATTERY_SECONDS,old
      else:
       assert lease['expiry']==PREVIOUS_MANUAL_CLOCK+90,old
       assert receipt['deadline']==PREVIOUS_MANUAL_CLOCK+PREVIOUS_MANUAL_SECONDS,old
    else:
     rpc(support,'attachApp')
     if active_previous:
      old=rpc(support,'startHold',minutes=10)
      assert old['status']['ownsOverride'] and old['control']['batteryHoldUntil']>time.time()
    if active_previous:
     if case=='actual-previous-detach-success':
      old=rpc(support,'detachApp')
      assert not old['status']['ownsOverride'] and not old['status']['appConnected']
    if missing_daemon:
     # Match the real damaged installation: loaded old helper + AC/open own
     # hold, every other recovery/watchdog component present, only plist gone.
     fake=json.loads((root/'fake.json').read_text());fake['power']='ac'
     (root/'fake.json').write_text(json.dumps(fake))
     old=rpc(support,'markDiagnostic')
     assert old['status']['power']=='ac' and not old['status']['lidClosed'] and old['status']['ownsOverride']
     (daemons/'local.tether.helper.plist').unlink()
     assert process_alive(old_pid) and not (daemons/'local.tether.helper.plist').exists()
     subprocess.run([str(mock/'launchctl'),'print','system/local.tether.helper'],env=env,check=True,capture_output=True)
    if case=='actual-previous-paused-stop':os.kill(old_pid,signal.SIGSTOP)
    if case.endswith('watchdog-failure'):(root/'failure').write_text('watchdog')
    if case.endswith('bootstrap-failure'):(root/'failure').write_text('helper')
    started=time.time()
   blocker=None
   if case=='rollback-lock-busy':
    def acquire_rollback_lock():
     deadline=time.monotonic()+15
     while not (root/'rollback-lock-requested').exists() and time.monotonic()<deadline:time.sleep(.01)
     if (root/'rollback-lock-requested').exists():
      fcntl.flock(holder,fcntl.LOCK_EX);(root/'rollback-lock-held').touch()
    blocker=threading.Thread(target=acquire_rollback_lock);blocker.start()
   result=subprocess.run(['/bin/sh',str(resources/'install-helper.sh')],env=env,text=True,capture_output=True,timeout=35,
                         umask=0o077 if case=='logs-new-umask077' else -1)
   if previous_case:
    verify_previous(case,root,support,tools,daemons,result,old,old_pid,started)
   elif case=='rollback-lock-busy':
    blocker.join(timeout=1);assert not blocker.is_alive()
    assert result.returncode!=0 and (root/'rollback-lock-held').exists(),(case,result.stdout,result.stderr)
    assert 'Recovery deferred: a service/transaction is still active.' in result.stderr
    assert (root/'watchdog.loaded').exists(),(case,'deferred rollback lost its independent watchdog')
    assert (tools/'local.tether.helper').read_bytes()==HELPER.read_bytes(),(case,'rolled files back without the lock')
    assert not (root/'commands.log').exists(),(case,'busy rollback wrote power settings')
    assert list((support/'upgrades').glob('helper-*')),(case,'lost rollback backup')
    assert 'Helper update verified.' not in result.stdout
    fcntl.flock(holder,fcntl.LOCK_UN)
   elif case in ['success','owned-recovery','writer-old-boot',*LOG_SUCCESS_CASES,*UPGRADE_SUCCESS_CASES] or case.startswith('schema-'):
    assert result.returncode==0,(result.stdout,result.stderr,(root/'helper.log').read_text() if (root/'helper.log').exists() else 'helper did not start')
    migrated=json.loads((support/'control.json').read_text())
    assert migrated['schemaVersion']==CURRENT_SCHEMA and migrated['enabled'] is False
    assert migrated['limits']=={'batteryFloor':40,'maxHoldHours':1} and 'holdLowPower' not in migrated
    assert migrated['debugLog'] is True and 'debugLogUntil' not in migrated
    assert 'batteryHoldUntil' not in migrated
    assert (tools/'local.tether.helper').read_bytes()==HELPER.read_bytes()
    assert (tools/'local.tether.power-recovery').read_bytes()==RECOVERY.read_bytes()
    backups=list((support/'migrations').glob('control-*.json'))
    if case==f'schema-{CURRENT_SCHEMA}':
     assert not backups,'A current schema must not migrate again'
     assert (support/'control.json').read_bytes()==raw,'Current-schema bytes were rewritten'
    else:assert len(backups)==1 and backups[0].read_bytes()==raw
    if case.startswith('schema-'):
     assert migrated['powerCondition']=='ac' and migrated['automaticHoldMinutes']==30
     if case!=f'schema-{CURRENT_SCHEMA}':
      report=json.loads((support/'migration-report.json').read_text())
      assert 'batteryAutomaticRetired' in report['cleared'],report
    version=plistlib.loads((ROOT/'Resources/Info.plist').read_bytes())['CFBundleShortVersionString']
    assert f'helper-ready {version} protocol=2 schema={CURRENT_SCHEMA}' in result.stdout
    if case.startswith('schema-'):
     first=rpc(support,'snapshot')
     assert not first['status']['ownsOverride'] and not first['status'].get('manualSession',{}).get('active'),first
     fake=json.loads((root/'fake.json').read_text());fake['power']='battery'
     (root/'fake.json').write_text(json.dumps(fake))
     departed=rpc(support,'markDiagnostic')
     assert not departed['status']['ownsOverride'] and not departed['status'].get('batteryHoldUntil'),departed
     current_bytes=(support/'control.json').read_bytes()
     subprocess.run([str(mock/'launchctl'),'bootout','system/local.tether.helper'],env=env,check=True)
     subprocess.run([str(mock/'launchctl'),'bootstrap','system',str(daemons/'local.tether.helper.plist')],env=env,check=True)
     build=int(plistlib.loads((ROOT/'Resources/Info.plist').read_bytes())['CFBundleVersion'])
     restarted=wait_snapshot(support,build,first['epoch'])
     assert not restarted['status']['ownsOverride'] and not restarted['status'].get('batteryHoldUntil'),restarted
     assert not restarted['status'].get('manualSession',{}).get('active'),restarted
     assert (support/'control.json').read_bytes()==current_bytes,'Restart changed the migrated choices'
     assert list((support/'migrations').glob('control-*.json'))==backups,'Restart repeated migration'
    if case=='owned-recovery': assert 'pmset -a disablesleep 0' in (root/'commands.log').read_text()
    if case in UPGRADE_SUCCESS_CASES:
     assert stat.S_IMODE(support.stat().st_mode)==0o755
     assert stat.S_IMODE((support/'upgrades').stat().st_mode)==0o700
     assert not log_path_state(support)['acl'] and not log_path_state(support/'upgrades')['acl']
   else:
    assert result.returncode!=0,(case,result.stdout,result.stderr)
    assert (support/'control.json').read_bytes()==raw,(case,'original changed')
    for name in ['local.tether.helper','local.tether.watchdog']:
     assert (tools/name).read_text()=='legacy-'+name
     assert (daemons/(name+'.plist')).read_text()=='legacy-plist-'+name
    if case in ['future-schema','corrupt-settings','lid-closed','lid-unknown','lid-closes-after-validation','writer-unresolved','writer-future','writer-corrupt','recovery-executor-missing','recovery-executor-unsafe']:assert not (root/'commands.log').exists()
    if case in UPGRADE_UNSAFE_CASES:
     assert 'Unsafe helper upgrade paths. Nothing was replaced.' in result.stderr,(case,result.stdout,result.stderr)
     assert {path:log_path_state(path) for path in upgrade_before}==upgrade_before,(case,'unsafe storage was modified')
     assert not (root/'launchctl.log').exists(),(case,'touched a service before storage verification')
     assert not (root/'commands.log').exists(),(case,'issued a power command')
     assert not list((support/'upgrades').glob('helper-*')),(case,'created a backup under unsafe storage')
    if case.startswith('target-'):
     assert not (root/'commands.log').exists(), (case,'issued a power command')
     assert not (root/'launchctl.log').exists(), (case,'touched a service before target verification')
     if case=='target-changes-after-validation':
      assert 'administrator helper is not required' in result.stderr
     else:
      assert not (support/'upgrades').exists(), (case,'created an upgrade backup before target verification')
     if case in ['target-desktop','target-ups']:
      assert 'administrator helper is not required' in result.stderr and 'Open the MacBook' not in result.stderr
     elif case=='target-unsupported':assert 'Apple Silicon Mac running macOS 26 or later' in result.stderr
     elif case!='target-changes-after-validation':assert 'could not be verified' in result.stderr
   assert (support/'custom-old-settings.json').read_text()=='retain me'
   assert lock.stat().st_ino==lock_inode,(case,'stable lock was replaced/deleted')
   if case=='no-effect':assert json.loads((support/'power-ownership.json').read_text())['owned'] is True
   if case=='owned-watchdog-failure':
    assert not (support/'power-ownership.json').exists(), 'Rollback replayed an already-consumed lease'
    assert (root/'commands.log').read_text().count('pmset -a disablesleep 0') == 1
   if case=='lock-busy-loaded-services':
    assert (root/'legacy-helper.loaded').exists() and (root/'watchdog.loaded').exists(),(case,'lost recovery service registrations')
    assert (support/'power-ownership.json').read_bytes()==ownership_before,(case,'busy lock changed the recovery lease')
    for name in ['local.tether.helper','local.tether.watchdog']:
     assert (tools/name).read_text()=='legacy-'+name,(case,'replaced original service')
     assert (daemons/(name+'.plist')).read_text()=='legacy-plist-'+name,(case,'changed original registration')
    calls=(root/'launchctl.log').read_text()
    assert 'bootstrap system ' in calls and 'original service registrations retained/restored' in result.stderr
    assert not (root/'commands.log').exists(),(case,'busy lock caused an unjournaled power write')
    # Registrations survive release too; no successful upgrade was claimed.
    fcntl.flock(holder,fcntl.LOCK_UN)
    assert (root/'legacy-helper.loaded').exists() and (root/'watchdog.loaded').exists()
    assert 'Helper update verified.' not in result.stdout
   if case in ['writer-unresolved','writer-future','writer-corrupt']:assert (support/'power-writer.json').exists()
   if case=='writer-old-boot':assert not (support/'power-writer.json').exists()
   if case in LOG_CASES:verify_log_fixture(case,root,logs,log_before,active_log,result)
   print('PASS installer',case,flush=True)
  finally:
   if active_log is not None:active_log.close()
   holder.close()
   cleanup_processes(root,owned_pids)
   if missing_daemon:
    assert owned_pids and all(not process_alive(pid) for pid in owned_pids),'missing-daemon fixture retained a process'
    print('  verified missing-daemon fixture process cleanup',flush=True)

if os.geteuid()==0:raise SystemExit('Run this test without root')
CASES=['success','schema-1','schema-2','schema-3','schema-4','watchdog-failure','owned-watchdog-failure','migration-failure','future-schema','corrupt-settings','lid-closed','lid-unknown','lid-closes-after-validation','lock-busy','unsafe-lock','owned-recovery','no-effect','writer-unresolved','writer-future','writer-corrupt','writer-old-boot','recovery-executor-missing','recovery-executor-unsafe']
CASES += ['target-desktop','target-ups','target-unknown','target-missing-lid','target-missing-battery',
          'target-unsupported','target-corrupt','target-unsafe','target-symlink','target-hardlink',
          'target-legacy-probe','target-changes-after-validation']
CASES += ['readiness-current','readiness-old-contract','readiness-previous-contract','readiness-before-p0-contract','readiness-before-display-contract','readiness-legacy-contract','readiness-missing-contract','readiness-future-contract',
          'readiness-future-state','readiness-stale-state','readiness-wrong-build','readiness-migration-failed','readiness-future-schema',
          'readiness-sleep-events-unavailable','readiness-previous-schema']
CASES += ['metadata-version','metadata-version-flags']
CASES += LOG_CASES
CASES += UPGRADE_SUCCESS_CASES+UPGRADE_UNSAFE_CASES
CASES += ['lock-busy-loaded-services','rollback-lock-busy']
if PREVIOUS:CASES += ['actual-previous-off-success','actual-previous-active-success','actual-previous-detach-success',
                     'actual-previous-watchdog-failure','actual-previous-active-watchdog-failure','actual-previous-bootstrap-failure','actual-previous-paused-stop',
                     'actual-previous-missing-daemon-success','actual-previous-missing-daemon-watchdog-failure','actual-previous-missing-daemon-bootstrap-failure']
if os.environ.get('TETHER_INSTALL_TEST_CASES'):
 selected=os.environ['TETHER_INSTALL_TEST_CASES'].split(',')
 assert len(set(selected))==len(selected) and all(case in CASES for case in selected),'unknown or repeated installer case'
 CASES=selected
for case in CASES:
 if case.startswith('metadata-'):run_metadata_case(case)
 elif case.startswith('readiness-'):run_readiness_case(case)
 else:run_case(case)
print('TOTAL',len(CASES),'installer scenarios passed',flush=True)
