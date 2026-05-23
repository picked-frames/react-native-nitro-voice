import Foundation
import NitroModules
import OSLog
import AVFoundation

private let ttsLog = Logger(subsystem: "com.nitrovoice", category: "TTS")

class HybridTTS: HybridTTSSpec {

  // MARK: - State

  private var tts: OpaquePointer?
  private var isSpeaking = false
  private var modelConfig: TTSConfig?

  private let processingQueue = DispatchQueue(label: "com.nitrovoice.tts.processing", qos: .userInitiated)

  // Audio playback
  private var audioEngine: AVAudioEngine?
  private var playerNode: AVAudioPlayerNode?
  private var audioFormat: AVAudioFormat?

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
      let fm = FileManager.default

      ttsLog.info("TTS initialize — modelDir: \(modelDir)")
      if let entries = try? fm.contentsOfDirectory(atPath: modelDir) {
        ttsLog.info("modelDir contents: \(entries.joined(separator: ", "))")
      } else {
        ttsLog.error("modelDir does not exist or is unreadable: \(modelDir)")
      }

      let dataDir = ["espeak-ng-data", "data"]
        .map { "\(modelDir)/\($0)" }
        .first(where: { fm.fileExists(atPath: $0) })
      ttsLog.info("espeak data dir: \(dataDir ?? "NOT FOUND")")

      switch config.type {
      case .vits:
        ttsConfig.model.vits.model = Self.toCString("\(modelDir)/model.onnx")
        ttsConfig.model.vits.tokens = Self.toCString("\(modelDir)/tokens.txt")
        if let dataDir = dataDir {
          ttsConfig.model.vits.data_dir = Self.toCString(dataDir)
        }
        ttsConfig.model.vits.length_scale = 1.0 / Float(config.speed ?? 1.0)

        let lexiconPath = "\(modelDir)/lexicon.txt"
        if fm.fileExists(atPath: lexiconPath) {
          ttsConfig.model.vits.lexicon = Self.toCString(lexiconPath)
        }

      case .kokoro:
        ttsConfig.model.kokoro.model = Self.toCString("\(modelDir)/model.onnx")
        ttsConfig.model.kokoro.voices = Self.toCString("\(modelDir)/voices.bin")
        ttsConfig.model.kokoro.tokens = Self.toCString("\(modelDir)/tokens.txt")
        if let dataDir = dataDir {
          ttsConfig.model.kokoro.data_dir = Self.toCString(dataDir)
        }
        ttsConfig.model.kokoro.length_scale = 1.0 / Float(config.speed ?? 1.0)

      case .matcha:
        ttsConfig.model.matcha.acoustic_model = Self.toCString("\(modelDir)/acoustic_model.onnx")
        ttsConfig.model.matcha.vocoder = Self.toCString("\(modelDir)/vocoder.onnx")
        ttsConfig.model.matcha.tokens = Self.toCString("\(modelDir)/tokens.txt")
        if let dataDir = dataDir {
          ttsConfig.model.matcha.data_dir = Self.toCString(dataDir)
        }
        ttsConfig.model.matcha.length_scale = 1.0 / Float(config.speed ?? 1.0)
      }

      let ruleFstsPath = "\(modelDir)/rule.fst"
      if fm.fileExists(atPath: ruleFstsPath) {
        ttsConfig.rule_fsts = Self.toCString(ruleFstsPath)
      }

