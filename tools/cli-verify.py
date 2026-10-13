#!/usr/bin/env python3
"""Independent native CLI tests; only test-owned subprocesses and paths are touched."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import verify

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / '_build/native/release/build/cmd/upload/upload.exe'
verify.BINARY = ROOT / '_build/native/release/build/cmd/server/server.exe'
ENV = os.environ | {'MOON_UPLOAD_KEY': verify.TEST_KEY}


def run(args, ok=True, env=ENV, timeout=600):
    p = subprocess.run([str(CLI), *map(str, args)], env=env, capture_output=True, timeout=timeout)
    assert (p.returncode == 0) == ok, (args, p.returncode, p.stderr[-1000:].decode(errors='replace'))
    return p


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--big-mib', type=int, default=1280)
    parser.add_argument('--output', type=Path, default=ROOT/'output'/time.strftime('cli-%Y%m%d-%H%M%S'))
    args = parser.parse_args()
    out = args.output
    out.mkdir(parents=True)
    checks = []
    def passed(name, **details):
        checks.append({'name': name, 'passed': True, **details})
        print('PASS', name, flush=True)
    s = verify.Server(out/'store')
    url = f'http://127.0.0.1:{s.port}'
    try:
        source = out/'small.bin'
        data = bytes(range(256))*16384 + b'tail'
        source.write_bytes(data)
        expected = hashlib.sha256(data).hexdigest()
        assert run(['hash', source]).stdout.decode().strip() == expected
        receipt_path = out/'receipt.json'
        p = run(['upload', source, '--server', url, '--state', receipt_path])
        receipt = json.loads(p.stdout)
        assert receipt['sha256'] == expected and int(receipt['length']) == len(data)
        assert b'100%' in p.stderr and verify.TEST_KEY not in receipt_path.read_text()
        first = receipt['path']
        assert json.loads(run(['upload', source, '--server', url, '--state', receipt_path]).stdout)['path'] == first
        assert len(list((out/'store').glob('[0-9]*'))) == 1
        passed('native CLI hash, progress, upload verification and completed resume reuse')
        target = out/'download.bin'
        run(['download', first, target, '--server', url, '--receipt', receipt_path])
        assert target.read_bytes() == data
        run(['verify', first, '--server', url, '--sha256', expected])
        passed('download publishes only hash-verified exact bytes and verify command')
        bad = out/'bad.bin'
        run(['download', first, bad, '--server', url, '--sha256', '0'*64], ok=False)
        assert not bad.exists()
        run(['download', first, target, '--server', url, '--sha256', expected], ok=False)
        assert target.read_bytes() == data
        passed('hash mismatch and existing destination never publish or overwrite')
        source.write_bytes(bytes([data[0]^1])+data[1:])
        run(['upload', source, '--server', url, '--state', receipt_path], ok=False)
        assert json.loads(receipt_path.read_text())['path'] == first
        source.write_bytes(data)
        run(['upload', source, '--server', url, '--state', receipt_path], ok=False,
            env=ENV | {'MOON_UPLOAD_KEY': verify.OTHER_KEY})
        passed('same-size content change and wrong owner refuse saved upload')
        forged = out/'forged.json'
        r = receipt | {'path':'https://example.org/steal'}
        forged.write_text(json.dumps(r))
        run(['upload', source, '--server', url, '--state', forged], ok=False)
        run(['verify', first, '--server', url+'/evil', '--sha256', expected], ok=False)
        run(['upload', source, '--server', url, '--state', receipt_path], ok=False, env=ENV | {'MOON_UPLOAD_KEY':''})
        passed('malformed receipt, external paths, invalid origin and missing key rejected')
        empty = out/'empty.bin'; empty.write_bytes(b'')
        run(['upload', empty, '--server', url])
        passed('zero-byte native CLI upload verifies empty SHA256')

        if args.big_mib:
            assert args.big_mib >= 32
            large = out/'large.bin'
            digest = hashlib.sha256()
            with large.open('wb') as f:
                for n in range(args.big_mib):
                    block = n.to_bytes(8,'little') + hashlib.shake_256(str(n).encode()).digest(1048576-8)
                    f.write(block); digest.update(block)
            sha = digest.hexdigest()
            state = out/'large.receipt.json'
            log = (out/'large-cli.log').open('wb')
            client = subprocess.Popen([str(CLI),'upload',str(large),'--server',url,'--state',str(state)],env=ENV,stdout=log,stderr=log)
            try:
                started_deadline=time.monotonic()+10
                while (out/'large-cli.log').stat().st_size==0:
                    assert client.poll() is None
                    assert time.monotonic()<started_deadline
                    time.sleep(.01)
                run(['upload',large,'--server',url,'--state',state],ok=False)
                deadline = time.monotonic()+300
                recovered = 0
                while time.monotonic()<deadline:
                    if state.exists():
                        r=json.loads(state.read_text())
                        recovered=int(json.loads((out/'store'/r['path'].split('/')[-1]/'manifest.json').read_text())['offset'])
                        if recovered >= min(256,args.big_mib//4)*1048576 and recovered < args.big_mib*1048576:
                            break
                    assert client.poll() is None, 'CLI finished before interruption'
                    time.sleep(.01)
                else: raise TimeoutError('CLI did not reach interruption offset')
                client.kill(); client.wait(timeout=10)
                s.stop(kill=True)
                s=verify.Server(out/'store',port=s.port)
                actual=s.offset(r['path'])
                assert recovered <= actual <= recovered+8388608
                recovered=actual
                passed('CLI SIGKILL and service restart preserve committed prefix', offset=recovered)
            finally:
                if client.poll() is None: client.kill(); client.wait(timeout=10)
                log.close()
            # Resume from the same receipt and origin, then restart the server while this CLI is live.
            log=(out/'resume-cli.log').open('wb')
            client=subprocess.Popen([str(CLI),'upload',str(large),'--server',url,'--state',str(state)],env=ENV,stdout=log,stderr=log)
            try:
                deadline=time.monotonic()+300
                while time.monotonic()<deadline:
                    current=int(json.loads((out/'store'/r['path'].split('/')[-1]/'manifest.json').read_text())['offset'])
                    if current>recovered and current<args.big_mib*1048576:
                        s.stop(kill=True)
                        time.sleep(2)
                        s=verify.Server(out/'store',port=s.port)
                        break
                    assert client.poll() is None
                    time.sleep(.01)
                else: raise TimeoutError('no live upload restart window')
                assert client.wait(timeout=600)==0
            finally:
                if client.poll() is None: client.kill(); client.wait(timeout=10)
                log.close()
            assert '重新查询已提交偏移' in (out/'resume-cli.log').read_text()
            assert s.download_hash(r['path'])==(args.big_mib*1048576,sha)
            passed('live CLI automatically reconnects after server restart and verifies large upload',bytes=args.big_mib*1048576,sha256=sha)
            downloaded=out/'large-download.bin'
            run(['download',r['path'],downloaded,'--server',url,'--receipt',state])
            h=hashlib.sha256()
            with downloaded.open('rb') as f:
                while chunk:=f.read(1048576): h.update(chunk)
            assert h.hexdigest()==sha
            passed('native large download matches independent Python SHA256',bytes=downloaded.stat().st_size)
            large.unlink(); downloaded.unlink() # Only our generated test source and verified copy.
    finally:
        s.stop()
    report={'passed':True,'platform':os.uname().sysname,'big_mib':args.big_mib,'checks':checks}
    (out/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print('REPORT',out/'verification.json',flush=True)

if __name__=='__main__': main()
