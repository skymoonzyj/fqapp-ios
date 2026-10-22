import 'package:flutter/foundation.dart';

/// Platform facts used to expose only controls with a working implementation.
/// PiP availability is supplied by the native runtime, never inferred from iOS.
class PlatformCapabilities {
  const PlatformCapabilities.forPlatform(
    this.platform, {
    this.pictureInPictureSupported = false,
  });

  final TargetPlatform platform;
  final bool pictureInPictureSupported;

  static PlatformCapabilities get current =>
      PlatformCapabilities.forPlatform(defaultTargetPlatform);

  bool get reader =>
      platform == TargetPlatform.android ||
      platform == TargetPlatform.iOS ||
      platform == TargetPlatform.windows;
  bool get speech => reader;
  bool get overlayPermission => platform == TargetPlatform.android;
  bool get decoderPreference => platform == TargetPlatform.android;
  bool get eink =>
      platform == TargetPlatform.android || platform == TargetPlatform.windows;
  bool get volumePaging => platform == TargetPlatform.android;
  bool get pictureInPicture =>
      platform == TargetPlatform.iOS && pictureInPictureSupported;
}
