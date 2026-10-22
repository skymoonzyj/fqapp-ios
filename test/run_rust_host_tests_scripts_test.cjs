'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');
const repository = path.resolve(__dirname, '..');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'fqapp-host-contract-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  for (const directory of ['scripts', 'rust/src', 'native', '.cargo', 'bin']) fs.mkdirSync(path.join(root, directory), { recursive: true });
  for (const name of ['run_rust_host_tests.sh', 'rust_host_provenance.py']) {
    const source = path.join(repository, 'scripts', name);
    if (fs.existsSync(source)) fs.copyFileSync(source, path.join(root, 'scripts', name));
  }
  for (const [name, text] of Object.entries({
    '.gitignore': 'rust/target/\nbuild/\nbin/\ncommands.jsonl\n',
    'rust/Cargo.toml': '[package]\nname="fixture"\nversion="0.1.0"\n',
    'rust/Cargo.lock': '# offline fixture lock\n', 'rust/src/lib.rs': '// fixture source\n',
    'native/fixture.c': '// fixture C input\n', '.cargo/config.toml': '# fixture linker config\n',
  })) fs.writeFileSync(path.join(root, name), text);
  const environment = { ...process.env, PATH: `${root}/bin:${process.env.PATH}`, CARGO_TARGET_DIR: `${root}/rust/target`,
    GIT_AUTHOR_NAME: 'Fixture', GIT_AUTHOR_EMAIL: 'fixture@example.invalid', GIT_COMMITTER_NAME: 'Fixture', GIT_COMMITTER_EMAIL: 'fixture@example.invalid' };
  for (const args of [['init', '-q'], ['add', '.'], ['commit', '-qm', 'fixture source']]) {
    assert.equal(spawnSync('git', args, { cwd: root, env: environment }).status, 0);
  }
  const fake = `#!/usr/bin/env python3
import json,os,pathlib,sys
name=pathlib.Path(sys.argv[0]).name
root=pathlib.Path(os.environ['CARGO_TARGET_DIR']).parents[1]
with (root/'commands.jsonl').open('a') as f: f.write(json.dumps([name,*sys.argv[1:]])+'\\n')
if name=='rustc':
 print('rustc 1.99.1 (fixture)')
 if '-vV' in sys.argv:
  print('host: '+('aarch64-apple-darwin' if sys.platform=='darwin' else 'x86_64-unknown-linux-gnu'))
if name in ('cc','c++'): print('fixture clang '+os.environ.get('HOST_FIXTURE_CC_VERSION','1'))
if name=='cargo':
 if os.environ.get('HOST_FIXTURE_CARGO_FAIL'): sys.exit(7)
 if os.environ.get('HOST_FIXTURE_NO_LIBRARY'): sys.exit(0)
 if os.environ.get('HOST_FIXTURE_CHANGE_SOURCE'): (root/'rust/src/lib.rs').write_text('// changed during build')
 target=pathlib.Path(os.environ['CARGO_TARGET_DIR'])/'debug'
 target.mkdir(parents=True,exist_ok=True)
 (target/('libfqapi_core.dylib' if sys.platform=='darwin' else 'libfqapi_core.so')).write_bytes(b'fixture host library')
`;
  for (const name of ['cargo', 'rustc', 'flutter', 'cc', 'c++']) fs.writeFileSync(path.join(root, 'bin', name), fake, { mode: 0o755 });
  const run = (args = [], extra = {}) => spawnSync('bash', [path.join(root, 'scripts/run_rust_host_tests.sh'), ...args], { cwd: root, env: { ...environment, ...extra }, encoding: 'utf8' });
  const commands = () => fs.existsSync(path.join(root, 'commands.jsonl')) ? fs.readFileSync(path.join(root, 'commands.jsonl'), 'utf8').trim().split('\n').map(JSON.parse) : [];
  const library = path.join(root, 'rust/target/debug', process.platform === 'darwin' ? 'libfqapi_core.dylib' : 'libfqapi_core.so');
  return { root, run, commands, library, stamp: `${library}.provenance.json`, environment };
}

function succeeds(result) { assert.equal(result.status, 0, result.stderr + result.stdout); }
function fails(result) { assert.notEqual(result.status, 0, result.stderr + result.stdout); }

test('build is locked, passes the bounded media feature, and emits Flutter machine output', t => {
  const f = fixture(t); succeeds(f.run(['--features', 'native-media-host-tests', '--machine']));
  const cargo = f.commands().find(c => c[0] === 'cargo');
  assert.ok(cargo.includes('--locked')); assert.ok(cargo.includes('--lib'));
  assert.deepEqual(cargo.slice(cargo.indexOf('--features')), ['--features', 'native-media-host-tests']);
  const flutter = f.commands().find(c => c[0] === 'flutter');
  assert.ok(flutter.includes('--machine')); assert.ok(flutter.includes('--no-pub'));
  const stamp = JSON.parse(fs.readFileSync(f.stamp));
  assert.deepEqual(stamp.features, ['native-media-host-tests']);
  assert.match(stamp.source_sha, /^[a-f0-9]{40}$/); assert.match(stamp.library_sha256, /^[a-f0-9]{64}$/);
});

