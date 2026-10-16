#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
"${MOON:-moon}" build --target native --release
mkdir -p bin
# Replace the inode: overwriting an executing/signed Mach-O can trigger SIGKILL.
for program in moon-upload moonrelay moonrelay-server; do
  case "$program" in
    moon-upload) package=upload ;;
    moonrelay) package=moonrelay ;;
    moonrelay-server) package=server ;;
  esac
  cp "_build/native/release/build/cmd/$package/$package.exe" "bin/$program.new"
  chmod 755 "bin/$program.new"
  mv -f "bin/$program.new" "bin/$program"
done
printf '%s\n' "CLI ready: $project_dir/bin/moon-upload"
