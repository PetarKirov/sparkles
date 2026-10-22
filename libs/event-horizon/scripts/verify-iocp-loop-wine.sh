#!/usr/bin/env bash
# Build and run the FULL EventLoop!IocpBackend fiber echo under Wine — the
# loop-integration gate for the IOCP peer backend. Where verify-iocp-wine.sh
# drives the raw backend's data path, this drives the whole stack — tier-A loop
# + tier-B fiber scheduler + the io recv/send verbs — through the IOCP backend
# on one completion port. accept (AcceptEx), connect (ConnectEx), recv and send
# ALL run through the loop + fibers — full parity with the kqueue backend.
#
# Must run inside a win32 dev shell whose ldc2 is LLD-integrated (see
# verify-iocp-wine.sh for the prerequisite):
#
#     nix develop .#win32 -c libs/event-horizon/scripts/verify-iocp-loop-wine.sh
#
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
exp="$(find "$HOME/.dub/packages/expected" -name expected.d -path '*source*' | sort -V | tail -1)"
exp_src="$(dirname "$exp")"

work="$(mktemp -d)"
export WINEPREFIX="$work/wine"
trap 'wineserver -k 2>/dev/null || true; wineserver -w 2>/dev/null || true; rm -rf "$work"' EXIT
cd "$work"

echo ">> cross-compiling the full EventLoop!IocpBackend fiber echo ..."
# `-i` compiles whatever the echo imports, so the closure follows the code
# instead of a hand-kept file list.
win32-ldc2 -preview=in -preview=dip1000 -g -i \
  -I"$repo/libs/event-horizon/src" \
  -I"$repo/libs/event-horizon-sys/src" \
  -I"$repo/libs/base/src" \
  -I"$repo/libs/metadata/src" \
  -I"$repo/libs/reflection/src" \
  -I"$repo/libs/test-runner/src" \
  -I"$exp_src" \
  "$repo/libs/event-horizon/scripts/echo-iocp-win.d" \
  -of=echowin.exe

echo ">> running under Wine ..."
WINEDEBUG=-all timeout 60 wine echowin.exe
echo ">> EventLoop!IocpBackend fiber echo verified under Wine."
