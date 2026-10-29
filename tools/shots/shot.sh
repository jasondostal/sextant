#!/bin/zsh
# shot.sh OUT.png [launch args…] — launch the Mac build with fixed view
# arguments, wait for it to draw, screenshot its window, quit.
# CONFIG=Debug|Release (default Release), WAIT=seconds before the shot.
set -e
out=$1; shift
here=${0:A:h}
app=${here:h:h}/DerivedData/Build/Products/${CONFIG:-Release}/Sky.app
pkill -x Sky 2>/dev/null || true
open -n "$app" --args "$@"
for i in {1..40}; do id=$(swift "$here/winid.swift" Sky 2>/dev/null); [[ -n $id ]] && break; sleep 0.25; done
sleep ${WAIT:-1.5}
screencapture -o -x -l"$id" "$out"
pkill -x Sky || true
echo "$out"