for (const args of [['--other'], ['--features'], ['--features', 'anything'], ['--features', 'native-media-host-tests,other']]) {
  test(`invalid arguments fail before build/test: ${args.join(' ')}`, t => {
    const f = fixture(t); fails(f.run(args)); assert.equal(f.commands().length, 0);
  });
}

test('skip-build rejects absent provenance even when a library exists', t => {
  const f = fixture(t); fs.mkdirSync(path.dirname(f.library), { recursive: true }); fs.writeFileSync(f.library, 'unstamped');
  fails(f.run(['--skip-build'])); assert.ok(!f.commands().some(c => c[0] === 'flutter'));
});

test('identical source, tools, features and library may reuse the stamped host build', t => {
  const f = fixture(t); succeeds(f.run(['--features', 'native-media-host-tests']));
  succeeds(f.run(['--skip-build', '--features', 'native-media-host-tests', '--machine']));
  assert.equal(f.commands().filter(c => c[0] === 'cargo').length, 1);
  assert.equal(f.commands().filter(c => c[0] === 'flutter').length, 2);
});

test('feature mismatch rejects reuse without invoking Flutter', t => {
  const f = fixture(t); succeeds(f.run()); fails(f.run(['--skip-build', '--features', 'native-media-host-tests']));
  assert.equal(f.commands().filter(c => c[0] === 'flutter').length, 1);
});

for (const name of ['rust/src/lib.rs', 'native/fixture.c', 'rust/Cargo.lock', '.cargo/config.toml']) {
  test(`changed ${name} rejects reuse even with preserved mtime`, t => {
    const f = fixture(t); succeeds(f.run()); const file = path.join(f.root, name); const stat = fs.statSync(file);
    fs.appendFileSync(file, '\n// changed source\n'); fs.utimesSync(file, stat.atime, stat.mtime);
    fails(f.run(['--skip-build'])); assert.equal(f.commands().filter(c => c[0] === 'flutter').length, 1);
  });
}

test('library tampering rejects reuse', t => {
  const f = fixture(t); succeeds(f.run()); fs.appendFileSync(f.library, 'changed'); fails(f.run(['--skip-build']));
});

test('source commit mismatch rejects reuse', t => {
  const f = fixture(t); succeeds(f.run());
  assert.equal(spawnSync('git', ['commit', '--allow-empty', '-qm', 'next source'], { cwd: f.root, env: f.environment }).status, 0);
  fails(f.run(['--skip-build']));
});

test('failed rebuild removes previous provenance instead of advertising stale success', t => {
  const f = fixture(t); succeeds(f.run()); fails(f.run([], { HOST_FIXTURE_CARGO_FAIL: '1' }));
  assert.equal(fs.existsSync(f.stamp), false); fails(f.run(['--skip-build']));
});


test('successful cargo exit without a fresh library cannot stamp an old library', t => {
  const f = fixture(t); succeeds(f.run());
  fails(f.run([], { HOST_FIXTURE_NO_LIBRARY: '1' }));
  assert.equal(fs.existsSync(f.stamp), false);
});

test('source changing during build is rejected before Flutter', t => {
  const f = fixture(t); fails(f.run([], { HOST_FIXTURE_CHANGE_SOURCE: '1' }));
  assert.equal(fs.existsSync(f.stamp), false);
  assert.equal(f.commands().filter(c => c[0] === 'flutter').length, 0);
});


for (const variable of ['CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'HOST_CFLAGS', 'TARGET_CFLAGS']) {
  test(`changed native compiler configuration ${variable} invalidates reuse`, t => {
    const f = fixture(t); succeeds(f.run(['--features', 'native-media-host-tests']));
    fails(f.run(['--skip-build', '--features', 'native-media-host-tests'], { [variable]: '-DFIXTURE_CHANGED=1' }));
    assert.equal(f.commands().filter(c => c[0] === 'flutter').length, 1);
  });
}

test('native compiler version change at the same path invalidates reuse', t => {
  const f = fixture(t); succeeds(f.run(['--features', 'native-media-host-tests']));
  fails(f.run(['--skip-build', '--features', 'native-media-host-tests'], { HOST_FIXTURE_CC_VERSION: '2' }));
  assert.equal(f.commands().filter(c => c[0] === 'flutter').length, 1);
});
