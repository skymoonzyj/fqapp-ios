import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/chapter_download.dart';
import 'package:fqapp/services/chapter_text_formatter.dart';
import 'package:fqapp/services/app_log.dart';

/// 不触磁盘的 [ChapterCache]：读永远 miss，写只记账。
class _FakeChapterCache implements ChapterCache {
  final reads = <String>[];
  final writes =
      <
        ({
          String bookId,
          String chapterId,
          String title,
          String text,
          bool pinned,
        })
      >[];
  int saveBookCalls = 0;

  @override
  int get chapterCapacity => 500;

  @override
  Future<String?> read({
    required String bookId,
    required String chapterId,
  }) async {
    reads.add(chapterId);
    return null;
  }

  @override
  Future<void> write({
    required String bookId,
    required String chapterId,
    required String title,
    required String text,
    bool pinned = false,
  }) async {
    writes.add((
      bookId: bookId,
      chapterId: chapterId,
      title: title,
      text: text,
      pinned: pinned,
    ));
  }

  @override
  Future<void> saveBook(CachedBook book) async {
    saveBookCalls++;
  }

  @override
  Future<Set<String>> cachedChapterIds(String bookId) async => {};

  @override
  Future<CachedBook?> cachedBook(String bookId) async => null;
}

class _DiagnosticCache extends _FakeChapterCache {
  final events = <String>[];
  Object? saveFailure;
  final readFailures = <int, Object>{};
  final writeFailures = <int, Object>{};
  var readCalls = 0;
  var writeCalls = 0;

  @override
  Future<void> saveBook(CachedBook book) async {
    events.add('saveBook');
    final failure = saveFailure;
    if (failure != null) throw failure;
    await super.saveBook(book);
  }

  @override
  Future<String?> read({
    required String bookId,
    required String chapterId,
  }) async {
    events.add('read');
    final failure = readFailures[++readCalls];
    if (failure != null) throw failure;
    return super.read(bookId: bookId, chapterId: chapterId);
  }

  @override
  Future<void> write({
    required String bookId,
    required String chapterId,
    required String title,
    required String text,
    bool pinned = false,
  }) async {
    events.add('write');
    final failure = writeFailures[++writeCalls];
    if (failure != null) throw failure;
    await super.write(
      bookId: bookId,
      chapterId: chapterId,
      title: title,
      text: text,
      pinned: pinned,
    );
  }
}

class _SensitiveFailure implements Exception {
  final String message = _privateMarkers.join('|');
  var toStringCalls = 0;
  @override
  String toString() {
    toStringCalls++;
    throw StateError(message);
  }
}

class _DiagnosticSinkFailure implements Exception {}

const _privateMarkers = [
  'QA_PRIVATE_BOOK_ID',
  'QA_PRIVATE_TITLE',
  'QA_PRIVATE_CHAPTER_ID',
  'QA_PRIVATE_BODY',
  'https://qa.invalid/private',
  'QA_PRIVATE_KEY',
  'QA_PRIVATE_HIVE',
];

CachedBook _privateBook() => CachedBook(
  id: _privateMarkers[0],
  title: _privateMarkers[1],
  cover: _privateMarkers[4],
  chapters: [
    Chapter(
      itemId: _privateMarkers[2],
      title: _privateMarkers[1],
      volumeName: _privateMarkers[6],
    ),
  ],
);

void _expectFailureLog(String phase, String type) {
  final entries = AppLog.instance.entries;
  expect(entries, hasLength(1));
  expect(entries.single.level, LogLevel.warn);
  expect(entries.single.tag, 'chapter-cache');
  expect(entries.single.message, 'failed phase=$phase type=$type');
  for (final marker in _privateMarkers) {
    expect(entries.single.message, isNot(contains(marker)));
  }
}

CachedBook _book(int chapterCount) => CachedBook(
  id: 'book-1',
  title: '书',
  chapters: [
    for (var i = 1; i <= chapterCount; i++)
      Chapter(itemId: 'c$i', title: '第$i章', volumeName: ''),
  ],
);

