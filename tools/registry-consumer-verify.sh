#!/bin/sh
# Usage: tools/registry-consumer-verify.sh SOURCE ENDPOINT OUTPUT REMOTE_BINARY SSH_CONFIG
# Requires a compatible installed SSH peer. Fetches the library from Mooncakes.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/moonrelay-registry-XXXXXX")
cp -R "$project_dir/examples/library-consumer" "$fixture_dir/consumer"
cd "$fixture_dir/consumer"
"${MOON:-moon}" update
"${MOON:-moon}" check --target native --deny-warn
"${MOON:-moon}" tree
"${MOON:-moon}" run . --target native --release -- "$@"
printf 'Registry consumer retained at %s\n' "$fixture_dir/consumer"
