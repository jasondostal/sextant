#!/bin/zsh
# shot.sh OUT.png [launch args…] — launch the Mac build with fixed view
# arguments, wait for it to draw, screenshot its window, quit.
# CONFIG=Debug|Release (default Release), WAIT=seconds before the shot,
# SIZE=WxH resizes the window first (e.g. SIZE=430x880 for portrait).
set -e
out=$1; shift
here=${0:A:h}
app=${here:h:h}/DerivedData/Build/Products/${CONFIG:-Release}/Sky.app
pkill -x Sky 2>/dev/null || true
open -n "$app" --args "$@"
for i in {1..40}; do id=$(swift "$here/winid.swift" Sextant 2>/dev/null); [[ -n $id ]] && break; sleep 0.25; done
if [[ -n $SIZE ]]; then
  osascript -e "tell application \"System Events\" to tell process \"Sextant\" to set size of window 1 to {${SIZE%x*}, ${SIZE#*x}}"
fi
sleep ${WAIT:-1.5}
screencapture -o -x -l"$id" "$out"
pkill -x Sky || true
echo "$out"
