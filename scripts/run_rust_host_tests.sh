#!/usr/bin/env bash
# Real Dart -> FRB -> Rust integration, using local synthetic/mock fixtures.
# Reuse requires exact source, toolchain, bounded features and library hashes.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
MANIFEST="$APP_DIR/rust/Cargo.toml"
SKIP_BUILD=0
FEATURES=
MACHINE=0
fail() { echo "error: $*" >&2; exit 2; }
usage() { echo "Usage: $0 [--skip-build] [--features native-media-host-tests] [--machine]" >&2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1 ;;
    --machine) MACHINE=1 ;;
    --features)
      [ "$#" -ge 2 ] || fail '--features requires a value'
      [ "$2" = native-media-host-tests ] || fail 'only native-media-host-tests is allowed'
      FEATURES="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; fail "unknown argument: $1" ;;
  esac
  shift
done
cd "$APP_DIR"
case "$(uname -s)" in
  Darwin) LIBRARY_NAME=libfqapi_core.dylib ;;
  Linux) LIBRARY_NAME=libfqapi_core.so ;;
  *) fail 'this host wrapper supports macOS/Linux only' ;;
esac
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$APP_DIR/rust/target}"
case "$CARGO_TARGET_DIR" in /*) ;; *) CARGO_TARGET_DIR="$APP_DIR/$CARGO_TARGET_DIR" ;; esac
LIBRARY="$CARGO_TARGET_DIR/debug/$LIBRARY_NAME"
STAMP="$LIBRARY.provenance.json"
PENDING="$STAMP.pending"
if [ "$SKIP_BUILD" -eq 0 ]; then
  mkdir -p "$(dirname "$LIBRARY")"
  # A failed rebuild must never leave an older stamp authorizing stale reuse.
  rm -f "$STAMP" "$LIBRARY"
  trap 'rm -f "$PENDING"' EXIT
  python3 "$SCRIPT_DIR/rust_host_provenance.py" snapshot --library "$LIBRARY" --features "$FEATURES" --snapshot-file "$PENDING"
  BUILD_ARGS=(build --manifest-path "$MANIFEST" --locked --lib)
  if [ -n "$FEATURES" ]; then BUILD_ARGS+=(--features "$FEATURES"); fi
  cargo "${BUILD_ARGS[@]}"
  python3 "$SCRIPT_DIR/rust_host_provenance.py" stamp --library "$LIBRARY" --features "$FEATURES" --snapshot-file "$PENDING"
else
  python3 "$SCRIPT_DIR/rust_host_provenance.py" verify --library "$LIBRARY" --features "$FEATURES"
fi
export FQAPP_RUST_HOST_LIB="$LIBRARY"
TEST_ARGS=(test --no-pub)
if [ "$MACHINE" -eq 1 ]; then TEST_ARGS+=(--machine); fi
TEST_ARGS+=(test/rust_host_integration_test.dart)
flutter "${TEST_ARGS[@]}"
