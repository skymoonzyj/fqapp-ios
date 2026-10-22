// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'media.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

/// @nodoc
mixin _$MediaSource {
  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType && other is MediaSource);
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    return 'MediaSource()';
  }
}

/// @nodoc
class $MediaSourceCopyWith<$Res> {
  $MediaSourceCopyWith(MediaSource _, $Res Function(MediaSource) __);
}

/// Adds pattern-matching-related methods to [MediaSource].
extension MediaSourcePatterns on MediaSource {
  /// A variant of `map` that fallback to returning `orElse`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(MediaSource_RemoteHttps value)? remoteHttps,
    TResult Function(MediaSource_LocalFile value)? localFile,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case MediaSource_RemoteHttps() when remoteHttps != null:
        return remoteHttps(_that);
      case MediaSource_LocalFile() when localFile != null:
        return localFile(_that);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// Callbacks receives the raw object, upcasted.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case final Subclass2 value:
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(MediaSource_RemoteHttps value) remoteHttps,
    required TResult Function(MediaSource_LocalFile value) localFile,
  }) {
    final _that = this;
    switch (_that) {
      case MediaSource_RemoteHttps():
        return remoteHttps(_that);
      case MediaSource_LocalFile():
        return localFile(_that);
    }
  }

  /// A variant of `map` that fallback to returning `null`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(MediaSource_RemoteHttps value)? remoteHttps,
    TResult? Function(MediaSource_LocalFile value)? localFile,
  }) {
    final _that = this;
    switch (_that) {
      case MediaSource_RemoteHttps() when remoteHttps != null:
        return remoteHttps(_that);
      case MediaSource_LocalFile() when localFile != null:
        return localFile(_that);
      case _:
        return null;
    }
  }

  /// A variant of `when` that fallback to an `orElse` callback.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(String url)? remoteHttps,
    TResult Function(String path)? localFile,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case MediaSource_RemoteHttps() when remoteHttps != null:
        return remoteHttps(_that.url);
      case MediaSource_LocalFile() when localFile != null:
        return localFile(_that.path);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// As opposed to `map`, this offers destructuring.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case Subclass2(:final field2):
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(String url) remoteHttps,
    required TResult Function(String path) localFile,
  }) {
    final _that = this;
    switch (_that) {
      case MediaSource_RemoteHttps():
        return remoteHttps(_that.url);
      case MediaSource_LocalFile():
        return localFile(_that.path);
    }
  }

  /// A variant of `when` that fallback to returning `null`
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(String url)? remoteHttps,
    TResult? Function(String path)? localFile,
  }) {
    final _that = this;
    switch (_that) {
      case MediaSource_RemoteHttps() when remoteHttps != null:
        return remoteHttps(_that.url);
      case MediaSource_LocalFile() when localFile != null:
        return localFile(_that.path);
      case _:
        return null;
    }
  }
}

/// @nodoc

class MediaSource_RemoteHttps extends MediaSource {
  const MediaSource_RemoteHttps({required this.url}) : super._();

  final String url;

  /// Create a copy of MediaSource
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $MediaSource_RemoteHttpsCopyWith<MediaSource_RemoteHttps> get copyWith =>
      _$MediaSource_RemoteHttpsCopyWithImpl<MediaSource_RemoteHttps>(
        this,
        _$identity,
      );

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is MediaSource_RemoteHttps &&
            (identical(other.url, url) || other.url == url));
  }

  @override
  int get hashCode => Object.hash(runtimeType, url);

  @override
  String toString() {
    return 'MediaSource.remoteHttps(url: $url)';
  }
}

/// @nodoc
abstract mixin class $MediaSource_RemoteHttpsCopyWith<$Res>
    implements $MediaSourceCopyWith<$Res> {
  factory $MediaSource_RemoteHttpsCopyWith(
    MediaSource_RemoteHttps value,
    $Res Function(MediaSource_RemoteHttps) _then,
  ) = _$MediaSource_RemoteHttpsCopyWithImpl;
  @useResult
  $Res call({String url});
}

/// @nodoc
class _$MediaSource_RemoteHttpsCopyWithImpl<$Res>
    implements $MediaSource_RemoteHttpsCopyWith<$Res> {
  _$MediaSource_RemoteHttpsCopyWithImpl(this._self, this._then);

  final MediaSource_RemoteHttps _self;
  final $Res Function(MediaSource_RemoteHttps) _then;

  /// Create a copy of MediaSource
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({Object? url = null}) {
    return _then(
      MediaSource_RemoteHttps(
        url: null == url
            ? _self.url
            : url // ignore: cast_nullable_to_non_nullable
                  as String,
      ),
    );
  }
}

/// @nodoc

class MediaSource_LocalFile extends MediaSource {
  const MediaSource_LocalFile({required this.path}) : super._();

  final String path;

  /// Create a copy of MediaSource
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $MediaSource_LocalFileCopyWith<MediaSource_LocalFile> get copyWith =>
      _$MediaSource_LocalFileCopyWithImpl<MediaSource_LocalFile>(
        this,
        _$identity,
      );

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is MediaSource_LocalFile &&
            (identical(other.path, path) || other.path == path));
  }

  @override
  int get hashCode => Object.hash(runtimeType, path);

  @override
  String toString() {
    return 'MediaSource.localFile(path: $path)';
  }
}

/// @nodoc
abstract mixin class $MediaSource_LocalFileCopyWith<$Res>
    implements $MediaSourceCopyWith<$Res> {
  factory $MediaSource_LocalFileCopyWith(
    MediaSource_LocalFile value,
    $Res Function(MediaSource_LocalFile) _then,
  ) = _$MediaSource_LocalFileCopyWithImpl;
  @useResult
  $Res call({String path});
}

/// @nodoc
class _$MediaSource_LocalFileCopyWithImpl<$Res>
    implements $MediaSource_LocalFileCopyWith<$Res> {
  _$MediaSource_LocalFileCopyWithImpl(this._self, this._then);

  final MediaSource_LocalFile _self;
  final $Res Function(MediaSource_LocalFile) _then;

  /// Create a copy of MediaSource
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({Object? path = null}) {
    return _then(
      MediaSource_LocalFile(
        path: null == path
            ? _self.path
            : path // ignore: cast_nullable_to_non_nullable
                  as String,
      ),
    );
  }
}
