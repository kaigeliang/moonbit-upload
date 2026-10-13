"""Native Windows client checks with private loopback HTTP fixtures."""
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / 'bin/moonrelay.exe'
KEY = os.urandom(32).hex()
ENV = os.environ | {'MOON_UPLOAD_KEYS': json.dumps({'test': KEY}), 'MOON_UPLOAD_KEY': KEY}

def run(*args, ok=True):
    result = subprocess.run([str(CLI), *map(str, args)], env=ENV, capture_output=True, timeout=180)
    assert (result.returncode == 0) == ok, result.stderr.decode(errors='replace')
    return result

with tempfile.TemporaryDirectory(prefix='moonrelay-windows-') as folder:
    base = Path(folder)
    source = base / 'source with spaces.bin'
    source.write_bytes(bytes(range(256)) * 262144 + b'tail')
    expected = hashlib.sha256(source.read_bytes()).hexdigest()
    assert json.loads(run('hash', source).stdout)['sha256'] == expected
    assert json.loads(run('verify', source, '--sha256', expected).stdout)['sha256'] == expected
    run('verify', source, '--sha256', '0' * 64, ok=False)
    # A drive path must be handled locally, even if it has no restore directory.
    result = run('status', base / 'absent.bin', ok=False)
    assert b'invalid SSH endpoint' not in result.stderr
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    server = subprocess.Popen([str(CLI), 'serve', str(base / 'store'), str(port)], cwd=ROOT, env=ENV,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            assert server.poll() is None, 'HTTP receiver exited'
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=.2):
                    break
            except OSError:
                time.sleep(.1)
        else:
            raise RuntimeError('HTTP receiver readiness timeout')
        receipt = json.loads(run('push', source, f'http://127.0.0.1:{port}').stdout)
        url = f'http://127.0.0.1:{port}' + receipt['path']
        assert int(json.loads(run('status', url).stdout)['offset']) == source.stat().st_size
        destination = base / 'copy with spaces.bin'
        run('pull', url, destination, '--sha256', expected)
        assert hashlib.sha256(destination.read_bytes()).hexdigest() == expected
        run('verify', url, '--sha256', expected)
        print('PASS: Windows native hash, drive paths, HTTP serve/upload/status/download/verify (64 MiB)', flush=True)
    finally:
        # serve launches its own receiver; terminate the owned process tree on Windows.
        subprocess.run(['taskkill', '/PID', str(server.pid), '/T', '/F'], capture_output=True)
        server.wait(timeout=15)
