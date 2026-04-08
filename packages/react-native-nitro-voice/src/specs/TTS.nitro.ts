import type { HybridObject } from 'react-native-nitro-modules'

export type TTSModelType = 'vits' | 'kokoro' | 'matcha'

export interface TTSConfig {
  modelDir: string
  type: TTSModelType
  speakerId?: number
  speed?: number
}

export interface TTS
  extends HybridObject<{ ios: 'swift'; android: 'kotlin' }> {
  /**
   * Initialize the TTS engine with a model config.
   * Must be called before speak().
   */
  initialize(config: TTSConfig): Promise<void>

  /**
   * Generate speech from text.
   * Calls onAudioChunk with PCM Float32 data as it is generated.
   * Calls onComplete when generation finishes.
   */
  speak(
    text: string,
    onAudioChunk: (samples: ArrayBuffer, sampleRate: number) => void,
    onComplete: () => void
  ): Promise<void>

  /** Stop any in-progress speech generation. */
  stop(): Promise<void>

  /** Release all native resources. The instance cannot be reused after this. */
  destroy(): Promise<void>

  /** The sample rate of the loaded TTS model's output audio. */
  readonly sampleRate: number

  /** The number of speakers supported by the loaded model. */
  readonly numSpeakers: number
}
