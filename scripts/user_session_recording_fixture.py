"""Private wire responder for the real CLI; never starts the app or touches preferences.

This models recording replies, not AppModel's recording policy. The latter is
covered by UserSessionCommandTests.testActualCLIDiagnose* (desktop/notebook,
newer GUI choice, existing GUI recording, and unsupported recording receipts).
"""
import copy
import ctypes
import json
import math
import os
from pathlib import Path
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid


def process_executable(pid):
    """Use the same kernel identity as ProcessIdentity.capture, not a Python launcher."""
    path = ctypes.create_string_buffer(4096)
    proc_pidpath = ctypes.CDLL('/usr/lib/libproc.dylib').proc_pidpath
    proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    proc_pidpath.restype = ctypes.c_int
    assert proc_pidpath(pid, path, len(path)) > 0, 'Cannot inspect fixture process executable: ' + str(pid)
    return os.fsdecode(path.value)


def diagnostic_environment(helper, *, session=None):
    """Even report-only CLI calls must never discover the installed app socket."""
    return dict(os.environ, TETHER_SERVICE_SOCKET=session.helper_socket if session else helper.sock,
                TETHER_USER_SESSION_SOCKET=session.socket if session else str(helper.folder / 'absent-app.sock'),
                TETHER_USER_SESSION_SERVER_EXECUTABLE=session.server_executable if session else process_executable(os.getpid()))


