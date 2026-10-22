// Self-authored offline fixtures only. This suite exercises the packaged core
// health and production page/store flows through existing injectable seams.
// The fake media adapter verifies UI state; device decoding, PiP, interruptions
// and background playback remain separate G1/G4 physical acceptance gates.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/main.dart' as app;
import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/pages/cached_book_reader.dart';
import 'package:fqapp/pages/detail_page.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/pages/search_page.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/backend_transport.dart';
import 'package:fqapp/services/chapter_cache_store.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_store.dart';

import '../test/rust_host_integration_test.dart' show pooledDevicesJson;
import '../test/support/fakes.dart' show FakeNativePlayer, MemoryReaderStore;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  tearDownAll(() {
    binding.reportData = {
      'fqapp_integration': {
        'schema_version': 1,
        'entry': 'ios_acceptance',
        'expected_tests': [
          'cold bootstrap reaches the packaged Rust core health endpoint',
          'search to detail to reading persists progress and reopens offline',
          'media controls preserve play pause and seek state with injected adapter',
        ],
        'results': {
          for (final entry in binding.results.entries)
            entry.key: entry.value == 'success' ? 'success' : 'failed',
        },
      },
    };
  });

  setUpAll(() {
    expect(Platform.isIOS, isTrue, reason: 'Run on an iOS simulator/device');
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({'reader_page_mode': 'scroll'});
  });

  testWidgets('cold bootstrap reaches the packaged Rust core health endpoint', (
    tester,
  ) async {
    final root = await Directory.systemTemp.createTemp('fqapp-ios-core-');
    final config = Directory('${root.path}/config')..createSync();
    File('${config.path}/config.json').writeAsStringSync(
      '{"algorithm_type":"8404","port":0,"anti_crawler":{"enabled":false,"redirect_url":""}}',
    );
    File(
      '${config.path}/device_pool.json',
    ).writeAsStringSync(pooledDevicesJson());
    final core = RustBackendTransport(port: 0);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await core.close();
      await root.delete(recursive: true);
    });
    var healthy = false;
    var backendFinished = false;
    String? startResult;
    Object? backendError;
    StackTrace? backendStack;
    await tester.pumpWidget(
      MaterialApp(
        home: app.AppBootstrap(
          initializer: () async {},
          backendStarter: () async {
            // This callback runs concurrently with tester.pump. Framework
            // assertions belong to the awaited test body, outside that guard.
            try {
              startResult = await core.start(
                configPath: '${config.path}/config.json',
                poolPath: '${config.path}/device_pool.json',
                filterPath: '${config.path}/filter.json',
                runtimeDir: root.path,
              );
              if (startResult == 'running') {
                healthy = await ApiClient(transport: core).health();
              }
            } catch (error, stack) {
              backendError = error;
              backendStack = stack;
              rethrow;
            } finally {
              backendFinished = true;
            }
          },
          child: const Text('fixture launch ready'),
        ),
      ),
    );
    await _until(tester, () => backendFinished, 'packaged Rust bootstrap');
    if (backendError != null) {
      Error.throwWithStackTrace(backendError!, backendStack!);
    }
    expect(startResult, 'running');
    expect(healthy, isTrue, reason: 'packaged Rust /health must return 200');
    expect(find.text('fixture launch ready'), findsOneWidget);
    expect(await core.status(), 'running');
  });

  testWidgets(
    'search to detail to reading persists progress and reopens offline',
    (tester) async {
      final root = await Directory.systemTemp.createTemp('fqapp-ios-reading-');
      Hive.init(root.path);
      await LibraryStore.instance.init();
      await ShelfStore.instance.init();
      final paths = <String>[];
      var online = true;
      final text = List.generate(
        100,
        (index) => '这是自行编写的离线验收第 $index 段。阅读、滚动与进度恢复均使用同一份合法测试文本。',
      ).join('\n\n');
      final client = MockClient((request) async {
        paths.add(request.url.path);
        if (!online) throw const SocketException('fixture offline');
        final payload = switch (request.url.path) {
          '/api/v1/search' => {
            'search_tabs': [
              {
                'title': '综合',
                'tab_type': 1,
                'has_more': false,
                'data': [
                  {
                    'book_id': 'ios-fixture-book',
                    'book_name': '离线验收故事',
                    'kind': 'book',
                  },
                ],
              },
            ],
          },
          '/api/detail' => {
            'data': {'abstract': '自行编写的验收故事，无真实上游内容。'},
          },
          '/api/directory' => {
            'data': {
              'chapterListWithVolume': [
                {
                  'volume_name': '第一卷',
                  'chapterList': [
                    {'itemId': 'ios-fixture-chapter', 'title': '第一章 验收开始'},
                  ],
                },
              ],
            },
          },
          '/api/v1/chapters/ios-fixture-chapter/novel' => {
            'data': {'content_decrypted': true, 'content': text},
          },
          '/api/content' => {
            'data': {'content': text},
          },
          _ => {'data': <String, dynamic>{}},
        };
        return http.Response.bytes(
          utf8.encode(jsonEncode({'code': 0, ...payload})),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        client.close();
        await Hive.close();
        await root.delete(recursive: true);
      });
      await http.runWithClient(() async {
        final api = ApiClient(client: client);
        await tester.pumpWidget(
          MaterialApp(
            home: SearchPage(
              searchLoader: (query, {required tabType, required offset}) =>
                  api.searchTabs(query, tabType: tabType, offset: offset),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '验收故事');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await _until(
          tester,
          () => find.text('离线验收故事').evaluate().isNotEmpty,
          'search fixture',
        );
        await tester.tap(find.text('离线验收故事'));
        await _until(
          tester,
          () => find.byType(DetailPage).evaluate().isNotEmpty,
          'detail route',
        );
        final read = find.byKey(const Key('detail_read_button'));
        await _until(
          tester,
          () => read.evaluate().isNotEmpty,
          'detail read action',
        );
        await tester.ensureVisible(read);
        await tester.pumpAndSettle();
        await tester.tap(read);
        final paragraphs = find.byKey(const ValueKey('reader-paragraph-list'));
        await _until(
          tester,
          () => paragraphs.evaluate().isNotEmpty,
          'reader body',
        );
        await tester.drag(paragraphs, const Offset(0, -600));
        await tester.pump(const Duration(seconds: 1));
        Navigator.of(tester.element(find.byType(ReaderPage))).pop();
        await tester.pumpAndSettle();
        final progress = await LibraryStore.instance.historyEntry(
          'ios-fixture-book',
        );
        expect(progress?['chapterId'], 'ios-fixture-chapter');
        expect((progress?['position'] as num?)?.toDouble(), greaterThan(0));
        final saved = (progress!['position'] as num).toDouble();
        expect(
          paths,
          containsAll(['/api/v1/search', '/api/detail', '/api/directory']),
        );
        final book = await ChapterCacheStore.instance.cachedBook(
          'ios-fixture-book',
        );
        expect(
          book,
          isNotNull,
          reason: 'online reading must populate encrypted cache',
        );

        // Unmount and close/reopen the on-disk store before the offline route.
        await tester.pumpWidget(const SizedBox.shrink());
        await Hive.close();
        Hive.init(root.path);
        await LibraryStore.instance.init();
        await ShelfStore.instance.init();
        expect(
          (await LibraryStore.instance.historyEntry(
            'ios-fixture-book',
          ))?['position'],
          saved,
        );
        online = false;
        final requestsBeforeOffline = paths.length;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => openCachedBook(context, book: book!),
                child: const Text('离线续读'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('离线续读'));
        await _until(
          tester,
          () => paragraphs.evaluate().isNotEmpty,
          'offline reader',
        );
        await tester.pumpAndSettle();
        final scrollable = find
            .descendant(of: paragraphs, matching: find.byType(Scrollable))
            .first;
        expect(
          tester.state<ScrollableState>(scrollable).position.pixels,
          greaterThan(0),
        );
        expect(
          paths.length,
          requestsBeforeOffline,
          reason: 'offline reopen must not request the network',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => client);
    },
  );

  testWidgets(
    'media controls preserve play pause and seek state with injected adapter',
    (tester) async {
      final player = FakeNativePlayer();
      final store = MemoryReaderStore();
      await tester.pumpWidget(
        MaterialApp(
          home: AudioPage(
            bookId: 'ios-fixture-audio',
            title: '自行编写的测试音频',
            chapters: [
              Chapter(itemId: 'audio-1', title: '测试一', volumeName: ''),
            ],
            historyStore: store,
            playerFactory: () => player,
            sourceLoader: (id, {toneId}) async => AudioSource(
              itemId: id,
              url: 'https://fixture.invalid/self-authored.aac',
            ),
            voicesLoader: () async => [],
            resumeSession: false,
          ),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await player.dispose();
      });
      await _until(tester, () => player.playing, 'fixture media autoplay');
      await tester.tap(find.byTooltip('暂停'));
      await _until(tester, () => !player.playing, 'fixture media pause');
      expect(player.playWhenReady, isFalse);
      await tester.tap(find.byTooltip('前进15秒'));
      await tester.pump();
      expect(player.position, const Duration(seconds: 35));
      expect(player.playing, isFalse);
      await tester.tap(find.byTooltip('播放'));
      await _until(tester, () => player.playing, 'fixture media resume');
      expect(player.playWhenReady, isTrue);
      expect(store.entry?['kind'], 'audio');
    },
  );
}

Future<void> _until(
  WidgetTester tester,
  bool Function() ready,
  String reason,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for $reason');
    await tester.pump(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  await tester.pump();
}
