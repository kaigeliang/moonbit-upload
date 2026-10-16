#!/usr/bin/env python3
"""Normalize platform sidecars and verify every archive before publishing sums."""
import hashlib
from pathlib import Path
import re
import sys


def main():
    root = Path(sys.argv[1]).resolve()
    entries = {}
    for sidecar in sorted(root.glob('*.sha256')):
        for line in sidecar.read_text(encoding='ascii').splitlines():
            parts = line.split()
            if len(parts) != 2 or not re.fullmatch('[0-9a-f]{64}', parts[0]):
                raise SystemExit('Invalid checksum row in ' + sidecar.name)
            digest, name = parts
            if not re.fullmatch('[A-Za-z0-9_.-]+', name) or name in entries:
                raise SystemExit('Invalid or duplicate archive name: ' + name)
            if not name.endswith(('.tar.gz', '.zip')):
                raise SystemExit('Unexpected archive type: ' + name)
            actual = hashlib.sha256((root / name).read_bytes()).hexdigest()
            if actual != digest:
                raise SystemExit('Archive checksum mismatch: ' + name)
            entries[name] = digest
    if not entries:
        raise SystemExit('No archive checksums found')
    manifest = ''.join(f'{entries[name]}  {name}\n' for name in sorted(entries))
    (root / 'SHA256SUMS').write_text(manifest, encoding='ascii', newline='\n')
    print('Verified', len(entries), 'archives; wrote LF-only SHA256SUMS')


if __name__ == '__main__':
    main()
