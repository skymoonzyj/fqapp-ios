'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');
const repository = path.resolve(__dirname, '..');
const udid = '11111111-2222-3333-4444-555555555555';
const bundle = 'com.fqapp.fqapp';

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'fqapp-ios-integration-contract-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  for (const name of ['scripts', 'bin', 'build/ios-native', 'integration_test', 'test_driver', 'user-data']) fs.mkdirSync(path.join(root, name), { recursive: true });
  fs.copyFileSync(path.join(repository, 'scripts/run_ios_integration.sh'), path.join(root, 'scripts/run_ios_integration.sh'));
  for (const entry of ['ios_acceptance', 'ios_parity']) {
    fs.writeFileSync(path.join(root, `integration_test/${entry}_test.dart`), '// controlled integration fixture\n');
    fs.writeFileSync(path.join(root, `test_driver/${entry}_driver.dart`), '// controlled driver fixture\n');
  }
  fs.writeFileSync(path.join(root, 'build/ios-native/manifest.json'), '{}');
  fs.writeFileSync(path.join(root, 'scripts/ios_artifact_provenance.py'), `import os\ndef verify_native(root,path,clean=False):\n if os.environ.get('FQ_FIX_BAD_NATIVE'): raise ValueError('stale native')\n return {'profile':'debug','platform':'simulator'}\n`);
  fs.writeFileSync(path.join(root, 'user-data/sentinel'), 'existing private library bytes');
  fs.writeFileSync(path.join(root, 'running'), 'old-process');
  const app = path.join(root, 'build/ios-app/Build/Products/Debug-iphonesimulator/Runner.app');
  fs.mkdirSync(app, { recursive: true });
  fs.writeFileSync(path.join(app, 'Runner'), 'existing normal App');
  fs.writeFileSync(path.join(app, 'Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${bundle}</string></dict></plist>`);
  const defines = path.join(root, 'fixtures.json');
  fs.writeFileSync(defines, JSON.stringify({ FQAPP_IOS_FIXTURES: JSON.stringify([['clear-avc1', ''], ['cenc-avc1', '00112233445566778899aabbccddeeff'], ['offline-hvc1', '']].map(([name, keyHex]) => ({ name, keyHex, bytesBase64: 'AA==' }))) }));
  const tool = `#!/usr/bin/env python3
import json,os,pathlib,sys
root=pathlib.Path(os.environ['FQ_IOS_SCRIPT_FIXTURE_ROOT']); name=pathlib.Path(sys.argv[0]).name; a=sys.argv[1:]
with (root/'calls.jsonl').open('a') as f: f.write(json.dumps([name,*a])+'\\n')
if name=='flutter':
 if a[0]=='build':
  target=a[a.index('-t')+1]
  if target!='lib/main.dart' and os.environ.get('FQ_FIX_FAIL_CONFIG'): sys.exit(7)
  if target=='lib/main.dart' and os.environ.get('FQ_FIX_FAIL_RESTORE'): sys.exit(8)
  (root/'target').write_text(target)
 elif a[0]=='drive':
  (root/'fresh-process').write_text(str(not (root/'running').exists()))
  (root/'running').write_text('new-process' if not (root/'running').exists() else 'old-process')
  if '--keep-app-running' not in a:
   (root/'user-data/sentinel').unlink(missing_ok=True)
   (root/'running').unlink(missing_ok=True)
  if os.environ.get('FQ_FIX_FAIL_DRIVE'): sys.exit(9)
  print('All tests passed.')
if name=='xcodebuild':
 target=(root/'target').read_text()
 if os.environ.get('FQ_FIX_INVALID_SIM'): sys.exit(6)
 if os.environ.get('FQ_FIX_FAIL_XCODE') and target!='lib/main.dart': sys.exit(6)
 if os.environ.get('FQ_FIX_FAIL_MAIN_BUILD') and target=='lib/main.dart': sys.exit(12)
 app=root/'build/ios-app/Build/Products/Debug-iphonesimulator/Runner.app';app.mkdir(parents=True,exist_ok=True);(app/'Runner').write_bytes(b'fake integration app');(root/'built-target').write_text(target)
if name=='xcrun':
 if os.environ.get('FQ_FIX_INVALID_SIM'): print('Invalid device: fixture',file=sys.stderr);sys.exit(148)
 if a[:2]==['simctl','terminate']:
  counter=root/'terminate-count'; n=int(counter.read_text())+1 if counter.exists() else 1;counter.write_text(str(n))
  if os.environ.get('FQ_FIX_FAIL_COLD_TERM') and n==1: print('permission denied',file=sys.stderr);sys.exit(5)
  if os.environ.get('FQ_FIX_FAIL_CLEANUP_TERM') and n>1: print('device disconnected',file=sys.stderr);sys.exit(11)
  if os.environ.get('FQ_FIX_UNEXPECTED_CODE3') and n==1: print('An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=3):\\npermission denied',file=sys.stderr);sys.exit(3)
  if not (root/'running').exists():
   b=a[3]
   print('An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=3):\\nSimulator device failed to terminate '+b+'.\\nfound nothing to terminate\\nUnderlying error (domain=NSPOSIXErrorDomain, code=3):\\n\\tThe request to terminate "'+b+'" failed. found nothing to terminate\\n\\tfound nothing to terminate',file=sys.stderr);sys.exit(3)
  (root/'running').unlink()
 elif a[:2]==['simctl','install']:
  if os.environ.get('FQ_FIX_FAIL_INSTALL'): sys.exit(10)
  (root/'installed-target').write_text((root/'built-target').read_text())
 else:
  print('unexpected simctl mutation',file=sys.stderr);sys.exit(90)
`;
  for (const name of ['flutter', 'xcodebuild', 'xcrun']) fs.writeFileSync(path.join(root, 'bin', name), tool, { mode: 0o755 });
  const env = { ...process.env, PATH: `${root}/bin:${process.env.PATH}`, FQ_IOS_SCRIPT_FIXTURE_ROOT: root };
  const run = (args, extra = {}) => spawnSync('bash', [path.join(root, 'scripts/run_ios_integration.sh'), ...args], { cwd: root, env: { ...env, ...extra }, encoding: 'utf8' });
  const calls = () => fs.existsSync(path.join(root, 'calls.jsonl')) ? fs.readFileSync(path.join(root, 'calls.jsonl'), 'utf8').trim().split('\n').map(JSON.parse) : [];
  return { root, defines, app, run, calls };
}
function success(r) { assert.equal(r.status, 0, r.stdout + r.stderr); }
function failure(r) { assert.notEqual(r.status, 0, r.stdout + r.stderr); }
function args(f) { return ['--entry', 'native-media', '--simulator', udid, '--fixtures', f.defines]; }
function preserved(f) { assert.equal(fs.readFileSync(path.join(f.root, 'user-data/sentinel'), 'utf8'), 'existing private library bytes'); }
function normalInstalled(f) { assert.equal(fs.readFileSync(path.join(f.root, 'installed-target'), 'utf8'), 'lib/main.dart'); }

test('native runtime cold-terminates its own bundle, keeps data, then installs normal main without launching it', t => {
  const f = fixture(t); success(f.run(args(f)));
  const calls = f.calls();
  assert.deepEqual(calls.map(c => c[0]), ['xcrun', 'flutter', 'xcodebuild', 'flutter', 'xcrun', 'flutter', 'xcodebuild', 'xcrun']);
  assert.deepEqual(calls[0], ['xcrun', 'simctl', 'terminate', udid, bundle]);
  assert.ok(calls[1].includes('--config-only') && calls[1].includes('integration_test/ios_parity_test.dart'));
  assert.ok(calls[1].includes(`--dart-define-from-file=${f.defines}`));
  const xcode = calls[2];
  for (const flag of ['CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-', 'DEVELOPMENT_TEAM=', 'ARCHS=arm64']) assert.ok(xcode.includes(flag));
  assert.equal(xcode[xcode.indexOf('-jobs') + 1], '2');
  assert.ok(calls[3].includes('--keep-app-running'));
  assert.ok(calls[3].some(a => a.startsWith('--use-application-binary=')));
  assert.deepEqual(calls[4], ['xcrun', 'simctl', 'terminate', udid, bundle]);
  assert.ok(calls[5].includes('lib/main.dart') && !calls[5].some(a => a.includes('dart-define')));
  assert.deepEqual(calls[7], ['xcrun', 'simctl', 'install', udid, f.app]);
  assert.equal(fs.readFileSync(path.join(f.root, 'fresh-process'), 'utf8'), 'True');
  assert.equal(fs.existsSync(path.join(f.root, 'running')), false);
  assert.ok(!calls.some(c => c.includes('uninstall') || c.includes('erase') || c.includes('launch')));
  preserved(f); normalInstalled(f);
});

test('UI acceptance uses its own entry and driver without media defines', t => {
  const f = fixture(t); success(f.run(['--entry', 'acceptance', '--simulator', udid]));
  const calls = f.calls();
  assert.ok(calls.find(c => c[0] === 'flutter' && c[1] === 'build').includes('integration_test/ios_acceptance_test.dart'));
  assert.ok(calls.find(c => c[0] === 'flutter' && c[1] === 'drive').includes('--driver=test_driver/ios_acceptance_driver.dart'));
  preserved(f); normalInstalled(f);
});

for (const [flag, exit] of [['FQ_FIX_FAIL_CONFIG', 7], ['FQ_FIX_FAIL_XCODE', 6], ['FQ_FIX_FAIL_DRIVE', 9]]) {
  test(`failure ${flag} preserves its exit, stops the test App and restores normal installed main`, t => {
    const f = fixture(t); const r = f.run(args(f), { [flag]: '1' }); assert.equal(r.status, exit, r.stdout + r.stderr);
    assert.equal(fs.existsSync(path.join(f.root, 'running')), false);
    preserved(f); normalInstalled(f);
  });
}

test('only the exact observed absent/not-running error is normalized', t => {
  const f = fixture(t); fs.unlinkSync(path.join(f.root, 'running')); success(f.run(args(f))); preserved(f); normalInstalled(f);
});

for (const [flag, exit] of [['FQ_FIX_FAIL_COLD_TERM', 5], ['FQ_FIX_UNEXPECTED_CODE3', 3], ['FQ_FIX_INVALID_SIM', 148]]) {
  test(`unexpected termination failure ${flag} never starts drive or becomes green`, t => {
    const f = fixture(t); const r = f.run(args(f), { [flag]: '1' }); assert.equal(r.status, exit, r.stdout + r.stderr);
    assert.ok(!f.calls().some(c => c[0] === 'flutter' && c[1] === 'drive')); preserved(f);
  });
}

for (const [flag, exit] of [['FQ_FIX_FAIL_CLEANUP_TERM', 11], ['FQ_FIX_FAIL_RESTORE', 8], ['FQ_FIX_FAIL_MAIN_BUILD', 12], ['FQ_FIX_FAIL_INSTALL', 10]]) {
  test(`cleanup failure ${flag} cannot turn successful drive green`, t => {
    const f = fixture(t); const r = f.run(args(f), { [flag]: '1' }); assert.equal(r.status, exit, r.stdout + r.stderr); preserved(f);
    assert.ok(r.stdout.includes('fqapp.integration.lifecycle'), 'cleanup statuses must be reported');
  });
}

test('the original drive failure survives an additional cleanup failure', t => {
  const f = fixture(t); const r = f.run(args(f), { FQ_FIX_FAIL_DRIVE: '1', FQ_FIX_FAIL_INSTALL: '1' });
  assert.equal(r.status, 9, r.stdout + r.stderr); preserved(f);
  assert.ok(r.stdout.includes('fqapp.integration.lifecycle'));
});

test('missing native provenance or invalid fixtures fail before changing simulator state', t => {
  const f = fixture(t); failure(f.run(args(f), { FQ_FIX_BAD_NATIVE: '1' })); assert.equal(f.calls().length, 0);
  fs.writeFileSync(f.defines, 'a'.repeat(60_001)); failure(f.run(args(f))); assert.equal(f.calls().length, 0); preserved(f);
});


test('mismatched App bundle cannot authorize simulator mutations', t => {
  const f = fixture(t);
  fs.writeFileSync(path.join(f.app, 'Info.plist'), '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.other.app</string></dict></plist>');
  failure(f.run(args(f))); assert.equal(f.calls().length, 0); preserved(f);
});
