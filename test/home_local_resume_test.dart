import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/book_open_preferences.dart';
import 'package:fqapp/services/imported_book_store.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/reader_history.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/widgets/home/home_resume_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Home resumes real local books offline and preserves network routing',
    (tester) async {
      final requests = <Uri>[];
      const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final directory = await _io(
        tester,
        () => Directory.systemTemp.createTemp('fqapp-home-local-'),
      );
      messenger.setMockMethodCallHandler(
        pathChannel,
        (_) async => directory.path,
      );
      try {
        SharedPreferences.setMockInitialValues({});
        await _io(tester, () async {
          Hive.init(directory.path);
          await LibraryStore.instance.init();
          await ShelfStore.instance.init();
        });
        // Only external HTTP I/O is replaced. Real ApiClient/_get and transport
        // run, so any mistaken local dispatch is recorded and fails promptly.
        http.runWithClient(
          () => ApiClient.instance,
          () => MockClient((request) async {
            requests.add(request.url);
            return http.Response('{}', 503);
          }),
        );
        // Hive retains source Futures from Reader writes. Keep every scenario
        // and final close in this one active fake-async/store lifecycle.
        for (final format in ['txt', 'epub']) {
          await _resetScenario(tester, requests);
          await _localScenario(tester, format, requests);
          await _unmountAndDrain(tester);
        }
        for (final unavailable in ['missing', 'empty']) {
          await _resetScenario(tester, requests);
          await _unavailableScenario(tester, unavailable, requests);
          await _unmountAndDrain(tester);
        }
        for (final direct in [false, true]) {
          await _resetScenario(tester, requests);
          await _networkScenario(tester, direct, requests);
          await _unmountAndDrain(tester);
        }
      } finally {
        await _unmountAndDrain(tester);
        await _io(tester, Hive.close);
        messenger.setMockMethodCallHandler(pathChannel, null);
        await _io(tester, () => directory.delete(recursive: true));
      }
    },
  );
}

Future<void> _resetScenario(WidgetTester tester, List<Uri> requests) async {
  SharedPreferences.setMockInitialValues({'reader_page_mode': 'scroll'});
  BookOpenPreferences.instance.resetForTest();
  await _io(tester, LibraryStore.instance.clearHistory);
  requests.clear();
}

Future<void> _localScenario(
  WidgetTester tester,
  String format,
  List<Uri> requests,
) async {
  final book = await _io(
    tester,
    () => ImportedBookStore.instance.importBytes(
      fileName: 'Home QA.$format',
      bytes: format == 'txt' ? _txt() : _epub(),
    ),
  );
  expect(book.chapters, hasLength(2));
  await _io(
    tester,
    () => ReaderHistory(LibraryStore.instance).save({
      'id': book.id, 'title': book.title, 'kind': 'book',
      'chapterId': format == 'txt'
          ? book.chapters[1].itemId
          : 'obsolete-chapter',
      // TXT chapterId wins over episode0; EPUB uses zero-based episode fallback.
      'episode': format == 'txt' ? 0 : 1,
      'progress': 0.01, 'position': 120.0, 'maxScroll': 1000.0,
      'time': DateTime.now().millisecondsSinceEpoch,
    }),
  );
  await _pumpHome(tester);
  await _tapResume(tester);
  expect(
    find.byType(DetailPage),
    findsNothing,
    reason: '$format must stay local',
  );
  expect(find.byType(ReaderPage), findsOneWidget);
  final reader = tester.widget<ReaderPage>(find.byType(ReaderPage));
  expect(reader.bookId, book.id);
  expect(reader.localOnly, isTrue);
  expect(reader.startIndex, 1);
  final content = await _io(
    tester,
    () => reader.chapterLoader!(reader.chapters[1]),
  );
  expect(content, contains('HOME_LOCAL_SECOND_MARKER'));
  await _pumpUntil(
    tester,
    () => find
        .byKey(const ValueKey('reader-paragraph-list'))
        .evaluate()
        .isNotEmpty,
  );
  expect(find.textContaining('HOME_LOCAL', findRichText: true), findsWidgets);
  final list = tester.widget<ListView>(
    find.byKey(const ValueKey('reader-paragraph-list')),
  );
  if (format == 'txt') {
    // Existing legacy restore uses position/maxScroll=12%; footer/padding
    // accounts for <0.1 percentage point, far from Home's unrelated1% card.
    final position = list.controller!.position;
    expect(position.pixels / position.maxScrollExtent, closeTo(0.12, 0.001));
  } else {
    // A stale chapter ID selects episode1 but cannot lend its old offset.
    expect(list.controller!.offset, 0);
  }
  expect(requests, isEmpty, reason: 'Local IDs must not reach any online API');
  expect(tester.takeException(), isNull);
}

