#!/usr/bin/env python3
"""Black-box HTTP + actual process crash tests. No MoonBit implementation imports."""
import argparse
import atexit
import concurrent.futures
import hashlib
import http.client
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import threading
import time

PROJECT = Path(__file__).resolve().parents[1]
BINARY = PROJECT / '_build/native/debug/build/cmd/server/server.exe'
TEST_KEY = 'a' * 64
OTHER_KEY = 'b' * 64
HEADERS = {'Tus-Resumable': '1.0.0', 'Authorization': 'Bearer ' + TEST_KEY}
ACTIVE = []


class Server:
    def __init__(self, store, failpoint='', limits=None, port=None):
        self.store = Path(store)
        self.store.mkdir(parents=True, exist_ok=True)
        if port is None:
            with socket.socket() as s:
                s.bind(('127.0.0.1', 0))
                self.port = s.getsockname()[1]
        else:
            self.port = port
        self.log = open(self.store / 'server.log', 'ab')
        self.process = subprocess.Popen(
            [str(BINARY), str(self.store), str(self.port), failpoint],
            stdout=self.log, stderr=self.log,
            env=os.environ | {'MOON_UPLOAD_KEYS': json.dumps({'alice': TEST_KEY, 'bob': OTHER_KEY})} | (limits or {}))
        ACTIVE.append(self)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError((self.store / 'server.log').read_text())
            try:
                if self.request('GET', '/health')[0] == 200:
                    return
            except OSError:
                pass
            time.sleep(.03)
        self.stop()
        raise TimeoutError('server readiness')

    def request(self, method, path, data=None, headers=None):
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=30)
        try:
            conn.request(method, path, body=data, headers=HEADERS | (headers or {}))
            response = conn.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            conn.close()

    def create(self, length):
        code, h, _ = self.request('POST', '/files', b'', {'Upload-Length': str(length)})
        assert code == 201, (code, h)
        return h['Location']

    def offset(self, path):
        code, h, _ = self.request('HEAD', path)
        assert code == 200, (code, h)
        return int(h['Upload-Offset'])

    def patch(self, path, offset, data):
        return self.request('PATCH', path, data, {
            'Upload-Offset': str(offset),
            'Content-Type': 'application/offset+octet-stream'})

    def download_hash(self, path):
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=30)
        try:
            conn.request('GET', path + '/content', headers=HEADERS)
            r = conn.getresponse()
            assert r.status == 200, r.status
            h = hashlib.sha256()
            total = 0
            while data := r.read(65536):
                h.update(data)
                total += len(data)
            return total, h.hexdigest()
        finally:
            conn.close()

    def stop(self, kill=False):
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGKILL if kill else signal.SIGTERM)
            self.process.wait(timeout=10)
        self.log.close()


@atexit.register
def cleanup_children():
    for server in ACTIVE:
        server.stop()


def partial_request(server, path, offset=0):
    s = socket.create_connection(('127.0.0.1', server.port))
    header = (
        f'PATCH {path} HTTP/1.1\r\nHost: localhost\r\nTus-Resumable: 1.0.0\r\n'
        f'Authorization: Bearer {TEST_KEY}\r\nUpload-Offset: {offset}\r\nContent-Type: application/offset+octet-stream\r\n'
        'Content-Length: 1048576\r\n\r\n')
    s.sendall(header.encode() + b'incomplete' * 100)
    return s


