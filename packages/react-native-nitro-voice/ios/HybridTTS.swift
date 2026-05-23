import Foundation
import NitroModules

class HybridTTS: HybridTTSSpec {

  // MARK: - State

  private var tts: OpaquePointer?
  private var isSpeaking = false
  private var modelConfig: TTSConfig?

  private let processingQueue = DispatchQueue(label: "com.nitrovoice.tts.processing", qos: .userInitiated)

  // MARK: - Properties

  var sampleRate: Double {
    guard let tts = tts else { return 0 }
    return Double(SherpaOnnxOfflineTtsSampleRate(tts))
  }

  var numSpeakers: Double {
    guard let tts = tts else { return 0 }
    return Double(SherpaOnnxOfflineTtsNumSpeakers(tts))
  }

  // MARK: - Initialize

  func initialize(config: TTSConfig) throws -> Promise<Void> {
    return Promise.async {
      self.modelConfig = config

      var ttsConfig = SherpaOnnxOfflineTtsConfig()
      ttsConfig.model.num_threads = 2
      ttsConfig.model.provider = Self.toCString("cpu")
      ttsConfig.model.debug = 0
      ttsConfig.max_num_sentences = 1

      let modelDir = config.modelDir

      switch config.type {
      case .vits:
        ttsConfig.model.vits.model = Self.toCString("\(modelDir)/model.onnx")
        ttsConfig.model.vits.tokens = Self.toCString("\(modelDir)/tokens.txt")
        ttsConfig.model.vits.data_dir = Self.toCString("\(modelDir)/data")
        ttsConfig.model.vits.length_scale = 1.0 / Float(config.speed ?? 1.0)

        // Optional lexicon
        let lexiconPath = "\(modelDir)/lexicon.txt"
        if FileManager.default.fileExists(atPath: lexiconPath) {
          ttsConfig.model.vits.lexicon = Self.toCString(lexiconPath)
        }

      case .kokoro:
        ttsConfig.model.kokoro.model = Self.toCString("\(modelDir)/model.onnx")
        ttsConfig.model.kokoro.voices = Self.toCString("\(modelDir)/voices.bin")
        ttsConfig.model.kokoro.tokens = Self.toCString("\(modelDir)/tokens.txt")
        ttsConfig.model.kokoro.data_dir = Self.toCString("\(modelDir)/data")
        ttsConfig.model.kokoro.length_scale = 1.0 / Float(config.speed ?? 1.0)

      case .matcha:
        ttsConfig.model.matcha.acoustic_model = Self.toCString("\(modelDir)/acoustic_model.onnx")
        ttsConfig.model.matcha.vocoder = Self.toCString("\(modelDir)/vocoder.onnx")
        ttsConfig.model.matcha.tokens = Self.toCString("\(modelDir)/tokens.txt")
        ttsConfig.model.matcha.data_dir = Self.toCString("\(modelDir)/data")
        ttsConfig.model.matcha.length_scale = 1.0 / Float(config.speed ?? 1.0)
      }

      // Rule FSTs for text normalization (optional)
      let ruleFstsPath = "\(modelDir)/rule.fst"
      if FileManager.default.fileExists(atPath: ruleFstsPath) {
        ttsConfig.rule_fsts = Self.toCString(ruleFstsPath)
      }

      self.tts = SherpaOnnxCreateOfflineTts(&ttsConfig)
      guard self.tts != nil else {
        throw NSError(domain: "TTS", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create TTS engine. Check model files in: \(modelDir)"])
      }
    }
  }

  // MARK: - Speak

  func speak(
    text: String,
    onAudioChunk: @escaping (_ samples: ArrayBuffer, _ sampleRate: Double) -> Void,
    onComplete: @escaping () -> Void
  ) throws -> Promise<Void> {
    return Promise.async {
      guard let tts = self.tts else {
        throw NSError(domain: "TTS", code: 2, userInfo: [NSLocalizedDescriptionKey: "Not initialized. Call initialize() first."])
      }

      self.isSpeaking = true

      var genConfig = SherpaOnnxGenerationConfig()
      genConfig.sid = Int32(self.modelConfig?.speakerId ?? 0)
      genConfig.speed = Float(self.modelConfig?.speed ?? 1.0)

      // Use the callback-based generation for streaming
      let callbackContext = TTSCallbackContext(
        onChunk: onAudioChunk,
        onComplete: onComplete,
        sampleRate: Double(SherpaOnnxOfflineTtsSampleRate(tts)),
        isSpeaking: { self.isSpeaking }
      )

      let contextPtr = Unmanaged.passRetained(callbackContext).toOpaque()

      let audio = SherpaOnnxOfflineTtsGenerateWithConfig(
        tts,
        text,
        &genConfig,
        { samplesPtr, count, _, arg in
          guard let arg = arg else { return 0 }
          let ctx = Unmanaged<TTSCallbackContext>.fromOpaque(arg).takeUnretainedValue()

          guard ctx.isSpeaking() else { return 0 } // return 0 to stop generation

          if let samplesPtr = samplesPtr, count > 0 {
            let bufferSize = Int(count) * MemoryLayout<Float>.size
            let buffer = ArrayBuffer.allocate(size: bufferSize)
            memcpy(buffer.data, samplesPtr, bufferSize)
            DispatchQueue.main.async {
              ctx.onChunk(buffer, ctx.sampleRate)
            }
          }
          return 1 // continue generation
        },
        contextPtr
      )

      Unmanaged<TTSCallbackContext>.fromOpaque(contextPtr).release()

      // If we generated audio without streaming callback, send the full result
      if let audio = audio {
        SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio)
      }

      DispatchQueue.main.async {
        onComplete()
      }

      self.isSpeaking = false
    }
  }

  // MARK: - Stop / Destroy

  func stop() throws -> Promise<Void> {
    return Promise.async {
      self.isSpeaking = false
    }
  }

  func destroy() throws -> Promise<Void> {
    return Promise.async {
      self.isSpeaking = false
      if let tts = self.tts {
        SherpaOnnxDestroyOfflineTts(tts)
        self.tts = nil
      }
    }
  }

  // MARK: - Helpers

  private static func toCString(_ string: String) -> UnsafePointer<CChar>? {
    return (string as NSString).utf8String
  }
}

// MARK: - TTS Callback Context

private class TTSCallbackContext {
  let onChunk: (ArrayBuffer, Double) -> Void
  let onComplete: () -> Void
  let sampleRate: Double
  let isSpeaking: () -> Bool

  init(
    onChunk: @escaping (ArrayBuffer, Double) -> Void,
    onComplete: @escaping () -> Void,
    sampleRate: Double,
    isSpeaking: @escaping () -> Bool
  ) {
    self.onChunk = onChunk
    self.onComplete = onComplete
    self.sampleRate = sampleRate
    self.isSpeaking = isSpeaking
  }
}
