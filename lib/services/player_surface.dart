/// A native output handle. iOS views must never be treated as Flutter textures.
sealed class PlayerSurface {
  const PlayerSurface();
}

final class TexturePlayerSurface extends PlayerSurface {
  const TexturePlayerSurface(this.textureId);
  final int textureId;
}

final class IosPlayerSurface extends PlayerSurface {
  const IosPlayerSurface(this.playerId);
  final int playerId;
}
