# shellcheck shell=bash
#
# The R2 binary cache (cache.sparkles.petar-kirov.dev), for the scripts that
# write to it: with-cache.sh, gc-root.sh and push-pin-set-r2.sh. Source after
# common.sh.
#
# Environment:
#   R2_ACCESS_KEY_ID      R2 API token's access key ID.
#   R2_SECRET_ACCESS_KEY  R2 API token's secret access key.
#   R2_ACCOUNT_ID         Cloudflare account ID (the S3 endpoint's host).
#   NIX_R2_SIGNING_KEY    Nix signing key (cache.sparkles.petar-kirov.dev-1),
#                         the contents of the file `nix key generate-secret`
#                         prints.
#   R2_BUCKET             Bucket name (default: sparkles-nix-cache).
#   R2_CACHE_URL          Public URL (default:
#                         https://cache.sparkles.petar-kirov.dev).

r2_bucket=${R2_BUCKET:-sparkles-nix-cache}
r2_cache_url=${R2_CACHE_URL:-https://cache.sparkles.petar-kirov.dev}

# True when every credential is set.
r2_configured() {
  [ -n "${R2_ACCESS_KEY_ID:-}" ] && [ -n "${R2_SECRET_ACCESS_KEY:-}" ] \
    && [ -n "${R2_ACCOUNT_ID:-}" ] && [ -n "${NIX_R2_SIGNING_KEY:-}" ]
}

# r2_init <dir>: writes the signing key into <dir> (private) and sets
# $r2_store, the Nix store URL to `nix copy --to`.
r2_init() {
  (umask 077 && printf '%s\n' "$NIX_R2_SIGNING_KEY" > "$1/signing.key")
  r2_endpoint="https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com"
  r2_store="s3://$r2_bucket?endpoint=$r2_endpoint&region=auto&compression=zstd&secret-key=$1/signing.key"
}

# r2_copy <nix copy args...>: `nix copy --to $r2_store` with the credentials.
r2_copy() {
  AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
    nix copy --to "$r2_store" "$@"
}

# r2_put <key> <file>: uploads <file> as object <key>, through the S3 API.
r2_put() {
  curl --fail --silent --show-error --retry 3 \
    --aws-sigv4 'aws:amz:auto:s3' --user "$R2_ACCESS_KEY_ID:$R2_SECRET_ACCESS_KEY" \
    -X PUT -H 'Content-Type: text/plain' --data-binary "@$2" \
    "$r2_endpoint/$r2_bucket/$1"
}

# r2_has <store path>: true when the cache serves its narinfo.
r2_has() {
  local hash
  hash=$(basename "$1" | cut -c1-32)
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$r2_cache_url/$hash.narinfo")" = 200 ]
}
