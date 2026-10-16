#!/usr/bin/env python3
"""Check cleanup against real persisted transfer state and held receiver locks."""
import hashlib
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import time
import verify

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / 'bin' / ('moonrelay.exe' if os.name == 'nt' else 'moonrelay')
verify.BINARY = ROOT / 'bin' / ('moonrelay-server.exe' if os.name == 'nt' else 'moonrelay-server')
out = ROOT / 'output' / time.strftime('maintenance-%Y%m%d-%H%M%S')
out.mkdir(parents=True)
checks = []


def run(*args, ok=True, env=None):
    p = subprocess.run([str(CLI), *map(str, args)], capture_output=True, env=env, timeout=120)
    assert (p.returncode == 0) == ok, (args, p.returncode, p.stderr[-2000:], p.stdout)
    return json.loads(p.stdout) if p.stdout.startswith(b'{') else p.stdout


def rpc(op, target, data=b'', length=0, sha='', offset=0, count=0):
    header = json.dumps(dict(op=op, path=str(target), length=str(length), sha256=sha,
                            offset=str(offset), count=count, stamp='')).encode()
    p = subprocess.run([str(CLI), 'rpc'], input=struct.pack('>I', len(header)) + header + data,
                       capture_output=True, timeout=60)
    assert p.returncode == 0, p.stderr
    n = struct.unpack('>I', p.stdout[:4])[0]
    return json.loads(p.stdout[4:4+n])


def snapshot(path):
    return {str(f.relative_to(path)): hashlib.sha256(f.read_bytes()).hexdigest()
            for f in path.rglob('*') if f.is_file()}


def create_received(target, data):
    sha = hashlib.sha256(data).hexdigest()
    assert rpc('open', target, length=len(data), sha=sha)['ok']
    for offset in range(0, len(data), 8388608):
        body = data[offset:offset+8388608]
        assert rpc('write', target, body, len(data), sha, offset, len(body))['ok']
    assert rpc('commit', target, length=len(data), sha=sha)['ok']
    return sha


