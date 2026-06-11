#!/usr/bin/env bash
#
# Write composer.json for each generated package. PSR-4 entries are derived
# from the actual on-disk layout produced by scripts/generate.sh.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# --- roadrunner-api -----------------------------------------------------------

RR_PKG_DIR="packages/roadrunner-api"
RR_SRC_DIR="$RR_PKG_DIR/src"

if [[ ! -d "$RR_SRC_DIR" ]]; then
    echo "error: $RR_SRC_DIR not found. Run scripts/generate.sh first." >&2
    exit 1
fi

# Each "<prefix>/V<n>" leaf yields one PSR-4 entry:
#   "RoadRunner\\<prefix>\\DTO\\" → "src/<prefix>/"
# `<prefix>` is "Jobs", "Centrifugal/API", etc.
rr_prefixes=$(find "$RR_SRC_DIR" -type d -regextype posix-extended -regex '.*/V[0-9]+' -printf '%P\n' \
              | xargs -I{} dirname {} \
              | sort -u)

if [[ -z "$rr_prefixes" ]]; then
    echo "error: no V<n>/ leaves under $RR_SRC_DIR" >&2
    exit 1
fi

rr_psr4=""
while IFS= read -r prefix; do
    ns_inner="${prefix//\//\\\\}"
    ns="RoadRunner\\\\${ns_inner}\\\\DTO\\\\"
    dir="src/${prefix}/"
    [[ -n "$rr_psr4" ]] && rr_psr4+=","
    rr_psr4+=$'\n            "'"$ns"'": "'"$dir"'"'
done <<<"$rr_prefixes"

echo ">> $RR_PKG_DIR/composer.json"
cat >"$RR_PKG_DIR/composer.json" <<JSON
{
    "name": "roadrunner-php/roadrunner-api-dto",
    "description": "RoadRunner protobuf DTOs (auto-generated from roadrunner-server/api).",
    "type": "library",
    "license": "BSD-3-Clause",
    "authors": [
        {
            "name": "RoadRunner",
            "homepage": "https://roadrunner.dev"
        }
    ],
    "require": {
        "php": ">=8.2",
        "google/protobuf": "^4.31 || ^5.34"
    },
    "autoload": {
        "psr-4": {${rr_psr4}
        }
    },
    "minimum-stability": "dev",
    "prefer-stable": true
}
JSON

# --- temporal-api -------------------------------------------------------------

TEMPORAL_PKG_DIR="packages/temporal-api"
TEMPORAL_SRC_DIR="$TEMPORAL_PKG_DIR/src"

if [[ ! -d "$TEMPORAL_SRC_DIR" ]]; then
    echo "warn: $TEMPORAL_SRC_DIR not found, skipping temporal-api manifest" >&2
else
    # Temporal protos don't declare php_metadata_namespace, so metadata files
    # live under GPBMetadata\Temporal\... The PSR-4 map covers both: real
    # types via Temporal\ → src/, and metadata via GPBMetadata\Temporal\ →
    # src/GPBMetadata/Temporal/. The disk layout puts everything under
    # src/Api/ (we stripped "Temporal/") which lines up with Temporal\Api\...
    echo ">> $TEMPORAL_PKG_DIR/composer.json"
    cat >"$TEMPORAL_PKG_DIR/composer.json" <<'JSON'
{
    "name": "roadrunner-php/temporal-api-dto",
    "description": "Temporal API protobuf DTOs (auto-generated from temporalio/api).",
    "type": "library",
    "license": "MIT",
    "authors": [
        {
            "name": "RoadRunner",
            "homepage": "https://roadrunner.dev"
        }
    ],
    "require": {
        "php": ">=8.2",
        "google/protobuf": "^4.31 || ^5.34"
    },
    "autoload": {
        "psr-4": {
            "Temporal\\": "src/",
            "GPBMetadata\\Temporal\\": "src/GPBMetadata/Temporal/"
        }
    },
    "minimum-stability": "dev",
    "prefer-stable": true
}
JSON
fi

echo "done."
