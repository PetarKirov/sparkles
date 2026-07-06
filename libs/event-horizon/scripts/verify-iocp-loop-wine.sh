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
eh="$repo/libs/event-horizon/src"
base="$repo/libs/base/src"
ehm="$eh/sparkles/event_horizon"
exp="$(find "$HOME/.dub/packages/expected" -name expected.d -path '*source*' | sort -V | tail -1)"
exp_src="$(dirname "$exp")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"

echo ">> cross-compiling the full EventLoop!IocpBackend fiber echo ..."
win32-ldc2 -preview=in -preview=dip1000 -g \
  -I"$eh" -I"$base" -I"$exp_src" \
  "$repo/libs/event-horizon/scripts/echo-iocp-win.d" \
  "$ehm/errors.d" "$ehm/op.d" "$ehm/buffer.d" "$ehm/net.d" "$ehm/capability.d" \
  "$ehm/cause.d" "$ehm/scope_.d" "$ehm/schedule.d" "$ehm/clock.d" "$ehm/loop.d" \
  "$ehm/sched.d" "$ehm/io.d" "$ehm/backend/concept.d" "$ehm/backend/probe.d" \
  "$ehm/backend/iocp.d" "$ehm/backend/select.d" "$exp_src/expected.d" \
  -of=echowin.exe

echo ">> running under Wine ..."
WINEPREFIX="$(mktemp -d)" WINEDEBUG=-all wine64 echowin.exe
echo ">> EventLoop!IocpBackend fiber echo verified under Wine."
