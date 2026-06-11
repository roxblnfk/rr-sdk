#!/usr/bin/env bash
#
# Regenerate PHP code in two packages:
#
#   packages/roadrunner-api/  — from proto/roadrunner/api/
#   packages/temporal-api/    — from proto/third_party/api/temporal/
#
# Each package contains:
#   * message DTOs   (protoc's built-in `--php_out`)
#   * service interfaces (`<Service>Interface`) extending
#     `Spiral\RoadRunner\GRPC\ServiceInterface`, produced by the
#     RoadRunner-specific `protoc-gen-php-grpc` plugin via `--php-grpc_out`.
#
# Pipeline (per package):
#   1. `buf build <module>` resolves every import (including BSR-managed
#      google.protobuf / google.api well-known types) into a single
#      FileDescriptorSet under runtime/. buf is used only for dependency
#      resolution — no BSR plugins are invoked.
#   2. Local `protoc --descriptor_set_in=<fds> --php_out=... --php-grpc_out=...`
#      consumes the descriptor set and emits both messages and interfaces in
#      one call. The bundled `--php_out` is more permissive than the BSR PHP
#      messages plugin and accepts the proto2 descriptor.proto enums that
#      temporal reaches transitively via google.api.http.
#   3. We walk each staging tree and move the namespace leaves into
#      packages/<pkg>/src/<short-path>/, dropping path segments that only
#      add depth (`RoadRunner/`, `DTO/`, `Temporal/`). PSR-4 entries in
#      composer.json map the original namespace prefix back to the path.
#
# Tooling: `vendor/bin/dload get` fetches buf, protoc, and
# protoc-gen-php-grpc into runtime/. Override via $BUF / $PROTOC /
# $PROTOC_GEN_PHP_GRPC if you need a different path.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# --- tool discovery -----------------------------------------------------------

find_tool() {
    local var_name="$1" base_name="$2" runtime_path
    if [[ -n "${!var_name:-}" ]]; then
        echo "${!var_name}"
        return
    fi
    # Check .exe first: Git Bash's `[[ -x foo ]]` matches `foo.exe` silently,
    # but native Windows tools (e.g. protoc invoking a plugin) need the full
    # `.exe` path, not the bare name.
    for runtime_path in "runtime/$base_name.exe" "runtime/$base_name"; do
        if [[ -f "$runtime_path" && -x "$runtime_path" ]]; then
            echo "$ROOT_DIR/$runtime_path"
            return
        fi
    done
    if command -v "$base_name" >/dev/null 2>&1; then
        echo "$base_name"
        return
    fi
    echo "error: $base_name not found. Run 'vendor/bin/dload get' or set $var_name=/path/to/$base_name." >&2
    return 1
}

BUF=$(find_tool BUF buf)
PROTOC=$(find_tool PROTOC protoc)
PROTOC_GEN_PHP_GRPC=$(find_tool PROTOC_GEN_PHP_GRPC protoc-gen-php-grpc)

# --- common -------------------------------------------------------------------

# protoc_generate <fds-file> <staging-dir> <relative-proto-path>...
#
# Runs a single protoc invocation that emits both PHP messages and
# `*Interface` service stubs from the given descriptor set. Paths must be
# relative to the module root used when building the FDS.
protoc_generate() {
    local fds="$1" staging="$2"
    shift 2

    "$PROTOC" \
        --plugin=protoc-gen-php-grpc="$PROTOC_GEN_PHP_GRPC" \
        --descriptor_set_in="$fds" \
        --php_out="$staging" \
        --php-grpc_out="$staging" \
        "$@"
}

# --- roadrunner-api -----------------------------------------------------------

RR_PROTO_MODULE="proto/roadrunner/api"
RR_PKG_DIR="packages/roadrunner-api"
RR_STAGING="runtime/proto-out-roadrunner"
RR_FDS="runtime/roadrunner.binpb"

echo ">> generating roadrunner-api"
rm -rf "$RR_STAGING"
mkdir -p "$RR_STAGING"
mkdir -p "$(dirname "$RR_FDS")"

"$BUF" build "$RR_PROTO_MODULE" -o "$RR_FDS"

