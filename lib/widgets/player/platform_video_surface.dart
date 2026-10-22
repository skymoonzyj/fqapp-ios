import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';

import '../../services/desktop_platform.dart';
import '../../services/player_surface.dart';

class PlatformVideoSurface extends StatelessWidget {
  const PlatformVideoSurface({super.key, required this.surface});

  final PlayerSurface surface;

  @override
  Widget build(BuildContext context) => switch (surface) {
    TexturePlayerSurface(:final textureId) =>
      isWindowsDesktop
          ? DesktopPlatform.instance.videoSurface(textureId)
          : Texture(textureId: textureId),
    IosPlayerSurface(:final playerId) => UiKitView(
      key: ValueKey(playerId),
      viewType: 'fqapp/player',
      // The native layer is passive; Flutter owns playback gestures.
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      creationParams: {'playerId': playerId},
      creationParamsCodec: const StandardMessageCodec(),
    ),
  };
}