Future<void> _unavailableScenario(
  WidgetTester tester,
  String unavailable,
  List<Uri> requests,
) async {
  final book = await _io(
    tester,
    () => ImportedBookStore.instance.importBytes(
      fileName: 'Unavailable.txt',
      bytes: _txt(),
    ),
  );
  await _io(
    tester,
    () => ReaderHistory(LibraryStore.instance).save({
      'id': book.id,
      'kind': 'book',
      'title': book.title,
      'episode': 1,
      'time': DateTime.now().millisecondsSinceEpoch,
    }),
  );
  await _io(tester, () async {
    if (unavailable == 'missing') {
      await ImportedBookStore.instance.deleteBook(book.id);
    } else {
      final file = File('${book.directory}/book.json');
      final manifest =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      manifest['chapters'] = [];
      await file.writeAsString(jsonEncode(manifest));
    }
  });
  await _pumpHome(tester);
  await _tapResume(tester);
  expect(find.text('本地书籍文件不可用'), findsOneWidget, reason: unavailable);
  expect(find.byType(ReaderPage), findsNothing);
  expect(find.byType(DetailPage), findsNothing);
  expect(requests, isEmpty);
  expect(tester.takeException(), isNull);
}

Future<void> _networkScenario(
  WidgetTester tester,
  bool direct,
  List<Uri> requests,
) async {
  await BookOpenPreferences.instance.setDiscoverDirectReader(direct);
  await BookOpenPreferences.instance.setShelfDirectReader(!direct);
  await _io(
    tester,
    () => ReaderHistory(LibraryStore.instance).save({
      // Local-looking prefix is deliberately outside the exact imported grammar.
      'id': 'local-network-book', 'kind': 'book', 'title': 'Network QA',
      'episode': 1, 'time': DateTime.now().millisecondsSinceEpoch,
    }),
  );
  await _pumpHome(tester);
  await _tapResume(tester);
  final detail = tester.widget<DetailPage>(find.byType(DetailPage));
  expect(detail.item.id, 'local-network-book');
  expect(detail.autoOpenReader, direct);
  expect(BookOpenPreferences.instance.discoverDirectReader.value, direct);
  expect(BookOpenPreferences.instance.shelfDirectReader.value, !direct);
  expect(requests, isNotEmpty);
  expect(requests.any((uri) => uri.path.contains('local_')), isFalse);
  expect(tester.takeException(), isNull);
}

Future<void> _pumpHome(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        homeProvider.overrideWith(
          () => HomeNotifier(
            homepageLoader:
                ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                    HomepagePage(
                      items: [_feedBook],
                      nextOffset: null,
                      sessionId: null,
                    ),
            searchLoader: (query, {int page = 1}) async => [],
          ),
        ),
      ],
      child: const MaterialApp(home: HomePage()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tapResume(WidgetTester tester) async {
  final card = find.byType(HomeResumeCard);
  await tester.ensureVisible(card);
  await tester.pumpAndSettle();
  await tester.tap(find.descendant(of: card, matching: find.text('继续阅读')));
  await _pumpUntil(
    tester,
    () =>
        find.byType(ReaderPage).evaluate().isNotEmpty ||
        find.byType(DetailPage).evaluate().isNotEmpty ||
        find.text('本地书籍文件不可用').evaluate().isNotEmpty,
  );
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _unmountAndDrain(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await _io(
    tester,
    () => ReaderHistory(LibraryStore.instance).load('__qa_cleanup__'),
  );
}

// runAsync must not await a Future whose retained source belongs to fakeAsync.
// Start real I/O without awaiting it there, then yield actual I/O and flush this
// still-active fake zone until the operation completes. Errors are rethrown.
Future<T> _io<T>(WidgetTester tester, Future<T> Function() action) async {
  var completed = false;
  late T value;
  Object? error;
  StackTrace? stack;
  await tester.runAsync(() async {
    action().then(
      (result) {
        value = result;
        completed = true;
      },
      onError: (Object caught, StackTrace trace) {
        error = caught;
        stack = trace;
        completed = true;
      },
    );
  });
  await _pumpUntil(tester, () => completed);
  if (error != null) Error.throwWithStackTrace(error!, stack!);
  return value;
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() complete) async {
  final elapsed = Stopwatch()..start();
  while (!complete() && elapsed.elapsed < const Duration(seconds: 3)) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(
    complete(),
    isTrue,
    reason: 'Real I/O and active fake-zone callbacks must settle',
  );
}

Uint8List _txt() => Uint8List.fromList(
  utf8.encode(
    '第一章 起点\nFIRST_LOCAL_MARKER。\n\n第二章 续读\n${List.filled(100, 'HOME_LOCAL_SECOND_MARKER 自创正文。').join('\n\n')}',
  ),
);

Uint8List _epub() {
  final archive = Archive()
    ..addFile(ArchiveFile.string('mimetype', 'application/epub+zip'))
    ..addFile(
      ArchiveFile.string(
        'META-INF/container.xml',
        '<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'OEBPS/content.opf',
        '<package><metadata><title>Home EPUB QA</title></metadata><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'OEBPS/one.xhtml',
        '<html><body><h1>第一章</h1><p>FIRST_LOCAL_MARKER</p></body></html>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'OEBPS/two.xhtml',
        '<html><body><h1>第二章</h1>${List.filled(100, '<p>HOME_LOCAL_SECOND_MARKER 自创正文。</p>').join()}</body></html>',
      ),
    );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

final _feedBook = MediaItem(
  id: 'feed-book',
  title: 'Feed QA',
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: 'book',
);
