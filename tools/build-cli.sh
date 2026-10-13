#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
"${MOON:-moon}" build --target native --release
mkdir -p bin
cp _build/native/release/build/cmd/upload/upload.exe bin/moon-upload
cp _build/native/release/build/cmd/moonrelay/moonrelay.exe bin/moonrelay
cp _build/native/release/build/cmd/server/server.exe bin/moonrelay-server
chmod 755 bin/moon-upload bin/moonrelay bin/moonrelay-server
printf '%s\n' "CLI ready: $project_dir/bin/moon-upload"
