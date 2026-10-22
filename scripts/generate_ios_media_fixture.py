#!/usr/bin/env python3
"""Generate synthetic clear/CENC fixtures solely for iOS integration tests.

No upstream inputs or real keys are accepted. The fixed public test key below
matches the native CENC regression fixture convention. Output belongs in build/;
never add the generated base64 JSON/media to product assets or Git.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

TEST_KEY = '00112233445566778899aabbccddeeff'
TEST_KID = '102132435465768798a9bacbdcedfe0f'
MAX_DEFINE_JSON_BYTES = 60_000


def encode_definition(entries):
    payload = json.dumps({'FQAPP_IOS_FIXTURES': json.dumps(entries, separators=(',', ':'))}) + '\n'
    if len(payload.encode()) > MAX_DEFINE_JSON_BYTES:
        raise ValueError('Synthetic fixture JSON exceeds 60000 bytes; DART_DEFINES would risk macOS exec limits')
    return payload


def generate_bundle(ffmpeg, output):
    output = Path(output)
    executable = shutil.which(str(ffmpeg))
    if not executable:
        raise ValueError('FFmpeg is required; synthetic media checks must not be skipped')

    def run(arguments):
        process = subprocess.run([executable, *arguments], capture_output=True,
                                 text=True, timeout=60)
        if process.returncode:
            raise RuntimeError(f'FFmpeg fixture command failed (exit {process.returncode})')
        return process.stdout

    version = run(['-version']).splitlines()[0]
    encoders = run(['-hide_banner', '-encoders'])
    if not all(re.search(r'\b' + name + r'\b', encoders) for name in ('libx264', 'libx265', 'aac')):
        raise ValueError('FFmpeg must provide libx264, libx265 and AAC encoders')
    with tempfile.TemporaryDirectory(prefix='fqapp-ios-media-') as folder:
        directory = Path(folder)
        for codec, tag in [('libx264', 'avc1'), ('libx265', 'hvc1')]:
            arguments = ['-hide_banner', '-loglevel', 'error', '-nostdin', '-y',
                         '-filter_threads', '1', '-f', 'lavfi', '-i', 'testsrc2=size=96x64:rate=6',
                         '-f', 'lavfi', '-i', 'sine=frequency=880:sample_rate=16000',
                         '-t', '1', '-c:v', codec, '-threads', '1', '-preset', 'ultrafast',
                         '-pix_fmt', 'yuv420p', '-b:v', '24k', '-maxrate', '24k',
                         '-bufsize', '48k', '-tag:v', tag]
            if codec == 'libx265':
                arguments += ['-x265-params', 'pools=2:frame-threads=2:log-level=error']
            arguments += ['-c:a', 'aac', '-ac', '1', '-b:a', '24k', '-map_metadata', '-1',
                          '-movflags', '+faststart', str(directory / f'{tag}.mp4')]
            run(arguments)
        encrypted = directory / 'avc1-cenc.mp4'
        run(['-hide_banner', '-loglevel', 'error', '-nostdin', '-y',
             '-i', str(directory / 'avc1.mp4'), '-map', '0', '-c', 'copy',
             '-encryption_scheme', 'cenc-aes-ctr', '-encryption_key', TEST_KEY,
             # FFmpeg bitexact fixes the IV for this public synthetic key only.
             # Never use deterministic IVs with private/production content keys.
             '-encryption_kid', TEST_KID, '-fflags', '+bitexact',
             '-movflags', '+faststart', str(encrypted)])

        def frame_hashes(path, key=''):
            arguments = ['-hide_banner', '-loglevel', 'error', '-nostdin', '-threads', '2']
            if key:
                arguments += ['-decryption_key', key]
            arguments += ['-i', str(path), '-map', '0:v:0', '-map', '0:a:0', '-f', 'framemd5', '-']
            return [line for line in run(arguments).splitlines() if line and not line.startswith('#')]

        clear_frames = frame_hashes(directory / 'avc1.mp4')
        if frame_hashes(encrypted, TEST_KEY) != clear_frames:
            raise ValueError('CENC fixture does not decode identically to synthetic clear media')
        hevc_frames = frame_hashes(directory / 'hvc1.mp4')
        counts = {'video': sum(line.startswith('0,') for line in clear_frames),
                  'audio': sum(line.startswith('1,') for line in clear_frames)}
        if counts['video'] != 6 or counts['audio'] < 12 or len(hevc_frames) < 12:
            raise ValueError('Synthetic fixtures lack expected video/audio frame evidence')
        entries = []
        hashes = {}
        for name, file, key in [('clear-avc1', directory / 'avc1.mp4', ''),
                                ('cenc-avc1', encrypted, TEST_KEY),
                                ('offline-hvc1', directory / 'hvc1.mp4', '')]:
            data = file.read_bytes()
            entries.append({'name': name, 'bytesBase64': base64.b64encode(data).decode(), 'keyHex': key})
            hashes[name] = hashlib.sha256(data).hexdigest()
        # Publish only after all encoders, decryption and frame checks passed.
        output.parent.mkdir(parents=True, exist_ok=True)
        temporary = Path(str(output) + '.pending')
        definition = encode_definition(entries)
        temporary.write_text(definition)
        temporary.replace(output)
        return {'ffmpeg_version': version, 'ffmpeg_sha256': hashlib.sha256(Path(executable).read_bytes()).hexdigest(),
                'fixtures_sha256': hashes, 'cenc_matches_clear_frames': True,
                'decoded_frame_records': counts, 'duration_seconds': 1,
                'define_json_size_bytes': len(definition.encode()),
                'define_json_size_limit_bytes': MAX_DEFINE_JSON_BYTES,
                'fixture_source': 'self-generated testsrc2 + sine; fixed public synthetic test key only'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ffmpeg', default=os.environ.get('FFMPEG', 'ffmpeg'))
    parser.add_argument('--output', type=Path, default=Path('build/ios-fixtures/dart-defines.json'))
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    try:
        report = generate_bundle(args.ffmpeg, args.output)
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report, indent=2))
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'iOS fixture generation failed: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
