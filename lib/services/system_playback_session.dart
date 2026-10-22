import 'dart:async';
import 'package:flutter/widgets.dart';
import 'native_player.dart';
import 'episode_source_cache.dart';

/// A business playback session outlives its presentation surface.
abstract interface class SystemPlaybackSession {
  String get id;
  Future<void> handleCommand(String action);
  Future<void> close();
}

class SystemPlaybackRegistry {
  static String? _activeID;
  static final _sessions = <String, SystemPlaybackSession>{};
  static final _closing = <String, Future<void>>{};

  static void adopt(SystemPlaybackSession session) {
    final existing = _sessions[session.id];
    if (_closing.containsKey(session.id) ||
        (existing != null && !identical(existing, session))) {
      throw StateError('Playback session ID is already owned');
    }
    _sessions[session.id] = session;
    _activeID = session.id;
  }

  static SystemPlaybackSession? find(String id) => _sessions[id];

  static bool get hasActiveContinuation => _sessions.isNotEmpty;

  static Future<void> closeAll() async {
    await Future.wait(_sessions.keys.toList().map(release));
  }

  static bool get hasRestorablePresentation {
    final session = _sessions[_activeID];
    return session is RetainedPlaybackSession &&
        session.detached &&
        session.restorePresentation != null;
  }

  static Future<bool> restorePresentation() async {
    final session = _sessions[_activeID];
    if (session is! RetainedPlaybackSession) return false;
    return await session.restorePresentation?.call() ?? false;
  }

  static void suspendRemoteDispatch() {
    _activeID = null;
  }

  static bool dispatch(String action) {
    final session = _sessions[_activeID];
    if (session == null ||
        (session is RetainedPlaybackSession && !session.detached)) {
      return false;
    }
    unawaited(session.handleCommand(action).catchError((Object _) {}));
    return true;
  }

  /// An externally owned controller has completed its own shutdown.
  static void forget(SystemPlaybackSession session) {
    if (identical(_sessions[session.id], session)) _sessions.remove(session.id);
    if (_activeID == session.id) _activeID = null;
  }

  static Future<void> release(String id) {
    final pending = _closing[id];
    if (pending != null) return pending;
    final session = _sessions.remove(id);
    if (session == null) return Future<void>.value();
    final completion = session.close().whenComplete(() {
      _closing.remove(id);
    });
    _closing[id] = completion;
    return completion;
  }
}

