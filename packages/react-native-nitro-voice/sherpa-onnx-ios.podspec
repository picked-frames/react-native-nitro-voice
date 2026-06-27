Pod::Spec.new do |s|
  header_files = [
    'sherpa-onnx.xcframework/ios-arm64/Headers/**/*.h',
    'sherpa-onnx.xcframework/ios-arm64_x86_64-simulator/Headers/**/*.h',
    'onnxruntime.xcframework/Headers/**/*.h'
  ]

  s.name = 'sherpa-onnx-ios'
  s.version = '1.13.0'
  s.summary = 'Prebuilt sherpa-onnx iOS XCFrameworks'
  s.description = 'Wraps the upstream sherpa-onnx iOS release archive for CocoaPods consumption.'
  s.homepage = 'https://github.com/k2-fsa/sherpa-onnx'
  s.license = { :type => 'Apache-2.0' }
  s.authors = 'k2-fsa'
  s.platforms = { :ios => '15.1' }
  s.source = {
    :http => 'https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.0/sherpa-onnx-v1.13.0-ios.tar.bz2'
  }

  s.prepare_command = <<-CMD
    set -e

    ROOT_DIR="$(pwd)"
    SHERPA_PATH="$(find "$ROOT_DIR" -type d -name sherpa-onnx.xcframework | head -n 1)"

    # Not present — download the release tarball ourselves.
    # This happens when the pod is referenced via :path (e.g. from node_modules)
    # rather than via the :http source, in which case CocoaPods would have
    # extracted the tarball for us before running this script.
    if [ -z "$SHERPA_PATH" ]; then
      TARBALL="$ROOT_DIR/sherpa-onnx-v1.13.0-ios.tar.bz2"
      echo "Downloading sherpa-onnx v1.13.0 iOS frameworks (~370 MB)..."
      curl -L -o "$TARBALL" "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.0/sherpa-onnx-v1.13.0-ios.tar.bz2"
      tar xjf "$TARBALL" -C "$ROOT_DIR"
      rm -f "$TARBALL"
      SHERPA_PATH="$(find "$ROOT_DIR" -type d -name sherpa-onnx.xcframework | head -n 1)"
    fi

    if [ -z "$SHERPA_PATH" ]; then
      echo "Could not find sherpa-onnx.xcframework in the sherpa-onnx archive."
      exit 1
    fi

    if [ "$SHERPA_PATH" != "$ROOT_DIR/sherpa-onnx.xcframework" ]; then
      rm -rf "$ROOT_DIR/sherpa-onnx.xcframework"
      mv "$SHERPA_PATH" "$ROOT_DIR/sherpa-onnx.xcframework"
    fi

    ORT_PATH="$(find "$ROOT_DIR" -type d -name onnxruntime.xcframework | head -n 1)"
    if [ -z "$ORT_PATH" ]; then
      echo "Could not find onnxruntime.xcframework in the sherpa-onnx archive."
      exit 1
    fi

    if [ "$ORT_PATH" != "$ROOT_DIR/onnxruntime.xcframework" ]; then
      rm -rf "$ROOT_DIR/onnxruntime.xcframework"
      mv "$ORT_PATH" "$ROOT_DIR/onnxruntime.xcframework"
    fi

    rm -rf "$ROOT_DIR/build-ios" "$ROOT_DIR/build-ios-no-tts" "$ROOT_DIR/ios-onnxruntime"
  CMD

  s.vendored_frameworks = 'sherpa-onnx.xcframework', 'onnxruntime.xcframework'
  s.preserve_paths = 'sherpa-onnx.xcframework', 'onnxruntime.xcframework'
  s.source_files = header_files
  s.public_header_files = header_files
  s.pod_target_xcconfig = {
    'HEADER_SEARCH_PATHS' => '"${PODS_TARGET_SRCROOT}/sherpa-onnx.xcframework/ios-arm64/Headers" "${PODS_TARGET_SRCROOT}/sherpa-onnx.xcframework/ios-arm64_x86_64-simulator/Headers" "${PODS_TARGET_SRCROOT}/onnxruntime.xcframework/Headers"',
    'OTHER_LDFLAGS' => '$(inherited) -lc++'
  }
  s.user_target_xcconfig = {
    'HEADER_SEARCH_PATHS' => '"${PODS_ROOT}/sherpa-onnx-ios/sherpa-onnx.xcframework/ios-arm64/Headers" "${PODS_ROOT}/sherpa-onnx-ios/sherpa-onnx.xcframework/ios-arm64_x86_64-simulator/Headers" "${PODS_ROOT}/sherpa-onnx-ios/onnxruntime.xcframework/Headers"',
    'OTHER_LDFLAGS' => '$(inherited) -lc++'
  }
end