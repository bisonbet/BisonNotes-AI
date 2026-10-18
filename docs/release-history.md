# Release history

Highlights by release. Current usage is in [features](features.md), and each
release's complete user guide is in [user-guide](user-guide/README.md).

## 3.0

- **Beta Features page**: a master switch plus one opt-in per feature, on its own
  page in Settings (the Beta tab on Mac).
- **Summary Prompt (beta)**: an editable prompt library with Business Meeting,
  Personal Notes, and up to five custom prompts. Each summary remembers its
  prompt.
- **Transcript Cleanup moves to Beta**: existing users keep it on. The version
  you save, Original or Cleaned, is now what summaries use.
- **Nemotron 3 speaker labels (experimental)**: NVIDIA's streaming diarization
  model on the Neural Engine, for up to 8 speakers. FluidAudio is updated to
  0.17.
- **Trim Recording**: save a start and end clip as a new recording.
- **Reliability hardening**: work that runs after a save can no longer make the
  app treat a saved result as failed. Before this, that could bill an AI
  provider twice for one summary or rerun a finished transcription. Also
  covers audio-session ownership, iCloud placeholders, and faster sync startup.

## 2.5

- On-device English transcript cleanup with S1-mini by Superwhisper. The
  original transcript is always kept.
- Deletions that survive a crash, better handling when storage is nearly full,
  and cache maintenance.
- Advanced Troubleshooting cleanup, and fixes for restoring and downloading
  recordings.

## 2.4

- **Faster iCloud sync**: a routine pass now reads everything in a couple of
  batched requests instead of minutes of per-record calls. CloudKit's
  retry-after requests are honored, and long waits are deferred instead of
  blocking the app.
- Two devices syncing at once no longer erase each other's index entries. Sync
  operations run one at a time and report when a request joined a run already
  in progress.
- Recording metadata syncs without waiting for audio uploads.
- **Interruption recovery**: a phone call now triggers one coordinated recovery
  instead of several competing ones. An unexpected background stop keeps the
  completed segment.
- **Mac meeting capture**: falls back to another microphone automatically and
  keeps system audio when the microphone can't start.
- **Cache maintenance**: model download blobs are released once a model is
  installed (a 7.9 GB model had been using 15.8 GB). CloudKit asset copies and
  the error log are now bounded.
- Sharded models are reported as installed only when every shard is present.
- Deleted imported transcripts no longer come back, and regenerating a summary
  can no longer leave local rows behind.
- In-app Help opens the guide for the installed version.

## 2.3

- **Native macOS app**, replacing Mac Catalyst while keeping the same bundle,
  data, and iCloud container. Adds native windows, Settings, menus and
  shortcuts, RTF/PDF export, a Share extension, and desktop widgets.
- Mac recording with selectable inputs and ScreenCaptureKit meeting audio,
  device-change recovery, and a guided permission flow.
- Ternary Bonsai 27B on Macs with 16 GB or more of RAM.
- Local Speaker Labels for completed Parakeet transcripts (Offline VBx and
  LS-EEND).
- Summary Detail (Brief, Balanced, Detailed) and Thinking (Off, Light) controls
  across engines.
- AWS Bedrock/Transcribe and the embedded llama.cpp engine removed; existing
  selections migrate. Ollama is Mac only, and llama.cpp servers still work
  through Compatible API.
- Import From Link for audio, video, transcript documents, and YouTube
  captions, with hardened downloads.
- VoiceOver labels, values, and hints across iPhone, iPad, Mac, and Apple Watch,
  an adjustable playback scrubber, Reduce Motion support, and accessibility
  audit tests.

## 2.1

- iCloud sync safeguards: the HIPAA notice, **Keep on This Device**, deletion
  markers, and review of older cloud-only items.
- More reliable Parakeet model recovery, and a choice of English v2 or
  multilingual v3.
- Safer audio-session ownership, crash-safe recording recovery, and test plans
  for releases.

## 2.0

- Redesigned SwiftUI interface.
- A new Apple Watch recorder: tap to record, tap to stop, mute to pause.
- On Device AI moves to MLX Swift with Ternary Bonsai models, and older GGUF
  files are cleaned up.
- The watch records on its own and sends complete files to the phone.

## Earlier

- **1.11**: API keys move to the Keychain, file protection is added, cleartext
  endpoints are blocked, and transcript and summary actions move onto the
  items they act on.
- **1.8**: WhisperKit is replaced by Parakeet, and existing users migrate
  automatically.
