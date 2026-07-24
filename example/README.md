# react-native-nitro-voice — example

An [Expo](https://expo.dev) (CNG) app demonstrating fully on-device speech-to-text and text-to-speech with `react-native-nitro-voice`.

## Setup

The example downloads its models at runtime from a bucket. Copy the env sample and set your bucket base URL:

```bash
cp .env.sample .env
# then edit .env and set EXPO_PUBLIC_R2_BASE_URL
```

## Run

Install once from the repo root:

```bash
npm install
```

Then build and launch a dev client (the first iOS build downloads the sherpa-onnx frameworks, ~370 MB):

```bash
npx expo prebuild --clean
npx expo run:ios       # or: npx expo run:android
```

After the first native build, `npm start` gives you fast JS reloads on the dev client.

> Live-mic STT needs a real device (or a simulator with host-mic access). The Android emulator's virtual microphone often returns silence unless "Virtual microphone uses host audio input" is enabled and the emulator has macOS mic permission.
