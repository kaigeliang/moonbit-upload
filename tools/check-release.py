#!/usr/bin/env python3
"""Smoke-test an archive after extraction, including packaged HTTP assets."""
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import tarfile
import tempfile
import time
import urllib.request
import zipfile
import sys

archive = Path(sys.argv[1]).resolve()
expected = Path(str(archive) + '.sha256').read_text().split()[0]
assert hashlib.sha256(archive.read_bytes()).hexdigest() == expected
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    if archive.suffix == '.zip':
        with zipfile.ZipFile(archive) as packed:
            packed.extractall(root)
    else:
        with tarfile.open(archive) as packed:
            packed.extractall(root, filter='data')
    package, = root.iterdir()
    meta = json.loads((package / 'build.json').read_text())
    cli = package / 'bin' / ('moonrelay.exe' if os.name == 'nt' else 'moonrelay')
    assert subprocess.check_output([str(cli), '--version'], text=True).strip() == 'moonrelay ' + meta['version']
    sample = root / 'sample.bin'
    sample.write_bytes(bytes(range(256)) * 4096)
    assert subprocess.check_output([str(cli), 'hash', str(sample)], text=True).strip() == hashlib.sha256(sample.read_bytes()).hexdigest()
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    env = dict(os.environ, MOON_UPLOAD_KEYS=json.dumps({'releasecheck': 'a' * 64}))
    with tempfile.TemporaryFile() as log:
        server = subprocess.Popen([str(cli), 'serve', str(root / 'store'), str(port)], cwd=package, env=env, stdout=log, stderr=log)
        try:
            for attempt in range(100):
                if server.poll() is not None:
                    log.seek(0)
                    raise RuntimeError(log.read().decode())
                try:
                    with urllib.request.urlopen(f'http://127.0.0.1:{port}/', timeout=1) as response:
                        assert b'<html' in response.read().lower()
                    break
                except OSError:
                    time.sleep(.1)
            else:
                raise RuntimeError('Packaged HTTP server did not become ready')
            for asset in ['app.mjs', 'client.mjs', 'style.css']:
                with urllib.request.urlopen(f'http://127.0.0.1:{port}/{asset}', timeout=3) as response:
                    assert response.read()
        finally:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
print('PASS archive checksum, extracted version/hash, packaged HTTP server and web assets')
