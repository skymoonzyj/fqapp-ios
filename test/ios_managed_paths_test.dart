import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/ios_managed_paths.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/bookshelf_card.dart';

void main() {
  late Directory temp;
  late Directory current;
  late IosManagedPaths paths;
  const bookId = 'local_12345_abcdef';
  const cover = 'imported_books/$bookId/cover.png';
  const font =
      'reader-fonts/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.font';
  const audio = 'offline-audio/chapter__tone.m4a';
  const drama = 'offline-video/episode.mp4';
  const kinds = {
    font: IosManagedFile.font,
    audio: IosManagedFile.audio,
    drama: IosManagedFile.drama,
    cover: IosManagedFile.bookCover,
  };

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fqapp-managed-path-');
    current = Directory(
      '${temp.path}/Containers/Data/Application/'
      '11111111-1111-4111-8111-111111111111/Library/Application Support',
    );
    await current.create(recursive: true);
    paths = IosManagedPaths(
      enabled: true,
      supportDirectoryProvider: () async => current,
    );
    await paths.initialize();
  });

  tearDown(() async => temp.delete(recursive: true));

  for (final entry in kinds.entries) {
    test(
      '${entry.value.name}: current, legacy and stable references read same real bytes',
      () async {
        final file = File('${current.path}/${entry.key}');
        await file.parent.create(recursive: true);
        await file.writeAsBytes([3, 1, 4]);
        final old = file.path.replaceFirst(
          '11111111-1111-4111-8111-111111111111',
          '22222222-2222-4222-8222-222222222222',
        );
        final stable = paths.persist(file.path, entry.value);
        for (final reference in [file.path, old, stable]) {
          final resolved = paths.resolve(
            reference,
            entry.value,
            requireFile: true,
          )!;
          expect(await File(resolved).readAsBytes(), [3, 1, 4]);
          expect(paths.persist(reference, entry.value), stable);
        }
      },
    );
  }

  test(
    'rejects traversal, external roots, schemes, wrong areas and file shapes',
    () {
      for (final entry in kinds.entries) {
        for (final value in [
          '../${entry.key}',
          '/tmp/${entry.key}',
          '${current.path}/../${entry.key}',
          '${current.path}/./${entry.key}',
          '${current.path}//${entry.key}',
          '${current.path}/${entry.key}/extra',
          'file://${current.path}/${entry.key}',
          'https://example.invalid/${entry.key}',
          'fqapp-support:v1/../${entry.key}',
          'fqapp-support:v1/${entry.key}%00',
          'fqapp-support:v1/${entry.key}\n',
          'fqapp-support:v1/${entry.key}\\extra',
          '${current.path.replaceFirst('/Containers/', '/OtherContainers/')}/${entry.key}',
          '${current.path.replaceFirst('11111111-1111-4111-8111-111111111111', 'not-a-uuid')}/${entry.key}',
          '${current.path}/private-data/hive.box',
        ]) {
          expect(paths.resolve(value, entry.value), isNull, reason: value);
          expect(
            () => paths.persist(value, entry.value),
            throwsFormatException,
            reason: value,
          );
        }
      }
      expect(
        paths.resolve('${current.path}/$font', IosManagedFile.audio),
        isNull,
      );
      expect(
        paths.resolve(
          '${current.path}/imported_books/$bookId/book.json',
          IosManagedFile.bookCover,
        ),
        isNull,
      );
      expect(
        paths.resolve(
          '${current.path}/imported_books/not-local/cover.png',
          IosManagedFile.bookCover,
        ),
        isNull,
      );
    },
  );

  test(
    'rejects leaf and ancestor symlinks, including missing descendants',
    () async {
      final outside = File('${temp.path}/private-marker')
        ..writeAsBytesSync([9, 9]);
      final audioFile = File('${current.path}/$audio');
      await audioFile.parent.create();
      await Link(audioFile.path).create(outside.path);
      expect(
        paths.resolve(audioFile.path, IosManagedFile.audio, requireFile: true),
        isNull,
      );
      expect(
        () => paths.persist(audioFile.path, IosManagedFile.audio),
        throwsFormatException,
      );
      await Link(audioFile.path).delete();
      await audioFile.parent.delete();
      await Link(audioFile.parent.path).create(temp.path);
      expect(paths.resolve(audioFile.path, IosManagedFile.audio), isNull);
      expect(
        () => paths.persist(audioFile.path, IosManagedFile.audio),
        throwsFormatException,
      );
      expect(await outside.readAsBytes(), [9, 9]);
    },
  );

  test(
    'does not search other containers or accept a different Simulator parent',
    () {
      final otherDevice =
          '${temp.path}/other-device/Containers/Data/Application/'
          '22222222-2222-4222-8222-222222222222/Library/Application Support/$audio';
      expect(paths.resolve(otherDevice, IosManagedFile.audio), isNull);
    },
  );

  test(
    'missing managed files resolve only when the reader does not require bytes',
    () {
      expect(
        paths.resolve('fqapp-support:v1/$drama', IosManagedFile.drama),
        isNotNull,
      );
      expect(
        paths.resolve(
          'fqapp-support:v1/$drama',
          IosManagedFile.drama,
          requireFile: true,
        ),
        isNull,
      );
    },
  );

  test(
    'history cover consumer reads moved artwork and rejects unrelated files',
    () async {
      final file = File('${current.path}/$cover');
      await file.parent.create(recursive: true);
      await file.writeAsBytes([2, 7, 1, 8]);
      final old = file.path.replaceFirst(
        '11111111-1111-4111-8111-111111111111',
        '22222222-2222-4222-8222-222222222222',
      );
      for (final reference in [old, 'fqapp-support:v1/$cover']) {
        expect(
          await bookshelfLocalCoverFile(
            reference,
            expectedBookId: bookId,
            managedPaths: paths,
          )!.readAsBytes(),
          [2, 7, 1, 8],
        );
      }
      expect(
        bookshelfLocalCoverFile(
          '${current.path}/private-data.bin',
          expectedBookId: bookId,
          managedPaths: paths,
        ),
        isNull,
      );
      expect(
        bookshelfLocalCoverFile(
          'file://${file.path}',
          expectedBookId: bookId,
          managedPaths: paths,
        ),
        isNull,
      );
    },
  );

  for (final format in ['current', 'legacy', 'stable']) {
    test(
      'R1 history cover binds item identity for $format references',
      () async {
        const aId = 'local_111_aaaa';
        const bId = 'local_222_bbbb';
        final a = File('${current.path}/imported_books/$aId/cover.png');
        final b = File('${current.path}/imported_books/$bId/cover.png');
        await a.parent.create(recursive: true);
        await b.parent.create(recursive: true);
        await a.writeAsBytes([65, 7, 65]);
        await b.writeAsBytes([66, 8, 66]);
        String reference(File file) => switch (format) {
          'stable' => paths.persist(file.path, IosManagedFile.bookCover),
          'legacy' => file.path.replaceFirst(
            '11111111-1111-4111-8111-111111111111',
            '22222222-2222-4222-8222-222222222222',
          ),
          _ => file.path,
        };
        MediaItem item(String cover) => MediaItem(
          id: aId,
          title: 'A',
          cover: cover,
          author: '',
          badge: '',
          ep: '',
          kind: 'book',
        );
        final correct = item(reference(a));
        final wrong = item(reference(b));
        expect(
          await bookshelfLocalCoverFile(
            correct.cover,
            expectedBookId: correct.id,
            managedPaths: paths,
          )!.readAsBytes(),
          [65, 7, 65],
        );
        expect(
          bookshelfLocalCoverFile(
            wrong.cover,
            expectedBookId: wrong.id,
            managedPaths: paths,
          ),
          isNull,
          reason: 'item ${wrong.id} must not show another book cover',
        );
        expect(await a.readAsBytes(), [65, 7, 65]);
        expect(await b.readAsBytes(), [66, 8, 66]);
      },
    );
  }

  test(
    'disabled platform leaves Android and Windows representations untouched',
    () async {
      final disabled = IosManagedPaths(
        enabled: false,
        supportDirectoryProvider: () async =>
            throw StateError('must not request iOS roots'),
      );
      await disabled.initialize();
      for (final value in [
        '/data/user/0/com.fqapp/files/a.m4a',
        r'C:\Users\QA\Downloads\episode.mp4',
        r'C:\QA\font.ttf',
        'content://provider/book',
        '',
      ]) {
        for (final kind in IosManagedFile.values) {
          expect(disabled.persist(value, kind), value);
          expect(disabled.resolve(value, kind, requireFile: true), value);
        }
      }
      final file = File('${temp.path}/ordinary-cover.png')
        ..writeAsBytesSync([5, 8]);
      expect(
        await bookshelfLocalCoverFile(
          file.path,
          expectedBookId: 'non-ios-identity-is-ignored',
          managedPaths: disabled,
        )!.readAsBytes(),
        [5, 8],
      );
      expect(
        await bookshelfLocalCoverFile(
          file.uri.toString(),
          expectedBookId: 'non-ios-identity-is-ignored',
          managedPaths: disabled,
        )!.readAsBytes(),
        [5, 8],
      );
    },
  );
}