rr_files=()
while IFS= read -r p; do rr_files+=("$p"); done < <(
    cd "$RR_PROTO_MODULE" && find . -name "*.proto" -type f -printf '%P\n' | sort
)
if (( ${#rr_files[@]} == 0 )); then
    echo "error: no .proto files under $RR_PROTO_MODULE" >&2
    exit 1
fi

protoc_generate "$RR_FDS" "$RR_STAGING" "${rr_files[@]}"

if [[ ! -d "$RR_STAGING/RoadRunner" ]]; then
    echo "error: nothing generated under $RR_STAGING/RoadRunner" >&2
    exit 1
fi

rm -rf "$RR_PKG_DIR/src"
mkdir -p "$RR_PKG_DIR/src"

# Move every `...\DTO\V<n>\` leaf under packages/roadrunner-api/src/,
# stripping the leading `RoadRunner/` and any `DTO/` path segment.
while IFS= read -r -d '' v_dir; do
    rel="${v_dir#$RR_STAGING/RoadRunner/}"
    target_rel="${rel//DTO\//}"
    target="$RR_PKG_DIR/src/$target_rel"
    mkdir -p "$(dirname "$target")"
    mv "$v_dir" "$target"
done < <(find "$RR_STAGING/RoadRunner" -type d -regextype posix-extended -regex '.*/DTO/V[0-9]+' -print0)

rr_leftover=$(find "$RR_STAGING" -type f 2>/dev/null || true)
if [[ -n "$rr_leftover" ]]; then
    echo "warn: unrecognized files left in $RR_STAGING:" >&2
    echo "$rr_leftover" >&2
else
    rm -rf "$RR_STAGING"
fi

# --- temporal-api -------------------------------------------------------------
#
# The third_party/api buf.yaml declares the whole tree (temporal + google +
# grpc-gateway). We only want temporal — google/* is provided by the
# `google/protobuf` composer package at runtime, and grpc-gateway has no PHP
# consumer. Build the full descriptor set, but ask protoc to generate code
# only for files under temporal/.

TEMPORAL_PROTO_MODULE="proto/third_party/api"
TEMPORAL_PKG_DIR="packages/temporal-api"
TEMPORAL_STAGING="runtime/proto-out-temporal"
TEMPORAL_FDS="runtime/temporal.binpb"

echo ">> generating temporal-api"
rm -rf "$TEMPORAL_STAGING"
mkdir -p "$TEMPORAL_STAGING"
mkdir -p "$(dirname "$TEMPORAL_FDS")"

"$BUF" build "$TEMPORAL_PROTO_MODULE" -o "$TEMPORAL_FDS"

temporal_files=()
while IFS= read -r p; do temporal_files+=("$p"); done < <(
    cd "$TEMPORAL_PROTO_MODULE" && find temporal -name "*.proto" -type f | sort
)
if (( ${#temporal_files[@]} == 0 )); then
    echo "error: no temporal protos found" >&2
    exit 1
fi

protoc_generate "$TEMPORAL_FDS" "$TEMPORAL_STAGING" "${temporal_files[@]}"

if [[ ! -d "$TEMPORAL_STAGING/Temporal/Api" ]]; then
    echo "error: nothing generated under $TEMPORAL_STAGING/Temporal/Api" >&2
    exit 1
fi

rm -rf "$TEMPORAL_PKG_DIR/src"
mkdir -p "$TEMPORAL_PKG_DIR/src"

# Layout decisions for temporal-api:
#   <staging>/Temporal/Api/<X>/V<n>/* → src/Api/<X>/V<n>/*  (strip "Temporal/")
#   <staging>/GPBMetadata/*           → src/GPBMetadata/*    (kept verbatim)
mv "$TEMPORAL_STAGING/Temporal/Api" "$TEMPORAL_PKG_DIR/src/Api"
mv "$TEMPORAL_STAGING/GPBMetadata"  "$TEMPORAL_PKG_DIR/src/GPBMetadata"

rmdir "$TEMPORAL_STAGING/Temporal" 2>/dev/null || true

temporal_leftover=$(find "$TEMPORAL_STAGING" -type f 2>/dev/null || true)
if [[ -n "$temporal_leftover" ]]; then
    echo "warn: unrecognized files left in $TEMPORAL_STAGING:" >&2
    echo "$temporal_leftover" >&2
else
    rm -rf "$TEMPORAL_STAGING"
fi

# --- composer.json manifests --------------------------------------------------

"$ROOT_DIR/scripts/scaffold-packages.sh"

echo "done."