      self.tts = SherpaOnnxCreateOfflineTts(&ttsConfig)
      guard self.tts != nil else {
        for filename in ["model.onnx", "voices.bin", "tokens.txt"] {
          let path = "\(modelDir)/\(filename)"
          ttsLog.error("\(filename): \(fm.fileExists(atPath: path) ? "EXISTS" : "MISSING") at \(path)")
        }
        if let d = dataDir {
          if let sub = try? fm.contentsOfDirectory(atPath: d) {
            ttsLog.info("data dir has \(sub.count) entries: \(sub.prefix(5).joined(separator: ", "))")
          }
        } else {
          ttsLog.error("no espeak data dir found — tried espeak-ng-data and data")
        }
        throw NSError(domain: "TTS", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create TTS engine. Check model files in: \(modelDir)"])
      }

      let sr = Double(SherpaOnnxOfflineTtsSampleRate(self.tts!))
      ttsLog.info("TTS engine created OK — sampleRate=\(sr)")
      self.setupAudioEngine(sampleRate: sr)
    }
  }

  private func setupAudioEngine(sampleRate: Double) {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, options: [.defaultToSpeaker])
      try session.setActive(true)
    } catch {
      ttsLog.error("Audio session setup failed: \(error)")
    }

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
      ttsLog.error("Failed to create AVAudioFormat for sampleRate=\(sampleRate)")
      return
    }

    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)

    do {
      try engine.start()
      player.play()
    } catch {
      ttsLog.error("AVAudioEngine start failed: \(error)")
      return
    }

    audioEngine = engine
    playerNode = player
    audioFormat = format
    ttsLog.info("AVAudioEngine started — sampleRate=\(sampleRate)")
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

      // Restart player node in case it was stopped by a previous stop() call
      if let player = self.playerNode, !player.isPlaying {
        player.play()
      }

      self.isSpeaking = true

      var genConfig = SherpaOnnxGenerationConfig()
      genConfig.sid = Int32(self.modelConfig?.speakerId ?? 0)
      genConfig.speed = Float(self.modelConfig?.speed ?? 1.0)

      let callbackContext = TTSCallbackContext(
        onChunk: onAudioChunk,
        onComplete: onComplete,
        sampleRate: Double(SherpaOnnxOfflineTtsSampleRate(tts)),
        isSpeaking: { self.isSpeaking },
        playerNode: self.playerNode,
        audioFormat: self.audioFormat
      )

      let contextPtr = Unmanaged.passRetained(callbackContext).toOpaque()

      SherpaOnnxOfflineTtsGenerateWithConfig(
        tts,
        text,
        &genConfig,
        { samplesPtr, count, _, arg in
          guard let arg = arg else { return 0 }
          let ctx = Unmanaged<TTSCallbackContext>.fromOpaque(arg).takeUnretainedValue()

          guard ctx.isSpeaking() else { return 0 }

          if let samplesPtr = samplesPtr, count > 0 {
            let frameCount = Int(count)

            // Schedule for playback
            if let player = ctx.playerNode,
               let format = ctx.audioFormat,
               let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
               let channelData = pcmBuffer.floatChannelData {
              pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
              memcpy(channelData[0], samplesPtr, frameCount * MemoryLayout<Float>.size)
              player.scheduleBuffer(pcmBuffer)
            }

            // JS callback with a copy of the samples
            let bufferSize = frameCount * MemoryLayout<Float>.size
            let buffer = ArrayBuffer.allocate(size: bufferSize)
            memcpy(buffer.data, samplesPtr, bufferSize)
            DispatchQueue.main.async {
              ctx.onChunk(buffer, ctx.sampleRate)
            }
          }
          return 1
        },
        contextPtr
      )

      Unmanaged<TTSCallbackContext>.fromOpaque(contextPtr).release()

      self.isSpeaking = false

      DispatchQueue.main.async {
        onComplete()
      }
    }
  }

  // MARK: - Stop / Destroy

  func stop() throws -> Promise<Void> {
    return Promise.async {
      self.isSpeaking = false
      // Stop and immediately restart so the player is ready for the next speak() call
      self.playerNode?.stop()
      self.playerNode?.play()
    }
  }

  func destroy() throws -> Promise<Void> {
    return Promise.async {
      self.isSpeaking = false
      self.playerNode?.stop()
      self.audioEngine?.stop()
      self.audioEngine = nil
      self.playerNode = nil
      self.audioFormat = nil
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
  let playerNode: AVAudioPlayerNode?
  let audioFormat: AVAudioFormat?

  init(
    onChunk: @escaping (ArrayBuffer, Double) -> Void,
    onComplete: @escaping () -> Void,
    sampleRate: Double,
    isSpeaking: @escaping () -> Bool,
    playerNode: AVAudioPlayerNode?,
    audioFormat: AVAudioFormat?
  ) {
    self.onChunk = onChunk
    self.onComplete = onComplete
    self.sampleRate = sampleRate
    self.isSpeaking = isSpeaking
    self.playerNode = playerNode
    self.audioFormat = audioFormat
  }
}
