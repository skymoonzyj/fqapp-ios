import Flutter

/// The implicit engine has one registration boundary for every app adapter.
@MainActor
enum PluginRegistry {
  static func register(with registry: FlutterPluginRegistry) {
    GeneratedPluginRegistrant.register(with: registry)
    NativePlayerPlugin.configure = { plugin in
      plugin.integration = PlaybackCoordinator(plugin: plugin)
    }
    let plugins: [(String, (FlutterPluginRegistrar) -> Void)] = [
      ("NativePlayerPlugin", NativePlayerPlugin.register),
      ("LocalBookPlugin", LocalBookPlugin.register),
      ("LibraryBackupPlugin", LibraryBackupPlugin.register),
      ("TextExportPlugin", TextExportPlugin.register),
      ("SharePlugin", SharePlugin.register),
      ("ReaderPlugin", ReaderPlugin.register),
      ("SystemTtsPlugin", SystemTtsPlugin.register),
      ("FanqieAccountPlugin", FanqieAccountPlugin.register),
      ("MemoryPressurePlugin", MemoryPressurePlugin.register),
    ]
    for (name, register) in plugins {
      if let registrar = registry.registrar(forPlugin: name) { register(registrar) }
    }
  }
}
