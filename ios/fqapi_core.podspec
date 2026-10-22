Pod::Spec.new do |s|
  s.name = 'fqapi_core'
  s.version = '0.1.0'
  s.summary = 'In-process Rust core for fqapp'
  s.homepage = 'https://cjycode.com/flutter_rust_bridge/'
  s.license = { :type => 'GPL-3.0', :file => '../LICENSE' }
  s.author = 'fqapp'
  s.source = { :path => '.' }
  s.platform = :ios, '16.0'
  s.vendored_frameworks = '../build/ios-native/fqapi_core.xcframework'
  s.static_framework = true
  s.frameworks = 'Security', 'SystemConfiguration'
  s.libraries = 'c++', 'resolv'
  # FRB uses DynamicLibrary.process(). Retain all Rust/C objects and export the
  # entry points in both Debug and stripped Release apps for dlsym lookup.
  archive = '${PODS_ROOT}/../../build/ios-native/fqapi_core.xcframework'
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS[sdk=iphoneos*]' => "$(inherited) -Wl,-force_load,\"#{archive}/ios-arm64/libfqapi_core.a\" -Wl,-export_dynamic",
    'OTHER_LDFLAGS[sdk=iphonesimulator*]' => "$(inherited) -Wl,-force_load,\"#{archive}/ios-arm64-simulator/libfqapi_core.a\" -Wl,-export_dynamic"
  }
end
