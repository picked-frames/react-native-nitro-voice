import Foundation
import NitroModules
import AVFoundation

class HybridSTT: HybridSTTSpec {

  // MARK: - State

  private var onlineRecognizer: OpaquePointer?
  private var onlineStream: OpaquePointer?
  private var offlineRecognizer: OpaquePointer?
  private var vad: OpaquePointer?
  private var audioCapture: AudioCapture?
  private var isRunning = false
  private var modelConfig: STTConfig?

  // Callbacks stored for the active session
  private var onPartialCallback: ((String) -> Void)?
  private var onFinalCallback: ((String) -> Void)?
  private var onTranscriptCallback: ((String) -> Void)?

  // Audio processing queue
  private let processingQueue = DispatchQueue(label: "com.nitrovoice.stt.processing", qos: .userInteractive)

  // MARK: - Initialize

  func initialize(config: STTConfig) throws -> Promise<Void> {
    return Promise.async {
      self.modelConfig = config
    }
  }

  // MARK: - Streaming Mode

  func startStreaming(
    onPartial: @escaping (_ text: String) -> Void,
    onFinal: @escaping (_ text: String) -> Void
  ) throws -> Promise<Void> {
    return Promise.async {
      guard let config = self.modelConfig else {
        throw NSError(domain: "STT", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not initialized. Call initialize() first."])
      }

      self.onPartialCallback = onPartial
      self.onFinalCallback = onFinal
      self.isRunning = true

      // Build online recognizer config
      var recognizerConfig = SherpaOnnxOnlineRecognizerConfig()
      recognizerConfig.feat_config.sample_rate = 16000
      recognizerConfig.feat_config.feature_dim = 80
      recognizerConfig.decoding_method = Self.toCString("greedy_search")
      recognizerConfig.enable_endpoint = 1
      recognizerConfig.rule1_min_trailing_silence = 2.4
      recognizerConfig.rule2_min_trailing_silence = 1.2
      recognizerConfig.rule3_min_utterance_length = 20.0
      recognizerConfig.model_config.num_threads = 2
      recognizerConfig.model_config.provider = Self.toCString("cpu")
      recognizerConfig.model_config.debug = 0

      let modelDir = config.modelDir
      let tokensPath = "\(modelDir)/tokens.txt"
      recognizerConfig.model_config.tokens = Self.toCString(tokensPath)

      switch config.type {
      case .transducer:
        recognizerConfig.model_config.transducer.encoder = Self.toCString("\(modelDir)/encoder.onnx")
        recognizerConfig.model_config.transducer.decoder = Self.toCString("\(modelDir)/decoder.onnx")
        recognizerConfig.model_config.transducer.joiner = Self.toCString("\(modelDir)/joiner.onnx")
      case .paraformer:
        recognizerConfig.model_config.paraformer.encoder = Self.toCString("\(modelDir)/encoder.onnx")
        recognizerConfig.model_config.paraformer.decoder = Self.toCString("\(modelDir)/decoder.onnx")
      case .nemoCTC:
        recognizerConfig.model_config.nemo_ctc.model = Self.toCString("\(modelDir)/model.onnx")
      default:
        throw NSError(domain: "STT", code: 2, userInfo: [NSLocalizedDescriptionKey: "Model type '\(config.type)' is not supported for streaming mode. Use transducer, paraformer, or nemo_ctc."])
      }

      self.onlineRecognizer = SherpaOnnxCreateOnlineRecognizer(&recognizerConfig)
      guard let recognizer = self.onlineRecognizer else {
        throw NSError(domain: "STT", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create online recognizer. Check model files."])
      }

      self.onlineStream = SherpaOnnxCreateOnlineStream(recognizer)
      guard self.onlineStream != nil else {
        throw NSError(domain: "STT", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create online stream."])
      }
    }
  }

  // MARK: - VAD-Gated Batch Mode

  func startVADGated(
    vadModelPath: String,
    onTranscript: @escaping (_ text: String) -> Void
  ) throws -> Promise<Void> {
    return Promise.async {
      guard let config = self.modelConfig else {
        throw NSError(domain: "STT", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not initialized. Call initialize() first."])
      }

      self.onTranscriptCallback = onTranscript
      self.isRunning = true

      // Create VAD
      var vadConfig = SherpaOnnxVadModelConfig()
      vadConfig.silero_vad.model = Self.toCString(vadModelPath)
      vadConfig.silero_vad.threshold = 0.5
      vadConfig.silero_vad.min_silence_duration = 0.5
      vadConfig.silero_vad.min_speech_duration = 0.25
      vadConfig.silero_vad.window_size = 512
      vadConfig.sample_rate = 16000
      vadConfig.num_threads = 1
      vadConfig.provider = Self.toCString("cpu")
      vadConfig.debug = 0

      self.vad = SherpaOnnxCreateVoiceActivityDetector(&vadConfig, 30)
      guard self.vad != nil else {
        throw NSError(domain: "STT", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to create VAD. Check model file at: \(vadModelPath)"])
      }

      // Create offline recognizer
      var offlineConfig = SherpaOnnxOfflineRecognizerConfig()
      offlineConfig.feat_config.sample_rate = 16000
      offlineConfig.feat_config.feature_dim = 80
      offlineConfig.decoding_method = Self.toCString("greedy_search")
      offlineConfig.model_config.num_threads = 2
      offlineConfig.model_config.provider = Self.toCString("cpu")
      offlineConfig.model_config.debug = 0

      let modelDir = config.modelDir
      offlineConfig.model_config.tokens = Self.toCString("\(modelDir)/tokens.txt")

      switch config.type {
      case .whisper:
        offlineConfig.model_config.whisper.encoder = Self.toCString("\(modelDir)/encoder.onnx")
        offlineConfig.model_config.whisper.decoder = Self.toCString("\(modelDir)/decoder.onnx")
        if let lang = config.language {
          offlineConfig.model_config.whisper.language = Self.toCString(lang)
        }
        offlineConfig.model_config.whisper.task = Self.toCString("transcribe")
      case .transducer:
        offlineConfig.model_config.transducer.encoder = Self.toCString("\(modelDir)/encoder.onnx")
        offlineConfig.model_config.transducer.decoder = Self.toCString("\(modelDir)/decoder.onnx")
        offlineConfig.model_config.transducer.joiner = Self.toCString("\(modelDir)/joiner.onnx")
      case .paraformer:
        offlineConfig.model_config.paraformer.model = Self.toCString("\(modelDir)/model.onnx")
      case .nemoCTC:
        offlineConfig.model_config.nemo_ctc.model = Self.toCString("\(modelDir)/model.onnx")
      case .senseVoice:
        offlineConfig.model_config.sense_voice.model = Self.toCString("\(modelDir)/model.onnx")
        if let lang = config.language {
          offlineConfig.model_config.sense_voice.language = Self.toCString(lang)
        }
      }

      self.offlineRecognizer = SherpaOnnxCreateOfflineRecognizer(&offlineConfig)
      guard self.offlineRecognizer != nil else {
        throw NSError(domain: "STT", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to create offline recognizer. Check model files."])
      }
    }
  }

  // MARK: - Audio Input

  func feedAudio(samples: ArrayBuffer, sampleRate: Double) throws {
    processingQueue.async { [weak self] in
      guard let self = self, self.isRunning else { return }

      let data = samples.data
      let count = samples.size / MemoryLayout<Float>.size
      let floatPtr = data.assumingMemoryBound(to: Float.self)

      // Resample to 16kHz if needed
      let targetRate: Double = 16000
      if abs(sampleRate - targetRate) < 1.0 {
        self.processAudioChunk(floatPtr, count: count)
      } else {
        let ratio = targetRate / sampleRate
        let outputCount = Int(Double(count) * ratio)
        var resampled = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
          let srcIndex = Double(i) / ratio
          let idx = min(Int(srcIndex), count - 1)
          resampled[i] = floatPtr[idx]
        }
        resampled.withUnsafeBufferPointer { buffer in
          self.processAudioChunk(buffer.baseAddress!, count: outputCount)
        }
      }
    }
  }

  func startMic() throws -> Promise<Void> {
    return Promise.async {
      let capture = AudioCapture()
      capture.onAudioChunk = { [weak self] samples, count in
        self?.processingQueue.async {
          self?.processAudioChunk(samples, count: count)
        }
      }
      try capture.start()
      self.audioCapture = capture
    }
  }

  func stopMic() throws {
    audioCapture?.stop()
    audioCapture = nil
  }

  // MARK: - Stop / Destroy

  func stop() throws -> Promise<Void> {
    return Promise.async {
      self.isRunning = false
      self.onPartialCallback = nil
      self.onFinalCallback = nil
      self.onTranscriptCallback = nil

      if let stream = self.onlineStream, let recognizer = self.onlineRecognizer {
        SherpaOnnxDestroyOnlineStream(stream)
        self.onlineStream = nil
      }
    }
  }

  func destroy() throws -> Promise<Void> {
    return Promise.async {
      self.isRunning = false
      try? self.stopMic()

      if let stream = self.onlineStream {
        SherpaOnnxDestroyOnlineStream(stream)
        self.onlineStream = nil
      }
      if let recognizer = self.onlineRecognizer {
        SherpaOnnxDestroyOnlineRecognizer(recognizer)
        self.onlineRecognizer = nil
      }
      if let recognizer = self.offlineRecognizer {
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
        self.offlineRecognizer = nil
      }
      if let vad = self.vad {
        SherpaOnnxDestroyVoiceActivityDetector(vad)
        self.vad = nil
      }
    }
  }

  // MARK: - Internal Audio Processing

  private func processAudioChunk(_ samples: UnsafePointer<Float>, count: Int) {
    guard isRunning else { return }

    if let stream = onlineStream, let recognizer = onlineRecognizer {
      processStreamingChunk(samples, count: count, stream: stream, recognizer: recognizer)
    } else if let vad = vad {
      processVADChunk(samples, count: count)
    }
  }

  private func processStreamingChunk(
    _ samples: UnsafePointer<Float>,
    count: Int,
    stream: OpaquePointer,
    recognizer: OpaquePointer
  ) {
    SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, samples, Int32(count))

    while SherpaOnnxIsOnlineStreamReady(recognizer, stream) == 1 {
      SherpaOnnxDecodeOnlineStream(recognizer, stream)
    }

    let result = SherpaOnnxGetOnlineStreamResult(recognizer, stream)
    if let result = result {
      let text = String(cString: result.pointee.text)
      if !text.isEmpty {
        DispatchQueue.main.async { [weak self] in
          self?.onPartialCallback?(text)
        }
      }

      if SherpaOnnxOnlineStreamIsEndpoint(recognizer, stream) == 1 {
        if !text.isEmpty {
          DispatchQueue.main.async { [weak self] in
            self?.onFinalCallback?(text)
          }
        }
        SherpaOnnxOnlineStreamReset(recognizer, stream)
      }

      SherpaOnnxDestroyOnlineRecognizerResult(result)
    }
  }

  private func processVADChunk(_ samples: UnsafePointer<Float>, count: Int) {
    guard let vad = vad else { return }

    // Feed audio in window-sized chunks (512 samples for Silero VAD)
    let windowSize = 512
    var offset = 0
    while offset + windowSize <= count {
      SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, samples.advanced(by: offset), Int32(windowSize))
      offset += windowSize

      // Check for completed speech segments
      while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
        let segment = SherpaOnnxVoiceActivityDetectorFront(vad)
        if let segment = segment {
          decodeOfflineSegment(samples: segment.pointee.samples, count: Int(segment.pointee.n))
          SherpaOnnxDestroySpeechSegment(segment)
        }
        SherpaOnnxVoiceActivityDetectorPop(vad)
      }
    }
  }

  private func decodeOfflineSegment(samples: UnsafePointer<Float>?, count: Int) {
    guard let recognizer = offlineRecognizer, let samples = samples, count > 0 else { return }

    let stream = SherpaOnnxCreateOfflineStream(recognizer)
    guard let stream = stream else { return }

    SherpaOnnxAcceptWaveformOffline(stream, 16000, samples, Int32(count))
    SherpaOnnxDecodeOfflineStream(recognizer, stream)

    let result = SherpaOnnxGetOfflineStreamResult(stream)
    if let result = result {
      let text = String(cString: result.pointee.text).trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty {
        DispatchQueue.main.async { [weak self] in
          self?.onTranscriptCallback?(text)
        }
      }
      SherpaOnnxDestroyOfflineRecognizerResult(result)
    }

    SherpaOnnxDestroyOfflineStream(stream)
  }

  // MARK: - Helpers

  private static func toCString(_ string: String) -> UnsafePointer<CChar>? {
    return (string as NSString).utf8String
  }
}
