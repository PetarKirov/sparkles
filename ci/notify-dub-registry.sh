#!/usr/bin/env bash
#
# Ask code.dlang.org to ingest the newly published tag now.
#
# The registry background-scans registered repos on its own schedule, so this
# only *speeds up* ingestion — it is not what makes a tag public. Pushing the
# tag is.
#
# Environment:
#   DUB_REGISTRY_SECRET  Optional. Only needed if the package was registered
#                        with an update secret; the empty default is accepted.
#   DUB_PACKAGE          Package name (default: sparkles).
set -euo pipefail

package=${DUB_PACKAGE:-sparkles}
secret=${DUB_REGISTRY_SECRET:-}

curl --fail-with-body --silent --show-error \
  --retry 3 --retry-delay 5 \
  -X POST "https://code.dlang.org/api/packages/${package}/update" \
  --data-urlencode "secret=${secret}"
