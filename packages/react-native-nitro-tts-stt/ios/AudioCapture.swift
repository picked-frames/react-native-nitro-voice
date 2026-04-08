import Foundation
import AVFoundation

class AudioCapture {

  var onAudioChunk: ((_ samples: UnsafePointer<Float>, _ count: Int) -> Void)?

  private var audioEngine: AVAudioEngine?
  private let targetSampleRate: Double = 16000

  func start() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
    try session.setActive(true)

    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)

    // Target format: 16kHz mono Float32
    guard let targetFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: targetSampleRate,
      channels: 1,
      interleaved: false
    ) else {
      throw NSError(domain: "AudioCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create target audio format"])
    }

    // Install a converter if sample rates differ
    guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
      throw NSError(domain: "AudioCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter from \(inputFormat.sampleRate)Hz to \(targetSampleRate)Hz"])
    }

    let bufferSize: AVAudioFrameCount = 1024

    inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
      guard let self = self else { return }

      if abs(inputFormat.sampleRate - self.targetSampleRate) < 1.0 && inputFormat.channelCount == 1 {
        // Already at target format, pass through
        if let channelData = buffer.floatChannelData {
          self.onAudioChunk?(channelData[0], Int(buffer.frameLength))
        }
      } else {
        // Resample
        let frameCapacity = AVAudioFrameCount(
          Double(buffer.frameLength) * self.targetSampleRate / inputFormat.sampleRate
        )
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
          return
        }

        var error: NSError?
        let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
          outStatus.pointee = .haveData
          return buffer
        }

        if status == .haveData, let channelData = convertedBuffer.floatChannelData {
          self.onAudioChunk?(channelData[0], Int(convertedBuffer.frameLength))
        }
      }
    }

    engine.prepare()
    try engine.start()
    self.audioEngine = engine
  }

  func stop() {
    audioEngine?.inputNode.removeTap(onBus: 0)
    audioEngine?.stop()
    audioEngine = nil

    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  deinit {
    stop()
  }
}
