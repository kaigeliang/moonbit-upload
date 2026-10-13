#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture_dir=$(mktemp -d "$project_dir/output/consumer-XXXXXX")
cp -R "$project_dir/examples/library-consumer" "$fixture_dir/consumer"
python3 - "$fixture_dir" "$project_dir" <<'PY'
import json,sys
from pathlib import Path
Path(sys.argv[1]+'/moon.work').write_text('members = ['+json.dumps(sys.argv[2])+', "./consumer"]\n')
PY
cd "$fixture_dir/consumer"
"${MOON:-moon}" run . --target native --release -- "$@"
