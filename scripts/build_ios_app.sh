#!/usr/bin/env bash
# No upload, signing-account changes, or device installation is performed here.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE=simulator
BUNDLE_ID=
TEAM_ID=
BUILD_NUMBER=
fail() { echo "error: $*" >&2; exit 2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode|--bundle-id|--team-id|--build-number)
      [ "$#" -ge 2 ] || fail "$1 requires a value"
      case "$1" in --mode) MODE="$2";; --bundle-id) BUNDLE_ID="$2";; --team-id) TEAM_ID="$2";; --build-number) BUILD_NUMBER="$2";; esac
      shift;;
    --help|-h) echo 'build_ios_app.sh --mode simulator|local-device|archive --bundle-id ID [--team-id ID] --build-number N'; exit 0;;
    *) fail "unknown argument: $1";;
  esac
  shift
done
case "$MODE" in simulator|local-device|archive) ;; *) fail "invalid mode: $MODE";; esac
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || fail 'invalid or required bundle-id'
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || fail 'invalid or required build-number'
if [ -n "$TEAM_ID" ]; then
  [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail 'invalid team-id (10 characters required)'
fi
if [ "$MODE" = archive ]; then
  [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail 'archive requires explicit signing team-id (10 characters)'
  security find-identity -v -p codesigning | grep -F "($TEAM_ID)" >/dev/null || fail 'archive signing identity unavailable for requested team'
fi
cd "$ROOT"
SOURCE_COMMIT="$(git rev-parse HEAD)"
if [ "$MODE" != simulator ]; then
  [ -z "$(git status --porcelain --untracked-files=normal)" ] || fail 'final artifact requires clean committed source'
fi
APP_VERSION="$(python3 - <<'PY'
import pathlib,re,sys
m=re.search(r'^version:\s*(\d+(?:\.\d+){1,2})\+[1-9]\d*\s*$',pathlib.Path('pubspec.yaml').read_text(),re.M)
if not m: sys.exit('error: invalid source application version')
print(m[1])
PY
)"
PROFILE=debug
PLATFORM=simulator
KIND=adhoc-local-simulator
CORE_ARGS=()
CAPTURE_ARGS=()
if [ "$MODE" = simulator ]; then
  mkdir -p "$ROOT/build/ios-app/provenance"
  RECORD="$(mktemp -d "$ROOT/build/ios-app/provenance/run.XXXXXX")"
else
  PROFILE=release
  PLATFORM=device
  KIND=unsigned-local-device
  SUFFIX=unsigned-local
  if [ "$MODE" = archive ]; then KIND=signed-device-archive; SUFFIX=signed-archive; fi
  RECORD="$ROOT/release-archives/ios-$APP_VERSION-$BUILD_NUMBER-$SOURCE_COMMIT-$SUFFIX"
  mkdir -p "$ROOT/release-archives"
  mkdir "$RECORD" || fail 'artifact directory already exists; previous evidence was preserved'
  CORE_ARGS+=(--require-clean)
  CAPTURE_ARGS+=(--clean)
fi
VERSION="$(flutter --version --machine)"
python3 - "$VERSION" <<'PY'
import json,sys
v=json.loads(sys.argv[1])
if v.get('frameworkVersion')!='3.44.6' or not v.get('dartSdkVersion','').startswith('3.12.2'):
    sys.exit('error: Flutter 3.44.6 / Dart 3.12.2 required')
PY
bash "$ROOT/scripts/build_ios_core.sh" --profile "$PROFILE" --platform "$PLATFORM" ${CORE_ARGS[@]+"${CORE_ARGS[@]}"}
flutter pub get --enforce-lockfile
flutter build ios --config-only --no-pub --no-codesign --"$PROFILE" --build-name "$APP_VERSION" --build-number "$BUILD_NUMBER"
(cd ios && pod install --deployment)
[ "$(git rev-parse HEAD)" = "$SOURCE_COMMIT" ] || fail 'source commit changed during preparation'
python3 "$ROOT/scripts/ios_artifact_provenance.py" capture --scope app --profile "$PROFILE" --platform "$PLATFORM" ${CAPTURE_ARGS[@]+"${CAPTURE_ARGS[@]}"} --output "$RECORD/inputs-before.json"
COMMON=(-workspace "$ROOT/ios/Runner.xcworkspace" -scheme Runner -jobs 2 "FQAPP_BUNDLE_ID=$BUNDLE_ID" "CURRENT_PROJECT_VERSION=$BUILD_NUMBER" IPHONEOS_DEPLOYMENT_TARGET=16.0 ARCHS=arm64 ONLY_ACTIVE_ARCH=YES)
if [ "$MODE" = simulator ]; then
  DERIVED="$ROOT/build/ios-app"
  XCODE_ARGS=("${COMMON[@]}" -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build)
  APP="$DERIVED/Build/Products/Debug-iphonesimulator/Runner.app"
else
  ARCHIVE="$RECORD/Runner.xcarchive"
  SIGNING=(CODE_SIGNING_ALLOWED=NO)
  if [ "$MODE" = archive ]; then SIGNING=("DEVELOPMENT_TEAM=$TEAM_ID" CODE_SIGN_STYLE=Automatic); fi
  XCODE_ARGS=("${COMMON[@]}" -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$ROOT/build/ios-app-device" -archivePath "$ARCHIVE" "${SIGNING[@]}" archive)
  APP="$ARCHIVE/Products/Applications/Runner.app"
fi
# Record the same argument array that is executed; no signing credentials.
python3 - "$RECORD/build-command.json" "${XCODE_ARGS[@]}" <<'PYCMD'
import json,pathlib,sys
with pathlib.Path(sys.argv[1]).open('x') as f: json.dump(sys.argv[2:],f,indent=2); f.write('\n')
PYCMD
xcodebuild "${XCODE_ARGS[@]}"
[ -d "$APP" ] || fail "missing Runner.app: $APP"
if [ "$MODE" = archive ]; then
  codesign --verify --deep --strict "$APP"
  [ -s "$APP/embedded.mobileprovision" ] || fail 'archive missing signing provisioning profile'
fi
# Preserve exactly the manifest and native slices consumed by this App build.
mkdir "$RECORD/native"
cp "$ROOT/build/ios-native/manifest.json" "$RECORD/native/manifest.json"
cp -R "$ROOT/build/ios-native/fqapi_core.xcframework" "$RECORD/native/fqapi_core.xcframework"
python3 "$ROOT/scripts/ios_artifact_provenance.py" finalize --before "$RECORD/inputs-before.json" --app "$APP" --native-manifest "$RECORD/native/manifest.json" --output "$RECORD" --kind "$KIND" --bundle "$BUNDLE_ID" --version "$APP_VERSION" --build "$BUILD_NUMBER"
if [ "$MODE" != simulator ]; then
  cp "$RECORD/app-provenance.json" "$ARCHIVE/app-provenance.json"
fi
python3 - "$RECORD" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1]); records=[]
for p in sorted(root.rglob('*')):
    if p.is_file():
        if not p.resolve().is_relative_to(root.resolve()): sys.exit('error: artifact path escapes archive')
        h=hashlib.sha256()
        with p.open('rb') as f:
            for chunk in iter(lambda:f.read(1024*1024),b''): h.update(chunk)
        records.append(f'{h.hexdigest()}  {p.relative_to(root)}\n')
with (root/'SHA256SUMS').open('x') as f: f.writelines(records)
PY
echo "Built $APP ($KIND); evidence: $RECORD"