def verify(output, big_mib):
    checks = []
    def passed(name, **details):
        checks.append({'name': name, 'passed': True, **details})
        print('PASS', name, flush=True)

    store = output / 'basic'
    s = Server(store)
    try:
        p = s.create(11)
        assert s.request('HEAD', p, headers={'Authorization': ''})[0] == 401
        assert s.request('PATCH', p, b'bad', headers={'Authorization': 'Bearer ' + OTHER_KEY, 'Upload-Offset': '0', 'Content-Type': 'application/offset+octet-stream'})[0] == 403
        assert s.request('GET', p + '/content', headers={'Authorization': 'Bearer ' + OTHER_KEY})[0] == 403
        assert s.request('HEAD', p, headers={'Authorization': 'Bearer ' + OTHER_KEY})[0] == 403
        assert s.offset(p) == 0
        passed('anonymous and cross-user access denied without mutations')
        assert s.patch(p, 0, b'hello ')[0] == 204
        assert s.offset(p) == 6
        s.stop(kill=True)
        s = Server(store)
        assert s.offset(p) == 6
        assert s.patch(p, 6, b'world')[0] == 204
        assert s.download_hash(p) == (11, hashlib.sha256(b'hello world').hexdigest())
        passed('committed prefix survives SIGKILL and resumes')
        assert s.patch(p, 0, b'bad')[0] == 409
        assert s.offset(p) == 11
        passed('stale offset cannot overwrite committed bytes')
        p2 = s.create(1048576)
        sock = partial_request(s, p2)
        sock.close()
        time.sleep(.15)
        assert s.offset(p2) == 0
        assert s.patch(p2, 0, b'z' * 1048576)[0] == 204
        assert s.download_hash(p2)[1] == hashlib.sha256(b'z' * 1048576).hexdigest()
        passed('interrupted HTTP body does not advance offset')
        empty = s.create(0)
        assert s.download_hash(empty) == (0, hashlib.sha256(b'').hexdigest())
        passed('zero-byte file')
        assert s.request('POST', '/files', b'', {'Upload-Length': '9223372036854775808'})[0] == 400
        assert s.request('POST', '/files', b'', {'Upload-Length': '17179869185'})[0] == 413
        assert s.request('HEAD', '/files/../store.lock')[0] == 404
        passed('overflow, size limit and path traversal rejected')
        owner = subprocess.run([str(BINARY), str(store), str(s.port + 1)],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5,
                               env=os.environ | {'MOON_UPLOAD_KEYS': json.dumps({'alice': TEST_KEY})})
        assert owner.returncode != 0
        passed('second process cannot open the same store')
        missing = s.create(3)
        assert s.patch(missing, 0, b'abc')[0] == 204
        (store / missing.rsplit('/', 1)[1] / '0').unlink()
        assert s.request('HEAD', missing)[0] != 200
        passed('missing committed chunk fails closed')
        if (PROJECT / 'tools/node_modules/tus-js-client').exists():
            resume = s.create(2 * 1024 * 1024)
            assert s.patch(resume, 0, b'x' * (1024 * 1024))[0] == 204
            result = subprocess.run(['node', str(PROJECT / 'tools/interop.mjs'),
                                     f'http://127.0.0.1:{s.port}', resume, TEST_KEY],
                                    check=True, capture_output=True, text=True, timeout=30)
            passed('standard tus-js-client create + resume', client_result=json.loads(result.stdout))
            result = subprocess.run(['node', str(PROJECT / 'tools/client-test.mjs'),
                                     f'http://127.0.0.1:{s.port}', TEST_KEY, OTHER_KEY],
                                    check=True, capture_output=True, text=True, timeout=30)
            passed('browser client pause/resume and identity guards', client_result=json.loads(result.stdout))
    finally:
        s.stop()

    limited = Server(output / 'limits', limits={'MOON_UPLOAD_MAX_BYTES': '1048576', 'MOON_UPLOAD_MAX_CHUNK': '1024', 'MOON_UPLOAD_QUOTA_BYTES': '1048576', 'MOON_UPLOAD_TIMEOUT_MS': '200'})
    try:
        p = limited.create(1048576)
        assert limited.request('POST', '/files', b'', {'Upload-Length': '1'})[0] == 507
        assert limited.patch(p, 0, b'z' * 1025)[0] == 413
        sock = socket.create_connection(('127.0.0.1', limited.port))
        sock.sendall((f'PATCH {p} HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {TEST_KEY}\r\nTus-Resumable: 1.0.0\r\nUpload-Offset: 0\r\nContent-Type: application/offset+octet-stream\r\nContent-Length: 1024\r\n\r\nx').encode())
        sock.settimeout(3)
        response = http.client.HTTPResponse(sock)
        response.begin()
        assert response.status == 408
        response.close(); sock.close()
        assert limited.offset(p) == 0
        assert limited.patch(p, 0, b'z' * 1024)[0] == 204
        passed('quota, chunk limit and slow-body timeout preserve upload state')
    finally:
        limited.stop()

    for stage in ['staged', 'installed', 'committed']:
        store = output / ('crash-' + stage)
        s = Server(store)
        p = s.create(6)
        assert s.patch(p, 0, b'abc')[0] == 204
        s.stop()
        s = Server(store, stage)
        errors = []
        def upload():
            try:
                s.patch(p, 3, b'def')
            except (OSError, http.client.HTTPException) as e:
                errors.append(type(e).__name__)
        t = threading.Thread(target=upload)
        t.start()
        deadline = time.monotonic() + 10
        marker = store / 'failpoint.ready'
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(.01)
        assert marker.exists(), stage
        if stage == 'staged':
            assert s.patch(p, 3, b'XYZ')[0] == 409
            passed('concurrent PATCH rejected while upload is busy')
        s.stop(kill=True)
        t.join(timeout=5)
        assert not t.is_alive()
        s = Server(store)
        try:
            expected = 6 if stage == 'committed' else 3
            assert s.offset(p) == expected
            if expected == 3:
                assert s.patch(p, 3, b'def')[0] == 204
            assert s.download_hash(p) == (6, hashlib.sha256(b'abcdef').hexdigest())
            passed('SIGKILL at ' + stage, recovered_offset=expected, client_errors=errors)
        finally:
            s.stop()

    if big_mib:
        size = big_mib * 1024 * 1024
        source = output / 'large-source.bin'
        digest = hashlib.sha256()
        with open(source, 'wb') as f:
            for i in range(big_mib):
                block = i.to_bytes(8, 'little') + hashlib.shake_256(str(i).encode()).digest(1024 * 1024 - 8)
                f.write(block)
                digest.update(block)
        store = output / 'large'
        s = Server(store)
        p = s.create(size)
        started = time.monotonic()
        rss_samples = []
        offset = 0
        try:
            with open(source, 'rb') as f:
                while block := f.read(8 * 1024 * 1024):
                    code, h, _ = s.patch(p, offset, block)
                    assert code == 204, (offset, code)
                    offset += len(block)
                    assert int(h['Upload-Offset']) == offset
                    if offset % (128 * 1024 * 1024) == 0:
                        rss = int(subprocess.check_output(['ps', '-o', 'rss=', '-p', str(s.process.pid)]))
                        rss_samples.append({'offset': offset, 'rss_kib': rss})
                        print('LARGE', offset // (1024 * 1024), 'MiB', 'RSS', rss, 'KiB', flush=True)
                    if offset == 256 * 1024 * 1024:
                        sock = partial_request(s, p, offset)
                        s.stop(kill=True)
                        sock.close()
                        s = Server(store)
                        assert s.offset(p) == offset
            actual_size, actual_hash = s.download_hash(p)
            assert (actual_size, actual_hash) == (size, digest.hexdigest())
            s.stop(kill=True)
            s = Server(store)
            assert s.offset(p) == size
            assert s.download_hash(p) == (size, digest.hexdigest())
            passed('large actual file upload + interrupted request + restart + SHA256',
                   bytes=size, sha256=digest.hexdigest(), elapsed_seconds=round(time.monotonic()-started, 2),
                   rss_samples=rss_samples, max_sampled_rss_kib=max(x['rss_kib'] for x in rss_samples))
        finally:
            s.stop()
        source.unlink()  # Only our generated source fixture; uploaded data and evidence remain.

    return {'passed': True, 'checks': checks, 'big_mib': big_mib,
            'scope': 'local single-process SIGKILL recovery; not power-loss durability',
            'platform': os.uname().sysname}


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--big-mib', type=int, default=1280)
    ap.add_argument('--output', type=Path, default=PROJECT / 'output' / time.strftime('%Y%m%d-%H%M%S'))
    args = ap.parse_args()
    if args.big_mib != 0 and args.big_mib < 128:
        ap.error('--big-mib must be 0 or at least 128 (memory sampling interval)')
    if not (PROJECT / 'tools/node_modules/tus-js-client').exists():
        ap.error('run npm ci --prefix tools --ignore-scripts before verification')
    args.output.mkdir(parents=True, exist_ok=False)
    try:
        report = verify(args.output, args.big_mib)
    except BaseException as e:
        (args.output / 'failure.json').write_text(json.dumps({'passed': False, 'error': repr(e)}, indent=2))
        raise
    (args.output / 'verification.json').write_text(json.dumps(report, indent=2))
    print('REPORT', args.output / 'verification.json', flush=True)
