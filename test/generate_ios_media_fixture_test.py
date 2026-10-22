import base64
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import tempfile
import subprocess
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/generate_ios_media_fixture.py'
spec = importlib.util.spec_from_file_location('generate_ios_media_fixture', SCRIPT)
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class GenerateIosMediaFixtureTest(unittest.TestCase):
    def test_oversized_define_is_rejected_before_publication(self):
        with self.assertRaisesRegex(ValueError, '60000 bytes'):
            fixture.encode_definition([{'bytesBase64': 'a' * 60_000}])

    def test_missing_ffmpeg_fails_without_publishing_fixture(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / 'defines.json'
            with self.assertRaises((OSError, ValueError)):
                fixture.generate_bundle('/definitely-missing-ffmpeg', output)
            self.assertFalse(output.exists())

    def test_failed_encoder_does_not_publish_partial_fixture(self):
        with tempfile.TemporaryDirectory() as folder:
            tool = Path(folder) / 'ffmpeg'
            tool.write_text('#!/bin/sh\nexit 7\n')
            tool.chmod(0o755)
            output = Path(folder) / 'defines.json'
            with self.assertRaises((OSError, ValueError, RuntimeError)):
                fixture.generate_bundle(str(tool), output)
            self.assertFalse(output.exists())

    def test_real_synthetic_bundle_matches_dart_define_and_cenc_contract(self):
        ffmpeg = os.environ.get('FFMPEG')
        self.assertTrue(ffmpeg, 'FFMPEG must identify the scoped verified tool; do not skip this check')
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / 'defines.json'
            report = fixture.generate_bundle(ffmpeg, output)
            bundle = json.loads(output.read_text())
            self.assertLessEqual(output.stat().st_size, 60_000,
                                 'DART_DEFINES must stay below macOS exec environment limit')
            self.assertIsInstance(bundle['FQAPP_IOS_FIXTURES'], str)
            entries = json.loads(bundle['FQAPP_IOS_FIXTURES'])
            self.assertEqual([entry['name'] for entry in entries], ['clear-avc1', 'cenc-avc1', 'offline-hvc1'])
            self.assertEqual([entry['keyHex'] for entry in entries], ['', '00112233445566778899aabbccddeeff', ''])
            payloads = [base64.b64decode(entry['bytesBase64'], validate=True) for entry in entries]
            self.assertTrue(all(len(payload) > 1000 and b'ftyp' in payload[:20] for payload in payloads))
            self.assertIn(b'cenc', payloads[1])
            self.assertIn(b'senc', payloads[1])
            self.assertNotIn(b'senc', payloads[0])
            repeated = Path(folder) / 'repeated.json'
            fixture.generate_bundle(ffmpeg, repeated)
            self.assertEqual(hashlib.sha256(repeated.read_bytes()).hexdigest(),
                             hashlib.sha256(output.read_bytes()).hexdigest(),
                             'fixed synthetic fixtures must reproduce for the same tool')
            self.assertTrue(report['cenc_matches_clear_frames'])
            self.assertEqual(report['decoded_frame_records']['video'], 6)
            self.assertGreaterEqual(report['decoded_frame_records']['audio'], 12)
            dart_define = base64.b64encode(('FQAPP_IOS_FIXTURES=' + bundle['FQAPP_IOS_FIXTURES']).encode()).decode()
            subprocess.run(['/usr/bin/true'], env={**os.environ, 'DART_DEFINES': dart_define}, check=True)


if __name__ == '__main__':
    unittest.main()
