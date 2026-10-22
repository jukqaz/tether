#!/usr/bin/env python3
"""Native Sparkle download/verify/replace test using synthetic, never-running app bundles.
Requires SPARKLE_TEST_CLI built from Sparkle's official sparkle-cli source and SPARKLE_TOOLS_DIR.
Each fixture generates a disposable signing key; production keys are never read.
The HTTP feed exists only on 127.0.0.1 during this test.
"""
import argparse,contextlib,datetime,functools,http.server,os,plistlib,shutil,subprocess,tempfile,threading,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
CLI=Path(os.environ['SPARKLE_TEST_CLI']);TOOLS=Path(os.environ['SPARKLE_TOOLS_DIR'])
SOURCE_INFO=plistlib.loads((ROOT/'Resources/Info.plist').read_bytes())
SECURITY_KEYS=('SURequireSignedFeed','SUSignedFeedFailureExpirationInterval','SUVerifyUpdateBeforeExtraction')
assert SOURCE_INFO['SURequireSignedFeed'] is True
assert SOURCE_INFO['SUSignedFeedFailureExpirationInterval'] == 0
assert SOURCE_INFO['SUVerifyUpdateBeforeExtraction'] is True
def run(*args,**kw):return subprocess.run([str(x) for x in args],capture_output=True,text=True,**kw)
class Quiet(http.server.SimpleHTTPRequestHandler):
 def log_message(self,*args):pass

def cleanup_test_domains(*domains):
 for domain in domains:
  prefix='io.github.jukqaz.tether.update-test.'
  assert domain.startswith(prefix), 'Refuse non-test preferences cleanup'
  uuid.UUID(domain[len(prefix):].removesuffix('.runner'))
  run('defaults','delete',domain)
  library=Path.home()/'Library'
  # defaults clears the values but can leave an empty plist; Sparkle also
  # creates per-fixture download caches outside TemporaryDirectory.
  (library/'Preferences'/f'{domain}.plist').unlink(missing_ok=True)
  cache=library/'Caches'/domain
  if cache.is_symlink():cache.unlink()
  elif cache.exists():shutil.rmtree(cache)

