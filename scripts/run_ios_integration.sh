#!/usr/bin/env bash
# Run real iOS integration against the current Task 10 native artifact.
# config-only + bounded ad-hoc Xcode + drive prebuilt matches device-free
# simulator acceptance. Restore normal main configuration/App on every exit.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRY=
SIMULATOR="${FQAPP_SIMULATOR_UDID:-}"
FIXTURES=
fail() { echo "error: $*" >&2; exit 2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --entry|--simulator|--fixtures)
      [ "$#" -ge 2 ] || fail "$1 requires a value"
      case "$1" in --entry) ENTRY="$2";; --simulator) SIMULATOR="$2";; --fixtures) FIXTURES="$2";; esac
      shift ;;
    *) fail "unknown argument: $1" ;;
  esac
  shift
done
[[ "$SIMULATOR" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || fail 'explicit simulator UDID required'
case "$ENTRY" in
  acceptance) TARGET=integration_test/ios_acceptance_test.dart; DRIVER=test_driver/ios_acceptance_driver.dart; [ -z "$FIXTURES" ] || fail 'acceptance does not accept media fixtures' ;;
  native-media) TARGET=integration_test/ios_parity_test.dart; DRIVER=test_driver/ios_parity_driver.dart; [ -f "$FIXTURES" ] || fail 'native-media requires generated fixture defines' ;;
  *) fail 'entry must be acceptance or native-media' ;;
esac
cd "$ROOT"
[ -f "$TARGET" ] && [ -f "$DRIVER" ] || fail 'integration entry/driver missing'
python3 - "$ROOT" "$FIXTURES" <<'PY'
import base64,json,pathlib,sys
root=pathlib.Path(sys.argv[1]); fixture=sys.argv[2]
if fixture:
    path=pathlib.Path(fixture)
    if path.stat().st_size>60000: sys.exit('error: fixture defines exceed 60000-byte transport budget')
    value=json.loads(path.read_text()).get('FQAPP_IOS_FIXTURES')
    if not isinstance(value,str): sys.exit('error: fixture define value must be a JSON string')
    entries=json.loads(value)
    expected={'clear-avc1':'','cenc-avc1':'00112233445566778899aabbccddeeff','offline-hvc1':''}
    if not isinstance(entries,list) or len(entries)!=3 or any(not isinstance(e,dict) for e in entries): sys.exit('error: invalid synthetic fixture inventory')
    if {e.get('name'):e.get('keyHex') for e in entries}!=expected: sys.exit('error: public synthetic fixture identity/key contract mismatch')
    for entry in entries:
        if not base64.b64decode(entry.get('bytesBase64',''),validate=True): sys.exit('error: empty synthetic fixture payload')
