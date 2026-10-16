#!/usr/bin/env python3
"""Recursive transfer behavior checks using a local SSH process shim."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / 'bin/moonrelay'
out = ROOT / 'output' / time.strftime('tree-%Y%m%d-%H%M%S')
out.mkdir(parents=True)
shimdir = out / 'shim'
shimdir.mkdir()
shim = shimdir / 'ssh'
shim.write_text('#!/usr/bin/env python3\nimport os,shlex,sys\na=shlex.split(sys.argv[-1]);os.execv(a[0],a)\n')
shim.chmod(0o755)
env = dict(os.environ, PATH=str(shimdir) + os.pathsep + os.environ['PATH'])
checks = []


def run(*args, ok=True):
    p = subprocess.run([str(CLI), *map(str, args), '--remote-bin', str(CLI)], env=env, capture_output=True, timeout=120)
    assert (p.returncode == 0) == ok, (args, p.stderr[-2000:], p.stdout)
    return json.loads(p.stdout) if p.stdout else None


def equal_files(source, target):
    for file in source.rglob('*'):
        dest = target / file.relative_to(source)
        if file.is_dir():
            assert dest.is_dir(), dest
        else:
            assert hashlib.sha256(dest.read_bytes()).digest() == hashlib.sha256(file.read_bytes()).digest(), dest


source = out / 'source'
(source / 'empty').mkdir(parents=True)
(source / 'nested space').mkdir()
(source / 'a.txt').write_text('hello')
(source / 'nested space' / '中文.txt').write_text('MoonRelay')
(source / 'zero').touch()
(source / 'large.bin').write_bytes(bytes(range(256)) * (32 * 4096))
remote = out / 'remote'
# Kill the client after a committed file prefix, then resume the entire directory.
args = [str(CLI), 'push', str(source), 'test:' + str(remote), '--recursive', '--remote-bin', str(CLI)]
p = subprocess.Popen(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
try:
    buffer = b''
    while True:
        byte = p.stderr.read(1)
        assert byte, (p.poll(), buffer[-1000:])
        buffer = (buffer + byte)[-4096:]
        if b'tree-push' in buffer:
            # Wait for the large file to have committed one chunk.
            state = Path(str(remote / 'large.bin') + '.moonrelay/1/manifest.json')
            if state.exists() and int(json.loads(state.read_text())['offset']) >= 8388608:
                os.killpg(p.pid, signal.SIGKILL)
                p.wait(timeout=10)
                break
finally:
    if p.poll() is None:
        os.killpg(p.pid, signal.SIGKILL)
        p.wait(timeout=10)
    p.stdout.close()
    p.stderr.close()
receipt = run('push', source, 'test:' + str(remote), '--recursive')
assert receipt['complete'] and receipt['files'] == 4 and receipt['skipped'] >= 1, receipt
equal_files(source, remote)
checks.append('directory push resumes committed files and chunks, preserves empty dirs and Unicode paths')
receipt = run('push', source, 'test:' + str(remote), '--recursive')
assert receipt['skipped'] == 4, receipt
checks.append('repeated directory push skips every verified completed file')
local = out / 'download'
p = subprocess.Popen([str(CLI), 'pull', 'test:' + str(remote), str(local), '--recursive', '--remote-bin', str(CLI)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
try:
    buffer = b''
    while True:
        byte = p.stderr.read(1)
        assert byte, (p.poll(), buffer[-1000:])
        buffer = (buffer + byte)[-4096:]
        state = Path(str(local / 'large.bin') + '.moonrelay/1/manifest.json')
        if b'tree-pull' in buffer and state.exists() and int(json.loads(state.read_text())['offset']) >= 8388608:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait(timeout=10)
            break
finally:
    if p.poll() is None:
        os.killpg(p.pid, signal.SIGKILL)
        p.wait(timeout=10)
    p.stdout.close()
    p.stderr.close()
receipt = run('pull', 'test:' + str(remote), local, '--recursive')
assert receipt['complete'] and receipt['files'] == 4, receipt
equal_files(source, local)
receipt = run('pull', 'test:' + str(remote), local, '--recursive')
assert receipt['skipped'] == 4, receipt
checks.append('directory pull and repeated pull verify managed files without copying internal state')
(remote / 'a.txt').write_text('damaged')
failed = run('push', source, 'test:' + str(remote), '--recursive', ok=False)
assert failed['failed'] == 1 and failed['failed_paths'] == ['a.txt'] and failed['files'] == 3, failed
assert int(failed['bytes']) == sum(f.stat().st_size for f in source.rglob('*') if f.is_file()) - 5, failed
assert (remote / 'a.txt').read_text() == 'damaged'
(remote / 'a.txt').write_text('hello')
checks.append('per-file failure returns nonzero and precise receipt while other verified files finish')
(source / 'a.txt').write_text('changed')
run('push', source, 'test:' + str(remote), '--recursive', ok=False)
assert (remote / 'a.txt').read_text() == 'hello'
checks.append('changed source manifest rejected without overwriting destination')
conflict = out / 'conflict'
conflict.mkdir()
(conflict / 'a.txt').write_text('keep')
run('push', source, 'test:' + str(conflict), '--recursive', ok=False)
assert (conflict / 'a.txt').read_text() == 'keep'
checks.append('unrelated existing destination file rejected')
(source / 'link').symlink_to(source / 'a.txt')
run('push', source, 'test:' + str(out / 'symlink-dest'), '--recursive', ok=False)
(source / 'link').unlink()
linked = out / 'linked'
linked.symlink_to(remote, target_is_directory=True)
run('pull', 'test:' + str(remote), linked, '--recursive', ok=False)
checks.append('source and destination symlinks rejected')
(out / 'verification.json').write_text(json.dumps({'passed': True, 'checks': checks}, indent=2) + '\n')
for check in checks:
    print('PASS', check)
print(out / 'verification.json')