def case(kind):
 with tempfile.TemporaryDirectory(prefix='tether-sparkle-',dir='/tmp') as temp, contextlib.ExitStack() as cleanup:
  folder=Path(temp);web=folder/'feed';web.mkdir()
  generated=run('swift','-e','''import Foundation
import CryptoKit
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
guard FileManager.default.createFile(atPath: folder.appendingPathComponent("fixture.key").path,
    contents: key.rawRepresentation.base64EncodedData(), attributes: [.posixPermissions: 0o600]) else { exit(1) }
try key.publicKey.rawRepresentation.base64EncodedData().write(to: folder.appendingPathComponent("fixture.pub"))
''',folder)
  assert generated.returncode==0,generated.stderr
  key=folder/'fixture.key';public=(folder/'fixture.pub').read_text().strip()
  server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Quiet,directory=str(web)))
  thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
  def stop_server():
   if thread.is_alive():server.shutdown()
   server.server_close();thread.join(timeout=5)
   assert not thread.is_alive(), 'Fixture HTTP server did not stop'
  cleanup.callback(stop_server)
  base=f'http://127.0.0.1:{server.server_port}'
  bundle_id='io.github.jukqaz.tether.update-test.'+str(uuid.uuid4())
  # Give the external updater its own defaults domain; never modify Tether's preferences.
  runner_id=bundle_id+'.runner'
  cleanup.callback(cleanup_test_domains,runner_id,bundle_id)
  runner=folder/'runner.app/Contents/MacOS/sparkle-cli'
  runner.parent.mkdir(parents=True)
  shutil.copy2(CLI,runner)
  (runner.parent.parent/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier=runner_id,CFBundleExecutable='sparkle-cli',CFBundlePackageType='APPL')))
  def app(path,version):
   (path/'Contents/MacOS').mkdir(parents=True)
   shutil.copyfile('/usr/bin/true',path/'Contents/MacOS/Fixture')
   (path/'Contents/MacOS/Fixture').chmod(0o755)
   display_version=SOURCE_INFO['CFBundleShortVersionString'] if kind.startswith('same-version-') else f'1.0.{version}'
   info=dict(CFBundleIdentifier=bundle_id,CFBundleExecutable='Fixture',CFBundleName='Tether Update Fixture',CFBundlePackageType='APPL',CFBundleVersion=str(version),CFBundleShortVersionString=display_version,LSMinimumSystemVersion='14.0',SUPublicEDKey=public,SUFeedURL=base+'/appcast.xml',SUEnableAutomaticChecks=False,SUAutomaticallyUpdate=False,SUVerifyUpdateBeforeExtraction=True,SURequireSignedFeed=True,NSAppTransportSecurity={'NSAllowsLocalNetworking':True})
   info.update({key:SOURCE_INFO[key] for key in SECURITY_KEYS})
   if kind=='legacy-aged-tampered-feed':info.pop('SUSignedFeedFailureExpirationInterval')
   (path/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
   result=run('codesign','--force','--sign','-',path);assert result.returncode==0,result.stderr
  installed=folder/'installed/Tether.app';new=folder/'new/Tether.app'
  candidate = int(SOURCE_INFO['CFBundleVersion']) if kind.startswith('same-version-') else 2
  initial = (candidate-1 if kind=='same-version-next-build' else candidate+1 if kind=='same-version-older-build' else candidate) if kind.startswith('same-version-') else 3 if kind == 'no-downgrade' else 2 if kind == 'same-build' else 1
  app(installed,initial);app(new,candidate)
  archive=web/'Tether-update.zip'
  assert run('ditto','-c','-k','--norsrc','--keepParent',new,archive).returncode==0
  signed=run(TOOLS/'bin/sign_update','--ed-key-file',key,'-p',archive)
  assert signed.returncode==0,signed.stderr
  signature=signed.stdout.strip()
  feed=web/'appcast.xml'
  display_version=SOURCE_INFO['CFBundleShortVersionString'] if kind.startswith('same-version-') else '1.0.2'
  feed.write_text(f'''<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><title>Fixture</title><item><title>{display_version}</title><sparkle:version>{candidate}</sparkle:version><sparkle:shortVersionString>{display_version}</sparkle:shortVersionString><sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion><enclosure url="{base}/Tether-update.zip" length="{archive.stat().st_size}" type="application/octet-stream" sparkle:edSignature="{signature}"/></item></channel></rss>''')
  if kind in ['stable-rejects-beta','beta-accepts-beta']:
   feed.write_text(feed.read_text().replace('<item>', '<item><sparkle:channel>beta</sparkle:channel>'))
  signed_feed=run(TOOLS/'bin/sign_update','--ed-key-file',key,feed);assert signed_feed.returncode==0,signed_feed.stderr
  if kind=='tampered-archive':
   data=bytearray(archive.read_bytes());data[len(data)//2]^=1;archive.write_bytes(data)
  if kind in ['tampered-feed','aged-tampered-feed','legacy-aged-tampered-feed']:
   feed.write_text(feed.read_text().replace('<title>Fixture</title>','<title>Altered</title>'))
  try:
   if kind in ['aged-tampered-feed','legacy-aged-tampered-feed']:
    # Sparkle's external updater records the first failure in its own domain with a host suffix.
    first_failure=(datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=30)).strftime('%Y-%m-%d %H:%M:%S +0000')
    seeded=run('defaults','write',runner_id,'SUInitialFailedFeedSigningValidationDate_'+bundle_id,'-date',first_failure)
    assert seeded.returncode==0,seeded.stderr
   options = ['--channels','beta'] if kind in ['beta-accepts-beta','beta-accepts-stable'] else []
   result=run(runner,installed,'--check-immediately','--verbose','--user-agent-name','TetherLocalUpdateTest',*options,timeout=60)
   version=plistlib.loads((installed/'Contents/Info.plist').read_bytes())['CFBundleVersion']
   LOG_DIR.mkdir(parents=True,exist_ok=True)
   (LOG_DIR/f'sparkle-{kind}.log').write_text(result.stdout+result.stderr)
   if kind in ['success','same-version-next-build','beta-accepts-beta','beta-accepts-stable','legacy-aged-tampered-feed']:assert result.returncode==0 and version==str(candidate),(result.returncode,version,result.stderr)
   # Official sparkle-cli uses exit 4 for SUNoUpdateError, not generic success/failure.
   elif kind in ['stable-rejects-beta','no-downgrade','same-build','same-version-older-build','same-version-same-build']:assert result.returncode==4 and version==str(initial) and 'No new update available!' in result.stdout+result.stderr,(kind,result.returncode,version,result.stderr)
   else:
    # A cache/connection failure must not pass a signature-rejection test.
    expected_error = 4005 if kind == 'tampered-archive' else 1000
    assert result.returncode==1 and version=='1' and f'error {expected_error} (SUSparkleErrorDomain)' in result.stderr,(kind,result.returncode,version,result.stderr)
   print('PASS native Sparkle',kind,'installed version',version,flush=True)
  finally:
   stop_server()
CASES = ['success','tampered-archive','tampered-feed','aged-tampered-feed','legacy-aged-tampered-feed','stable-rejects-beta','beta-accepts-beta','beta-accepts-stable','no-downgrade','same-build','same-version-next-build','same-version-older-build','same-version-same-build']
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--case', choices=CASES, action='append', help='Run only the named case(s). Default: all cases.')
parser.add_argument('--log-dir',type=Path,default=ROOT.parent,help='Directory for native updater logs.')
args=parser.parse_args();LOG_DIR=args.log_dir
for kind in args.case or CASES: case(kind)
