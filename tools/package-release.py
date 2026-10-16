#!/usr/bin/env python3
"""Package binaries built on this host; never relabel cross-platform binaries."""
import hashlib
import json
import platform
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    system = {'Darwin': 'macos', 'Linux': 'linux', 'Windows': 'windows'}[platform.system()]
    arch = {'aarch64': 'arm64', 'arm64': 'arm64', 'AMD64': 'x86_64', 'x86_64': 'x86_64'}[platform.machine()]
    version = next(line.split('"')[1] for line in (ROOT / 'moon.mod').read_text().splitlines() if line.startswith('version ='))
    tag = os.environ.get('GITHUB_REF', '')
    if tag.startswith('refs/tags/') and tag != 'refs/tags/v' + version:
        raise SystemExit('Release tag must match moon.mod version')
    suffix = '.exe' if system == 'windows' else ''
    build = ['powershell', '-NoProfile', '-File', str(ROOT / 'tools/build-cli.ps1')] if system == 'windows' else ['sh', str(ROOT / 'tools/build-cli.sh')]
    subprocess.run(build, cwd=ROOT, check=True)
    binary = ROOT / 'bin' / ('moonrelay' + suffix)
    reported = subprocess.check_output([str(binary), '--version'], text=True).strip()
    if reported != 'moonrelay ' + version:
        raise SystemExit('Binary version disagrees with moon.mod: ' + reported)
    name = f'moonrelay-{version}-{system}-{arch}'
    output = ROOT / 'output' / 'release'
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temp:
        stage = Path(temp) / name
        (stage / 'bin').mkdir(parents=True)
        for executable in ['moonrelay', 'moonrelay-server', 'moon-upload']:
            shutil.copy2(ROOT / 'bin' / (executable + suffix), stage / 'bin')
        shutil.copytree(ROOT / 'web', stage / 'web')
        shutil.copy2(ROOT / 'LICENSE', stage)
        (stage / 'INSTALL.txt').write_text(
            'Extract the entire archive. From the extracted directory run:\n'
            f'  ./bin/moonrelay{suffix} --version\n'
            f'  ./bin/moonrelay{suffix} --help\n'
            'For HTTP serve, keep this working directory so bin/ and web/ resolve.\n'
            'For SSH, install a matching platform package at the remote end and use --remote-bin.\n'
            'OpenSSH must be installed separately for SSH transfers.\n', encoding='utf-8')
        metadata = {'version': version, 'platform': system, 'arch': arch,
                    'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                    'dirty': bool(subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=normal'], cwd=ROOT, text=True).strip()),
                    'moon': subprocess.check_output(['moon', 'version', '--all'], text=True).strip()}
        (stage / 'build.json').write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
        archive = output / (name + ('.zip' if system == 'windows' else '.tar.gz'))
        if system == 'windows':
            with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as packed:
                for path in sorted(stage.rglob('*')):
                    if path.is_file():
                        packed.write(path, path.relative_to(stage.parent))
        else:
            with tarfile.open(archive, 'w:gz') as packed:
                packed.add(stage, arcname=name)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        (output / (archive.name + '.sha256')).write_text(f'{digest}  {archive.name}\n', encoding='ascii')
        print(archive)


if __name__ == '__main__':
    main()
