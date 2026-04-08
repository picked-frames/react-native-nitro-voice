import type { HybridObject } from 'react-native-nitro-modules'

export type STTModelType =
  | 'whisper'
  | 'transducer'
  | 'paraformer'
  | 'nemo_ctc'
  | 'sense_voice'

export interface STTConfig {
  modelDir: string
  type: STTModelType
  language?: string
}

export interface STT
  extends HybridObject<{ ios: 'swift'; android: 'kotlin' }> {
  /**
   * Initialize the STT engine with a model config.
   * Must be called before start/feedAudio.
   */
  initialize(config: STTConfig): Promise<void>

  /**
   * Start streaming recognition.
   * Emits partial results as recognition progresses and final results at endpoints.
   * Requires a streaming-capable model (transducer, paraformer, nemo_ctc).
   */
  startStreaming(
    onPartial: (text: string) => void,
    onFinal: (text: string) => void
  ): Promise<void>

  /**
   * Start VAD-gated batch recognition.
   * Accumulates audio until VAD detects end-of-speech, then runs batch inference.
   * Best paired with Whisper models.
   */
  startVADGated(
    vadModelPath: string,
    onTranscript: (text: string) => void
  ): Promise<void>

  /**
   * Feed raw audio samples from an external source.
   * Samples should be PCM — the library resamples to 16kHz mono internally.
   */
  feedAudio(samples: ArrayBuffer, sampleRate: number): void

  /**
   * Start capturing audio from the device microphone.
   * Audio is fed internally to the active recognition mode.
   */
  startMic(): Promise<void>

  /** Stop the device microphone capture. */
  stopMic(): void

  /** Stop the current recognition session (streaming or VAD-gated). */
  stop(): Promise<void>

  /** Release all native resources. The instance cannot be reused after this. */
  destroy(): Promise<void>
}
