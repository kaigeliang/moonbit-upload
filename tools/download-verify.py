#!/usr/bin/env python3
"""Verify HTTP byte ranges and actual interrupted download continuation."""
import hashlib
import http.client
import http.server
import threading
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import verify

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / 'bin' / ('moonrelay.exe' if os.name == 'nt' else 'moonrelay')
verify.BINARY = ROOT / 'bin' / ('moonrelay-server.exe' if os.name == 'nt' else 'moonrelay-server')
out = ROOT / 'output' / time.strftime('download-%Y%m%d-%H%M%S')
out.mkdir(parents=True)
server = verify.Server(out / 'store')
env = dict(os.environ, MOON_UPLOAD_KEY=verify.TEST_KEY)
checks = []
proxy_state = {"drop": False, "ranges": []}


class SlowProxy(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def forward(self):
        upstream = http.client.HTTPConnection('127.0.0.1', server.port, timeout=30)
        try:
            if self.path.endswith('/content'):
                proxy_state['ranges'].append(self.headers.get('Range'))
            sent = 0
            upstream.request(self.command, self.path, headers={k: v for k, v in self.headers.items() if k.lower() != 'host'})
            response = upstream.getresponse()
            self.send_response(response.status)
            for key, value in response.getheaders():
                if key.lower() not in ['connection', 'transfer-encoding']:
                    self.send_header(key, value)
            self.send_header('Connection', 'close')
            self.end_headers()
            if self.command != 'HEAD':
                while chunk := response.read(65536):
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    sent += len(chunk)
                    if proxy_state['drop'] and sent >= 2097152:
                        proxy_state['drop'] = False
                        self.close_connection = True
                        return
                    if self.path.endswith('/content'):
                        time.sleep(.005)
        except (OSError, http.client.HTTPException):
            pass
        finally:
            upstream.close()

    do_GET = forward
    do_HEAD = forward


proxy = http.server.ThreadingHTTPServer(('127.0.0.1', 0), SlowProxy)
proxy.daemon_threads = True
threading.Thread(target=proxy.serve_forever, daemon=True).start()


def cli(*args, ok=True):
    p = subprocess.run([str(CLI), *map(str, args)], env=env, capture_output=True, timeout=120)
    assert (p.returncode == 0) == ok, (p.returncode, p.stderr[-2000:])
    return p


def interrupted(url, target):
    p = subprocess.Popen([str(CLI), 'pull', url, str(target), '--sha256', sha], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        buffer = b''
        while True:
            byte = p.stderr.read(1)
            assert byte, (p.poll(), buffer[-1000:])
            buffer = (buffer + byte)[-2048:]
            if b'download ' in buffer and b'1048576/' in buffer:
                inventory = json.loads(cli('tasks', target.parent).stdout)
                task = next(task for task in inventory['tasks'] if Path(task['target']) == target)
                assert task['active'] and task['status'] == 'active', task
                cli('clean', target, ok=False)
                p.kill()
                p.wait(timeout=10)
                break
    finally:
        if p.poll() is None:
            p.kill()
            p.wait(timeout=10)
        p.stdout.close()
        p.stderr.close()
    part = Path(str(target) + '.part')
    assert 0 < part.stat().st_size < len(data)
    assert not target.exists()
    return part


try:
    data = bytes(range(256)) * (32 * 4096)
    sha = hashlib.sha256(data).hexdigest()
    source = out / 'source.bin'
    source.write_bytes(data)
    receipt = json.loads(cli('push', source, f'http://127.0.0.1:{server.port}').stdout)
    path = receipt['path']
    url = f'http://127.0.0.1:{proxy.server_port}' + path
    code, headers, body = server.request('GET', path + '/content', headers={'Range': 'bytes=8388600-'})
    assert code == 206 and body == data[8388600:] and headers['Content-Range'] == f'bytes 8388600-{len(data)-1}/{len(data)}'
    for invalid in [f'bytes={len(data)}-', 'bytes=0-5', 'bytes=-10', 'bytes=0-,2-']:
        assert server.request('GET', path + '/content', headers={'Range': invalid})[0] == 416
    checks.append('bounded byte-range download crosses storage chunks and rejects invalid ranges')
    target = out / 'download.bin'
    part = interrupted(url, target)
    prefix = part.stat().st_size
    # Restart the actual server; persistent remote and local identities must survive.
    port = server.port
    server.stop()
    server = verify.Server(out / 'store', port=port)
    result = cli('pull', url, target, '--sha256', sha)
    assert f'{prefix}/{len(data)}'.encode() in result.stderr
    assert hashlib.sha256(target.read_bytes()).hexdigest() == sha
    checks.append('actual killed download resumes nonzero prefix after server restart and verifies full hash')
    cli('pull', url, target, '--sha256', sha, ok=False)
    checks.append('existing final destination never overwritten')
    damaged = out / 'damaged.bin'
    part = interrupted(url, damaged)
    with part.open('r+b') as f:
        f.write(b'BAD')
    cli('pull', url, damaged, '--sha256', sha, ok=False)
    assert not damaged.exists()
    checks.append('corrupt retained prefix cannot pass final hash or publish')
    mismatch = out / 'mismatch.bin'
    part = interrupted(url, mismatch)
    before = part.read_bytes()
    cli('pull', url, mismatch, '--sha256', '0' * 64, ok=False)
    assert part.read_bytes() == before and not mismatch.exists()
    checks.append('changed trusted hash rejects identity reuse before appending')
    unidentified = out / 'unidentified.bin'
    Path(str(unidentified) + '.part').write_bytes(b'keep')
    cli('pull', url, unidentified, '--sha256', sha, ok=False)
    assert Path(str(unidentified) + '.part').read_bytes() == b'keep'
    checks.append('unidentified existing partial file is preserved and rejected')
    reconnect = out / 'reconnect.bin'
    proxy_state['ranges'].clear()
    proxy_state['drop'] = True
    cli('pull', url, reconnect, '--sha256', sha)
    assert hashlib.sha256(reconnect.read_bytes()).hexdigest() == sha
    assert len(proxy_state['ranges']) >= 2 and any(r != 'bytes=0-' for r in proxy_state['ranges']), proxy_state
    checks.append('truncated HTTP response automatically reconnects using the retained nonzero range')
    empty = out / 'empty' 
    empty.touch()
    r = json.loads(cli('push', empty, f'http://127.0.0.1:{server.port}').stdout)
    cli('pull', f'http://127.0.0.1:{server.port}' + r['path'], out / 'empty-copy', '--sha256', hashlib.sha256(b'').hexdigest())
    assert (out / 'empty-copy').read_bytes() == b''
    checks.append('zero-byte HTTP file download succeeds')
    assert server.process.poll() is None, server.process.returncode
    checks.append('HTTP service survives repeated client cancellation and truncated responses')
    checks.append('active native HTTP download lock is reported and prevents cleanup')
    (out / 'verification.json').write_text(json.dumps({'passed': True, 'checks': checks}, indent=2) + '\n')
    for check in checks:
        print('PASS', check)
    print(out / 'verification.json')
finally:
    proxy.shutdown()
    proxy.server_close()
    server.stop()
