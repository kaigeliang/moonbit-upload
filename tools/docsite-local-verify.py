#!/usr/bin/env python3
"""Reproduce the real-library case with a fixture-owned loopback SSH daemon."""
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parents[1]
Fixture = runpy.run_path(str(repo / 'tools/ssh-fixture.py'))['Fixture']
root = Path(tempfile.mkdtemp(prefix='moonrelay-docsite-sshd-'))
fixture = Fixture(root / 'ssh')
try:
    subprocess.run([sys.executable, str(repo / 'tools/docsite-case.py'),
                    '--host', 'local-test', '--remote-parent', str(root),
                    '--remote-bin', str(repo / 'bin/moonrelay'),
                    '--ssh-config', str(fixture.client_config)], cwd=repo, check=True)
finally:
    fixture.close()
