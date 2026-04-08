require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "NitroTtsStt"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => '15.1' }
  s.source       = { :git => "https://github.com/user/react-native-nitro-tts-stt.git", :tag => "#{s.version}" }

  s.source_files = [
    # Implementation (Swift)
    "ios/**/*.{swift}",
    # Autolinking/Registration (Objective-C++)
    "ios/**/*.{m,mm}",
    # Implementation (C++ objects)
    "cpp/**/*.{hpp,cpp}",
  ]

  load 'nitrogen/generated/ios/NitroTtsStt+autolinking.rb'
  add_nitrogen_files(s)

  s.dependency 'React-jsi'
  s.dependency 'React-callinvoker'
  install_modules_dependencies(s)

  # sherpa-onnx headers and library — consumer must link the XCFramework manually
  # or add 'sherpa-onnx-ios' pod to their app Podfile
  s.xcconfig = {
    'OTHER_LDFLAGS' => '-lc++',
    'HEADER_SEARCH_PATHS' => '"${PODS_ROOT}/Headers/Public/sherpa-onnx-ios"'
  }
  s.frameworks = 'AVFoundation', 'AudioToolbox'
end
