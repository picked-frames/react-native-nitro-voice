import Foundation
import NitroModules

class HybridVAD: HybridVADSpec {

  // MARK: - State

  private var vad: OpaquePointer?
  private var onSpeechStartCallback: (() -> Void)?
  private var onSpeechEndCallback: ((ArrayBuffer) -> Void)?
  private var wasSpeaking = false

  private let processingQueue = DispatchQueue(label: "com.nitrottsstt.vad.processing", qos: .userInteractive)

  // MARK: - Initialize

  func initialize(config: VADConfig) throws -> Promise<Void> {
    return Promise.async {
      var vadConfig = SherpaOnnxVadModelConfig()
      vadConfig.silero_vad.model = Self.toCString(config.modelPath)
      vadConfig.silero_vad.threshold = Float(config.threshold ?? 0.5)
      vadConfig.silero_vad.min_silence_duration = Float(config.minSilenceDuration ?? 0.5)
      vadConfig.silero_vad.min_speech_duration = Float(config.minSpeechDuration ?? 0.25)
      vadConfig.silero_vad.window_size = 512
      vadConfig.sample_rate = 16000
      vadConfig.num_threads = 1
      vadConfig.provider = Self.toCString("cpu")
      vadConfig.debug = 0

      self.vad = SherpaOnnxCreateVoiceActivityDetector(&vadConfig, 30)
      guard self.vad != nil else {
        throw NSError(domain: "VAD", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create VAD. Check model file at: \(config.modelPath)"])
      }
    }
  }

  // MARK: - Start

  func start(
    onSpeechStart: @escaping () -> Void,
    onSpeechEnd: @escaping (_ audio: ArrayBuffer) -> Void
  ) throws -> () -> Void {
    self.onSpeechStartCallback = onSpeechStart
    self.onSpeechEndCallback = onSpeechEnd
    self.wasSpeaking = false

    return { [weak self] in
      self?.onSpeechStartCallback = nil
      self?.onSpeechEndCallback = nil
    }
  }

  // MARK: - Process Chunk

  func processChunk(samples: ArrayBuffer) throws {
    processingQueue.async { [weak self] in
      guard let self = self, let vad = self.vad else { return }

      let data = samples.data
      let count = samples.size / MemoryLayout<Float>.size
      let floatPtr = data.assumingMemoryBound(to: Float.self)

      // Feed audio in window-sized chunks (512 samples for Silero VAD)
      let windowSize = 512
      var offset = 0
      while offset + windowSize <= count {
        SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, floatPtr.advanced(by: offset), Int32(windowSize))
        offset += windowSize

        let isSpeaking = SherpaOnnxVoiceActivityDetectorDetected(vad) == 1

        // Detect speech start
        if isSpeaking && !self.wasSpeaking {
          self.wasSpeaking = true
          DispatchQueue.main.async { [weak self] in
            self?.onSpeechStartCallback?()
          }
        }

        // Check for completed speech segments
        while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
          let segment = SherpaOnnxVoiceActivityDetectorFront(vad)
          if let segment = segment {
            let segmentCount = Int(segment.pointee.n)
            if segmentCount > 0, let segmentSamples = segment.pointee.samples {
              let bufferSize = segmentCount * MemoryLayout<Float>.size
              let buffer = ArrayBuffer.allocate(size: bufferSize)
              memcpy(buffer.data, segmentSamples, bufferSize)
              DispatchQueue.main.async { [weak self] in
                self?.onSpeechEndCallback?(buffer)
              }
            }
            SherpaOnnxDestroySpeechSegment(segment)
          }
          SherpaOnnxVoiceActivityDetectorPop(vad)
          self.wasSpeaking = false
        }
      }
    }
  }

  // MARK: - Reset / Destroy

  func reset() throws {
    if let vad = vad {
      SherpaOnnxVoiceActivityDetectorReset(vad)
    }
    wasSpeaking = false
  }

  func destroy() throws {
    onSpeechStartCallback = nil
    onSpeechEndCallback = nil
    if let vad = vad {
      SherpaOnnxDestroyVoiceActivityDetector(vad)
      self.vad = nil
    }
  }

  // MARK: - Helpers

  private static func toCString(_ string: String) -> UnsafePointer<CChar>? {
    return (string as NSString).utf8String
  }
}
