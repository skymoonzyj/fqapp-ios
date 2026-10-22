import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/audio_download_store.dart';
import 'package:fqapp/services/drama_download_store.dart';
import 'package:fqapp/services/reader_device.dart';
import 'package:fqapp/services/ios_managed_paths.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/services/audio_downloader.dart';
import 'package:fqapp/services/episode_source_cache.dart';
import 'package:fqapp/services/drama_downloader.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/services/secure_key_provider.dart';
import 'package:fqapp/services/shelf_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late Directory oldRoot;
  late Directory newRoot;
  late SecureKeyProvider keys;
  const library = 'Library/Application Support';
  const book = 'local_123456_abcdef';

  Directory support(Directory root) => Directory('${root.path}/$library');

  IosManagedPaths paths(Directory root) => IosManagedPaths(
    enabled: true,
    supportDirectoryProvider: () async => support(root),
  );

  Future<void> migrate() async {
    await Hive.close();
    await oldRoot.rename(newRoot.path);
    expect(oldRoot.existsSync(), isFalse);
    Hive.init('${support(newRoot).path}/hive');
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fqapp-ios-paths-');
    oldRoot = Directory(
      '${temp.path}/Containers/Data/Application/'
      '11111111-1111-4111-8111-111111111111',
    );
    newRoot = Directory(
      '${temp.path}/Containers/Data/Application/'
      '22222222-2222-4222-8222-222222222222',
    );
    await support(oldRoot).create(recursive: true);
    Hive.init('${support(oldRoot).path}/hive');
    keys = SecureKeyProvider(storage: InMemorySecureKeyStorage());
    SharedPreferences.setMockInitialValues({});
    ReaderFonts.debugReset();
  });

  tearDown(() async {
    ReaderFonts.debugReset();
    await Hive.close();
    await temp.delete(recursive: true);
  });

  test(
    'legacy audio keeps the local source and bytes after container move',
    () async {
      final old = HiveAudioDownloadStore(
        keys: keys,
        directoryResolver: () async => support(oldRoot),
        managedPaths: paths(oldRoot),
      );
      await old.warmUp();
      final file = File('${(await old.directory()).path}/chapter__tone.m4a');
      await file.writeAsBytes([1, 4, 9, 16]);
      final raw = CachedAudioChapter(
        bookId: 'book',
        itemId: 'chapter',
        toneId: 'tone',
        title: 'chapter',
        index: 4,
        keyHex: '',
        bytes: 4,
        filePath: file.path,
        cachedAt: 123,
        durationMs: 60000,
      ).toMap();
      await Hive.box('audio_download_v1_enc').put('chapter:chapter|tone', raw);
      await Hive.box('audio_download_v1_enc').put('key:chapter|tone', 'qa-key');
      await migrate();
      final moved = HiveAudioDownloadStore(
        keys: keys,
        directoryResolver: () async => support(newRoot),
        managedPaths: paths(newRoot),
      );
      await moved.warmUp();
      final cached = (await moved.chapter('chapter', toneId: 'tone'))!;
      expect(
        await File.fromUri(Uri.parse(cached.toSource().url)).readAsBytes(),
        [1, 4, 9, 16],
      );
      expect(cached.index, 4);
      expect(cached.keyHex, 'qa-key');
      expect(cached.durationMs, 60000);
      expect(await moved.downloadedIds('book', toneId: 'tone'), {'chapter'});
    },
  );

  test(
    'legacy drama keeps its file source and metadata after container move',
    () async {
      final old = HiveDramaDownloadStore(
        keys: keys,
        directoryResolver: () async => support(oldRoot),
        managedPaths: paths(oldRoot),
      );
      await old.warmUp();
      final file = File('${(await old.directory()).path}/episode.mp4');
      await file.writeAsBytes([2, 3, 5, 7]);
      await Hive.box('drama_download_v1_enc').put(
        'episode:episode',
        CachedEpisode(
          seriesId: 'series',
          itemId: 'episode',
          title: 'episode',
          index: 2,
          keyHex: '',
          height: 720,
          variantName: 'HD',
          bytes: 4,
          filePath: file.path,
          cachedAt: 456,
        ).toMap(),
      );
      await Hive.box('drama_download_v1_enc').put('key:episode', 'qa-key');
      await migrate();
      final moved = HiveDramaDownloadStore(
        keys: keys,
        directoryResolver: () async => support(newRoot),
        managedPaths: paths(newRoot),
      );
      await moved.warmUp();
      final cached = (await moved.episode('episode'))!;
      expect(
        await File.fromUri(Uri.parse(cached.toSource().url)).readAsBytes(),
        [2, 3, 5, 7],
      );
      expect(cached.keyHex, 'qa-key');
      expect(cached.height, 720);
      expect(cached.cachedAt, 456);
      expect((await moved.dramas()).single.episodes.single.itemId, 'episode');
    },
  );

  test(
    'legacy selected font actually reads moved bytes and retains preferences',
    () async {
      final file = File(
        '${support(oldRoot).path}/reader-fonts/${'a' * 64}.font',
      );
      await file.parent.create();
      await file.writeAsBytes(List.generate(16, (i) => i));
      SharedPreferences.setMockInitialValues({
        'reader_font_path': file.path,
        'reader_font_name': 'QA Font',
        'reader_font_size': 24.0,
      });
      await migrate();
      final movedPaths = paths(newRoot);
      final prefs = await ReaderPreferences.load(managedPaths: movedPaths);
      List<int>? loaded;
      ReaderFonts.debugLoader = (path) async {
        loaded = await File(path).readAsBytes();
      };
      expect(
        await ReaderFonts.load(prefs.fontPath, managedPaths: movedPaths),
        isNotNull,
      );
      expect(loaded, List.generate(16, (i) => i));
      expect(prefs.fontName, 'QA Font');
      expect(prefs.fontSize, 24);
    },
  );

  test(
    'legacy shelf cover actually reads moved file without changing identity',
    () async {
      final file = File(
        '${support(oldRoot).path}/imported_books/$book/cover.png',
      );
      await file.parent.create(recursive: true);
      await file.writeAsBytes([8, 6, 7, 5]);
      final oldShelf = ShelfStore(managedPaths: paths(oldRoot));
      await oldShelf.init();
      await Hive.box(ShelfStore.boxName).put('shelf_v1:book:$book', {
        'id': book,
        'kind': 'book',
        'title': 'QA book',
        'cover': file.path,
        'addedAt': 123456,
      });
      await migrate();
      final movedShelf = ShelfStore(managedPaths: paths(newRoot));
      await movedShelf.init();
      final record = movedShelf.records().single;
      expect(await File(record.item.cover).readAsBytes(), [8, 6, 7, 5]);
      expect(record.item.id, book);
      expect(record.addedAt.millisecondsSinceEpoch, 123456);
    },
  );

  for (final audio in [true, false]) {
    test(
      'new ${audio ? 'audio' : 'drama'} records stay relative and survive move',
      () async {
        final oldPaths = paths(oldRoot);
        final oldAudio = HiveAudioDownloadStore(
          keys: keys,
          directoryResolver: () async => support(oldRoot),
          managedPaths: oldPaths,
        );
        final oldDrama = HiveDramaDownloadStore(
          keys: keys,
          directoryResolver: () async => support(oldRoot),
          managedPaths: oldPaths,
        );
        final dir = await (audio ? oldAudio.directory() : oldDrama.directory());
        final file = File(
          '${dir.path}/${audio ? 'chapter__tone.m4a' : 'episode.mp4'}',
        );
        await file.writeAsBytes([10, 20, 30]);
        if (audio) {
          await oldAudio.saveChapter(
            CachedAudioChapter(
              bookId: 'book',
              itemId: 'chapter',
              toneId: 'tone',
              title: 'chapter',
              index: 1,
              keyHex: 'qa',
              bytes: 3,
              filePath: file.path,
              cachedAt: 123,
            ),
          );
        } else {
          await oldDrama.saveEpisode(
            CachedEpisode(
              seriesId: 'series',
              itemId: 'episode',
              title: 'episode',
              index: 1,
              keyHex: 'qa',
              height: 720,
              variantName: 'HD',
              bytes: 3,
              filePath: file.path,
              cachedAt: 123,
            ),
          );
        }
        final raw =
            Hive.box(
                  audio ? 'audio_download_v1_enc' : 'drama_download_v1_enc',
                ).get(audio ? 'chapter:chapter|tone' : 'episode:episode')
                as Map;
        expect(raw['filePath'], startsWith('fqapp-support:v1/'));
        expect(raw['filePath'], isNot(contains(oldRoot.path)));
        await migrate();
        final movedPaths = paths(newRoot);
        final String source;
        if (audio) {
          final moved = HiveAudioDownloadStore(
            keys: keys,
            directoryResolver: () async => support(newRoot),
            managedPaths: movedPaths,
          );
          source = (await moved.chapter(
            'chapter',
            toneId: 'tone',
          ))!.toSource().url;
          expect(await moved.isDownloaded('chapter', toneId: 'tone'), isTrue);
          await File.fromUri(
            Uri.parse(source),
          ).readAsBytes().then((bytes) => expect(bytes, [10, 20, 30]));
          await moved.removeChapter('chapter', toneId: 'tone');
        } else {
          final moved = HiveDramaDownloadStore(
            keys: keys,
            directoryResolver: () async => support(newRoot),
            managedPaths: movedPaths,
          );
          source = (await moved.episode('episode'))!.toSource().url;
          expect(await moved.isDownloaded('episode'), isTrue);
          await File.fromUri(
            Uri.parse(source),
          ).readAsBytes().then((bytes) => expect(bytes, [10, 20, 30]));
          await moved.removeEpisode('episode');
        }
        expect(File.fromUri(Uri.parse(source)).existsSync(), isFalse);
      },
    );
  }

  test(
    'new selected font stays relative on disk and reads moved bytes',
    () async {
      final file = File(
        '${support(oldRoot).path}/reader-fonts/${'b' * 64}.font',
      );
      await file.parent.create();
      await file.writeAsBytes(List.filled(16, 42));
      await ReaderPreferences(
        fontPath: file.path,
        fontName: 'QA Font',
        fontSize: 23,
      ).save(managedPaths: paths(oldRoot));
      expect(
        (await SharedPreferences.getInstance()).getString('reader_font_path'),
        'fqapp-support:v1/reader-fonts/${'b' * 64}.font',
      );
      await migrate();
      final movedPaths = paths(newRoot);
      final prefs = await ReaderPreferences.load(managedPaths: movedPaths);
      ReaderFonts.debugLoader = (path) async {
        expect(await File(path).readAsBytes(), List.filled(16, 42));
      };
      expect(
        await ReaderFonts.load(prefs.fontPath, managedPaths: movedPaths),
        isNotNull,
      );
      expect(prefs.fontName, 'QA Font');
      expect(prefs.fontSize, 23);
    },
  );

  test(
    'new shelf cover reference survives move with identity and time intact',
    () async {
      final file = File(
        '${support(oldRoot).path}/imported_books/$book/cover.svg',
      );
      await file.parent.create(recursive: true);
      await file.writeAsString('<svg/>');
      final old = ShelfStore(managedPaths: paths(oldRoot));
      await old.init();
      await old.restoreAll([
        ShelfRecord(
          item: MediaItem(
            id: book,
            title: 'QA',
            cover: file.path,
            author: '',
            badge: '',
            ep: '',
            kind: 'book',
          ),
          addedAt: DateTime.fromMillisecondsSinceEpoch(98765),
        ),
      ]);
      final raw =
          Hive.box(ShelfStore.boxName).get('shelf_v1:book:$book') as Map;
      expect(raw['cover'], 'fqapp-support:v1/imported_books/$book/cover.svg');
      await migrate();
      final moved = ShelfStore(managedPaths: paths(newRoot));
      await moved.init();
      final record = moved.records().single;
      expect(await File(record.item.cover).readAsString(), '<svg/>');
      expect(record.item.id, book);
      expect(record.addedAt.millisecondsSinceEpoch, 98765);
    },
  );

  test(
    'invalid iOS font rejects before any appearance preference is written',
    () async {
      SharedPreferences.setMockInitialValues({
        'reader_font_size': 18.0,
        'reader_font_name': 'original',
      });
      await expectLater(
        const ReaderPreferences(
          fontSize: 29,
          fontPath: '/external/font.ttf',
          fontName: 'rejected',
        ).save(managedPaths: paths(oldRoot)),
        throwsFormatException,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('reader_font_size'), 18);
      expect(prefs.getString('reader_font_name'), 'original');
    },
  );

  test(
    'R1 drama legacy key split cannot overwrite another row content key',
    () async {
      final store = HiveDramaDownloadStore(
        keys: keys,
        directoryResolver: () async => support(oldRoot),
        managedPaths: paths(oldRoot),
      );
      final file = File('${(await store.directory()).path}/B.mp4');
      await file.writeAsBytes([66, 3, 66]);
      await store.saveEpisode(
        CachedEpisode(
          seriesId: 'B-series',
          itemId: 'B',
          title: 'B',
          index: 1,
          keyHex: 'B-key',
          height: 720,
          variantName: 'HD',
          bytes: 3,
          filePath: file.path,
          cachedAt: 123,
        ),
      );
      final box = Hive.box('drama_download_v1_enc');
      final originalB = Map<dynamic, dynamic>.from(box.get('episode:B') as Map);
      await box.put(
        'episode:A',
        Map<dynamic, dynamic>.from(originalB)
          ..['seriesId'] = 'A-series'
          ..['keyHex'] = 'A-embedded-key',
      );
      await box.delete('__key_split_v1');
      await store.warmUp();
      expect(box.get('key:B'), 'B-key');
      expect(box.get('episode:B'), originalB);
      expect(await file.readAsBytes(), [66, 3, 66]);
    },
  );

  for (final audio in [true, false]) {
    for (final operation in ['lookup', 'direct', 'bulk']) {
      test(
        'R1 ${audio ? 'audio' : 'drama'} key A raw B preserves B during $operation',
        () async {
          final managed = paths(oldRoot);
          final audioStore = HiveAudioDownloadStore(
            keys: keys,
            directoryResolver: () async => support(oldRoot),
            managedPaths: managed,
          );
          final dramaStore = HiveDramaDownloadStore(
            keys: keys,
            directoryResolver: () async => support(oldRoot),
            managedPaths: managed,
          );
          final dir = await (audio
              ? audioStore.directory()
              : dramaStore.directory());
          final a = File('${dir.path}/${audio ? 'A__tone.m4a' : 'A.mp4'}');
          final b = File('${dir.path}/${audio ? 'B__tone.m4a' : 'B.mp4'}');
          await a.writeAsBytes([65, 1, 65]);
          await b.writeAsBytes([66, 2, 66]);
          if (audio) {
            await audioStore.saveChapter(
              CachedAudioChapter(
                bookId: 'other-book',
                itemId: 'B',
                toneId: 'tone',
                title: 'B',
                index: 7,
                keyHex: 'B-key',
                bytes: 3,
                filePath: b.path,
                cachedAt: 987,
              ),
            );
          } else {
            await dramaStore.saveEpisode(
              CachedEpisode(
                seriesId: 'other-series',
                itemId: 'B',
                title: 'B',
                index: 7,
                keyHex: 'B-key',
                height: 720,
                variantName: 'HD',
                bytes: 3,
                filePath: b.path,
                cachedAt: 987,
              ),
            );
          }
          final box = Hive.box(
            audio ? 'audio_download_v1_enc' : 'drama_download_v1_enc',
          );
          final aRecordKey = audio ? 'chapter:A|tone' : 'episode:A';
          final bRecordKey = audio ? 'chapter:B|tone' : 'episode:B';
          final aContentKey = audio ? 'key:A|tone' : 'key:A';
          final bContentKey = audio ? 'key:B|tone' : 'key:B';
          final originalB = Map<dynamic, dynamic>.from(
            box.get(bRecordKey) as Map,
          );
          final corruptA = Map<dynamic, dynamic>.from(originalB)
            ..[audio ? 'bookId' : 'seriesId'] = 'selected';
          if (operation == 'direct') corruptA['filePath'] = b.path;
          if (operation == 'bulk') {
            corruptA['filePath'] = b.path.replaceFirst(
              '11111111-1111-4111-8111-111111111111',
              '22222222-2222-4222-8222-222222222222',
            );
          }
          await box.put(aRecordKey, corruptA);
          await box.put(aContentKey, 'A-key');
          if (operation == 'lookup') {
            if (audio) {
              final record = await audioStore.chapter('A', toneId: 'tone');
              final downloaded = await audioStore.isDownloaded(
                'A',
                toneId: 'tone',
              );
              final selected = await audioStore.downloadedIds(
                'selected',
                toneId: 'tone',
              );
              expect(record, isNull);
              expect(downloaded, isFalse);
              expect(selected, isEmpty);
            } else {
              final record = await dramaStore.episode('A');
              final downloaded = await dramaStore.isDownloaded('A');
              final groups = await dramaStore.dramas();
              expect(record, isNull);
              expect(downloaded, isFalse);
              expect(groups.map((group) => group.drama.id), ['other-series']);
            }
          } else if (operation == 'direct') {
            if (audio) {
              await audioStore.removeChapter('A', toneId: 'tone');
            } else {
              await dramaStore.removeEpisode('A');
            }
          } else {
            if (audio) {
              await audioStore.removeBook('selected', toneId: 'tone');
            } else {
              await dramaStore.removeDrama('selected');
            }
          }
          expect(b.existsSync(), isTrue, reason: 'A must not delete B bytes');
          expect(await b.readAsBytes(), [66, 2, 66]);
          expect(
            box.get(bRecordKey),
            originalB,
            reason: 'B record is separate',
          );
          expect(box.get(bContentKey), 'B-key', reason: 'B key is separate');
          expect(await a.readAsBytes(), [65, 1, 65]);
          if (operation != 'lookup') expect(box.get(aRecordKey), isNull);
          if (audio) {
            final record = (await audioStore.chapter('B', toneId: 'tone'))!;
            expect(
              await File.fromUri(
                Uri.parse(record.toSource().url),
              ).readAsBytes(),
              [66, 2, 66],
            );
            expect(record.keyHex, 'B-key');
          } else {
            final record = (await dramaStore.episode('B'))!;
            expect(
              await File.fromUri(
                Uri.parse(record.toSource().url),
              ).readAsBytes(),
              [66, 2, 66],
            );
            expect(record.keyHex, 'B-key');
          }
        },
      );
    }
  }

  for (final audio in [true, false]) {
    test(
      '${audio ? 'audio' : 'drama'} refuses a record borrowing another owned file',
      () async {
        final managed = paths(oldRoot);
        final audioStore = HiveAudioDownloadStore(
          keys: keys,
          directoryResolver: () async => support(oldRoot),
          managedPaths: managed,
        );
        final dramaStore = HiveDramaDownloadStore(
          keys: keys,
          directoryResolver: () async => support(oldRoot),
          managedPaths: managed,
        );
        await (audio ? audioStore.warmUp() : dramaStore.warmUp());
        final dir = await (audio
            ? audioStore.directory()
            : dramaStore.directory());
        final other = File(
          '${dir.path}/${audio ? 'other__tone.m4a' : 'other.mp4'}',
        );
        await other.writeAsBytes([99, 98]);
        final record = audio
            ? CachedAudioChapter(
                bookId: 'book',
                itemId: 'chapter',
                toneId: 'tone',
                title: 'QA',
                index: 1,
                keyHex: '',
                bytes: 2,
                filePath: other.path,
                cachedAt: 123,
              ).toMap()
            : CachedEpisode(
                seriesId: 'series',
                itemId: 'episode',
                title: 'QA',
                index: 1,
                keyHex: '',
                height: 720,
                variantName: 'HD',
                bytes: 2,
                filePath: other.path,
                cachedAt: 123,
              ).toMap();
        final box = Hive.box(
          audio ? 'audio_download_v1_enc' : 'drama_download_v1_enc',
        );
        final recordKey = audio ? 'chapter:chapter|tone' : 'episode:episode';
        await box.put(recordKey, record);
        if (audio) {
          expect(await audioStore.chapter('chapter', toneId: 'tone'), isNull);
          expect(
            await audioStore.isDownloaded('chapter', toneId: 'tone'),
            isFalse,
          );
          expect(
            await audioStore.downloadedIds('book', toneId: 'tone'),
            isEmpty,
          );
          await audioStore.removeChapter('chapter', toneId: 'tone');
        } else {
          expect(await dramaStore.episode('episode'), isNull);
          expect(await dramaStore.isDownloaded('episode'), isFalse);
          expect(await dramaStore.dramas(), isEmpty);
          await dramaStore.removeDrama('series');
        }
        expect(await other.readAsBytes(), [99, 98]);
        expect(box.get(recordKey), isNull);
      },
    );
  }

  for (final audio in [true, false]) {
    test(
      '${audio ? 'audio' : 'drama'} partial bytes resume at current root after move',
      () async {
        final dirName = audio ? 'offline-audio' : 'offline-video';
        final filename = audio ? 'chapter__tone.m4a' : 'episode.mp4';
        final partial = File(
          '${support(oldRoot).path}/$dirName/$filename.part',
        );
        await partial.parent.create();
        await partial.writeAsBytes([1, 2, 3]);
        await migrate();
        final ranges = <String?>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final serving = server.listen((request) async {
          ranges.add(request.headers.value(HttpHeaders.rangeHeader));
          request.response.statusCode = 206;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 3-5/6',
          );
          request.response.contentLength = 3;
          request.response.add([4, 5, 6]);
          await request.response.close();
        });
        final url = 'http://127.0.0.1:${server.port}/qa';
        final movedPaths = paths(newRoot);
        Future<void> waitUntil(bool Function() done) async {
          final until = DateTime.now().add(const Duration(seconds: 5));
          while (!done() && DateTime.now().isBefore(until)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(done(), isTrue);
        }

        try {
          if (audio) {
            final store = HiveAudioDownloadStore(
              keys: keys,
              directoryResolver: () async => support(newRoot),
              managedPaths: movedPaths,
            );
            final engine = AudioDownloader(
              store: store,
              clientFactory: () =>
                  _LoopbackHttpOverrides().createHttpClient(null),
              resolve: (bookId, itemId, toneId) async =>
                  AudioSource(itemId: itemId, toneId: toneId, url: url),
            );
            try {
              await engine.enqueue(
                book: CachedAudioBook(
                  bookId: 'book',
                  title: 'QA',
                  cover: '',
                  toneId: 'tone',
                  chapters: [
                    Chapter(
                      itemId: 'chapter',
                      title: 'chapter',
                      volumeName: '',
                    ),
                  ],
                ),
                chapters: [
                  Chapter(itemId: 'chapter', title: 'chapter', volumeName: ''),
                ],
              );
              await waitUntil(
                () =>
                    engine.value.isNotEmpty &&
                    engine.value.single.status == AudioDownloadStatus.completed,
              );
              expect(
                await File(
                  (await store.chapter('chapter', toneId: 'tone'))!.filePath,
                ).readAsBytes(),
                [1, 2, 3, 4, 5, 6],
              );
            } finally {
              engine.dispose();
            }
          } else {
            final store = HiveDramaDownloadStore(
              keys: keys,
              directoryResolver: () async => support(newRoot),
              managedPaths: movedPaths,
            );
            final engine = DramaDownloader(
              store: store,
              clientFactory: () =>
                  _LoopbackHttpOverrides().createHttpClient(null),
              resolve: (_) async => EpisodeSource(url, '', const []),
            );
            try {
              await engine.enqueue(
                drama: CachedDrama(
                  id: 'series',
                  title: 'QA',
                  cover: '',
                  episodes: [
                    Chapter(
                      itemId: 'episode',
                      title: 'episode',
                      volumeName: '',
                    ),
                  ],
                ),
                episodes: [
                  Chapter(itemId: 'episode', title: 'episode', volumeName: ''),
                ],
              );
              await waitUntil(
                () =>
                    engine.value.isNotEmpty &&
                    engine.value.single.status == DramaDownloadStatus.completed,
              );
              expect(
                await File(
                  (await store.episode('episode'))!.filePath,
                ).readAsBytes(),
                [1, 2, 3, 4, 5, 6],
              );
            } finally {
              engine.dispose();
            }
          }
          expect(ranges, ['bytes=3-']);
          expect(
            File(
              '${support(newRoot).path}/$dirName/$filename.part',
            ).existsSync(),
            isFalse,
          );
        } finally {
          await server.close(force: true);
          await serving.cancel();
        }
      },
    );
  }
}

class _LoopbackHttpOverrides extends HttpOverrides {}