/// Owns the player, next-episode requests and progress independently of a State.
class RetainedPlaybackSession extends ChangeNotifier
    with WidgetsBindingObserver
    implements SystemPlaybackSession {
  RetainedPlaybackSession({
    required this.id,
    required NativePlayer player,
    required int index,
    required this.length,
    required this.loadSource,
    required this.playerFactory,
    required this.saveProgress,
    this.onChangedPlayer,
    this.onClose,
    this.restorePresentation,
    this.loadRate,
    this.configurePlayer,
    this.backgroundAllowed,
    this.backgroundPreference,
    this.onBackgroundDisabled,
  // Keep the public named constructor arguments while storing authority privately.
  // ignore: prefer_initializing_formals
  }) : _player = player,
       // ignore: prefer_initializing_formals
       _index = index;
  @override
  final String id;
  NativePlayer _player;
  NativePlayer get player => _player;
  int _index;
  int get index => _index;
  final int length;
  final Future<EpisodeSource?> Function(int) loadSource;
  final NativePlayer Function() playerFactory;
  final Future<void> Function(int, NativePlayer) saveProgress;
  final Future<void> Function(int, NativePlayer)? onChangedPlayer;
  final void Function()? onClose;
  final Future<bool> Function()? restorePresentation;
  final Future<double> Function()? loadRate;
  final Future<void> Function(NativePlayer)? configurePlayer;
  final bool Function()? backgroundAllowed;
  final Listenable? backgroundPreference;
  final Future<void> Function()? onBackgroundDisabled;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _enforceBackground(state);
  }

  void _preferencesChanged() =>
      _enforceBackground(WidgetsBinding.instance.lifecycleState);
  void _enforceBackground(AppLifecycleState? state) {
    if (!_detached ||
        _closed ||
        state == null ||
        state == AppLifecycleState.resumed ||
        backgroundAllowed?.call() != false) {
      return;
    }
    unawaited(player.pause());
    unawaited(onBackgroundDisabled?.call());
  }

  StreamSubscription<bool>? _completed;
  StreamSubscription<Duration>? _position;
  Timer? _saveTimer;
  bool _detached = false;
  bool get detached => _detached;
  bool _closed = false;
  bool get closed => _closed;
  bool _switching = false;
  Future<void>? _operation;
  Future<void> get settled => _operation ?? Future<void>.value();
  int _generation = 0;
  NativePlayer? _candidate;
  Future<void>? _closing;
  Object? error;
  double rate = 1;

  void detach() {
    if (_closed || _detached) return;
    _detached = true;
    if (backgroundAllowed != null) {
      WidgetsBinding.instance.addObserver(this);
      backgroundPreference?.addListener(_preferencesChanged);
    }
    _subscribe();
    _saveTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (player.playWhenReady) unawaited(saveProgress(index, player));
    });
  }

  void attach() {
    _detached = false;
    if (backgroundAllowed != null) {
      WidgetsBinding.instance.removeObserver(this);
      backgroundPreference?.removeListener(_preferencesChanged);
    }
    _completed?.cancel();
    _position?.cancel();
    _completed = null;
    _position = null;
    _saveTimer?.cancel();
  }

  void _subscribe() {
    _completed?.cancel();
    _position?.cancel();
    final active = player;
    _completed = active.completedStream.listen((done) {
      if (!done || !_detached || _closed || !identical(player, active)) return;
      if (index + 1 < length) {
        unawaited(select(index + 1));
      } else {
        unawaited(SystemPlaybackRegistry.release(id));
      }
    });
    _position = active.positionStream.listen((_) {
      if (!_closed) notifyListeners();
    });
  }

  Future<void> select(int target) {
    if (_switching) return settled;
    return _operation = _select(target);
  }

  Future<void> _select(int target) async {
    if (_closed || _switching || target < 0 || target >= length) return;
    _switching = true;
    final generation = ++_generation;
    NativePlayer? candidate;
    try {
      final source = await loadSource(target);
      if (_closed || generation != _generation) return;
      if (source == null || source.url.isEmpty) {
        throw StateError('Media unavailable');
      }
      final previous = player;
      await saveProgress(index, previous);
      candidate = _candidate = playerFactory();
      await candidate.create(source.url, source.keyHex);
      if (_closed || generation != _generation) return;
      rate = await loadRate?.call() ?? rate;
      await candidate.setRate(rate);
      await configurePlayer?.call(candidate);
      await candidate.play();
      if (_closed || generation != _generation) return;
      await onChangedPlayer?.call(target, candidate);
      if (_closed || generation != _generation) return;
      _player = candidate;
      _candidate = null;
      candidate = null;
      _index = target;
      error = null;
      if (_detached) _subscribe();
      // Publish the new authority before asynchronous cleanup of the old host.
      notifyListeners();
      await previous.dispose();
    } catch (failure) {
      if (!_closed) {
        error = failure;
        notifyListeners();
      }
    } finally {
      await candidate?.dispose();
      _candidate = null;
      _switching = false;
    }
  }

  @override
  Future<void> handleCommand(String action) async {
    if (_closed) return;
    switch (action) {
      case 'next':
        await select(index + 1);
      case 'prev':
        await select(index - 1);
      case 'play':
        await player.play();
      case 'pause':
        await player.pause();
      case 'playPause':
        if (player.playWhenReady) {
          await player.pause();
        } else {
          await player.play();
        }
      case 'stop':
        await SystemPlaybackRegistry.release(id);
    }
    if (!_closed) notifyListeners();
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    ++_generation;
    attach();
    try {
      await saveProgress(index, player);
    } finally {
      await Future.wait([
        player.dispose(),
        if (_candidate != null) _candidate!.dispose(),
      ]);
      onClose?.call();
      notifyListeners();
    }
  }
}
