import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Only these existing, app-owned files can be rebased after an iOS data
/// container move. External Files URLs and other private directories are never
/// accepted. Non-iOS callers retain their original path representation.
enum IosManagedFile { font, audio, drama, bookCover }

class IosManagedPaths {
  IosManagedPaths({
    bool? enabled,
    Future<Directory> Function()? supportDirectoryProvider,
  }) : enabled = enabled ?? Platform.isIOS,
       _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory;

  static final instance = IosManagedPaths();
  static const _referencePrefix = 'fqapp-support:v1/';
  static final _container = RegExp(
    r'^(.*?/Containers/Data/Application/)[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    r'/Library/Application Support$',
  );
  static final _patterns = {
    IosManagedFile.font: RegExp(r'^reader-fonts/[a-f0-9]{64}\.font$'),
    IosManagedFile.audio: RegExp(
      r'^offline-audio/[A-Za-z0-9_-]{1,128}__[A-Za-z0-9_-]{1,128}\.m4a$',
    ),
    IosManagedFile.drama: RegExp(r'^offline-video/[A-Za-z0-9_-]{1,128}\.mp4$'),
    IosManagedFile.bookCover: RegExp(
      r'^imported_books/local_[0-9]+_[a-f0-9]+/cover\.(?:png|jpg|svg)$',
    ),
  };

  final bool enabled;
  final Future<Directory> Function() _supportDirectoryProvider;
  Future<void>? _initializing;
  String? _root;
  String? _providerRoot;

  Future<void> initialize() async {
    if (!enabled || _root != null) return;
    final pending = _initializing ??= _initialize();
    try {
      await pending;
    } finally {
      if (identical(_initializing, pending)) _initializing = null;
    }
  }

  Future<void> _initialize() async {
    final directory = await _supportDirectoryProvider();
    // This root is supplied by path_provider, never by a stored record. Resolve
    // Apple's /var -> /private/var alias before checking child symlinks.
    _providerRoot = directory.absolute.path;
    _root = await directory.resolveSymbolicLinks();
  }

  String persist(String value, IosManagedFile kind) {
    if (!enabled || value.isEmpty) return value;
    final relative = _relative(value, kind);
    if (relative == null || _checkedPath(relative) == null) {
      throw const FormatException('无效的应用文件路径');
    }
    return '$_referencePrefix$relative';
  }

  /// Returns a current absolute path, or null for malformed/out-of-scope paths.
  /// Missing files can retain their record, while readers request an existing
  /// regular file. No file is copied, searched for, renamed or deleted here.
  String? resolve(
    String value,
    IosManagedFile kind, {
    bool requireFile = false,
  }) {
    if (!enabled) return value;
    if (value.isEmpty) return '';
    final relative = _relative(value, kind);
    if (relative == null) return null;
    final path = _checkedPath(relative);
    if (path == null) return null;
    if (requireFile &&
        FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.file) {
      return null;
    }
    return path;
  }

  String? _relative(String value, IosManagedFile kind) {
    final root = _root;
    if (root == null ||
        value.length > 4096 ||
        value.contains('\\') ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      return null;
    }
    String? relative;
    if (value.startsWith(_referencePrefix)) {
      relative = value.substring(_referencePrefix.length);
    } else {
      // Both the current absolute root and old UUID roots must have the same
      // container parent (including the Simulator device). This is not a
      // basename search or a mapping of arbitrary absolute filesystem paths.
      final candidate = _appleAlias(value);
      final roots = {_appleAlias(root), _appleAlias(_providerRoot!)};
      for (final current in roots) {
        if (candidate.startsWith('$current/')) {
          relative = candidate.substring(current.length + 1);
          break;
        }
        final container = _container.firstMatch(current);
        if (container == null) continue;
        final legacy = RegExp(
          '^${RegExp.escape(container.group(1)!)}'
          r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
          r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/Library/Application Support/(.+)$',
        ).firstMatch(candidate);
        if (legacy != null) {
          relative = legacy.group(1);
          break;
        }
      }
    }
    return relative != null && _patterns[kind]!.hasMatch(relative)
        ? relative
        : null;
  }

  String? _checkedPath(String relative) {
    final root = _root;
    if (root == null) return null;
    var path = root;
    // Reject symlinks even when their target is currently inside the root.
    // This includes missing leaf files whose parent was replaced by a link.
    try {
      for (final component in relative.split('/')) {
        path = '$path/$component';
        if (FileSystemEntity.typeSync(path, followLinks: false) ==
            FileSystemEntityType.link) {
          return null;
        }
      }
    } on FileSystemException {
      return null;
    } on ArgumentError {
      return null;
    }
    return path;
  }

  static String _appleAlias(String path) => path.startsWith('/private/var/')
      ? path.substring('/private'.length)
      : path;
}
