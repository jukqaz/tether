"""Shared isolated helper harness. Every system power write is dry-run."""
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
       Path(subprocess.check_output(['swift', 'build', '--disable-sandbox', '--show-bin-path'], cwd=ROOT, text=True).strip()))

class Fixture:
    def __init__(self, control=None, helper_binary=None, legacy_state=True, **sensor):
        self.helper_binary = Path(helper_binary or os.environ.get('TETHER_TEST_HELPER') or BIN / 'TetherHelper')
        self.temp=tempfile.TemporaryDirectory(prefix='tether-core-',dir='/tmp')
        self.folder=Path(self.temp.name)
        self.control=self.folder/'control.json';self.status=self.folder/'status.json';self.fake=self.folder/'fake.json'
        self.sock=str(self.folder/'service.sock');self.log=self.folder/'helper.log';self.helper=None
        self.control.write_text(json.dumps({'enabled':True,'limits':{'batteryFloor':30}} | (control or {})))
        if legacy_state:
            # The retained v1/v2 integration suite represents an existing
            # installation. No journal means a fresh v3 lease-only helper.
            state=self.folder/'helper-state.json';state.write_text('{}');state.chmod(0o600)
        self.readings=dict(power='ac',lid='open',sleepDisabled=False,fullWake=True,external=False,temperature=30,
                           thermal=0,battery=80,current=-400,displaySleeping=True,powerClock=100) | sensor
        self.patch()
        try:self.start()
        except BaseException:
            self.stop();self.temp.cleanup();raise
    def patch(self, **values):
        self.readings.update(values)
        tmp=self.folder/'fake.tmp';tmp.write_text(json.dumps(self.readings));tmp.replace(self.fake)
    def rpc(self, action, **values):
        request=dict(version=2,id=str(uuid.uuid4()),action=action) | values
        with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as connection:
            connection.settimeout(5);connection.connect(self.sock);connection.sendall(json.dumps(request).encode()+b'\n')
            data=b''
            while not data.endswith(b'\n'):
                part=connection.recv(8192);assert part,'missing response';data+=part
        reply=json.loads(data);assert reply['id'].lower()==request['id'].lower()
        return reply
    def ok(self, action, **values):
        reply=self.rpc(action,**values);assert reply['ok'],reply;return reply
    def config(self, **values):
        before=self.ok('snapshot')
        return self.ok('configure',control=before['control']|values,epoch=before['epoch'],revision=before['revision'])
    def step(self, **values): self.patch(**values);return self.config()
    def logs(self): return self.log.read_text()
    def start(self):
        with self.log.open('a') as output:
            self.helper=subprocess.Popen([str(self.helper_binary),'--dry-run','--control',str(self.control),
                '--status',str(self.status),'--fake',str(self.fake)],stdout=output,stderr=output)
        for _ in range(100):
            assert self.helper.poll() is None,self.logs()
            try:
                if self.ok('snapshot').get('status'):return
            except (OSError,AssertionError):pass
            time.sleep(.03)
        raise AssertionError('helper readiness timeout\n'+self.logs())
    def stop(self):
        if self.helper and self.helper.poll() is None:self.helper.terminate();self.helper.wait(timeout=10)
    def __enter__(self):return self
    def __exit__(self,*args):self.stop();self.temp.cleanup()
