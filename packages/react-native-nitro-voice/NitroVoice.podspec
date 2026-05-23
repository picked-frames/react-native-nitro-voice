require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "NitroVoice"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => '15.1' }
  s.source       = { :git => "https://github.com/user/react-native-nitro-voice.git", :tag => "#{s.version}" }

  s.source_files = [
    # Implementation (Swift)
    "ios/**/*.{swift}",
    # Public/private iOS headers
    "ios/**/*.h",
    # Autolinking/Registration (Objective-C++)
    "ios/**/*.{m,mm}",
    # Implementation (C++ objects)
    "cpp/**/*.{hpp,cpp}",
  ]

  load 'nitrogen/generated/ios/NitroVoice+autolinking.rb'
  add_nitrogen_files(s)

  s.dependency 'React-jsi'
  s.dependency 'React-callinvoker'
  install_modules_dependencies(s)
  s.vendored_frameworks = [
    'vendor/sherpa-onnx-ios/sherpa-onnx.xcframework',
    'vendor/sherpa-onnx-ios/onnxruntime.xcframework'
  ]
  s.preserve_paths = [
    'vendor/sherpa-onnx-ios/sherpa-onnx.xcframework',
    'vendor/sherpa-onnx-ios/onnxruntime.xcframework'
  ]

  current_public_header_files = Array(s.attributes_hash['public_header_files'])
  s.public_header_files = current_public_header_files + [
    'ios/SherpaOnnxExports.h'
  ]

  # Local development expects the prebuilt iOS frameworks under vendor/sherpa-onnx-ios.
  current_pod_target_xcconfig = s.attributes_hash['pod_target_xcconfig'] || {}
  s.pod_target_xcconfig = current_pod_target_xcconfig.merge({
    'OTHER_LDFLAGS' => '$(inherited) -lc++',
    'HEADER_SEARCH_PATHS' => '$(inherited) "${PODS_TARGET_SRCROOT}/vendor/sherpa-onnx-ios/sherpa-onnx.xcframework/ios-arm64/Headers" "${PODS_TARGET_SRCROOT}/vendor/sherpa-onnx-ios/sherpa-onnx.xcframework/ios-arm64_x86_64-simulator/Headers" "${PODS_TARGET_SRCROOT}/vendor/sherpa-onnx-ios/onnxruntime.xcframework/Headers"',
    'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES'
  })
  s.frameworks = 'AVFoundation', 'AudioToolbox'
end