void main() {
  setUp(() => AppLog.instance.resetForTest());
  tearDown(() => AppLog.instance.resetForTest());

  test('双启：运行中再次 start 被忽略，只跑一批', () async {
    final gate = Completer<void>();
    final entered = Completer<void>();
    final loaderCalls = <String>[];
    final cache = _FakeChapterCache();
    final download = ChapterDownload(
      cache: cache,
      book: _book(3),
      loader: (chapter) async {
        loaderCalls.add(chapter.itemId);
        if (chapter.itemId == 'c1') {
          // 第一章的 loader 进来 = 批次已在跑；用门挡住它，好让第二次
          // start 有机会在运行中发生。
          if (!entered.isCompleted) entered.complete();
          await gate.future;
        }
        return '正文${chapter.itemId}内容……';
      },
    );
    addTearDown(download.dispose);

    final first = download.start(startIndex: 0, count: 3);
    await entered.future;
    expect(download.value.running, isTrue);

    // 第二次 start 在运行中：立即返回，不产生第二次 loader 调用，
    // 不重置进度、不开第二批。
    await download.start(startIndex: 0, count: 3);
    expect(loaderCalls, ['c1']);

    gate.complete();
    await first;
    expect(loaderCalls, ['c1', 'c2', 'c3']);
    expect(cache.writes, hasLength(3));
    expect(download.value.running, isFalse);
    expect(download.value.completed, 3);
    expect(download.value.total, 3);
    expect(download.value.message, isNotNull);
  });

  test('取消：门开后不再落盘，已保存数保持 0', () async {
    final gate = Completer<void>();
    final entered = Completer<void>();
    final cache = _FakeChapterCache();
    final download = ChapterDownload(
      cache: cache,
      book: _book(2),
      loader: (chapter) async {
        if (!entered.isCompleted) entered.complete();
        await gate.future;
        return '正文${chapter.itemId}内容……';
      },
    );
    addTearDown(download.dispose);

    final first = download.start(startIndex: 0, count: 2);
    await entered.future;
    expect(download.value.running, isTrue);

    download.cancel();
    expect(download.value.running, isFalse);
    expect(download.value.completed, 0);
    expect(download.value.message, contains('已停止'));

    // 在途的 loader 回包后，批次必须认出 job 已死：不写盘、不改计数、
    // 不覆盖取消的终态。
    gate.complete();
    await first;
    expect(cache.writes, isEmpty);
    expect(download.value.completed, 0);
    expect(download.value.running, isFalse);
    expect(download.value.message, contains('已停止'));
  });

  for (final phase in [
    'saveBook',
    'readCached',
    'loadContent',
    'decodeContent',
    'emptyContent',
    'readLatest',
    'publishContent',
    'writeCache',
  ]) {
    test(
      'failure diagnostic identifies $phase without exposing payload or changing result',
      () async {
        final cache = _DiagnosticCache();
        final failure = _SensitiveFailure();
        if (phase == 'saveBook') cache.saveFailure = failure;
        if (phase == 'readCached') cache.readFailures[1] = failure;
        if (phase == 'readLatest') cache.readFailures[2] = failure;
        if (phase == 'writeCache') cache.writeFailures[1] = failure;
        final complete = ChapterContent.fromPlainText(
          _privateMarkers[3],
          illustrationsChecked: true,
        ).toCacheText();
        final download = ChapterDownload(
          cache: cache,
          book: _privateBook(),
          loader: (_) async {
            cache.events.add('load');
            if (phase == 'loadContent') throw failure;
            if (phase == 'emptyContent') return '';
            if (phase == 'decodeContent') {
              final prefix = complete.substring(0, complete.indexOf('\n') + 1);
              return '$prefix{';
            }
            return complete;
          },
          onContentAvailable: (_, _) {
            cache.events.add('publish');
            if (phase == 'publishContent') throw failure;
          },
        );
        addTearDown(download.dispose);
        await download.start(startIndex: 0, count: 1, pin: true);
        expect(download.value.running, isFalse);
        expect(download.value.completed, 0);
        expect(download.value.total, 1);
        expect(download.value.message, '缓存未完成，已保存 0/1 章。检查网络后可重试');
        expect(cache.writes, isEmpty);
        expect(failure.toStringCalls, 0);
        final expectedEvents = switch (phase) {
          'saveBook' => ['saveBook'],
          'readCached' => ['saveBook', 'read'],
          'loadContent' ||
          'decodeContent' ||
          'emptyContent' => ['saveBook', 'read', 'load'],
          'readLatest' => ['saveBook', 'read', 'load', 'read'],
          'publishContent' => ['saveBook', 'read', 'load', 'read', 'publish'],
          _ => ['saveBook', 'read', 'load', 'read', 'publish', 'write'],
        };
        expect(cache.events, expectedEvents);
        _expectFailureLog(
          phase,
          phase == 'emptyContent'
              ? 'StateError'
              : phase == 'decodeContent'
              ? 'FormatException'
              : '_SensitiveFailure',
        );
      },
    );
  }

  test(
    'failure diagnostic retains completed count and callback-before-write order',
    () async {
      final cache = _DiagnosticCache();
      final failure = _SensitiveFailure();
      var loads = 0;
      final download = ChapterDownload(
        cache: cache,
        book: _book(2),
        loader: (_) async {
          cache.events.add('load');
          if (++loads == 2) throw failure;
          return ChapterContent.fromPlainText(
            'safe content',
            illustrationsChecked: true,
          ).toCacheText();
        },
        onContentAvailable: (_, _) => cache.events.add('publish'),
      );
      addTearDown(download.dispose);
      await download.start(startIndex: 0, count: 2, pin: true);
      expect(download.value.completed, 1);
      expect(download.value.total, 2);
      expect(download.value.running, isFalse);
      expect(download.value.message, '缓存未完成，已保存 1/2 章。检查网络后可重试');
      expect(cache.writes.single.chapterId, 'c1');
      expect(cache.writes.single.pinned, isTrue);
      expect(cache.events, [
        'saveBook',
        'read',
        'load',
        'read',
        'publish',
        'write',
        'read',
        'load',
      ]);
      expect(failure.toStringCalls, 0);
      _expectFailureLog('loadContent', '_SensitiveFailure');
    },
  );

  test(
    'successful batch keeps its original outcome without a failure diagnostic',
    () async {
      final cache = _DiagnosticCache();
      final download = ChapterDownload(
        cache: cache,
        book: _book(1),
        loader: (_) async => ChapterContent.fromPlainText(
          'safe content',
          illustrationsChecked: true,
        ).toCacheText(),
      );
      addTearDown(download.dispose);
      await download.start(startIndex: 0, count: 1);
      expect(download.value.completed, 1);
      expect(download.value.total, 1);
      expect(download.value.message, '缓存完成，可从书架的离线缓存入口继续阅读');
      expect(cache.writes, hasLength(1));
      expect(AppLog.instance.entries, isEmpty);
    },
  );

  for (final dispose in [false, true]) {
    test(
      '${dispose ? 'disposed' : 'cancelled'} batch ignores late failure without a diagnostic',
      () async {
        final cache = _DiagnosticCache();
        final entered = Completer<void>();
        final gate = Completer<void>();
        final failure = _SensitiveFailure();
        final download = ChapterDownload(
          cache: cache,
          book: _book(1),
          loader: (_) async {
            entered.complete();
            await gate.future;
            throw failure;
          },
        );
        final running = download.start(startIndex: 0, count: 1);
        await entered.future;
        if (dispose) {
          download.dispose();
        } else {
          download.cancel();
        }
        final prior = download.value;
        gate.complete();
        await running;
        expect(identical(download.value, prior), isTrue);
        expect(cache.writes, isEmpty);
        expect(AppLog.instance.entries, isEmpty);
        expect(failure.toStringCalls, 0);
        if (!dispose) download.dispose();
      },
    );
  }

  test(
    'unavailable diagnostic persistence does not change batch failure outcome',
    () async {
      final dir = await Directory.systemTemp.createTemp('fqapp-cache-log-');
      addTearDown(() async {
        await AppLog.instance.resetForTest();
        await dir.delete(recursive: true);
      });
      final blocked = File('${dir.path}/not-a-directory');
      await blocked.writeAsString('self-authored marker');
      await AppLog.instance.startPersistence(
        directory: Directory(blocked.path),
      );
      expect(AppLog.instance.filePath, isNull);
      final failure = _SensitiveFailure();
      final download = ChapterDownload(
        cache: _DiagnosticCache(),
        book: _book(1),
        loader: (_) async => throw failure,
      );
      addTearDown(download.dispose);
      await download.start(startIndex: 0, count: 1);
      expect(download.value.message, '缓存未完成，已保存 0/1 章。检查网络后可重试');
      expect(failure.toStringCalls, 0);
      _expectFailureLog('loadContent', '_SensitiveFailure');
    },
  );

  test(
    'synchronous diagnostic failure cannot interrupt the original terminal state',
    () async {
      final failure = _SensitiveFailure();
      final download = ChapterDownload(
        cache: _DiagnosticCache(),
        book: _book(1),
        loader: (_) async => throw failure,
      );
      addTearDown(download.dispose);
      var attempts = 0;
      void brokenDiagnosticListener() {
        attempts++;
        throw _DiagnosticSinkFailure();
      }

      final previous = FlutterError.onError;
      FlutterError.onError = (_) => throw _DiagnosticSinkFailure();
      AppLog.instance.revision.addListener(brokenDiagnosticListener);
      try {
        await download.start(startIndex: 0, count: 1);
      } finally {
        AppLog.instance.revision.removeListener(brokenDiagnosticListener);
        FlutterError.onError = previous;
      }
      expect(attempts, 1);
      expect(download.value.running, isFalse);
      expect(download.value.completed, 0);
      expect(download.value.message, '缓存未完成，已保存 0/1 章。检查网络后可重试');
      expect(failure.toStringCalls, 0);
    },
  );

  for (final dispose in [false, true]) {
    test(
      'R1 synchronous diagnostic ${dispose ? 'dispose' : 'cancel'} preserves its state and completes',
      () async {
        final failure = _SensitiveFailure();
        final download = ChapterDownload(
          cache: _DiagnosticCache(),
          book: _book(1),
          loader: (_) async => throw failure,
        );
        var didDispose = false;
        var notifications = 0;
        ChapterDownloadState? preserved;
        addTearDown(() {
          if (!didDispose) download.dispose();
        });
        void invalidateJob() {
          notifications++;
          if (dispose) {
            preserved = download.value;
            download.dispose();
            didDispose = true;
          } else {
            download.cancel();
            preserved = download.value;
          }
        }

        AppLog.instance.revision.addListener(invalidateJob);
        try {
          await expectLater(download.start(startIndex: 0, count: 1), completes);
          expect(notifications, 1);
          expect(identical(download.value, preserved), isTrue);
          if (!dispose) {
            expect(download.value.running, isFalse);
            expect(download.value.message, '已停止缓存，已保存的章节会保留');
          }
          expect(failure.toStringCalls, 0);
          _expectFailureLog('loadContent', '_SensitiveFailure');
        } finally {
          AppLog.instance.revision.removeListener(invalidateJob);
        }
      },
    );
  }

  test(
    'R1 synchronous diagnostic restart cannot overwrite replacement state or result',
    () async {
      final cache = _DiagnosticCache();
      final failure = _SensitiveFailure();
      final replacementEntered = Completer<void>();
      final replacementGate = Completer<void>();
      final download = ChapterDownload(
        cache: cache,
        book: _book(2),
        loader: (chapter) async {
          if (chapter.itemId == 'c1') throw failure;
          replacementEntered.complete();
          await replacementGate.future;
          return ChapterContent.fromPlainText(
            'replacement content',
            illustrationsChecked: true,
          ).toCacheText();
        },
      );
      addTearDown(download.dispose);
      var notifications = 0;
      Future<void>? replacement;
      ChapterDownloadState? replacementRunning;
      void restartJob() {
        notifications++;
        AppLog.instance.revision.removeListener(restartJob);
        download.cancel();
        replacement = download.start(startIndex: 1, count: 1, pin: true);
        replacementRunning = download.value;
      }

      AppLog.instance.revision.addListener(restartJob);
      try {
        await expectLater(download.start(startIndex: 0, count: 1), completes);
        await replacementEntered.future;
        expect(notifications, 1);
        expect(replacementRunning!.running, isTrue);
        expect(identical(download.value, replacementRunning), isTrue);
        expect(download.value.running, isTrue);
        expect(download.value.message, isNull);
      } finally {
        AppLog.instance.revision.removeListener(restartJob);
        replacementGate.complete();
        await replacement;
      }
      expect(download.value.running, isFalse);
      expect(download.value.completed, 1);
      expect(download.value.total, 1);
      expect(download.value.message, '缓存完成，可从书架的离线缓存入口继续阅读');
      expect(cache.writes.single.chapterId, 'c2');
      expect(cache.writes.single.pinned, isTrue);
      expect(failure.toStringCalls, 0);
      _expectFailureLog('loadContent', '_SensitiveFailure');
    },
  );
}
