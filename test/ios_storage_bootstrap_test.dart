import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/main.dart';
import 'package:fqapp/services/backend_transport.dart';
import 'package:fqapp/services/secure_key_provider.dart';

class _Storage implements SecureKeyStorage {
  int writes = 0;
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {
    writes++;
  }
}

void main() {
  test(
    'existing encrypted pool vetoes replacement key and core provisioning',
    () async {
      final dir = await Directory.systemTemp.createTemp('fqapp-pool-guard-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/device_pool.json');
      final bytes = Uint8List.fromList('FQPOOL1fixture-ciphertext'.codeUnits);
      await file.writeAsBytes(bytes);
      final storage = _Storage();
      var provisions = 0;
      await expectLater(
        provisionDevicePoolKey(
          poolPath: file.path,
          keys: SecureKeyProvider(storage: storage),
          provision: (_) async {
            provisions++;
          },
        ),
        throwsStateError,
      );
      expect(storage.writes, 0);
      expect(provisions, 0);
      expect(await file.readAsBytes(), bytes);
    },
  );
  test(
    'first pool provisions once, failures are actionable without file mutation',
    () async {
      final dir = await Directory.systemTemp.createTemp('fqapp-pool-new-');
      addTearDown(() => dir.delete(recursive: true));
      final storage = _Storage();
      await expectLater(
        provisionDevicePoolKey(
          poolPath: '${dir.path}/device_pool.json',
          keys: SecureKeyProvider(storage: storage),
          provision: (_) async {
            throw StateError('fixture');
          },
        ),
        throwsStateError,
      );
      expect(storage.writes, 1);
      expect(await Directory(dir.path).list().isEmpty, isTrue);
    },
  );
  testWidgets('startup failure explains unlock and preserved encrypted data', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppBootstrap(
          initializer: () async {
            throw StateError('missing key');
          },
          child: const Text('ready'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('解锁'), findsOneWidget);
    expect(find.textContaining('JSON'), findsOneWidget);
    expect(find.text('ready'), findsNothing);
  });
}
