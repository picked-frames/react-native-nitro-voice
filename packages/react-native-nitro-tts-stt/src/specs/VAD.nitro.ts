import type { HybridObject } from 'react-native-nitro-modules'

export interface VADConfig {
  modelPath: string
  threshold?: number
  minSilenceDuration?: number
  minSpeechDuration?: number
}

export interface VAD
  extends HybridObject<{ ios: 'swift'; android: 'kotlin' }> {
  /**
   * Initialize the VAD engine with config.
   * Must be called before start/processChunk.
   */
  initialize(config: VADConfig): Promise<void>

  /**
   * Start VAD detection with callbacks.
   * Returns a cleanup function that stops detection when called.
   */
  start(
    onSpeechStart: () => void,
    onSpeechEnd: (audio: ArrayBuffer) => void
  ): () => void

  /**
   * Feed a chunk of PCM audio (16kHz mono Float32) to the VAD.
   * Triggers onSpeechStart / onSpeechEnd callbacks as registered via start().
   */
  processChunk(samples: ArrayBuffer): void

  /** Reset the VAD state, clearing any accumulated audio. */
  reset(): void

  /** Release all native resources. The instance cannot be reused after this. */
  destroy(): void
}
