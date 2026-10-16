#!/usr/bin/env python3
"""Run real SSH upload/download interruption checks against an installed peer.

Creates new files under --remote-dir; never overwrites or removes existing data.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1048576), b''):
            h.update(chunk)
    return h.hexdigest()


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--host', required=True)
    p.add_argument('--remote-dir', required=True)
    p.add_argument('--remote-bin', required=True)
    p.add_argument('--ssh-config')
    p.add_argument('--resume-output', type=Path)
    p.add_argument('--cli', type=Path, default=Path('bin/moonrelay'))
    p.add_argument('--big-mib', type=int, default=1280)
    a = p.parse_args()
    if a.big_mib < 32:
        p.error('Use at least 32 MiB to exercise partial transfer')
    out = a.resume_output or Path('output') / time.strftime('cross-machine-%Y%m%d-%H%M%S')
    out.mkdir(parents=True, exist_ok=a.resume_output is not None)
    cli = str(a.cli.resolve())
    source = out / 'source.bin'
    if a.resume_output is None:
        with source.open('wb') as f:
            for i in range(a.big_mib):
                f.write(hashlib.shake_256(('moonrelay-cross-machine-' + str(i)).encode()).digest(1048576))
    elif not (out / 'push-interrupted.log').exists():
        raise RuntimeError('Resume requires the original interrupted upload log')
    expected = digest(source)
    endpoint = a.host + ':' + a.remote_dir.rstrip('/') + '/transfer-' + out.name + '.bin'
    common = ['--remote-bin', a.remote_bin]
    if a.ssh_config:
        common += ['--ssh-config', str(Path(a.ssh_config).resolve())]
    checks = []

    def run(*argv):
        result = subprocess.run([cli, *map(str, argv), *common], capture_output=True, timeout=1800)
        (out / ('last-' + str(argv[0]) + '.log')).write_bytes(result.stderr)
        if result.returncode:
            raise RuntimeError(result.stderr[-2000:].decode(errors='replace'))
        return json.loads(result.stdout)

    def interrupt(stage, *argv):
        if os.name == 'nt':
            raise RuntimeError('Process-group interruption currently requires a Unix test driver')
        with (out / (stage + '-interrupted.stdout')).open('wb') as stdout, (out / (stage + '-interrupted.log')).open('wb') as log:
            process = subprocess.Popen([cli, *map(str, argv), *common], stdout=stdout, stderr=subprocess.PIPE, start_new_session=True)
            buffer = b''
            try:
                while True:
                    byte = process.stderr.read(1)
                    if not byte:
                        raise RuntimeError('Transfer ended before interruption: ' + buffer[-1000:].decode(errors='replace'))
                    log.write(byte)
                    buffer = (buffer + byte)[-2048:]
                    if re.search(stage.encode() + rb' \d+% 8388608/', buffer):
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=10)
                        break
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=10)
                process.stderr.close()

    if a.resume_output is None:
        interrupt('push', 'push', source, endpoint)
    before = run('status', endpoint)
    assert 0 < int(before['offset']) < source.stat().st_size, before
    assert not before['complete'], before
    uploaded = run('push', source, endpoint)
    assert uploaded['complete'] and uploaded['sha256'] == expected, uploaded
    remote = run('verify', endpoint, '--sha256', expected)
    assert remote['sha256'] == expected
    checks.append({'name': 'physical SSH upload interrupted then resumed and verified', 'prefix': before, 'result': uploaded})
    print('PASS upload interruption/resume and remote SHA-256', flush=True)
    target = out / 'download.bin'
    interrupt('pull', 'pull', endpoint, target)
    before = run('status', target)
    assert 0 < int(before['offset']) < source.stat().st_size, before
    assert not target.exists()
    downloaded = run('pull', endpoint, target)
    assert downloaded['complete'] and digest(target) == expected
    checks.append({'name': 'physical SSH download interrupted then resumed and verified', 'prefix': before, 'result': downloaded})
    receipt = {'passed': True, 'bytes': source.stat().st_size, 'sha256': expected, 'checks': checks,
               'client': subprocess.check_output([cli, '--version'], text=True).strip(),
               'dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], text=True).strip()),
               'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()}
    (out / 'verification.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print('PASS download interruption/resume and local SHA-256', flush=True)
    print(out / 'verification.json')


if __name__ == '__main__':
    main()
