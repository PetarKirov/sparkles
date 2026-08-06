#!/usr/bin/env bash
#
# Install LDC (and the dub it bundles) on a Windows runner, and put it on PATH
# for the rest of the job.
#
# Run this with `shell: bash.exe` — the Git Bash that ships with the CircleCI
# Windows image. Keeping it bash rather than PowerShell is what lets it reuse
# lib/common.sh, and in particular `ci_export`, so the PATH edit reaches later
# steps the same way it does on every other platform.
#
# This is the Windows equivalent of `dlang-community/setup-dlang`, which the
# GitHub Actions workflow still uses; there is no CircleCI orb for D.
#
# Environment:
#   LDC_VERSION  LDC release to install (default 1.41.0 — keep in step with
#                the `compiler:` pin in .github/workflows/ci.yml).
set -euo pipefail

# shellcheck source=ci/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

version=${LDC_VERSION:-1.41.0}
prefix=${LDC_PREFIX:-/c/ldc}
archive="ldc2-${version}-windows-x64.7z"
url="https://github.com/ldc-developers/ldc/releases/download/v${version}/${archive}"
bin="$prefix/ldc2-${version}-windows-x64/bin"

if [ -x "$bin/ldc2.exe" ]; then
  printf 'LDC %s already present at %s\n' "$version" "$bin"
  ci_export PATH "$bin:$PATH"
  exit 0
fi

# LDC publishes Windows builds only as .7z and as an interactive installer, so
# an extractor is required; PowerShell's Expand-Archive handles zip alone.
if ! ci_have 7z; then
  ci_group 'Installing 7-Zip'
  choco install 7zip -y --no-progress
  export PATH="/c/Program Files/7-Zip:$PATH"
  ci_endgroup
fi

ci_group "Installing LDC $version"
mkdir -p "$prefix"
curl --fail --silent --show-error --location --retry 3 "$url" -o "/tmp/$archive"
7z x "/tmp/$archive" -o"$(cygpath -w "$prefix")" -y >/dev/null
rm -f "/tmp/$archive"
ci_endgroup

[ -x "$bin/ldc2.exe" ] || ci_die "LDC did not land at $bin"

ci_export PATH "$bin:$PATH"
"$bin/ldc2.exe" --version | head -n 2