data = bytes(range(256)) * (16 * 4096)
sha = hashlib.sha256(data).hexdigest()
if os.name != 'nt':
    target = out / 'complete.bin'
    sha = create_received(target, data)
    inventory = run('tasks', out)
    task = next(t for t in inventory['tasks'] if Path(t['target']) == target)
    assert task['status'] == 'complete' and int(task['reclaimable_bytes']) >= len(data)
    original_chunks = {p.name: p.read_bytes() for p in (Path(str(target)+'.moonrelay')/'1').iterdir()}
    before = sum(p.stat().st_size for p in Path(str(target)+'.moonrelay').rglob('*') if p.is_file())
    receipt = run('clean', target)
    after = sum(p.stat().st_size for p in Path(str(target)+'.moonrelay').rglob('*') if p.is_file())
    assert int(receipt['reclaimed_bytes']) == before-after > len(data)-1024
    assert hashlib.sha256(target.read_bytes()).hexdigest() == sha
    assert run('status', target)['complete']
    assert rpc('open', target, length=len(data), sha=sha)['info']['complete']
    assert rpc('commit', target, length=len(data), sha=sha)['info']['complete']
    assert int(run('clean', target)['reclaimed_bytes']) == 0
    checks.append('completed SSH cleanup releases payload bytes, preserves final hash and status/reuse, is idempotent')
    # A durable cleanup marker may precede deletion when a process is interrupted.
    checkpoint = Path(str(target)+'.moonrelay')/'1'
    checkpoint.mkdir()
    for name, content in original_chunks.items():
        (checkpoint/name).write_bytes(content)
    task = next(t for t in run('tasks', out)['tasks'] if Path(t['target']) == target)
    assert task['status'] == 'cleaned' and int(task['reclaimable_bytes']) >= len(data)
    assert int(run('clean', target)['reclaimed_bytes']) >= len(data)
    assert run('status', target)['complete']
    checks.append('durable cleanup checkpoint can finish deleting leftover chunks after interruption')

    target.write_bytes(b'changed')
    run('clean', target, ok=False)
    assert not rpc('open', target, length=len(data), sha=sha)['ok']
    checks.append('changed final file cannot be accepted after cleanup')
    partial = out / 'partial.bin'
    assert rpc('open', partial, length=len(data), sha=sha)['ok']
    assert rpc('write', partial, data[:1048576], len(data), sha, 0, 1048576)['ok']
    state = Path(str(partial)+'.moonrelay')
    before = snapshot(state)
    run('clean', partial, ok=False)
    assert snapshot(state) == before
    checks.append('incomplete task cleanup refused without changing committed state')
    request = dict(op='write', path=str(partial), length=str(len(data)), sha256=sha, offset='1048576', count=8388608, stamp='')
    raw = json.dumps(request).encode()
    receiver = subprocess.Popen([str(CLI), 'rpc'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        receiver.stdin.write(struct.pack('>I', len(raw))+raw+b'prefix')
        receiver.stdin.flush()
        deadline = time.monotonic()+10
        while not (state/'1/chunk.pending').exists():
            assert time.monotonic()<deadline and receiver.poll() is None
            time.sleep(.01)
        inventory = run('tasks', out)
        task = next(t for t in inventory['tasks'] if Path(t['target'])==partial)
        assert task['active'] and task['status']=='active'
        run('clean', partial, ok=False)
        assert int(json.loads((state/'1/manifest.json').read_text())['offset'])==1048576
    finally:
        receiver.kill()
        receiver.wait(timeout=10)
        receiver.stdin.close()
        receiver.stdout.close()
        receiver.stderr.close()
    checks.append('actual active receiver lock is visible and blocks cleanup')
    if os.name != 'nt':
        outside = out/'outside'
        outside.mkdir()
        (outside/'keep').write_text('untouched')
        (state/'1/link').symlink_to(outside, target_is_directory=True)
        run('clean', partial, ok=False)
        assert (outside/'keep').read_text()=='untouched'
        inventory = run('tasks', out)
        assert inventory['issues']
        (state/'1/link').unlink()
        checks.append('symlink payload cannot redirect cleanup outside the named task')

    # Build a completed tree through its actual receiver protocol, then clean its exact root.
    tree = out/'tree'
    tree_manifest = {'version': 1, 'entries': [
        {'path': 'empty', 'directory': True, 'length': '0', 'sha256': ''},
        {'path': 'file', 'directory': False, 'length': str(len(data)), 'sha256': sha}]}
    body = json.dumps(tree_manifest).encode()
    assert rpc('tree-open', tree, data=body, count=len(body))['ok']
    create_received(tree/'file', data)
    receipt = run('clean', str(tree) + '/')
    assert receipt['kind']=='ssh-tree' and int(receipt['reclaimed_bytes'])>len(data)-1024
    assert (tree/'empty').is_dir() and (tree/'file').read_bytes()==data
    manifest = rpc('tree-scan', tree)
    assert manifest['ok']
    checks.append('named directory task cleanup preserves contents and empty directories')

server = verify.Server(out/'http-store')
try:
    path = server.create(len(data))
    for offset in range(0, len(data), 8388608):
        assert server.patch(path, offset, data[offset:offset+8388608])[0]==204
    env = dict(os.environ, MOON_UPLOAD_KEY=verify.TEST_KEY)
    downloaded = out/'download.bin'
    url = f'http://127.0.0.1:{server.port}'+path
    run('pull', url, downloaded, '--sha256', sha, env=env)
    task = next(t for t in run('tasks', out)['tasks'] if Path(t['target'])==downloaded)
    assert task['status']=='complete'
    assert int(run('clean', downloaded)['reclaimed_bytes'])>0
    assert downloaded.read_bytes()==data and not Path(str(downloaded)+'.part.json').exists()
    checks.append('HTTP download metadata cleanup preserves verified final data')
    store_inventory = run('store-tasks', server.store)
    assert store_inventory['tasks'][0]['active']
    upload_id = path.split('/')[-1]
    run('store-delete', server.store, upload_id, '--delete-data', ok=False)
    assert server.download_hash(path)==(len(data), sha)
    checks.append('running HTTP store lock blocks upload data deletion')
    port = server.port
    server.stop()
    result = run('store-delete', server.store, upload_id, '--delete-data')
    assert int(result['reclaimed_bytes'])>len(data)-1024
    assert (server.store/upload_id/'deleted.json').exists()
    assert not (server.store/upload_id/'manifest.json').exists()
    assert int(run('store-delete', server.store, upload_id, '--delete-data')['reclaimed_bytes'])==0
    server = verify.Server(out/'http-store', port=port)
    assert server.request('HEAD',path)[0]==404
    new = server.create(0)
    assert new!=path
    assert server.request('HEAD',path)[0]==404
    checks.append('explicit stopped-store deletion frees bytes, keeps tombstone and never reuses old resource ID')
    orphan = server.create(3)
    assert server.patch(orphan, 0, b'abc')[0] == 204
    server.stop()
    orphan_id = orphan.split('/')[-1]
    (server.store/orphan_id/'deleted.json').write_text('{"version":1}')
    server = verify.Server(out/'http-store', port=port)
    assert server.request('HEAD', orphan)[0] == 404
    assert server.create(0) != orphan
    server.stop()
    assert int(run('store-delete', server.store, orphan_id, '--delete-data')['reclaimed_bytes']) > 0
    checks.append('interrupted deletion tombstone hides old data and does not block future resource creation')

finally:
    server.stop()
(out/'verification.json').write_text(json.dumps({'passed':True,'checks':checks},indent=2)+'\n')
for check in checks:
    print('PASS',check)
print(out/'verification.json')
