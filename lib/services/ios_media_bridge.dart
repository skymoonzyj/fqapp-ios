import 'dart:typed_data';

import '../src/rust/api/media.dart' as media;

class IosMediaLease {
  IosMediaLease({
    required this.requestId,
    required this.reference,
    required this.playbackUrl,
  });
  final String requestId;
  final media.MediaSessionRef reference;
  final Uri playbackUrl;
  Future<void>? _closing;
}

typedef MediaCreate =
    Future<media.MediaSession> Function({
      required String requestId,
      required media.MediaSource source,
      Uint8List? key,
    });
typedef MediaCancel = Future<bool> Function({required String requestId});
typedef MediaClose =
    Future<void> Function({required media.MediaSessionRef session});

/// Keeps media alive until the native owner actually releases its player.
/// Its registry is independent of route/controller disposal and PiP handoff.
class IosMediaBridge {
  IosMediaBridge({MediaCreate? create, MediaCancel? cancel, MediaClose? close})
    : _create = create ?? media.mediaCreate,
      _cancel = cancel ?? media.mediaCancel,
      _close = close ?? media.mediaClose;

  static final instance = IosMediaBridge();
  static final _owners = <int, IosMediaBridge>{};
  final MediaCreate _create;
  final MediaCancel _cancel;
  final MediaClose _close;
  final _players = <int, IosMediaLease>{};

  Future<IosMediaLease> open(
    String source,
    String keyHex, {
    required String requestId,
  }) async {
    final uri = Uri.tryParse(source);
    final media.MediaSource input;
    if (uri != null && uri.scheme == 'https' && uri.host.isNotEmpty) {
      input = media.MediaSource.remoteHttps(url: source);
    } else if (uri != null && uri.scheme == 'file' && uri.host.isEmpty) {
      input = media.MediaSource.localFile(path: uri.toFilePath());
    } else if (source.startsWith('/')) {
      input = media.MediaSource.localFile(path: source);
    } else {
      throw ArgumentError('Invalid media source');
    }
    if (keyHex.isNotEmpty &&
        !RegExp(r'^(?:[0-9a-fA-F]{2})+$').hasMatch(keyHex)) {
      throw ArgumentError('Invalid media key');
    }
    final key = keyHex.isEmpty
        ? null
        : Uint8List.fromList([
            for (var i = 0; i < keyHex.length; i += 2)
              int.parse(keyHex.substring(i, i + 2), radix: 16),
          ]);
    final session = await _create(
      requestId: requestId,
      source: input,
      key: key,
    );
    final lease = IosMediaLease(
      requestId: requestId,
      reference: session.session,
      playbackUrl: Uri.tryParse(session.playbackUrl) ?? Uri(),
    );
    final url = lease.playbackUrl;
    if (url.scheme != 'http' ||
        url.host != '127.0.0.1' ||
        !url.hasPort ||
        url.userInfo.isNotEmpty) {
      await close(lease);
      throw StateError('Invalid media playback URL');
    }
    return lease;
  }

  Future<void> cancel(String requestId) async {
    await _cancel(requestId: requestId);
  }

  Future<void> close(IosMediaLease lease) =>
      lease._closing ??= _close(session: lease.reference);

  void bind(int playerId, IosMediaLease lease) {
    if (_owners.containsKey(playerId)) {
      throw StateError('Player lease already bound');
    }
    _owners[playerId] = this;
    _players[playerId] = lease;
  }

  Future<void> releasePlayer(int playerId) async {
    final lease = _players.remove(playerId);
    if (identical(_owners[playerId], this)) _owners.remove(playerId);
    if (lease != null) await close(lease);
  }

  static Future<void> releaseRegisteredPlayer(int playerId) async {
    await _owners[playerId]?.releasePlayer(playerId);
  }
}
