# react-native-nitro-voice

Fully offline, on-device **Speech-to-Text** and **Text-to-Speech** for React Native, powered by [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) and [Nitro Modules](https://github.com/mrousavy/nitro).

- All inference runs on-device — no network calls, no cloud dependency
- Models are not bundled — consumers download and manage their own model files
- New Architecture only (Nitro Modules)
- iOS 16.4+, Android API 29+

## Features

| Feature | Description |
|---------|-------------|
| **STT Streaming** | Real-time transcription with partial + final results. Best with transducer/Zipformer models. |
| **STT VAD-gated** | VAD detects end-of-speech, then runs batch inference. Best with Whisper models for conversational AI. |
| **TTS Streaming** | Generate speech from text with streaming PCM output. Supports VITS, Kokoro, Matcha models. |
| **VAD Standalone** | Voice Activity Detection as a standalone utility for custom pipelines. |
| **Mic Capture** | Built-in microphone capture (16kHz mono). Also supports external audio via `feedAudio()`. |

## Installation

```bash
npm install react-native-nitro-voice react-native-nitro-modules
```

### iOS Setup

Add the following line to your app's `ios/Podfile` **inside the target block**, before calling `use_react_native!`:

```ruby
pod 'sherpa-onnx-ios', :path => '../node_modules/react-native-nitro-voice'
```

Then run:

```bash
cd ios && pod install
```

CocoaPods will download the sherpa-onnx XCFrameworks (~370 MB) from the upstream GitHub release automatically on first install. No manual framework management required.

### Android Setup

sherpa-onnx is included as a Gradle dependency automatically.

Add JitPack to your project-level `build.gradle` if not already present:

```groovy
allprojects {
  repositories {
    maven { url 'https://jitpack.io' }
  }
}
```

## Model Directory Structure

Models are **not bundled** with the library. Download models from the [sherpa-onnx model zoo](https://k2-fsa.github.io/sherpa-onnx/) and place them in your app's accessible file system.

### STT Models

| Type | Required Files | Best For |
|------|---------------|----------|
| `whisper` | `encoder.onnx`, `decoder.onnx`, `tokens.txt` | VAD-gated batch mode, high accuracy |
| `transducer` | `encoder.onnx`, `decoder.onnx`, `joiner.onnx`, `tokens.txt` | Streaming mode, real-time captions |
| `paraformer` | `model.onnx`, `tokens.txt` | Streaming or batch, balanced |
| `nemo_ctc` | `model.onnx`, `tokens.txt` | Streaming mode, fast inference |
| `sense_voice` | `model.onnx`, `tokens.txt` | Batch mode, multilingual |

### TTS Models

| Type | Required Files |
|------|---------------|
| `vits` | `model.onnx`, `tokens.txt`, optional: `lexicon.txt`, `data/` |
| `kokoro` | `model.onnx`, `voices.bin`, `tokens.txt`, `data/` |
| `matcha` | `acoustic_model.onnx`, `vocoder.onnx`, `tokens.txt`, optional: `data/` |

### VAD Model

Single file: `silero_vad.onnx` — download from [silero-vad releases](https://github.com/snakers4/silero-vad/releases)

### Downloading Models

Because models aren't bundled, your app fetches them at runtime, stores them in a writable directory on-device (e.g. `RNFS.DocumentDirectoryPath`), and passes those local paths to `NitroSTT.create`, `NitroTTS.create`, and `startVADGated`. There's no prescribed transport — obtain the model files from the [sherpa-onnx model zoo](https://k2-fsa.github.io/sherpa-onnx/), host them wherever you like, and download them on first launch.

The [example app](https://github.com/picked-frames/react-native-nitro-voice/blob/main/example/App.tsx) is a complete, working reference for this. On launch it checks whether the files already exist with `RNFS.exists`; if not, it downloads each one — streaming large `.onnx` files to disk with [`react-native-fs`](https://github.com/itinance/react-native-fs)' `downloadFile` (with a progress callback), pulling tiny text files like `tokens.txt` via a lightweight fetch, and unzipping any archives (such as Kokoro's espeak data) with [`react-native-zip-archive`](https://github.com/mockingbot/react-native-zip-archive) — then points the STT/TTS/VAD configs at the resulting directories. It serves the files from a Cloudflare R2 bucket (base URL injected via `example/.env`), and surfaces per-file progress plus a retry path in the UI. See the `MODELS_DIR` constants and the `downloadModelFile` / `checkModelsReady` helpers there for the specifics.

## Expo (config plugin)

If you use Expo with CNG (`expo prebuild`), you don't need the manual iOS Podfile, Android Gradle, or permission edits — this package ships an Expo config plugin that applies them for you. Add it to your `app.json`:

```json
{
  "expo": {
    "plugins": [
      [
        "react-native-nitro-voice",
        { "microphonePermission": "Used for on-device speech recognition. Your audio never leaves your device." }
      ]
    ]
  }
}
```

The plugin:

- adds the `sherpa-onnx-ios` CocoaPod to your Podfile (iOS),
- adds the JitPack Maven repository (Android),
- adds the microphone permission — `NSMicrophoneUsageDescription` (iOS; message configurable via the `microphonePermission` prop) and `RECORD_AUDIO` (Android).

The plugin intentionally does **not** set the iOS deployment target or Android `minSdkVersion`. This library targets **iOS 16.4+** and **Android API 29+** — the React Native 0.86 / Expo SDK 57 baseline. Expo already enforces the iOS floor for you, so in practice you only need to raise Android's `minSdkVersion` via `expo-build-properties`:

```json
[
  "expo-build-properties",
  {
    "android": { "minSdkVersion": 29 }
  }
]
```

Then run `npx expo prebuild --clean` and build a dev client. The first iOS `pod install` downloads the sherpa-onnx frameworks (~370 MB).

## Permissions

> Skip this section if you use the Expo config plugin above — it adds these for you.

### iOS

Add microphone usage description to your `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Used for speech recognition</string>
```

### Android

Add the `RECORD_AUDIO` permission to your `AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
```

You must also request the permission at runtime before calling `startMic()` or using the default mic-enabled mode. Use `PermissionsAndroid` from React Native or a library like `react-native-permissions`.

## Usage

### Speech-to-Text (VAD-gated Whisper — recommended for conversational AI)

```typescript
import { NitroSTT } from 'react-native-nitro-voice';

const stt = await NitroSTT.create({
  modelDir: '/path/to/whisper-model',
  type: 'whisper',
  language: 'en',
});

// Start VAD-gated batch recognition (mic starts automatically)
await stt.startVADGated('/path/to/silero_vad.onnx', {
  onTranscript: (text) => {
    console.log('Transcript:', text);
  },
});

// ... user speaks, pauses → clean transcript per utterance

// Stop (mic stops automatically)
await stt.stop();
await stt.destroy();
```

### Speech-to-Text (Streaming — real-time captions)

```typescript
import { NitroSTT } from 'react-native-nitro-voice';

const stt = await NitroSTT.create({
  modelDir: '/path/to/transducer-model',
  type: 'transducer',
});

await stt.startStreaming({
  onPartial: (text) => console.log('Partial:', text),
  onFinal: (text) => console.log('Final:', text),
});

// Mic starts automatically — stop with:
await stt.stop();
```

### Speech-to-Text (External audio source)

```typescript
const stt = await NitroSTT.create(config);

// Disable automatic mic — feed audio manually
await stt.startStreaming(callbacks, { mic: false });

// Feed pre-recorded or streamed audio
// Accepts any sample rate — resampled to 16kHz internally
stt.feedAudio(pcmArrayBuffer, 44100);
```

### Text-to-Speech

```typescript
import { NitroTTS } from 'react-native-nitro-voice';

const tts = await NitroTTS.create({
  modelDir: '/path/to/kokoro-model',
  type: 'kokoro',
  speed: 1.0,
  speakerId: 0,
});

console.log(`Sample rate: ${tts.sampleRate}, Speakers: ${tts.numSpeakers}`);

await tts.speak('Hello, world!', {
  onAudioChunk: (samples, sampleRate) => {
    // Feed PCM Float32 to your audio player
    // e.g. expo-av, react-native-audio-api
  },
  onComplete: () => {
    console.log('Done speaking');
  },
});

await tts.destroy();
```

### VAD Standalone

```typescript
import { NitroVAD } from 'react-native-nitro-voice';

const vad = await NitroVAD.create({
  modelPath: '/path/to/silero_vad.onnx',
  threshold: 0.5,
  minSilenceDuration: 0.5,
  minSpeechDuration: 0.25,
});

const cleanup = vad.start({
  onSpeechStart: () => console.log('Speech started'),
  onSpeechEnd: (audio) => {
    console.log(`Speech ended, ${audio.byteLength} bytes of audio`);
  },
});

// Feed 16kHz mono Float32 PCM chunks
vad.processChunk(audioChunk);

// Stop
cleanup();
vad.destroy();
```

## Mode Selection Guide

| Use Case | Mode | Model Type | Why |
|----------|------|-----------|-----|
| Conversational AI | VAD-gated | Whisper | Clean utterance boundaries, high accuracy |
| Live captions | Streaming | Transducer/Zipformer | Low latency, partial results |
| Voice commands | VAD-gated | Paraformer | Fast batch inference |
| Dictation | Streaming | Transducer | Real-time feedback |
| Multilingual | VAD-gated | SenseVoice | Multi-language support |

## API Reference

### `NitroSTT`

| Method | Description |
|--------|-------------|
| `NitroSTT.create(config: STTConfig)` | Factory — creates and initializes STT engine |
| `startStreaming(callbacks, options?)` | Start streaming recognition with `onPartial`/`onFinal`. Starts mic by default. |
| `startVADGated(vadModelPath, callbacks, options?)` | Start VAD-gated batch recognition with `onTranscript`. Starts mic by default. |
| `feedAudio(samples, sampleRate)` | Feed external audio (any sample rate, resampled internally) |
| `startMic()` | Manually start device microphone (for advanced use) |
| `stopMic()` | Manually stop microphone capture |
| `stop()` | Stop current recognition session (stops mic if active) |
| `destroy()` | Release all native resources |

### `NitroTTS`

| Method | Description |
|--------|-------------|
| `NitroTTS.create(config: TTSConfig)` | Factory — creates and initializes TTS engine |
| `speak(text, callbacks)` | Generate speech with streaming `onAudioChunk`/`onComplete` |
| `stop()` | Cancel in-progress generation |
| `destroy()` | Release all native resources |
| `sampleRate` | Output sample rate of loaded model |
| `numSpeakers` | Number of speakers in loaded model |

### `NitroVAD`

| Method | Description |
|--------|-------------|
| `NitroVAD.create(config: VADConfig)` | Factory — creates and initializes VAD |
| `start(callbacks)` | Register `onSpeechStart`/`onSpeechEnd` callbacks. Returns cleanup function. |
| `processChunk(samples)` | Feed 16kHz mono Float32 PCM audio |
| `reset()` | Clear accumulated audio state |
| `destroy()` | Release all native resources |

## Types

```typescript
type STTModelType = 'whisper' | 'transducer' | 'paraformer' | 'nemo_ctc' | 'sense_voice'

interface STTConfig {
  modelDir: string       // Path to directory containing model files
  type: STTModelType
  language?: string      // e.g. 'en', 'fr', 'zh' — required for Whisper
}

type TTSModelType = 'vits' | 'kokoro' | 'matcha'

interface TTSConfig {
  modelDir: string       // Path to directory containing model files
  type: TTSModelType
  speakerId?: number     // Speaker index for multi-speaker models (default: 0)
  speed?: number         // Playback speed multiplier (default: 1.0)
}

interface VADConfig {
  modelPath: string      // Path to silero_vad.onnx
  threshold?: number     // Speech detection threshold (default: 0.5)
  minSilenceDuration?: number  // Seconds of silence to end speech (default: 0.5)
  minSpeechDuration?: number   // Minimum seconds to count as speech (default: 0.25)
}

interface STTOptions {
  mic?: boolean          // Start microphone automatically (default: true)
}
```

## Example App

The `example/` directory contains a demo app showing:
- VAD-gated Whisper STT with microphone input
- Kokoro TTS with text input

The example app downloads its models from an R2 bucket. Before running, copy `example/.env.sample` to `example/.env` and set the bucket base URL:

```
R2_BASE_URL=https://pub-28d1fdcf7fc645feb5a92306699262f7 DOT r2 DOT dev
```

To run:

```bash
# Install deps
npm install

cd example

npm run ios
# or
npm run android
```

## License

MIT
