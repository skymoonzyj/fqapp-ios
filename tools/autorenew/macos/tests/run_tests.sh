#!/bin/bash
set -euo pipefail
MACOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ ! -f "$MACOS_DIR/Core.swift" ]]; then
  echo 'FAIL: native GUI scheduling and engine boundary are not implemented' >&2
  exit 1
fi
TEST_DIR="$(mktemp -d "$MACOS_DIR/.test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/runtime 测试"
cat > "$TEST_DIR/runtime 测试/renew.py" <<'PY'
import json
import sys
assert sys.argv[1] == '--home'
assert sys.argv[2].endswith('runtime 测试')
assert sys.argv[3] in ('check', 'renew')
sys.stderr.write('private diagnostic ' * 20_000)
sys.stderr.flush()
failed = sys.argv[3] == 'renew'
print(json.dumps({'schema_version': 1, 'status': 'error' if failed else 'healthy', 'paused': False, 'message': 'x' * 200_000}))
sys.exit(1 if failed else 0)
PY
xcrun swiftc -swift-version 5 "$MACOS_DIR/Core.swift" "$MACOS_DIR/tests/CoreTests.swift" -o "$TEST_DIR/core-tests"
"$TEST_DIR/core-tests" "$TEST_DIR/runtime 测试"