sys.path.insert(0,str(root/'scripts'))
from ios_artifact_provenance import verify_native
manifest=verify_native(root,root/'build/ios-native/manifest.json')
if manifest.get('profile')!='debug' or manifest.get('platform')!='simulator': sys.exit('error: matching debug simulator native artifact required')
PY
APP="$ROOT/build/ios-app/Build/Products/Debug-iphonesimulator/Runner.app"
BUNDLE_ID=com.fqapp.fqapp
verify_own_app() {
  python3 - "$APP/Info.plist" "$BUNDLE_ID" <<'PY_BUNDLE'
import pathlib,plistlib,sys
info=plistlib.loads(pathlib.Path(sys.argv[1]).read_bytes())
if info.get('CFBundleIdentifier')!=sys.argv[2]: sys.exit('error: integration App bundle identity mismatch')
PY_BUNDLE
}
# A fresh product build precedes this wrapper. Never terminate a bundle taken
# from untrusted or mismatched metadata, including during failure cleanup.
verify_own_app
terminate_own_app() {
  python3 - "$SIMULATOR" "$BUNDLE_ID" "$1" <<'PY_TERMINATE'
import json,subprocess,sys
simulator,bundle,phase=sys.argv[1:]
r=subprocess.run(['xcrun','simctl','terminate',simulator,bundle],capture_output=True,text=True)
# Exact stopped/absent-process response observed with pinned Xcode27 simctl.
# Invalid devices, permission errors and other code3 results remain failures.
expected=(f'An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=3):\n'
          f'Simulator device failed to terminate {bundle}.\n'
          'found nothing to terminate\n'
          'Underlying error (domain=NSPOSIXErrorDomain, code=3):\n'
          f'\tThe request to terminate "{bundle}" failed. found nothing to terminate\n'
          '\tfound nothing to terminate\n')
absent=(r.returncode==3 and not r.stdout and r.stderr.replace('\r\n','\n').strip()==expected.strip())
print(json.dumps({'type':'fqapp.integration.termination','phase':phase,'exit_code':r.returncode,'expected_not_running':absent}),flush=True)
if r.returncode and not absent:
    sys.stdout.write(r.stdout);sys.stderr.write(r.stderr)
sys.exit(0 if absent else r.returncode)
PY_TERMINATE
}
COMMON=(-workspace "$ROOT/ios/Runner.xcworkspace" -scheme Runner -configuration Debug -sdk iphonesimulator -destination "platform=iOS Simulator,id=$SIMULATOR" -derivedDataPath "$ROOT/build/ios-app" -jobs 2 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ARCHS=arm64 ONLY_ACTIVE_ARCH=YES)
restore_main() {
  local result="$?" terminated=0 configured=0 built=not_run installed=not_run cleanup=0
  trap - EXIT
  set +e
  terminate_own_app cleanup
  terminated="$?"
  flutter build ios --simulator --debug --config-only --no-pub -t lib/main.dart
  configured="$?"
  if [ "$configured" -eq 0 ]; then
    xcodebuild "${COMMON[@]}" build
    built="$?"
    if [ "$built" = 0 ] && [ "$terminated" -eq 0 ]; then
      verify_own_app
      installed="$?"
      if [ "$installed" -eq 0 ]; then
        xcrun simctl install "$SIMULATOR" "$APP"
        installed="$?"
      fi
    fi
  fi
  for cleanup in "$terminated" "$configured" "$built" "$installed"; do
    if [ "$cleanup" != 0 ]; then
      echo 'error: normal main App termination/configuration/build/install failed' >&2
      if [ "$result" -eq 0 ]; then
        if [ "$cleanup" = not_run ]; then result=1; else result="$cleanup"; fi
      fi
      break
    fi
  done
  python3 - "$ENTRY" "$terminated" "$configured" "$built" "$installed" "$result" <<'PY_LIFECYCLE'
import json,sys
entry,terminated,configured,built,installed,result=sys.argv[1:]
print(json.dumps({'type':'fqapp.integration.lifecycle','entry':entry,'terminate_exit':terminated,'configure_exit':configured,'build_exit':built,'install_exit':installed,'overall_exit':int(result),'restored_target':'lib/main.dart','uninstall_performed':False}),flush=True)
PY_LIFECYCLE
  local recorded="$?"
  if [ "$result" -eq 0 ] && [ "$recorded" -ne 0 ]; then result="$recorded"; fi
  exit "$result"
}
trap restore_main EXIT
terminate_own_app cold_start
CONFIG_ARGS=(build ios --simulator --debug --config-only --no-pub -t "$TARGET")
if [ -n "$FIXTURES" ]; then CONFIG_ARGS+=("--dart-define-from-file=$FIXTURES"); fi
flutter "${CONFIG_ARGS[@]}"
xcodebuild "${COMMON[@]}" build
[ -s "$APP/Runner" ] || fail 'integration App executable missing'
verify_own_app
# Flutter's default stop path uninstalls the App and deletes its container.
# Keep it installed, then terminate explicitly and install normal main in EXIT.
flutter drive -d "$SIMULATOR" --no-pub --keep-app-running "--driver=$DRIVER" -t "$TARGET" "--use-application-binary=$APP"
