#!/usr/bin/env bash
# Build arm64 device/simulator static slices; never combine their object files.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE=release
PLATFORM=all
SKIP_CODEGEN=0
REQUIRE_CLEAN=0
fail() { echo "error: $*" >&2; exit 2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile|--platform)
      [ "$#" -ge 2 ] || fail "$1 requires a value"
      case "$1" in --profile) PROFILE="$2";; --platform) PLATFORM="$2";; esac
      shift;;
    --skip-codegen) SKIP_CODEGEN=1;;
    --require-clean) REQUIRE_CLEAN=1;;
    --help|-h) echo 'build_ios_core.sh --profile debug|release --platform device|simulator|all [--skip-codegen] [--require-clean]'; exit 0;;
    *) fail "unknown argument: $1";;
  esac
  shift
done
case "$PROFILE" in debug|release) ;; *) fail "invalid profile: $PROFILE";; esac
case "$PLATFORM" in device|simulator|all) ;; *) fail "invalid platform: $PLATFORM";; esac
cd "$ROOT"
OUT="$ROOT/build/ios-native"
mkdir -p "$OUT"
rm -f "$OUT/manifest.json"
for tool in cargo rustc flutter_rust_bridge_codegen xcrun xcodebuild python3; do
  command -v "$tool" >/dev/null || fail "required tool: $tool"
done
# Codegen itself can invoke Cargo: reject untracked tool selection before it runs.
python3 "$ROOT/scripts/ios_artifact_provenance.py" preflight
FRB_VERSION="$(flutter_rust_bridge_codegen --version)"
[ "$FRB_VERSION" = 'flutter_rust_bridge_codegen 2.13.0' ] || fail "FRB 2.13.0 required (got $FRB_VERSION)"
RUST_VERSION="$(rustc --version)"
case "$RUST_VERSION" in 'rustc 1.99.1'|'rustc 1.99.1 '*) ;; *) fail "Rust 1.99.1 required (got $RUST_VERSION)";; esac
if [ "$SKIP_CODEGEN" -eq 0 ]; then
  command -v cargo-expand >/dev/null || fail 'required codegen tool: cargo-expand (install to a dedicated tool root)'
  flutter_rust_bridge_codegen generate --config-file flutter_rust_bridge.yaml
fi
# --skip-codegen only reuses matching generated bindings, never silently old ones.
python3 - "$ROOT" <<'PY'
import pathlib,re,sys
root=pathlib.Path(sys.argv[1])
r=(root/'rust/src/frb_generated.rs').read_text()
d=(root/'lib/src/rust/frb_generated.dart').read_text()
rs=re.findall(r'FLUTTER_RUST_BRIDGE_CODEGEN_CONTENT_HASH: i32 = (-?\d+);',r)
ds=re.findall(r'int get rustContentHash => (-?\d+);',d)
if len(rs)!=1 or rs!=ds or "String get codegenVersion => '2.13.0';" not in d:
    sys.exit('error: generated binding content IDs/version mismatch')
PY

export IPHONEOS_DEPLOYMENT_TARGET=16.0
export CARGO_PROFILE_RELEASE_STRIP=none
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/build/ios-native/cargo}"
OUT="$ROOT/build/ios-native"
mkdir -p "$OUT"
# Publish the manifest only after every output validates. A failed rebuild must
# not leave an old manifest advertising the previous source as current.
rm -f "$OUT/manifest.json"
STAGING="$(mktemp -d "$OUT/.xcframework.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
CAPTURE_ARGS=(capture --scope native --profile "$PROFILE" --platform "$PLATFORM" --output "$STAGING/inputs-before.json")
if [ "$REQUIRE_CLEAN" -eq 1 ]; then CAPTURE_ARGS+=(--clean); fi
python3 "$ROOT/scripts/ios_artifact_provenance.py" "${CAPTURE_ARGS[@]}"
LIBRARY_ARGS=()
build_slice() {
  local target="$1" sdk="$2" archive sdkroot compiler archiver
  sdkroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  local cc_var="CC_${target//-/_}"
  local ar_var="AR_${target//-/_}"
  compiler="$(xcrun --sdk "$sdk" --find clang)"
  archiver="$(xcrun --sdk "$sdk" --find ar)"
  local args=(build --manifest-path "$ROOT/rust/Cargo.toml" --locked --lib --target "$target")
  if [ "$PROFILE" = release ]; then args+=(--release); fi
  # Pin SDK tools for this child only; do not alter the pre/post caller snapshot.
  env "SDKROOT=$sdkroot" "$cc_var=$compiler" "$ar_var=$archiver" cargo "${args[@]}"
  archive="$CARGO_TARGET_DIR/$target/$PROFILE/libfqapi_core.a"
  [ -s "$archive" ] || fail "missing static archive: $archive"
  [ "$(xcrun lipo -archs "$archive")" = arm64 ] || fail "invalid architecture: $archive"
  local symbols
  # Inspect the native Mach-O symbols. Rust embeds newer LLVM IR alongside
  # native code; Xcode's optional bitcode reader may lag Rust's LLVM version.
  symbols="$(xcrun nm --no-llvm-bc -gU "$archive")"
  case "$symbols" in *frb_get_rust_content_hash*frb_pde_ffi_dispatcher_primary*|*frb_pde_ffi_dispatcher_primary*frb_get_rust_content_hash*) ;; *) fail "FRB entry symbols missing: $archive";; esac
  LIBRARY_ARGS+=(-library "$archive")
}
if [ "$PLATFORM" = all ] || [ "$PLATFORM" = device ]; then build_slice aarch64-apple-ios iphoneos; fi
if [ "$PLATFORM" = all ] || [ "$PLATFORM" = simulator ]; then build_slice aarch64-apple-ios-sim iphonesimulator; fi
xcodebuild -create-xcframework "${LIBRARY_ARGS[@]}" -output "$STAGING/fqapi_core.xcframework"
CODEGEN=generated
if [ "$SKIP_CODEGEN" -eq 1 ]; then CODEGEN=reused; fi
python3 "$ROOT/scripts/ios_artifact_provenance.py" native --before "$STAGING/inputs-before.json" --framework "$STAGING/fqapi_core.xcframework" --codegen "$CODEGEN" --output "$STAGING/manifest.json"

rm -rf "$OUT/fqapi_core.xcframework"
mv "$STAGING/fqapi_core.xcframework" "$OUT/fqapi_core.xcframework"
mv "$STAGING/manifest.json" "$OUT/manifest.json"
echo "Built $OUT/fqapi_core.xcframework ($PROFILE, $PLATFORM)"
