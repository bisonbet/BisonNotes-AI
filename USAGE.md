# Audio Journal — Quick Start

Quick links: [Full User Guide](HOW_TO_USE.md) • [Architecture](README.md#architecture) • [Build & Test](README.md#build-and-test)

This short guide covers core app usage. For a comprehensive walkthrough, see HOW_TO_USE.md.

## Record
- Open the app and tap the microphone to start. Tap again to stop.
- Recording continues in the background if enabled in Settings.
- Import audio via the “Import Audio Files” action.

## Transcribe
- Go to Settings → Transcription Settings and pick an engine:
  - Apple (on-device, no setup)
  - Whisper (local server) or Wyoming (streaming)
  - OpenAI or AWS Transcribe (cloud; requires keys)
- Start transcription from a recording; progress shows in place. Engine setup details: see [AI Engines (Setup)](HOW_TO_USE.md#ai-engines-setup).

## Summarize and Extract Tasks
- In Summaries, open a recording to view the AI summary, tasks, and reminders.
- Switch engines in AI Settings to regenerate summaries.

## Watch App
- Install the watchOS companion and open it to control recording.
- The app syncs via WatchConnectivity; it recovers state when the phone becomes reachable.

## Privacy and Keys
- API keys are entered only in the app’s settings screens and stored securely at runtime. Keys are never committed to the repo.

## Troubleshooting
- No audio? Check Microphone permission.
- Cloud errors/timeouts? Verify network and keys or try a local engine.
- Large files? They are chunked and processed in the background; keep the app available.

## Support
- File issues and feature requests on GitHub. Include device, iOS version, and steps to reproduce.
