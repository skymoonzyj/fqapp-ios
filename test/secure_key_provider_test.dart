import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:fqapp/services/secure_key_provider.dart';

/// The bootstrap awaits this provider during startup, so a secure-storage
/// call that never resolves must degrade (null) instead of hanging startup
/// forever — a wedged Keystore, or an unmocked platform channel in widget
/// tests, both present as a Future that never completes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'iOS reads and writes device-only keys accessible after first unlock',
    () async {
      final platform = _RecordingPlatformStorage();
      final storage = FlutterSecureKeyStorage(platform);
      await storage.read(SecureKeyProvider.hiveBoxKeyName);
      await storage.write(SecureKeyProvider.devicePoolKeyName, 'test-fixture');
      expect(platform.calls.map((call) => call.$1), [
        SecureKeyProvider.hiveBoxKeyName,
        SecureKeyProvider.devicePoolKeyName,
      ]);
      for (final call in platform.calls) {
        expect(call.$2['accessibility'], 'first_unlock_this_device');
        expect(call.$2['synchronizable'], 'false');
      }
    },
  );

  test('an unavailable key read never writes a replacement', () async {
    final storage = _UnavailableStorage();
    final provider = SecureKeyProvider(storage: storage);
    expect(await provider.getOrCreateKey(), isNull);
    expect(storage.writes, 0);
  });

  test(
    'device pool with existing data does not provision a missing key',
    () async {
      final storage = _MapStorage();
      final provider = SecureKeyProvider(storage: storage);
      expect(await provider.devicePoolKey(allowCreate: false), isNull);
      expect(storage.values, isEmpty);
    },
  );

  test('a never-resolving read degrades to null after the timeout', () async {
    final provider = SecureKeyProvider(
      storage: _HangingStorage(),
      storageTimeout: const Duration(milliseconds: 100),
    );
    final stopwatch = Stopwatch()..start();
    expect(await provider.getOrCreateKey(), isNull);
    expect(stopwatch.elapsedMilliseconds, lessThan(5000));
  });

  test(
    'a failed load is cached: the next lookup returns null at once',
    () async {
      final provider = SecureKeyProvider(
        storage: _HangingStorage(),
        storageTimeout: const Duration(milliseconds: 100),
      );
      expect(await provider.getOrCreateKey(), isNull);
      final stopwatch = Stopwatch()..start();
      expect(await provider.getOrCreateKey(), isNull);
      // Would take another full timeout if the failure were not cached.
      expect(stopwatch.elapsedMilliseconds, lessThan(50));
    },
  );

  test('a throwing store degrades to null', () async {
    final provider = SecureKeyProvider(
      storage: _ThrowingStorage(),
      storageTimeout: const Duration(milliseconds: 100),
    );
    expect(await provider.getOrCreateKey(), isNull);
  });

  test('a working store generates once and reuses the persisted key', () async {
    final storage = _MapStorage();
    final first = SecureKeyProvider(
      storage: storage,
      storageTimeout: const Duration(milliseconds: 100),
    );
    final key = await first.getOrCreateKey();
    expect(key, isNotNull);
    expect(key!.length, 32);
    expect(await first.getOrCreateKey(), same(key));

    // A fresh provider reads the persisted key instead of generating anew.
    final second = SecureKeyProvider(
      storage: storage,
      storageTimeout: const Duration(milliseconds: 100),
    );
    expect(await second.getOrCreateKey(), key);
  });
}

class _HangingStorage implements SecureKeyStorage {
  @override
  Future<String?> read(String key) => Completer<String?>().future;

  @override
  Future<void> write(String key, String value) => Completer<void>().future;
}

class _ThrowingStorage implements SecureKeyStorage {
  @override
  Future<String?> read(String key) async => throw StateError('no keystore');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('no keystore');
}

class _MapStorage implements SecureKeyStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

class _UnavailableStorage implements SecureKeyStorage {
  int writes = 0;
  @override
  Future<String?> read(String key) async =>
      throw PlatformException(code: 'keychain_unavailable');
  @override
  Future<void> write(String key, String value) async {
    writes++;
  }
}

// Capture options at our storage boundary: the plugin itself selects its
// operating system with dart:io, not debugDefaultTargetPlatformOverride.
class _RecordingPlatformStorage extends FlutterSecureStorage {
  final calls = <(String, Map<String, String>)>[];
  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    calls.add((key, iOptions?.toMap() ?? const {}));
    return null;
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    calls.add((key, iOptions?.toMap() ?? const {}));
  }
}
