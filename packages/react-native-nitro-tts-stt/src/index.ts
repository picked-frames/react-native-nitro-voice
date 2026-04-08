import { NitroModules } from 'react-native-nitro-modules'
import type { STT, STTConfig, STTModelType } from './specs/STT.nitro'
import type { TTS, TTSConfig, TTSModelType } from './specs/TTS.nitro'
import type { VAD, VADConfig } from './specs/VAD.nitro'

// Re-export types for consumers
export type { STTConfig, STTModelType, TTSConfig, TTSModelType, VADConfig }

// ─── STT ────────────────────────────────────────────────────────────────────

export interface STTStreamingCallbacks {
  onPartial: (text: string) => void
  onFinal: (text: string) => void
}

export interface STTVADCallbacks {
  onTranscript: (text: string) => void
}

export class NitroSTT {
  private hybrid: STT

  private constructor(hybrid: STT) {
    this.hybrid = hybrid
  }

  static async create(config: STTConfig): Promise<NitroSTT> {
    const hybrid = NitroModules.createHybridObject<STT>('STT')
    await hybrid.initialize(config)
    return new NitroSTT(hybrid)
  }

  async startStreaming(callbacks: STTStreamingCallbacks): Promise<void> {
    return this.hybrid.startStreaming(callbacks.onPartial, callbacks.onFinal)
  }

  async startVADGated(
    vadModelPath: string,
    callbacks: STTVADCallbacks
  ): Promise<void> {
    return this.hybrid.startVADGated(vadModelPath, callbacks.onTranscript)
  }

  feedAudio(samples: ArrayBuffer, sampleRate: number): void {
    this.hybrid.feedAudio(samples, sampleRate)
  }

  async startMic(): Promise<void> {
    return this.hybrid.startMic()
  }

  stopMic(): void {
    this.hybrid.stopMic()
  }

  async stop(): Promise<void> {
    return this.hybrid.stop()
  }

  async destroy(): Promise<void> {
    return this.hybrid.destroy()
  }
}

// ─── TTS ────────────────────────────────────────────────────────────────────

export interface TTSCallbacks {
  onAudioChunk: (samples: ArrayBuffer, sampleRate: number) => void
  onComplete: () => void
}

export class NitroTTS {
  private hybrid: TTS

  private constructor(hybrid: TTS) {
    this.hybrid = hybrid
  }

  static async create(config: TTSConfig): Promise<NitroTTS> {
    const hybrid = NitroModules.createHybridObject<TTS>('TTS')
    await hybrid.initialize(config)
    return new NitroTTS(hybrid)
  }

  async speak(text: string, callbacks: TTSCallbacks): Promise<void> {
    return this.hybrid.speak(
      text,
      callbacks.onAudioChunk,
      callbacks.onComplete
    )
  }

  async stop(): Promise<void> {
    return this.hybrid.stop()
  }

  async destroy(): Promise<void> {
    return this.hybrid.destroy()
  }

  get sampleRate(): number {
    return this.hybrid.sampleRate
  }

  get numSpeakers(): number {
    return this.hybrid.numSpeakers
  }
}

// ─── VAD ────────────────────────────────────────────────────────────────────

export interface VADCallbacks {
  onSpeechStart: () => void
  onSpeechEnd: (audio: ArrayBuffer) => void
}

export class NitroVAD {
  private hybrid: VAD

  private constructor(hybrid: VAD) {
    this.hybrid = hybrid
  }

  static async create(config: VADConfig): Promise<NitroVAD> {
    const hybrid = NitroModules.createHybridObject<VAD>('VAD')
    await hybrid.initialize(config)
    return new NitroVAD(hybrid)
  }

  start(callbacks: VADCallbacks): () => void {
    return this.hybrid.start(callbacks.onSpeechStart, callbacks.onSpeechEnd)
  }

  processChunk(samples: ArrayBuffer): void {
    this.hybrid.processChunk(samples)
  }

  reset(): void {
    this.hybrid.reset()
  }

  destroy(): void {
    this.hybrid.destroy()
  }
}

