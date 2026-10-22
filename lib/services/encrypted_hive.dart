import 'dart:io';

import 'package:hive_ce/hive.dart';

import 'secure_key_provider.dart';
import 'ios_storage_protection.dart';

/// Opens every Hive box encrypted (hive_ce, AES-256 `HiveAesCipher`).
///
/// Layout: the encrypted box lives at `<name>_enc`; the legacy plaintext box
/// at `<name>` is only ever read for migration. Migration is crash-safe:
/// copy the legacy entries into the encrypted box (merging keys the
/// encrypted box is still missing after a crash), and only then delete the
/// legacy box. A crash mid-migration leaves the legacy box in place, so the
/// next launch retries instead of losing records.
///
/// Key unavailability or mismatch preserves every existing encrypted file.
/// Callers can retry after unlocking or guide the user to restore an app JSON
/// backup. Never erase a box or silently show an empty replacement on failure.
class EncryptedHive {
  EncryptedHive._();

  /// Name of the encrypted box for a legacy box [name].
  static String encryptedBoxName(String name) => '${name}_enc';

  static bool isBoxOpen(HiveInterface hive, String name) =>
      hive.isBoxOpen(encryptedBoxName(name)) || hive.isBoxOpen(name);

  /// A single key protects all boxes. Check the whole Hive directory before
  /// any parallel initializer can generate a replacement key for a new box.
  /// Keep this synchronous because bootstrap also runs in widget fake-async.
  static bool _encryptedDataOnDisk() {
    final home = (Hive as dynamic).homePath as String?;
    if (home == null || home.isEmpty) return false;
    final directory = Directory(home);
    if (!directory.existsSync()) return false;
    return directory.listSync().whereType<File>().any((file) {
      final path = file.path.toLowerCase();
      return path.endsWith('_enc.hive') ||
          path.endsWith('_enc.hivec') ||
          path.endsWith('_enc.lock');
    });
  }

  /// The open box, preferring the encrypted one. Callers must check
  /// [isBoxOpen] first.
  static Box<E> box<E>(HiveInterface hive, String name) =>
      hive.isBoxOpen(encryptedBoxName(name))
      ? hive.box<E>(encryptedBoxName(name))
      : hive.box<E>(name);

  static Future<Box<E>> openBox<E>(
    HiveInterface hive,
    String name, {
    SecureKeyProvider? keys,
    bool requireEncryption = false,
    CompactionStrategy? compactionStrategy,
  }) async {
    Future<Box<E>> protected(Future<Box<E>> pending) async {
      final box = await pending;
      await IosStorageProtection.boxOpened(name);
      return box;
    }

    // hive_ce's openBox takes a non-nullable compaction strategy (its
    // default is internal, so reproduce it here: compact once 15% of the
    // entries and at least 60 entries have been deleted).
    final strategy =
        compactionStrategy ??
        (int entries, int deleted) => deleted > 60 && deleted / entries > 0.15;
    final encName = encryptedBoxName(name);
    if (hive.isBoxOpen(encName)) {
      return protected(Future.value(hive.box<E>(encName)));
    }

    final encryptedExists = _encryptedDataOnDisk();
    final key = await (keys ?? SecureKeyProvider.instance).getOrCreateKey(
      allowCreate: !encryptedExists,
    );
    if (key == null) {
      // An encrypted box already on disk means an earlier session did have a
      // key and the data is still there. Degrading to the legacy plaintext box
      // in that case shows an empty library, hides the real records, and starts
      // writing in parallel beside them - so fail closed instead. Callers sit
      // under a retryable bootstrap, so the user can retry once the key is
      // available and nothing is lost.
      if (_encryptedDataOnDisk()) {
        throw StateError('加密密钥不可用，已保留原有加密数据。请解锁设备后重试，或通过应用内 JSON 备份恢复。');
      }
      if (requireEncryption) {
        throw StateError('加密密钥不可用，请解锁后重试，拒绝以明文打开 $name');
      }
      // Degraded path (tests, a first run before any key existed, a broken
      // Keystore with no encrypted data yet): plaintext legacy box, so the app
      // keeps working. Never used when a key is available.
      return protected(hive.openBox<E>(name, compactionStrategy: strategy));
    }

    final cipher = HiveAesCipher(key);
    if (await hive.boxExists(encName)) {
      try {
        final box = await hive.openBox<E>(
          encName,
          encryptionCipher: cipher,
          crashRecovery: false,
          compactionStrategy: strategy,
        );
        await _reconcileLegacy(hive, name, box);
        return protected(Future.value(box));
      } on HiveError catch (e) {
        if (!_looksLikeDecryptionFailure(e)) rethrow;
        throw StateError('加密数据无法读取，已保留 $encName。请使用原设备密钥重试，或通过应用内 JSON 备份恢复。');
      }
    }

    if (await hive.boxExists(name)) {
      final legacy = await hive.openBox<E>(name);
      final entries = <dynamic, dynamic>{};
      for (final legacyKey in legacy.keys) {
        entries[legacyKey] = legacy.get(legacyKey);
      }
      await legacy.close();
      final box = await hive.openBox<E>(
        encName,
        encryptionCipher: cipher,
        compactionStrategy: strategy,
      );
      if (entries.isNotEmpty) {
        await box.putAll(Map<dynamic, E>.from(entries));
      }
      await _reconcileLegacy(hive, name, box);
      return protected(Future.value(box));
    }

    return protected(
      hive.openBox<E>(
        encName,
        encryptionCipher: cipher,
        compactionStrategy: strategy,
      ),
    );
  }

  /// Reconciles a leftover legacy box with the encrypted box.
  ///
  /// A crash between the copy and the delete can leave a partial encrypted
  /// box next to the full legacy box. Missing keys are copied from the
  /// legacy box (never overwriting: a key already present in the encrypted
  /// box may hold a newer write from after the migration started). Once
  /// every legacy key is present in the encrypted box, the legacy box is
  /// deleted; otherwise it is kept so the next launch can retry.
  static Future<void> _reconcileLegacy<E>(
    HiveInterface hive,
    String name,
    Box<E> encrypted,
  ) async {
    if (!await hive.boxExists(name)) return;
    final legacy = await hive.openBox<E>(name);
    try {
      final missing = <dynamic, dynamic>{};
      for (final key in legacy.keys) {
        if (!encrypted.containsKey(key)) {
          missing[key] = legacy.get(key);
        }
      }
      if (missing.isNotEmpty) {
        await encrypted.putAll(Map<dynamic, E>.from(missing));
      }
    } finally {
      await legacy.close();
    }
    await hive.deleteBoxFromDisk(name);
  }

  /// Report a recovery path for key/cipher failures without changing the file.
  /// Other failures keep their original error for retry diagnostics.
  static bool _looksLikeDecryptionFailure(HiveError error) {
    final message = error.message.toLowerCase();
    return const [
      'checksum',
      'decrypt',
      'cipher',
      'corrupt',
      'authentication',
      'wrong key',
      'invalid key',
      'bad key',
      'tag mismatch',
      'mac mismatch',
    ].any(message.contains);
  }
}
