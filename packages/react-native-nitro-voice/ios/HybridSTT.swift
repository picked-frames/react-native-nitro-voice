import Foundation
import NitroModules
import AVFoundation
import OSLog

private let sttLog = Logger(subsystem: "com.nitrovoice", category: "STT")

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

  // Accumulates resampled 16kHz samples until we have a full VAD window (512 samples)
  private var vadBuffer: [Float] = []

  // Throttle audio-chunk logs to once per second
  private var lastAudioLogTime: Date = .distantPast
  private var chunksSinceLastLog = 0

  // MARK: - Initialize

  func initialize(config: STTConfig) throws -> Promise<Void> {
    return Promise.async {
      sttLog.info("initialize — modelDir: \(config.modelDir), type: \(String(describing: config.type))")
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
      recognizerConfig.model_config.tokens = Self.toCString("\(modelDir)/tokens.txt")

      switch config.type {
      case .transducer:
        recognizerConfig.model_config.transducer.encoder = Self.toCString("\(modelDir)/encoder.onnx")
        recognizerConfig.model_config.transducer.decoder = Self.toCString("\(modelDir)/decoder.onnx")
        recognizerConfig.model_config.transducer.joiner = Self.toCString("\(modelDir)/joiner.onnx")
      case .paraformer:
        recognizerConfig.model_config.paraformer.encoder = Self.toCString("\(modelDir)/encoder.onnx")
        recognizerConfig.model_config.paraformer.decoder = Self.toCString("\(modelDir)/decoder.onnx")
      case .nemoCtc:
        recognizerConfig.model_config.nemo_ctc.model = Self.toCString("\(modelDir)/model.onnx")
      default:
        throw NSError(domain: "STT", code: 2, userInfo: [NSLocalizedDescriptionKey: "Model type '\(config.type)' is not supported for streaming mode."])
      }

      self.onlineRecognizer = SherpaOnnxCreateOnlineRecognizer(&recognizerConfig)
      guard let recognizer = self.onlineRecognizer else {
        throw NSError(domain: "STT", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create online recognizer."])
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

      sttLog.info("startVADGated — vadModelPath: \(vadModelPath)")

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
        throw NSError(domain: "STT", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to create VAD at: \(vadModelPath)"])
      }
      sttLog.info("VAD created OK")

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
      case .nemoCtc:
        offlineConfig.model_config.nemo_ctc.model = Self.toCString("\(modelDir)/model.onnx")
      case .senseVoice:
        offlineConfig.model_config.sense_voice.model = Self.toCString("\(modelDir)/model.onnx")
        if let lang = config.language {
          offlineConfig.model_config.sense_voice.language = Self.toCString(lang)
        }
      }

      self.offlineRecognizer = SherpaOnnxCreateOfflineRecognizer(&offlineConfig)
      guard self.offlineRecognizer != nil else {
        throw NSError(domain: "STT", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to create offline recognizer. Check model files in: \(modelDir)"])
      }
      sttLog.info("offline recognizer created OK")
    }
  }

  // MARK: - Audio Input

  func feedAudio(samples: ArrayBuffer, sampleRate: Double) throws {
    processingQueue.async { [weak self] in
      guard let self = self, self.isRunning else { return }

      let data = samples.data
      let count = samples.size / MemoryLayout<Float>.size
      let floatPtr = UnsafeRawPointer(data).assumingMemoryBound(to: Float.self)

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
      sttLog.info("startMic — creating AudioCapture")
      let capture = AudioCapture()
      capture.onAudioChunk = { [weak self] samples, count in
        self?.processingQueue.async {
          self?.processAudioChunk(samples, count: count)
        }
      }
      try capture.start()
      self.audioCapture = capture
      sttLog.info("AudioCapture started OK")
    }
  }

  func stopMic() throws {
    sttLog.debug("stopMic")
    audioCapture?.stop()
    audioCapture = nil
  }

  // MARK: - Stop / Destroy

  func stop() throws -> Promise<Void> {
    return Promise.async {
      sttLog.debug("stop")
      self.isRunning = false
      self.onPartialCallback = nil
      self.onFinalCallback = nil
      self.onTranscriptCallback = nil
      self.vadBuffer.removeAll()

      if let stream = self.onlineStream {
        SherpaOnnxDestroyOnlineStream(stream)
        self.onlineStream = nil
      }
    }
  }

  func destroy() throws -> Promise<Void> {
    return Promise.async {
      sttLog.debug("destroy")
      self.isRunning = false
      self.vadBuffer.removeAll()
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

    // Log once per second so we can confirm audio is flowing
    chunksSinceLastLog += 1
    let now = Date()
    if now.timeIntervalSince(lastAudioLogTime) >= 1.0 {
      sttLog.info("audio flowing — \(self.chunksSinceLastLog) chunks/s, count=\(count), vadBuf=\(self.vadBuffer.count)")
      chunksSinceLastLog = 0
      lastAudioLogTime = now
    }

    if let stream = onlineStream, let recognizer = onlineRecognizer {
      processStreamingChunk(samples, count: count, stream: stream, recognizer: recognizer)
    } else if vad != nil {
      processVADChunk(samples, count: count)
    } else {
      sttLog.warning("processAudioChunk called but no stream or VAD configured")
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

    // Accumulate incoming samples — AudioCapture delivers ~341 frames after resampling
    // from the device's 48 kHz native rate, which is less than Silero VAD's required 512.
    vadBuffer.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))

    let windowSize = 512
    while vadBuffer.count >= windowSize {
      vadBuffer.withUnsafeBufferPointer { buf in
        SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, buf.baseAddress!, Int32(windowSize))
      }
      vadBuffer.removeFirst(windowSize)

      while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
        sttLog.info("VAD: speech segment ready")
        let segment = SherpaOnnxVoiceActivityDetectorFront(vad)
        if let segment = segment {
          sttLog.info("VAD segment: \(segment.pointee.n) samples")
          decodeOfflineSegment(samples: segment.pointee.samples, count: Int(segment.pointee.n))
          SherpaOnnxDestroySpeechSegment(segment)
        }
        SherpaOnnxVoiceActivityDetectorPop(vad)
      }
    }
  }

  private func decodeOfflineSegment(samples: UnsafePointer<Float>?, count: Int) {
    guard let recognizer = offlineRecognizer, let samples = samples, count > 0 else {
      sttLog.warning("decodeOfflineSegment skipped — recognizer=\(self.offlineRecognizer == nil ? "nil" : "ok"), count=\(count)")
      return
    }

    sttLog.info("decodeOfflineSegment — \(count) samples (\(String(format: "%.2f", Double(count) / 16000.0))s)")

    let stream = SherpaOnnxCreateOfflineStream(recognizer)
    guard let stream = stream else {
      sttLog.error("decodeOfflineSegment — failed to create offline stream")
      return
    }

    SherpaOnnxAcceptWaveformOffline(stream, 16000, samples, Int32(count))
    SherpaOnnxDecodeOfflineStream(recognizer, stream)

    let result = SherpaOnnxGetOfflineStreamResult(stream)
    if let result = result {
      let text = String(cString: result.pointee.text).trimmingCharacters(in: .whitespacesAndNewlines)
      sttLog.info("transcript: '\(text)'")
      if !text.isEmpty {
        DispatchQueue.main.async { [weak self] in
          self?.onTranscriptCallback?(text)
        }
      }
      SherpaOnnxDestroyOfflineRecognizerResult(result)
    } else {
      sttLog.warning("decodeOfflineSegment — no result returned from recognizer")
    }

    SherpaOnnxDestroyOfflineStream(stream)
  }

  // MARK: - Helpers

  private static func toCString(_ string: String) -> UnsafePointer<CChar>? {
    return (string as NSString).utf8String
  }
}