class RecordingSessionFixture:
    def __init__(self, helper, executable, *, confirms_recording=True):
        self.helper = helper
        self.executable = Path(executable)
        self.server_executable = process_executable(os.getpid())
        self.build = helper.ok('snapshot')['status']['build']
        self.temp = tempfile.TemporaryDirectory(prefix='recording-', dir=helper.folder)
        folder = Path(self.temp.name)
        folder.chmod(0o700)
        self.socket = str(folder / 'commands.sock')
        # Keep report collection in the helper's existing dry-run directory.
        self.helper_socket = str(helper.folder / 'recording-helper.sock')
        self.epoch = str(uuid.uuid4())
        self.revision = 0
        self.until = None
        self.owner = None
        self.entries = []
        self.starts = []
        self.finishes = []
        self.root_actions = []
        self.errors = []
        self.accepted = []
        self.user_frames = 0
        self.confirms_recording = confirms_recording
        self.lock = threading.RLock()
        self.started = threading.Event()
        self.stopped = threading.Event()
        self.listeners = []
        self.threads = []
        try:
            self._listen(self.socket, self._user_reply, authenticate=True)
            self._listen(self.helper_socket, self._helper_reply)
        except BaseException:
            self.close()
            raise

    @staticmethod
    def _receive(connection):
        data = b''
        while len(data) <= 256 * 1024:
            part = connection.recv(8192)
            if not part:
                assert not data, 'truncated fixture frame'
                return None  # A CLI rejecting this server closes before sending.
            data += part
            assert len(data) <= 256 * 1024, 'oversized fixture frame'
            if b'\n' in data:
                assert data.endswith(b'\n') and data.count(b'\n') == 1, 'invalid fixture frame'
                return json.loads(data)
        raise AssertionError('oversized fixture frame')

    def _authenticate(self, connection):
        # Kernel UID/PID and executable checks restrict this responder to the
        # selected real CLI. Its reciprocal expected-server check sees Python.
        uid, gid = ctypes.c_uint(), ctypes.c_uint()
        libc = ctypes.CDLL(None)
        assert libc.getpeereid(connection.fileno(), ctypes.byref(uid), ctypes.byref(gid)) == 0
        assert uid.value == os.getuid()
        pid = struct.unpack('i', connection.getsockopt(0, 2, 4))[0]  # Darwin SOL_LOCAL / LOCAL_PEERPID.
        assert pid > 1 and os.path.samefile(process_executable(pid), self.executable)

    def _listen(self, path, handle, *, authenticate=False):
        folder = os.lstat(Path(path).parent)
        assert stat.S_ISDIR(folder.st_mode) and folder.st_uid == os.geteuid() and folder.st_mode & 0o077 == 0, (
            path, folder.st_uid, oct(stat.S_IMODE(folder.st_mode)))
        assert len(os.fsencode(path)) < 104, 'Private Darwin socket path is too long: ' + path
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listeners.append(listener)
        listener.bind(path)
        os.chmod(path, 0o600)
        endpoint = os.lstat(path)
        assert stat.S_ISSOCK(endpoint.st_mode) and endpoint.st_uid == os.geteuid() and endpoint.st_mode & 0o077 == 0
        listener.listen(8)
        listener.settimeout(.1)

        def serve():
            while not self.stopped.is_set():
                try:
                    connection, _ = listener.accept()
                    self.accepted.append(path)
                except socket.timeout:
                    continue
                except OSError:
                    if not self.stopped.is_set():
                        self.errors.append('fixture listener unexpectedly closed')
                    return
                try:
                    with connection:
                        connection.settimeout(5)
                        request = self._receive(connection)
                        if request is not None:
                            if authenticate:
                                self._authenticate(connection)
                            reply = handle(request)
                            connection.sendall(json.dumps(reply).encode() + b'\n')
                except BaseException as error:
                    self.errors.append(repr(error))

        thread = threading.Thread(target=serve, daemon=True)
        self.threads.append(thread)
        thread.start()

    def _helper_reply(self, request):
        self.root_actions.append(request['action'])
        assert request['action'] == 'snapshot', 'CLI recording attempted a privileged helper mutation: ' + request['action']
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(5)
            connection.connect(self.helper.sock)
            connection.sendall(json.dumps(request).encode() + b'\n')
            return self._receive(connection)

    def _event(self, kind, *, detail=False):
        # JSONEncoder's default Date representation is seconds since 2001-01-01.
        entry = dict(id=len(self.entries) + 1, date=time.time() - 978307200, kind=kind)
        if detail:
            entry['inputs'] = dict(thermal=1, batteryPercent=80, manualRemaining=0, batteryRemaining=0)
        self.entries.append(entry)

    def select_gui_recording(self, minutes):
        """Controlled reply state for a pre-existing or newer GUI choice."""
        with self.lock:
            self.owner = None
            self.until = time.time() + minutes * 60
            self._event('recordingStarted')
            self._event('detail', detail=True)
            return self.until

    def _user_reply(self, request):
        with self.lock:
            self.user_frames += 1
            assert request['version'] == 1 and request['build'] == self.build
            uuid.UUID(request['id'])
            assert request['command'] == {'status': {}}
            assert math.isfinite(request['deadline'])
            reply = dict(version=1, build=self.build, id=request['id'], epoch=self.epoch,
                         revision=self.revision, ok=True, observedAt=time.time(), lidSupport='unavailable')
            recording = request.get('recording')
            if recording:
                assert request['epoch'].lower() == self.epoch.lower()
                assert request['revision'] == self.revision
                assert len(recording) == 1
                if 'start' in recording:
                    minutes = recording['start']['minutes']
                    assert isinstance(minutes, int) and 1 <= minutes <= 240
                    self.starts.append(copy.deepcopy(request))
                    if self.confirms_recording:
                        if self.until and self.until > time.time():
                            self.owner = None
                        else:
                            self.owner = request['id']
                            self.until = time.time() + minutes * 60
                            self._event('recordingStarted')
                            self._event('detail', detail=True)
                    self.started.set()
                else:
                    token = recording['finish']['recordingID']
                    assert any(start['id'].lower() == token.lower() for start in self.starts)
                    self.finishes.append(copy.deepcopy(request))
                    if self.owner and token.lower() == self.owner.lower():
                        self.owner = None
                        self.until = None
                        self._event('recordingEnded')
                self.revision += 1
                reply['revision'] = self.revision
                if self.confirms_recording:
                    reply['recordingID'] = request['id']
            if self.until is not None:
                reply['recordingUntil'] = self.until - 978307200
            reply['commonActivity'] = copy.deepcopy(self.entries)
            return reply

    def wait_for_start(self, cli, timeout=5):
        if self.started.wait(timeout):
            return
        # Preserve the CLI's original failure instead of terminating a process
        # waiting at readLine and discarding its diagnostic stderr.
        poll = cli.poll()
        try:
            stdout, stderr = cli.communicate('\n', timeout=10)
        except subprocess.TimeoutExpired:
            cli.terminate()
            try:
                stdout, stderr = cli.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                cli.kill()
                stdout, stderr = cli.communicate(timeout=5)
        endpoints = {}
        for path in (str(Path(self.socket).parent), self.socket, self.helper_socket):
            info = os.lstat(path)
            endpoints[path] = dict(uid=info.st_uid, mode=oct(stat.S_IMODE(info.st_mode)))
        raise AssertionError(json.dumps(dict(
            failure='CLI recording start timeout', pid=cli.pid, poll_before_cleanup=poll,
            returncode=cli.returncode, stdout=stdout, stderr=stderr,
            server_executable=self.server_executable, python_executable=sys.executable,
            python_resolved=str(Path(sys.executable).resolve()), endpoints=endpoints,
            accepted_connections={path:self.accepted.count(path) for path in (self.socket,self.helper_socket)},
            user_frames=self.user_frames, server_errors=self.errors), indent=2))

    def assert_healthy(self):
        assert not self.errors, self.errors
        assert all(action == 'snapshot' for action in self.root_actions), self.root_actions

    def close(self):
        self.stopped.set()
        for listener in self.listeners:
            listener.close()
        for thread in self.threads:
            thread.join(timeout=6)
            assert not thread.is_alive(), 'fixture server failed to stop'
        for path in (self.socket, self.helper_socket):
            Path(path).unlink(missing_ok=True)
        self.temp.cleanup()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()
