import 'package:flutter/material.dart';

import '../services/imported_book_store.dart';
import '../services/library_store.dart';
import '../services/reader_history.dart';
import 'reader_page.dart';

/// Shared local-only entry for the shelf and Home's continue-reading card.
/// Resolve the current private manifest and saved chapter without a detail API.
Future<void> openImportedBook(
  BuildContext context,
  String bookId, {
  ReaderStore? readerStore,
}) async {
  final store = ImportedBookStore.instance;
  final book = await store.book(bookId);
  if (!context.mounted) return;
  if (book == null || book.chapters.isEmpty) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('本地书籍文件不可用')));
    return;
  }
  final historyStore = readerStore ?? LibraryStore.instance;
  Map<String, dynamic>? saved;
  try {
    saved = await ReaderHistory(historyStore).load(book.id);
  } catch (_) {}
  if (!context.mounted) return;
  var startIndex = book.chapters.indexWhere(
    (chapter) => chapter.itemId == saved?['chapterId']?.toString(),
  );
  if (startIndex < 0) {
    final episode = num.tryParse(saved?['episode']?.toString() ?? '');
    startIndex = episode != null && episode.isFinite
        ? episode.toInt().clamp(0, book.chapters.length - 1).toInt()
        : 0;
  }
  await Navigator.push<void>(
    context,
    MaterialPageRoute<void>(
      builder: (_) => ReaderPage(
        bookId: book.id,
        title: book.title,
        chapters: book.chapters,
        startIndex: startIndex,
        localOnly: true,
        readerStore: historyStore,
        chapterLoader: (chapter) => store.chapterText(book.id, chapter.itemId),
      ),
    ),
  );
}
