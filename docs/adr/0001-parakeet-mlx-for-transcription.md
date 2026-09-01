# Parakeet (MLX) for on-device transcription

The app records in-person lectures and transcribes them fully on-device. We chose Parakeet TDT 0.6b v3 running via MLX-Swift over WhisperKit, whisper.cpp, and Apple's Speech framework: the model was already downloaded and preferred by the user, it is the fastest accurate option on Apple Silicon, and macOS 26 is the only target. Consequences: transcription is batch, post-lecture only (no live captions are shown during recording); English-first despite v3's multilingual capability; no speaker diarization.
