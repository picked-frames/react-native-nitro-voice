const {
  withDangerousMod,
  withInfoPlist,
  withProjectBuildGradle,
  AndroidConfig,
  createRunOncePlugin,
} = require('@expo/config-plugins')
const fs = require('fs')
const path = require('path')

const pkg = require('./package.json')

const DEFAULT_MICROPHONE_PERMISSION =
  'Used for on-device speech recognition. Your audio never leaves your device.'
const POD_MARKER = "pod 'sherpa-onnx-ios'"
const JITPACK_URL = 'https://jitpack.io'

// iOS: add the sherpa-onnx-ios pod to the app's Podfile.
// Resolved via node so it works regardless of node_modules hoisting.
function withSherpaPod(config) {
  return withDangerousMod(config, [
    'ios',
    (cfg) => {
      const podfile = path.join(cfg.modRequest.platformProjectRoot, 'Podfile')
      let contents = fs.readFileSync(podfile, 'utf8')
      if (!contents.includes(POD_MARKER)) {
        const line =
          "  pod 'sherpa-onnx-ios', :path => File.dirname(`node --print \"require.resolve('react-native-nitro-voice/package.json')\"`.strip)"
        if (/use_expo_modules!.*\n/.test(contents)) {
          contents = contents.replace(/(use_expo_modules!.*\n)/, `$1${line}\n`)
        } else {
          contents = contents.replace(
            /(target ['"][^'"]+['"] do\n)/,
            `$1${line}\n`
          )
        }
        fs.writeFileSync(podfile, contents)
      }
      return cfg
    },
  ])
}

// iOS: microphone usage description.
function withMicrophoneUsageDescription(config, message) {
  return withInfoPlist(config, (cfg) => {
    cfg.modResults.NSMicrophoneUsageDescription =
      cfg.modResults.NSMicrophoneUsageDescription || message
    return cfg
  })
}

// Android: add the JitPack Maven repository so the sherpa-onnx AAR resolves.
function withJitpackRepository(config) {
  return withProjectBuildGradle(config, (cfg) => {
    if (cfg.modResults.language !== 'groovy') return cfg
    if (!cfg.modResults.contents.includes(JITPACK_URL)) {
      cfg.modResults.contents = cfg.modResults.contents.replace(
        /allprojects\s*{[\s\S]*?repositories\s*{/,
        (match) => `${match}\n        maven { url '${JITPACK_URL}' }`
      )
    }
    return cfg
  })
}

// Android: RECORD_AUDIO permission.
function withRecordAudioPermission(config) {
  return AndroidConfig.Permissions.withPermissions(config, [
    'android.permission.RECORD_AUDIO',
  ])
}

/**
 * Expo config plugin for react-native-nitro-voice.
 *
 * Applies the native setup this library needs under CNG (`expo prebuild`):
 * the sherpa-onnx CocoaPod, the JitPack Maven repo, and microphone permissions.
 *
 * It deliberately does NOT set the iOS deployment target or Android
 * minSdkVersion — set those yourself (this lib needs iOS 15.5+ / API 29+),
 * e.g. via expo-build-properties.
 *
 * @param {object} config Expo config
 * @param {{ microphonePermission?: string }} [props]
 */
function withNitroVoice(config, props = {}) {
  const message =
    (props && props.microphonePermission) || DEFAULT_MICROPHONE_PERMISSION
  config = withSherpaPod(config)
  config = withMicrophoneUsageDescription(config, message)
  config = withJitpackRepository(config)
  config = withRecordAudioPermission(config)
  return config
}

module.exports = createRunOncePlugin(withNitroVoice, pkg.name, pkg.version)
