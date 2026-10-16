#!/usr/bin/env python3
"""Generate docs with MoonDocKit; SIGKILL/resume public MoonRelay API delivery.

Uses registry dependencies in an isolated, out-of-repository consumer. Writes
only a fresh run directory at the supplied SSH remote parent. No upstream edits
or deployment/service configuration changes are made.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
import re
import posixpath
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', required=True)
    parser.add_argument('--remote-parent', required=True)
    parser.add_argument('--remote-bin', required=True)
    parser.add_argument('--ssh-config', type=Path)
    parser.add_argument('--moon', default=os.environ.get('MOON', 'moon'))
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    run_id = 'docsite-' + dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    out = (args.output or REPO / 'output' / run_id).resolve()
    out.mkdir(parents=True, exist_ok=False)
    work = Path(tempfile.mkdtemp(prefix='moonrelay-docsite-'))
    app = work / 'app'
    shutil.copytree(REPO / 'examples/docsite-delivery', app)
    # There is deliberately no moon.work, path dependency, or local library copy.
    assert not (work / 'moon.work').exists()
    moon = shutil.which(args.moon) or str(Path(args.moon).resolve())
    events = []

    def run(command, label, cwd=None):
        start = time.monotonic()
        result = subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=600)
        (out / (label + '.log')).write_text(result.stdout)
        events.append({'step': label, 'exit_code': result.returncode,
                       'seconds': round(time.monotonic() - start, 3)})
        print(label, result.returncode, flush=True)
        if result.returncode:
            raise RuntimeError(label + ': ' + result.stdout[-3000:])
        return result.stdout

    run([moon, 'update'], 'registry-update', app)
    run([moon, 'check', '--target', 'native', '--deny-warn'], 'consumer-check', app)
    dependency_tree = run([moon, 'tree'], 'registry-tree', app)
    assert 'Estrella-11/moondockit@0.6.0' in dependency_tree
    assert 'kaigeliang/upload@0.4.0' in dependency_tree
    run([moon, 'build', '--target', 'native', '--release'], 'consumer-build', app)
    executables = list((app / '_build/native/release/build').glob('*.exe'))
    assert len(executables) == 1, executables
    executable = str(executables[0])
    sources = work / 'sources'
    sources.mkdir()
    source_map = {'overview.md': 'README.md', 'http-guide.md': 'docs/cli.md',
                  'maintenance.md': 'docs/maintenance.md',
                  'releases.md': 'docs/releases.md', 'references.md': 'docs/references.md'}
    for name, relative in source_map.items():
        text = (REPO / relative).read_text()
        # Preserve working source links when Markdown moves to a standalone site.
        def source_link(match):
            image, label, target = match.groups()
            if target.startswith(('https://', 'http://', '#', 'mailto:')):
                return match.group(0)
            path, sep, anchor = target.partition('#')
            path = posixpath.normpath(posixpath.join(posixpath.dirname(relative), path))
            base = 'https://raw.githubusercontent.com/kaigeliang/moonbit-upload/' if image else 'https://github.com/kaigeliang/moonbit-upload/blob/'
            commit = subprocess.check_output(['git','rev-parse','HEAD'], cwd=REPO, text=True).strip()
            return image + '[' + label + '](' + base + commit + '/' + path + (sep+anchor if sep else '') + ')'
        text = re.sub(r'(!?)\[([^\]]+)\]\(([^)]+)\)', source_link, text)
        (sources / name).write_text(text)
    site = out / 'site'
    run([executable, 'build', str(sources), str(site)], 'generate-site')
    assert (site / 'index.html').is_file()
    files = sorted(p.name for p in site.iterdir() if p.is_file())
    expected = {name: {'bytes': (site/name).stat().st_size, 'sha256': sha(site/name)} for name in files}
    (out / 'expected-files.json').write_text(json.dumps(expected, indent=2) + '\n')
    ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15']
    if args.ssh_config:
        ssh += ['-F', str(args.ssh_config.resolve())]
    remote = args.remote_parent.rstrip('/') + '/' + run_id
    assert remote.startswith('/') and '..' not in remote.split('/')
    # mkdir without -p refuses to reuse an existing target.
    run([*ssh, args.host, shlex.join(['mkdir', remote])], 'remote-create')
    returned = out / 'returned'
    checkpoint = out / 'committed.checkpoint'
    common = [executable, 'deliver', str(site), args.host+':'+remote,
              str(returned), args.remote_bin,
              str(args.ssh_config.resolve()) if args.ssh_config else '-']
    with (out/'interrupted.log').open('w') as log:
        process = subprocess.Popen([*common, str(checkpoint)], stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            deadline = time.monotonic() + 180
            while not checkpoint.exists():
                if process.poll() is not None:
                    raise RuntimeError('Consumer exited before checkpoint: ' + (out/'interrupted.log').read_text())
                if time.monotonic() > deadline:
                    raise TimeoutError('First committed file checkpoint')
                time.sleep(.1)
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=10)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=10)
    assert process.returncode == -signal.SIGKILL
    first = checkpoint.read_text()
    assert first in expected and not Path(str(returned)+'.receipt.json').exists()
    print('SIGKILL after committed file:', first, flush=True)
    run([*common, '-'], 'resume-delivery')
    delivery = json.loads(Path(str(returned)+'.receipt.json').read_text())
    assert delivery['complete'] and len(delivery['files']) == len(expected)
    prior = next(f for f in delivery['files'] if f['path'] == first)
    assert int(prior['initial_offset']) == int(prior['length']) and int(prior['advanced_bytes']) == 0, 'Committed file did not resume at full offset'
    assert set(p.name for p in returned.iterdir() if p.is_file()) == set(expected)
    for name, info in expected.items():
        assert sha(returned/name) == info['sha256'], name
    remote_code = "import pathlib,sys,hashlib,json;p=pathlib.Path(sys.argv[1]);print(json.dumps({f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in p.iterdir() if f.is_file()}))"
    remote_hashes = json.loads(run([*ssh, args.host, shlex.join(['python3','-c',remote_code,remote])], 'remote-independent-hashes'))
    assert remote_hashes == {name: info['sha256'] for name, info in expected.items()}
    package_sources = {}
    for module in ['Estrella-11/moondockit', 'kaigeliang/upload']:
        root = app / '.mooncakes' / module
        package_sources[module] = {str(f.relative_to(root)): sha(f) for f in sorted(root.rglob('*.mbt'))}
    receipt = {'passed': True, 'run_id': run_id, 'timestamp_utc': dt.datetime.now(dt.timezone.utc).isoformat(),
               'integration': 'MoonDocKit library -> generated documentation -> MoonRelay public API -> Linux -> return verification',
               'dependencies': {'Estrella-11/moondockit':'0.6.0','kaigeliang/upload':'0.4.0','moonbitlang/async':'0.22.4'},
               'registry_consumer_outside_repository': True, 'workspace_override': False,
               'third_party_adoption_claim': False, 'files': expected, 'file_count':len(expected),
               'bytes':sum(f['bytes'] for f in expected.values()),
               'interruption': {'signal':'SIGKILL','boundary':'after one file was published and remotely verified; before the rest of the batch',
                                'first_committed_file':first,'resumed_initial_offset':prior['initial_offset'],'resumed_progress_advance_bytes':prior['advanced_bytes']},
               'checks':['registry native build','real MoonDocKit generated site','remote full hash verification',
                         'SIGKILL and batch restart','committed file reused','public pull API','independent per-file local and remote SHA-256'],
               'events':events,'generated_package_sources':package_sources,
               'inputs':{relative:sha(REPO/relative) for relative in source_map.values()},
               'integration_sources':{str(f.relative_to(REPO)):sha(f) for f in (REPO/'examples/docsite-delivery').iterdir() if f.is_file()},
               'moon_version':run([moon,'version','--all'],'toolchain').strip(),
               'source_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=REPO,text=True).strip(),
               'working_tree_dirty':bool(subprocess.check_output(['git','status','--porcelain'],cwd=REPO,text=True).strip()),
               'local_workdir':str(work),'remote_directory':remote}
    (out/'verification.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print('PASS:', out/'verification.json', flush=True)


if __name__ == '__main__':
    main()
