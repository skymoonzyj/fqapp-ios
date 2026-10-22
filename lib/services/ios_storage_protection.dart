import 'dart:io';
import 'platform_channel.dart';

/// Fixed native paths only: no Dart-supplied filesystem path crosses the channel.
class IosStorageProtection {
  static const _channel = AppMethodChannel('fqapp/fair_memory');
  static Future<void> configure({String? boxName}) async {
    if (!Platform.isIOS) return;
    final configured = await _channel
        .invokeMethod<bool>(
          boxName == null ? 'configureStorage' : 'configureBox',
          boxName == null ? null : {'name': boxName},
        )
        .timeout(const Duration(seconds: 15));
    if (configured != true) throw StateError('无法配置本机存储保护，请解锁设备后重试。');
  }

  static Future<void> boxOpened(String name) async {
    if (!const {
      'history',
      'read_time',
      'watched_episodes',
      'audio_download_v1',
      'drama_download_v1',
      'chapter_cache_v1',
    }.contains(name)) {
      return;
    }
    await configure(boxName: name);
  }
}
