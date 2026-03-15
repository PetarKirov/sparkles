#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
examples_dir="$root_dir/libs/core-cli/examples"

failed=0

for f in "$examples_dir"/*.d; do
    name=$(basename "$f")

    # term_size.d is interactive (waits for stdin); build-only
    if [ "$name" = "term_size.d" ]; then
        echo -n "Building $name ... "
        if dub build --root "$root_dir" --single "$f" > /dev/null 2>&1; then
            echo "ok"
        else
            echo "FAILED"
            failed=1
        fi
        continue
    fi

    echo -n "Running $name ... "
    if dub run --root "$root_dir" --single "$f" > /dev/null 2>&1; then
        echo "ok"
    else
        echo "FAILED"
        failed=1
    fi
done

exit $failed
